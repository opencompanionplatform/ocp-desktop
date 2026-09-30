//! Live Voice Realtime V2 diagnostic for Gemini Live transcription.
//!
//! Reads a local PCM16 WAV, converts it to mono 16 kHz, sends it through the
//! exact `gemini_asr` transport used by Kernel, and prints provider timing plus
//! interim/final transcript text. The API key is loaded from the same sources
//! as production (env first, then OS keystore) and is never logged.
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example gemini_asr_live -- gemini_thai.wav

use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use ocp_llm_router::providers::gemini_asr::{
    start_live_asr, GeminiAsrEvent, LIVE_TRANSCRIBE_MODEL, LIVE_TRANSCRIBE_SAMPLE_RATE,
};
use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";
const READY_TIMEOUT: Duration = Duration::from_secs(10);
const FINAL_TIMEOUT: Duration = Duration::from_secs(12);
const FRAME_MS: u64 = 20;
const MODEL_URL: &str =
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe-live";

fn main() {
    let wav_path = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("gemini_thai.wav"));
    let (samples, source_rate) = match read_pcm16_wav(&wav_path) {
        Ok(value) => value,
        Err(error) => fail(&format!("WAV input failed: {error}")),
    };
    let pcm16 = resample_mono_pcm16(&samples, source_rate, LIVE_TRANSCRIBE_SAMPLE_RATE);
    if pcm16.is_empty() {
        fail("WAV input produced no 16 kHz samples");
    }

    let (key, source) = match std::env::var("GEMINI_API_KEY").ok() {
        Some(key) if !key.trim().is_empty() => (Some(key), "env:GEMINI_API_KEY"),
        _ => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get("gemini-cloud"),
            "OS keystore:gemini-cloud",
        ),
    };
    let Some(key) = key else {
        fail("No Gemini credential found. Set GEMINI_API_KEY or store gemini-cloud in the OCP OS keystore.");
    };

    println!("credential source: {source}");
    let model_status = probe_model_access(&key);
    println!("model REST access: HTTP {model_status}");
    if model_status != 200 {
        fail("Gemini credential/model access probe failed before WebSocket setup");
    }
    println!("model: {LIVE_TRANSCRIBE_MODEL}");
    println!("input: {}", wav_path.display());
    println!("source rate: {source_rate} Hz");
    println!("asr rate: {LIVE_TRANSCRIBE_SAMPLE_RATE} Hz");
    println!(
        "audio duration: {:.2} s",
        pcm16.len() as f64 / LIVE_TRANSCRIBE_SAMPLE_RATE as f64
    );

    let started = Instant::now();
    let (control, events) = match start_live_asr(key, vec!["th-TH".to_owned(), "en-US".to_owned()])
    {
        Ok(session) => session,
        Err(error) => fail(&format!("ASR session start failed: {error}")),
    };

    if !wait_ready(&events, started) {
        let _ = control.close();
        events.join();
        fail("Gemini ASR did not become ready before timeout");
    }
    let ready_ms = started.elapsed().as_millis();
    println!("ready: {ready_ms} ms");

    if !control.activity_start() {
        fail("ASR activityStart was not accepted");
    }
    let frame_samples = (LIVE_TRANSCRIBE_SAMPLE_RATE as usize * FRAME_MS as usize) / 1000;
    let audio_started = Instant::now();
    for frame in pcm16.chunks(frame_samples) {
        let mut bytes = Vec::with_capacity(frame.len() * 2);
        for &sample in frame {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        if !control.send_pcm16(bytes) {
            fail("ASR audio frame was not accepted");
        }
        thread::sleep(Duration::from_millis(FRAME_MS));
    }
    if !control.activity_end() {
        fail("ASR activityEnd was not accepted");
    }
    println!("audio sent: {} ms", audio_started.elapsed().as_millis());

    let final_started = Instant::now();
    let mut finals = Vec::<String>::new();
    let mut first_transcript_ms = None;
    while final_started.elapsed() < FINAL_TIMEOUT {
        if let Some(event) = events.try_recv() {
            match event {
                GeminiAsrEvent::Interim(text) => {
                    first_transcript_ms.get_or_insert_with(|| started.elapsed().as_millis());
                    println!("interim: {text}");
                }
                GeminiAsrEvent::Final(text) => {
                    first_transcript_ms.get_or_insert_with(|| started.elapsed().as_millis());
                    println!("final: {text}");
                    if finals.last().is_none_or(|last| last != &text) {
                        finals.push(text);
                    }
                    // inputTranscription is the finalized utterance for Live
                    // Transcription. Do not inflate latency by waiting for an
                    // optional turnComplete event after Final.
                    break;
                }
                GeminiAsrEvent::TurnComplete => break,
                GeminiAsrEvent::Error(reason) => {
                    let _ = control.close();
                    events.join();
                    fail(&format!("Gemini ASR provider error: {reason}"));
                }
                GeminiAsrEvent::Closed => break,
                GeminiAsrEvent::Interrupted | GeminiAsrEvent::Ready => {}
            }
        } else {
            thread::sleep(Duration::from_millis(20));
        }
    }

    let _ = control.close();
    events.join();
    if finals.is_empty() {
        fail("Gemini ASR returned no final transcript");
    }
    println!(
        "first transcript: {} ms",
        first_transcript_ms.unwrap_or_default()
    );
    println!("provider total: {} ms", started.elapsed().as_millis());
    println!("completion authority: final transcript");
    println!("transcript: {}", finals.join(" "));
    println!("Gemini Live ASR check passed");
}

