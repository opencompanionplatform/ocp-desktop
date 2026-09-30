//! Voice-turn benchmark diagnostic for local Windows TTS.

use std::time::Instant;

use ocp_llm_router::adapter::{Synthesizer, WindowsSynthesizer};

const DEFAULT_TEXT: &str = "สวัสดีค่ะ ยินดีที่ได้คุยกับคุณ";

fn main() {
    let text = std::env::var("OCP_WINDOWS_TTS_TEXT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_TEXT.to_owned());
    let voice_setting = std::env::var("OCP_WINDOWS_TTS_VOICE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "profile:female:adult".to_owned());
    let synth = WindowsSynthesizer::from_voice_setting(&voice_setting);
    let started = Instant::now();
    match synth.synthesize(&text, None) {
        Ok(clip) => {
            println!(
                "[VOICE-TURN-WINDOWS-TTS] ok=true total_ms={} audio_ms={} bytes={}",
                started.elapsed().as_millis(),
                clip.duration_ms,
                clip.bytes.len()
            );
        }
        Err(error) => {
            eprintln!("Windows TTS failed: {error:?}");
            std::process::exit(1);
        }
    }
}
