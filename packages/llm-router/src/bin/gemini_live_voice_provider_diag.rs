//! Live acceptance of the production Gemini 3.8 Live provider module.
//!
//! Streams a PCM16 WAV in real time through `providers::gemini_live_voice`,
//! then reports latency from activityEnd to first returned audio. Credentials
//! are resolved exactly like Kernel: GEMINI_API_KEY, then OS keystore.

use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use ocp_llm_router::providers::gemini_live_voice::{
    start_live_voice, GeminiLiveVoiceEvent, LIVE_VOICE_INPUT_RATE, LIVE_VOICE_MODEL,
};
use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";
const FRAME_MS: u64 = 100;
const READY_TIMEOUT: Duration = Duration::from_secs(10);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(15);

fn main() {
    let wav_path = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("gemini_thai.wav"));
    let (key, source) = credential();
    let Some(key) = key else {
        fail("Gemini credential is unavailable");
    };
    let (source_pcm, source_rate) = read_pcm16_wav(&wav_path)
        .unwrap_or_else(|error| fail(&format!("could not read {}: {error}", wav_path.display())));
    let pcm = resample_mono_pcm16(&source_pcm, source_rate, LIVE_VOICE_INPUT_RATE);
    if pcm.is_empty() {
        fail("input WAV produced no PCM samples");
    }

    println!("credential source: {source}");
    println!("model: {LIVE_VOICE_MODEL}");
    println!("input: {}", wav_path.display());
    println!(
        "audio duration: {:.2} s",
        pcm.len() as f64 / LIVE_VOICE_INPUT_RATE as f64
    );

    let (control, events) = start_live_voice(
        key,
        "ตอบกลับเป็นภาษาไทยสั้น ๆ หนึ่งประโยคอย่างเป็นธรรมชาติ".to_owned(),
    )
    .unwrap_or_else(|error| fail(&format!("provider start failed: {error}")));

    let ready_started = Instant::now();
    let mut ready = false;
    while ready_started.elapsed() < READY_TIMEOUT {
        match events.try_recv() {
            Some(GeminiLiveVoiceEvent::Ready) => {
                ready = true;
                break;
            }
            Some(GeminiLiveVoiceEvent::Error(reason)) => {
                fail(&format!("provider setup failed: {reason}"));
            }
            Some(GeminiLiveVoiceEvent::Closed) => fail("provider closed before ready"),
            Some(_) | None => thread::sleep(Duration::from_millis(20)),
        }
    }
    if !ready {
        let _ = control.close();
        events.join();
        fail("provider did not become ready before timeout");
    }
    println!("ready: {} ms", ready_started.elapsed().as_millis());

    if !control.activity_start() {
        fail("activityStart was rejected");
    }
    let samples_per_frame = (u64::from(LIVE_VOICE_INPUT_RATE) * FRAME_MS / 1000) as usize;
    let audio_started = Instant::now();
    for frame in pcm.chunks(samples_per_frame) {
        let mut bytes = Vec::with_capacity(frame.len() * 2);
        for sample in frame {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        if !control.send_pcm16(bytes) {
            fail("audio frame was rejected");
        }
        thread::sleep(Duration::from_millis(FRAME_MS));
    }
    if !control.activity_end() {
        fail("activityEnd was rejected");
    }
    println!("audio sent: {} ms", audio_started.elapsed().as_millis());

    let ended = Instant::now();
    let mut first_audio_ms = None;
    let mut turn_complete_ms = None;
    let mut chunks = 0_u64;
    let mut bytes = 0_usize;
    let mut input_text = String::new();
    let mut output_text = String::new();
    while ended.elapsed() < RESPONSE_TIMEOUT {
        match events.try_recv() {
            Some(GeminiLiveVoiceEvent::Audio(audio)) => {
                first_audio_ms.get_or_insert_with(|| ended.elapsed().as_millis());
                chunks += 1;
                bytes += audio.len();
            }
            Some(GeminiLiveVoiceEvent::InputTranscript(text)) => merge_text(&mut input_text, &text),
            Some(GeminiLiveVoiceEvent::OutputTranscript(text)) => {
                merge_text(&mut output_text, &text)
            }
            Some(GeminiLiveVoiceEvent::TurnComplete) => {
                turn_complete_ms = Some(ended.elapsed().as_millis());
                break;
            }
            Some(GeminiLiveVoiceEvent::Interrupted) => {}
            Some(GeminiLiveVoiceEvent::Error(reason)) => {
                let _ = control.close();
                events.join();
                fail(&format!("provider error: {reason}"));
            }
            Some(GeminiLiveVoiceEvent::Closed) => break,
            Some(GeminiLiveVoiceEvent::Ready) | None => thread::sleep(Duration::from_millis(10)),
        }
    }
    let _ = control.close();
    events.join();
    let Some(first_audio_ms) = first_audio_ms else {
        fail("production provider returned no audio before timeout");
    };
    println!(
        "[VOICE-LIVE-PROVIDER] ok=true first_audio_after_end_ms={} turn_complete_after_end_ms={} audio_chunks={} audio_bytes={} input_transcript={} output_transcript={}",
        first_audio_ms,
        turn_complete_ms.unwrap_or_default(),
        chunks,
        bytes,
        sanitize_metric(&input_text),
        sanitize_metric(&output_text),
    );
}

