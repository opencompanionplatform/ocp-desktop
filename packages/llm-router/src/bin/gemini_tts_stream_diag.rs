//! Voice-turn benchmark diagnostic for Gemini streaming TTS.
//!
//! Uses the production `GeminiSynthesizer` streaming path and reports only
//! timing/size metadata. Credentials remain in GEMINI_API_KEY or the OCP OS
//! keystore and are never printed.

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
        fail("Gemini credential is unavailable");
    };
    let model = std::env::var("GEMINI_TTS_MODEL")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| STREAMING_MODEL.to_owned());
    let text = std::env::var("GEMINI_TTS_TEXT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_TEXT.to_owned());
    let voice = std::env::var("GEMINI_TTS_VOICE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_VOICE.to_owned());

    println!("credential source: {source}");
    println!("model: {model}");
    println!("voice: {voice}");

    let synth = GeminiSynthesizer::new(model, voice, Duration::from_secs(20));
    let started = Instant::now();
    let mut first_audio_ms = None;
    let mut chunks = 0_u64;
    let mut pcm_bytes = 0_usize;
    let result = synth.stream_synthesize(&text, Some(key.as_str()), &mut |audio: &[u8]| -> Result<
        (),
        ProviderError,
    > {
        if !audio.is_empty() {
            first_audio_ms.get_or_insert_with(|| started.elapsed().as_millis());
            chunks += 1;
            pcm_bytes += audio.len();
        }
        Ok(())
    });
    if let Err(error) = result {
        fail(&format!("Gemini streaming TTS failed: {error:?}"));
    }
    let Some(ttfa_ms) = first_audio_ms else {
        fail("Gemini streaming TTS returned no audio");
    };
    if pcm_bytes == 0 {
        fail("Gemini streaming TTS returned zero PCM bytes");
    }
    let total_ms = started.elapsed().as_millis();
    println!(
        "[VOICE-TURN-TTS] ok=true ttfa_ms={ttfa_ms} total_ms={total_ms} chunks={chunks} pcm_bytes={pcm_bytes}"
    );
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1)
}