fn wait_ready(
    events: &ocp_llm_router::providers::gemini_asr::GeminiLiveAsrEvents,
    started: Instant,
) -> bool {
    while started.elapsed() < READY_TIMEOUT {
        if let Some(event) = events.try_recv() {
            match event {
                GeminiAsrEvent::Ready => return true,
                GeminiAsrEvent::Error(reason) => {
                    fail(&format!("Gemini ASR setup failed: {reason}"))
                }
                GeminiAsrEvent::Closed => return false,
                _ => {}
            }
        } else {
            thread::sleep(Duration::from_millis(20));
        }
    }
    false
}

fn probe_model_access(api_key: &str) -> u16 {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(10)))
        .http_status_as_error(false)
        .proxy(ureq::Proxy::try_from_env())
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .provider(ureq::tls::TlsProvider::NativeTls)
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .build();
    let agent = config.new_agent();
    match agent
        .get(MODEL_URL)
        .header("x-goog-api-key", api_key)
        .call()
    {
        Ok(response) => response.status().as_u16(),
        Err(_) => 0,
    }
}

fn read_pcm16_wav(path: &Path) -> Result<(Vec<i16>, u32), String> {
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_owned());
    }
    let mut offset = 12usize;
    let mut format: Option<(u16, u16, u32)> = None;
    let mut data: Option<&[u8]> = None;
    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let start = offset + 8;
        let end = start.saturating_add(size);
        if end > bytes.len() {
            return Err("WAV chunk exceeds file length".to_owned());
        }
        if id == b"fmt " && size >= 16 {
            let audio_format = u16::from_le_bytes(bytes[start..start + 2].try_into().unwrap());
            let channels = u16::from_le_bytes(bytes[start + 2..start + 4].try_into().unwrap());
            let sample_rate = u32::from_le_bytes(bytes[start + 4..start + 8].try_into().unwrap());
            let bits = u16::from_le_bytes(bytes[start + 14..start + 16].try_into().unwrap());
            if audio_format != 1 || bits != 16 || channels == 0 {
                return Err(format!(
                    "unsupported WAV format={audio_format} channels={channels} bits={bits}"
                ));
            }
            format = Some((channels, bits, sample_rate));
        } else if id == b"data" {
            data = Some(&bytes[start..end]);
        }
        offset = end + (size & 1);
    }
    let Some((channels, _, sample_rate)) = format else {
        return Err("WAV fmt chunk missing".to_owned());
    };
    let Some(data) = data else {
        return Err("WAV data chunk missing".to_owned());
    };
    let mut mono = Vec::with_capacity(data.len() / (2 * channels as usize));
    let frame_bytes = channels as usize * 2;
    for frame in data.chunks_exact(frame_bytes) {
        let mut sum = 0i32;
        for channel in 0..channels as usize {
            let at = channel * 2;
            sum += i32::from(i16::from_le_bytes([frame[at], frame[at + 1]]));
        }
        mono.push((sum / i32::from(channels)) as i16);
    }
    Ok((mono, sample_rate))
}

fn resample_mono_pcm16(samples: &[i16], source_rate: u32, target_rate: u32) -> Vec<i16> {
    if samples.is_empty() || source_rate == 0 || target_rate == 0 {
        return Vec::new();
    }
    if source_rate == target_rate {
        return samples.to_vec();
    }
    let output_len =
        ((samples.len() as u64 * u64::from(target_rate)) / u64::from(source_rate)) as usize;
    let mut output = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let source_index =
            ((index as u64 * u64::from(source_rate)) / u64::from(target_rate)) as usize;
        output.push(samples[source_index.min(samples.len() - 1)]);
    }
    output
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1);
}
