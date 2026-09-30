//! Live Voice Realtime V2 diagnostic for Gemini 3.1 streaming TTS.
//!
//! Uses the exact `GeminiSynthesizer` + `StreamingSynthesizer` path consumed by
//! Kernel. It reports time-to-first-audio (TTFA), chunk count, PCM bytes and
//! total provider time without logging the API key. Credential lookup matches
//! Kernel: `GEMINI_API_KEY`, then OS keystore `ocp-ai-provider/gemini-cloud`.
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example gemini_tts_stream_live
//!
//! Optional environment:
//!   GEMINI_TTS_TEXT=<text>
//!   GEMINI_TTS_VOICE=<voice>
//!   GEMINI_TTS_STREAM_TIMEOUT_SECONDS=15

use std::time::{Duration, Instant};

use ocp_llm_router::adapter::{ProviderError, StreamingSynthesizer};
use ocp_llm_router::providers::gemini_tts::{GeminiSynthesizer, DEFAULT_VOICE, STREAMING_MODEL};
use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";
const DEFAULT_TEXT: &str = "สวัสดีค่ะ นี่คือการทดสอบเสียงแบบเรียลไทม์จาก Open Companion Platform";

fn main() {
    let (key, source) = match std::env::var("GEMINI_API_KEY").ok() {
        Some(key) if !key.trim().is_empty() => (Some(key), "env:GEMINI_API_KEY"),
        _ => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get("gemini-cloud"),
            "OS keystore:gemini-cloud",
        ),
    };
    let Some(key) = key else {
        eprintln!(
            "No Gemini credential found. Set GEMINI_API_KEY or store `gemini-cloud` in the OCP OS keystore."
        );
        std::process::exit(2);
    };

    let voice = std::env::var("GEMINI_TTS_VOICE").unwrap_or_else(|_| DEFAULT_VOICE.to_owned());
    let text = std::env::var("GEMINI_TTS_TEXT").unwrap_or_else(|_| DEFAULT_TEXT.to_owned());
    let timeout_seconds = std::env::var("GEMINI_TTS_STREAM_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| (3..=60).contains(value))
        .unwrap_or(15);

    println!("credential source: {source}");
    println!("model: {STREAMING_MODEL}");
    println!("voice: {voice}");
    println!("timeout: {timeout_seconds}s");

    let synth =
        GeminiSynthesizer::new(STREAMING_MODEL, voice, Duration::from_secs(timeout_seconds));
    let format = synth.stream_format();
    let started = Instant::now();
    let mut first_audio_ms: Option<u128> = None;
    let mut chunk_count = 0_u64;
    let mut pcm = Vec::<u8>::new();
    let mut on_audio = |audio: &[u8]| -> Result<(), ProviderError> {
        if audio.is_empty() {
            return Ok(());
        }
        if first_audio_ms.is_none() {
            first_audio_ms = Some(started.elapsed().as_millis());
        }
        chunk_count += 1;
        pcm.extend_from_slice(audio);
        Ok(())
    };

    if let Err(error) = synth.stream_synthesize(&text, Some(key.as_str()), &mut on_audio) {
        eprintln!("Gemini streaming TTS failed: {error:?}");
        std::process::exit(1);
    }

    let total_ms = started.elapsed().as_millis();
    let Some(ttfa_ms) = first_audio_ms else {
        eprintln!("Gemini streaming TTS completed without any audio delta");
        std::process::exit(1);
    };
    if pcm.is_empty() {
        eprintln!("Gemini streaming TTS returned zero PCM bytes");
        std::process::exit(1);
    }

    let out = std::env::current_dir()
        .unwrap_or_default()
        .join("gemini_stream_thai.wav");
    let wav = pcm_to_wav(
        &pcm,
        format.sample_rate,
        u16::from(format.channels),
        u16::from(format.sample_width) * 8,
    );
    if let Err(error) = std::fs::write(&out, wav) {
        eprintln!("could not write {}: {error}", out.display());
        std::process::exit(1);
    }

    println!("Gemini streaming TTS live check passed");
    println!("TTFA: {ttfa_ms} ms");
    println!("total provider time: {total_ms} ms");
    println!("audio chunks: {chunk_count}");
    println!("PCM bytes: {}", pcm.len());
    println!(
        "format: {} Hz / {} channel(s) / {}-bit",
        format.sample_rate,
        format.channels,
        format.sample_width * 8
    );
    println!("wrote: {}", out.display());
}

fn pcm_to_wav(pcm: &[u8], sample_rate: u32, channels: u16, bits_per_sample: u16) -> Vec<u8> {
    let bytes_per_sample = bits_per_sample / 8;
    let block_align = channels.saturating_mul(bytes_per_sample);
    let byte_rate = sample_rate.saturating_mul(u32::from(block_align));
    let data_len = u32::try_from(pcm.len()).unwrap_or(u32::MAX);
    let riff_len = 36_u32.saturating_add(data_len);

    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&riff_len.to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}
