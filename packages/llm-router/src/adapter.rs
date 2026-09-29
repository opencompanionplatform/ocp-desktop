//! Provider adapter boundary (AI_ROUTER.md anti-corruption layer). Every
//! implementor translates its own vendor wire format to/from the neutral
//! [`crate::types::RouterRequest`]/[`crate::types::RouterResponse`] shape —
//! the router core (`router.rs`) never sees anything vendor-specific.
//!
//! **This slice ships two reference/test adapters only** (`LocalEchoAdapter`,
//! `ScriptedAdapter`) so the router's own fallback/consent/tool-gating logic
//! can be certified (CS-AIP) without a network. The real vendor adapters
//! I4's sibling checklist item names explicitly — OpenRouter, Ollama,
//! Claude, GPT, each behind this same trait — are a separate follow-up
//! slice (each is its own wire format + auth scheme + streaming protocol,
//! deliberately not guessed into this one).

use std::collections::VecDeque;
use std::sync::Mutex;

use uuid::Uuid;

use crate::types::{
    ContentPart, CostClass, EstimatedCost, ProviderCapabilities, RouterRequest, RouterResponse,
    StopReason, Usage,
};

/// Provider-side failure a health-check/fallback decision reacts to.
/// Vendor-level content refusals are **not** modeled here — a model
/// declining to answer is a normal, successful call that returns
/// `StopReason::Refused` in a `RouterResponse`, not a `ProviderError`; only
/// transport/availability failures reach this type (AI_PROVIDER_API §4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderError {
    /// Elevated latency; Available -> Degraded (or Degraded -> Failed on repeat).
    Timeout,
    /// Elevated error rate; same escalation as `Timeout`.
    ElevatedErrorRate,
    /// Hard, immediate outage (connection refused, DNS failure) — goes
    /// straight to `Failed` regardless of current health (see `health.rs`).
    Unreachable,
    /// Credential was rejected. Hosts may project a bounded remediation code
    /// without exposing provider response bodies.
    AuthFailed,
    /// Short-lived provider request/token rate limit. Hosts may retry with
    /// backoff or fall through to another configured provider/model.
    RateLimited,
    /// Provider daily/project quota allocation is exhausted. This is not a
    /// short retry condition; hosts should surface a quota-reset/remediation UI.
    QuotaExceeded,
}

pub trait ProviderAdapter: Send + Sync {
    fn capabilities(&self) -> &ProviderCapabilities;

    /// `credential` is whatever `CredentialStore::get` returned for this
    /// provider at call time (SEC-030) — real adapters use it for auth; the
    /// reference adapters below ignore it (they make no real call at all).
    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError>;
}

fn neutral_reply(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    text: &str,
) -> RouterResponse {
    RouterResponse {
        request_id: request.request_id,
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        content: vec![ContentPart::Text {
            value: text.to_owned(),
        }],
        tool_calls: Vec::new(),
        stop_reason: StopReason::End,
        usage: Usage {
            input_tokens: 0,
            output_tokens: 0,
            cost_class: CostClass::Free,
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0, // overwritten by Router::route
    }
}

/// Stands in for a local provider (e.g. Ollama) until a real HTTP client
/// exists: always `Available`, always succeeds, deterministic canned reply.
/// Records the last request it received (`last_request`) so tests can
/// assert what actually reached it — e.g. that sensitive excerpts were (or
/// weren't) stripped before this call.
pub struct LocalEchoAdapter {
    caps: ProviderCapabilities,
    last_request: Mutex<Option<RouterRequest>>,
}

impl LocalEchoAdapter {
    #[must_use]
    pub fn new(caps: ProviderCapabilities) -> Self {
        Self {
            caps,
            last_request: Mutex::new(None),
        }
    }

    #[must_use]
    pub fn last_request(&self) -> Option<RouterRequest> {
        self.last_request.lock().expect("adapter lock").clone()
    }
}

impl ProviderAdapter for LocalEchoAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        _credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        *self.last_request.lock().expect("adapter lock") = Some(request.clone());
        Ok(neutral_reply(
            request,
            &self.caps.provider_id,
            "local-echo-model",
            "(local echo) ok",
        ))
    }
}

