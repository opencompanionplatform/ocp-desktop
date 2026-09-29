//! I7 V1.1 spike (diagnostic-only): prove OpenAI TTS against a real key — that
//! `gpt-4o-mini-tts` (a) authenticates, (b) speaks **Thai** (the reason for a
//! cloud voice; and a second cloud provider that routes around the Gemini
//! project's 403), and (c) returns a **WAV** we can play directly. Runs BEFORE
//! any `OpenAiSynthesizer` is written — verify the contract, never guess it.
//!
//! Unlike Gemini (base64 PCM → wrap), OpenAI's speech endpoint returns the
//! audio **bytes directly** in the requested `response_format` — ask for `wav`
//! and write them straight to a file. Verified shape
//! (developers.openai.com/api/docs/guides/text-to-speech): `POST
//! /v1/audio/speech` with `{model, input, voice, instructions?, response_format}`,
//! Bearer auth; `instructions` steers tone/accent/pace (gpt-4o-mini-tts only).
//!
//! Usage (PowerShell):
//!   $env:OPENAI_API_KEY = "sk-..."         # or store `openai-cloud` in the keystore
//!   cargo run -p ocp-llm-router --example openai_tts_live
//!   Start-Process .\openai_thai.wav
//! Overrides: $env:OPENAI_TTS_VOICE (marin|coral|...), $env:OPENAI_TTS_TEXT.

use std::time::Duration;

use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";
const MODEL: &str = "gpt-4o-mini-tts";
const DEFAULT_VOICE: &str = "marin";
const DEFAULT_TEXT: &str = "สวัสดีครับ ผมคือ AI companion ยินดีที่ได้รู้จักครับ";
const INSTRUCTIONS: &str = "Warm, calm, concise Thai companion voice.";

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .http_status_as_error(false) // read the JSON error body on a 4xx/5xx
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .provider(ureq::tls::TlsProvider::NativeTls)
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .build()
        .new_agent()
}

fn main() {
    let (key, source) = match std::env::var("OPENAI_API_KEY").ok() {
        Some(k) if !k.is_empty() => (Some(k), "env var OPENAI_API_KEY".to_owned()),
        _ => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get("openai-cloud"),
            "OS keystore (openai-cloud)".to_owned(),
        ),
    };
    let Some(key) = key else {
        eprintln!(
            "No OpenAI credential (checked OPENAI_API_KEY and keystore `openai-cloud`). \
             $env:OPENAI_API_KEY = \"sk-...\" or store it with \
             `cargo run -p ocp-llm-router --example store_credential -- set openai-cloud`."
        );
        std::process::exit(1);
    };
    let voice = std::env::var("OPENAI_TTS_VOICE").unwrap_or_else(|_| DEFAULT_VOICE.to_owned());
    let text = std::env::var("OPENAI_TTS_TEXT").unwrap_or_else(|_| DEFAULT_TEXT.to_owned());
    println!("credential source: {source}");
    println!("model: {MODEL}   voice: {voice}");
    println!("text:  {text}\n");

    let body = serde_json::json!({
        "model": MODEL,
        "input": text,
        "voice": voice,
        "instructions": INSTRUCTIONS,
        "response_format": "wav",
    });
    let result = agent()
        .post("https://api.openai.com/v1/audio/speech")
        .header("Authorization", format!("Bearer {key}").as_str())
        .send_json(&body);

    let mut response = match result {
        Ok(r) => r,
        Err(e) => {
            eprintln!("transport-level failure (no HTTP response): {e:?}");
            std::process::exit(1);
        }
    };
    let status = response.status().as_u16();
    // The body is binary WAV on 200, a JSON error otherwise — read bytes either way.
    let bytes = match response.body_mut().read_to_vec() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("could not read response body: {e}");
            std::process::exit(1);
        }
    };
    if status != 200 {
        let msg = String::from_utf8_lossy(&bytes);
        let preview: String = msg.chars().take(1200).collect();
        eprintln!("HTTP {status} — OpenAI rejected the request. Body:\n{preview}");
        eprintln!(
            "\n401 = bad key; 429 = quota/rate; 400 = bad request (e.g. an unknown voice — \
             the valid set is alloy/ash/ballad/coral/echo/fable/onyx/nova/sage/shimmer/verse/marin/cedar)."
        );
        std::process::exit(1);
    }

    let out = std::env::current_dir()
        .unwrap_or_default()
        .join("openai_thai.wav");
    if let Err(e) = std::fs::write(&out, &bytes) {
        eprintln!("could not write {}: {e}", out.display());
        std::process::exit(1);
    }
    let duration = ocp_os_tts::wav_duration_ms(&bytes);
    println!("HTTP 200 ✅");
    println!(
        "WAV bytes: {}   duration: {}",
        bytes.len(),
        duration.map_or("unknown (not a WAV?)".to_owned(), |ms| format!("{ms} ms"))
    );
    println!("wrote: {}", out.display());
    println!("\nPLAY it: Start-Process \"{}\"", out.display());
    println!(
        "\nIf it speaks Thai clearly, the spike passed — OpenAiSynthesizer is this request \
         (WAV straight through, no PCM wrap) behind the Synthesizer seam, voice+instructions from \
         the resolved VoiceProfile variant."
    );
}