fn credential() -> (Option<String>, &'static str) {
    match std::env::var("GEMINI_API_KEY").ok() {
        Some(key) if !key.trim().is_empty() => (Some(key), "env:GEMINI_API_KEY"),
        _ => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get("gemini-cloud"),
            "OS keystore:gemini-cloud",
        ),
    }
}

fn merge_text(target: &mut String, incoming: &str) {
    let text = incoming.trim();
    if text.is_empty() {
        return;
    }
    if target.is_empty() || text.starts_with(target.as_str()) {
        *target = text.to_owned();
    } else if !target.starts_with(text) {
        target.push(' ');
        target.push_str(text);
    }
}

fn sanitize_metric(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
        .chars()
        .take(120)
        .collect()
}

fn read_pcm16_wav(path: &Path) -> Result<(Vec<i16>, u32), String> {
    let data = std::fs::read(path).map_err(|error| error.to_string())?;
    if data.len() < 44 || &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_owned());
    }
    let mut offset = 12usize;
    let mut format: Option<(u16, u32, u16)> = None;
    let mut audio: Option<&[u8]> = None;
    while offset + 8 <= data.len() {
        let id = &data[offset..offset + 4];
        let size = u32::from_le_bytes(data[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let start = offset + 8;
        let end = start.saturating_add(size);
        if end > data.len() {
            return Err("WAV chunk exceeds file length".to_owned());
        }
        if id == b"fmt " && size >= 16 {
            let audio_format = u16::from_le_bytes(data[start..start + 2].try_into().unwrap());
            let channels = u16::from_le_bytes(data[start + 2..start + 4].try_into().unwrap());
            let rate = u32::from_le_bytes(data[start + 4..start + 8].try_into().unwrap());
            let bits = u16::from_le_bytes(data[start + 14..start + 16].try_into().unwrap());
            if audio_format != 1 || bits != 16 || channels == 0 {
                return Err("unsupported WAV format".to_owned());
            }
            format = Some((channels, rate, bits));
        } else if id == b"data" {
            audio = Some(&data[start..end]);
        }
        offset = end + (size & 1);
    }
    let Some((channels, rate, _)) = format else {
        return Err("WAV fmt chunk missing".to_owned());
    };
    let Some(audio) = audio else {
        return Err("WAV data chunk missing".to_owned());
    };
    let frame_bytes = channels as usize * 2;
    let mut mono = Vec::with_capacity(audio.len() / frame_bytes);
    for frame in audio.chunks_exact(frame_bytes) {
        let mut sum = 0i32;
        for channel in 0..channels as usize {
            let at = channel * 2;
            sum += i32::from(i16::from_le_bytes([frame[at], frame[at + 1]]));
        }
        mono.push((sum / i32::from(channels)) as i16);
    }
    Ok((mono, rate))
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
