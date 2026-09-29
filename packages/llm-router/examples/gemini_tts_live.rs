//! Live diagnostic for the exact Gemini TTS adapter used by the OCP kernel.
//!
//! This intentionally reuses `GeminiSynthesizer` instead of duplicating the
//! HTTP contract in a spike. It proves the current Interactions API path,
//! credential lookup, Thai synthesis, PCM/WAV handling, and the exact bytes the
//! RuntimeV3 audio transport will receive.
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example gemini_tts_live
//!
//! Credential lookup matches the kernel: `GEMINI_API_KEY` first, then the OS
//! keystore entry `ocp-ai-provider` / `gemini-cloud`.

use std::time::Duration;

use ocp_llm_router::adapter::Synthesizer;
use ocp_llm_router::providers::gemini_tts::{GeminiSynthesizer, DEFAULT_MODEL, DEFAULT_VOICE};
use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";
const DEFAULT_TEXT: &str = "สวัสดีค่ะ นี่คือเสียงทดสอบจาก Open Companion Platform";

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
        std::process::exit(1);
    };

    let voice = std::env::var("GEMINI_TTS_VOICE").unwrap_or_else(|_| DEFAULT_VOICE.to_owned());
    let text = std::env::var("GEMINI_TTS_TEXT").unwrap_or_else(|_| DEFAULT_TEXT.to_owned());
    println!("credential source: {source}");
    println!("model: {DEFAULT_MODEL}");
    println!("voice: {voice}");

    let synth = GeminiSynthesizer::new(DEFAULT_MODEL, voice, Duration::from_secs(30));
    let clip = match synth.synthesize(&text, Some(key.as_str())) {
        Ok(clip) => clip,
        Err(error) => {
            eprintln!("Gemini TTS failed: {error:?}");
            std::process::exit(1);
        }
    };

    if clip.bytes.len() < 44 || &clip.bytes[0..4] != b"RIFF" || &clip.bytes[8..12] != b"WAVE" {
        eprintln!("Gemini TTS returned audio, but the adapter did not produce a valid WAV");
        std::process::exit(1);
    }

    let out = std::env::current_dir()
        .unwrap_or_default()
        .join("gemini_thai.wav");
    if let Err(error) = std::fs::write(&out, &clip.bytes) {
        eprintln!("could not write {}: {error}", out.display());
        std::process::exit(1);
    }

    println!("Gemini TTS live check passed");
    println!("WAV bytes: {}", clip.bytes.len());
    println!("duration: {} ms", clip.duration_ms);
    println!("wrote: {}", out.display());
    println!("Play it with: Start-Process \"{}\"", out.display());
}