/// A scripted outcome queue for fault-injection testing (CS-AIP:
/// "fault-injected providers walk the chain"). Stands in for a cloud
/// provider until a real vendor client exists.
pub enum ScriptedOutcome {
    Ok(&'static str),
    Err(ProviderError),
}

pub struct ScriptedAdapter {
    caps: ProviderCapabilities,
    script: Mutex<VecDeque<ScriptedOutcome>>,
    last_request: Mutex<Option<RouterRequest>>,
}

impl ScriptedAdapter {
    #[must_use]
    pub fn new(caps: ProviderCapabilities, script: Vec<ScriptedOutcome>) -> Self {
        Self {
            caps,
            script: Mutex::new(script.into()),
            last_request: Mutex::new(None),
        }
    }

    #[must_use]
    pub fn last_request(&self) -> Option<RouterRequest> {
        self.last_request.lock().expect("adapter lock").clone()
    }
}

impl ProviderAdapter for ScriptedAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        _credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        *self.last_request.lock().expect("adapter lock") = Some(request.clone());
        let outcome = self
            .script
            .lock()
            .expect("adapter lock")
            .pop_front()
            .unwrap_or(ScriptedOutcome::Ok("(scripted) exhausted, default ok"));
        match outcome {
            ScriptedOutcome::Ok(text) => Ok(neutral_reply(
                request,
                &self.caps.provider_id,
                "scripted-model",
                text,
            )),
            ScriptedOutcome::Err(e) => Err(e),
        }
    }
}

fn audio_reply(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    audio_ref_id: Uuid,
) -> RouterResponse {
    RouterResponse {
        request_id: request.request_id,
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        // AI_PROVIDER_API §2a: an audio ContentPart's `value` is the `audioRef`
        // id, never inline bytes — the router core routes refs like text.
        content: vec![ContentPart::Audio {
            value: audio_ref_id.to_string(),
        }],
        tool_calls: Vec::new(),
        stop_reason: StopReason::End,
        usage: Usage {
            input_tokens: 0,
            output_tokens: 0,
            cost_class: CostClass::Free,
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0, // overwritten by Router::route
    }
}

/// Concatenates the text of every `Text` content part across a request's
/// messages — what a `tts` adapter speaks (non-text parts are ignored).
fn request_text(request: &RouterRequest) -> String {
    request
        .messages
        .iter()
        .flat_map(|m| &m.content)
        .filter_map(|part| match part {
            ContentPart::Text { value } => Some(value.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A rendered speech clip: the audio bytes plus the metadata the audio store
/// needs. Returned by a [`Synthesizer`] and `put` into the store by
/// [`TtsAdapter`].
pub struct Synthesized {
    pub bytes: Vec<u8>,
    pub format: ocp_audio_store::AudioFormat,
    pub duration_ms: u32,
}

/// The seam behind a `tts` adapter: turn text into a speech clip. Swappable
/// like every other real-resource boundary in this workspace — a deterministic
/// [`ReferenceSynthesizer`] for tests, the real [`WindowsSynthesizer`] (OS
/// voice) offline, a cloud voice (`providers::gemini_tts::GeminiSynthesizer`)
/// when a language the OS can't speak is needed — so [`TtsAdapter`]'s
/// routing/store logic is written and tested once.
pub trait Synthesizer: Send + Sync {
    /// `credential` is whatever `CredentialStore::get` returned for this
    /// provider at call time (SEC-030), threaded straight through from
    /// [`TtsAdapter::invoke`] — a cloud synthesizer uses it as its API key; the
    /// local reference/OS-voice synthesizers ignore it (they make no
    /// authenticated call). A synthesis failure is a *provider* failure
    /// (OS voice unavailable, cloud request rejected), surfaced as a
    /// [`ProviderError`] so the router falls back — never a panic.
    fn synthesize(
        &self,
        text: &str,
        credential: Option<&str>,
    ) -> Result<Synthesized, ProviderError>;
}

/// Provider-neutral description of one streaming PCM transport. Vendor
/// adapters translate their wire format into this shape before Runtime sees
/// any audio. Keeping it beside [`Synthesizer`] means Gemini, OpenAI and future
/// providers can share the same Kernel -> Runtime playback contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamingAudioFormat {
    pub sample_rate: u32,
    pub channels: u16,
    pub sample_width: u16,
}

/// Streaming counterpart to [`Synthesizer`]. The callback receives decoded PCM
/// bytes, never vendor JSON/base64. This is deliberately object-safe so Kernel
/// can select a provider adapter at runtime without knowing its concrete type.
pub trait StreamingSynthesizer: Synthesizer {
    fn stream_format(&self) -> StreamingAudioFormat;

    fn stream_synthesize(
        &self,
        text: &str,
        credential: Option<&str>,
        on_audio: &mut dyn FnMut(&[u8]) -> Result<(), ProviderError>,
    ) -> Result<(), ProviderError>;
}

/// Deterministic reference [`Synthesizer`], the audio-side twin of
/// [`LocalEchoAdapter`]: the "clip" is just the text's bytes tagged `wav`, so
/// the routed-TTS + `audioRef` path can be proven without a real voice (like
/// the echo/scripted adapters proved the router without a network).
#[derive(Default)]
pub struct ReferenceSynthesizer;

impl ReferenceSynthesizer {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Synthesizer for ReferenceSynthesizer {
    fn synthesize(
        &self,
        text: &str,
        _credential: Option<&str>,
    ) -> Result<Synthesized, ProviderError> {
        let bytes = text.as_bytes().to_vec();
        // Reference "duration": 1 ms per byte — a stand-in for a real clip length.
        let duration_ms = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
        Ok(Synthesized {
            bytes,
            format: ocp_audio_store::AudioFormat::Wav,
            duration_ms,
        })
    }
}

/// Real OS-voice [`Synthesizer`] — Windows System.Speech via
/// [`ocp_os_tts`] (V1 slice 3). Off Windows (or on synth failure) it returns
/// `Unreachable`, so the router falls through to a local reference/subtitle
/// path (`tts-unavailable`) rather than crashing.
pub struct WindowsSynthesizer {
    gender: String,
    age: String,
}

impl Default for WindowsSynthesizer {
    fn default() -> Self {
        Self::new()
    }
}

impl WindowsSynthesizer {
    #[must_use]
    pub fn new() -> Self {
        Self {
            gender: "neutral".to_owned(),
            age: "adult".to_owned(),
        }
    }

    #[must_use]
    pub fn from_voice_setting(setting: &str) -> Self {
        use crate::providers::gemini_tts::{VoiceAge, VoiceGender, VoiceProfile};

        let profile = VoiceProfile::parse(setting).unwrap_or_default();
        let gender = match profile.gender {
            VoiceGender::Male => "male",
            VoiceGender::Female => "female",
            VoiceGender::Neutral => "neutral",
        };
        let age = match profile.age {
            VoiceAge::Child => "child",
            VoiceAge::Adult => "adult",
        };
        Self {
            gender: gender.to_owned(),
            age: age.to_owned(),
        }
    }

    fn preference_for(&self, text: &str) -> ocp_os_tts::VoicePreference {
        let language = if text
            .chars()
            .any(|ch| ('\u{0e00}'..='\u{0e7f}').contains(&ch))
        {
            "th-TH"
        } else if text.is_ascii() {
            "en"
        } else {
            ""
        };
        ocp_os_tts::VoicePreference {
            language: language.to_owned(),
            gender: self.gender.clone(),
            age: self.age.clone(),
            voice_name: String::new(),
        }
    }

    /// Safe bounded diagnostic for a failed OS fallback. It intentionally
    /// exposes no installed voice names or subprocess detail.
    #[must_use]
    pub fn failure_reason(text: &str, setting: &str) -> &'static str {
        let synth = Self::from_voice_setting(setting);
        let preference = synth.preference_for(text);
        if preference.language.is_empty() {
            return "tts-unavailable";
        }
        match ocp_os_tts::has_matching_voice(&preference) {
            Ok(false) => "local-voice-not-installed",
            _ => "tts-unavailable",
        }
    }
}

impl Synthesizer for WindowsSynthesizer {
    fn synthesize(
        &self,
        text: &str,
        _credential: Option<&str>,
    ) -> Result<Synthesized, ProviderError> {
        let preference = self.preference_for(text);
        let bytes = ocp_os_tts::synthesize_wav_with_preference(text, &preference)
            .map_err(|_| ProviderError::Unreachable)?;
        let duration_ms = ocp_os_tts::wav_duration_ms(&bytes).unwrap_or(0);
        Ok(Synthesized {
            bytes,
            format: ocp_audio_store::AudioFormat::Wav,
            duration_ms,
        })
    }
}

/// I7 Voice V1 `tts` adapter (AI_PROVIDER_API §2a, VOICE.md): on `invoke` it
/// synthesizes the request's text via its [`Synthesizer`], `put`s the clip
/// into the shared [`AudioStore`], and returns a response whose single audio
/// content part carries the resulting `audioRef` id — never bytes. The router
/// core routes that ref exactly like text (fallback/consent/accounting
/// unchanged); which voice actually spoke is the injected synthesizer's
/// concern, not the router's.
pub struct TtsAdapter {
    caps: ProviderCapabilities,
    store: std::sync::Arc<ocp_audio_store::AudioStore>,
    synth: Box<dyn Synthesizer>,
    last_request: Mutex<Option<RouterRequest>>,
}

impl TtsAdapter {
    #[must_use]
    pub fn new(
        caps: ProviderCapabilities,
        store: std::sync::Arc<ocp_audio_store::AudioStore>,
        synth: Box<dyn Synthesizer>,
    ) -> Self {
        Self {
            caps,
            store,
            synth,
            last_request: Mutex::new(None),
        }
    }

    #[must_use]
    pub fn last_request(&self) -> Option<RouterRequest> {
        self.last_request.lock().expect("adapter lock").clone()
    }
}

impl ProviderAdapter for TtsAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        *self.last_request.lock().expect("adapter lock") = Some(request.clone());
        // Thread the router-supplied credential (SEC-030) straight to the
        // synthesizer: a cloud voice authenticates with it, a local voice
        // ignores it. The adapter itself never inspects or stores the key.
        let clip = self.synth.synthesize(&request_text(request), credential)?;
        let audio_ref = self.store.put(clip.bytes, clip.format, clip.duration_ms);
        Ok(audio_reply(
            request,
            &self.caps.provider_id,
            "tts",
            audio_ref.id,
        ))
    }
}

/// Helper for tests that need a `RouterResponse` carrying tool calls (the
/// two reference adapters above never emit any on their own).
#[must_use]
pub fn reply_with_tool_calls(
    request: &RouterRequest,
    provider_id: &str,
    tool_calls: Vec<crate::types::ToolCallOut>,
) -> RouterResponse {
    let mut r = neutral_reply(request, provider_id, "scripted-model", "");
    r.stop_reason = StopReason::ToolCall;
    r.tool_calls = tool_calls;
    r
}

/// Deterministic id helper for tests/log lines that want a stable-looking
/// call id without pulling in a fixture generator.
#[must_use]
pub fn new_call_id() -> Uuid {
    Uuid::now_v7()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_voice_routes_thai_only_to_a_thai_profile() {
        let synth = WindowsSynthesizer::from_voice_setting("profile:female:child");
        let thai = synth.preference_for("สวัสดีค่ะ");
        assert_eq!(thai.language, "th-TH");
        assert_eq!(thai.gender, "female");
        assert_eq!(thai.age, "child");
        assert_eq!(synth.preference_for("hello").language, "en");
    }

    #[test]
    fn reference_voice_still_synthesizes_ignoring_the_credential() {
        // The reference synth ignores the threaded credential (it makes no
        // authenticated call) — a plain round-trip of the text bytes.
        let clip = ReferenceSynthesizer::new()
            .synthesize("hello", None)
            .expect("reference synth never fails");
        assert_eq!(clip.bytes, b"hello");
        assert_eq!(clip.format, ocp_audio_store::AudioFormat::Wav);
    }
}
