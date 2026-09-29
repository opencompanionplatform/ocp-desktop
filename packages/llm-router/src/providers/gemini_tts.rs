//! I7 Voice V2: Gemini cloud TTS behind the [`Synthesizer`] seam.
//!
//! The demo's local voice (`adapter::WindowsSynthesizer`, Windows System.Speech)
//! can only speak the OS's installed voices — English only on this Windows ARM64
//! machine, where the Thai OneCore voice refuses to install. Gemini TTS speaks
//! Thai (and 40+ other languages, auto-detected from the text), so it plugs in
//! here as the *preferred* `tts` provider with the OS voice as the offline/
//! fallback tail of the chain: online → real Thai voice, offline/quota-exhausted
//! → OS voice, never silence.
//!
//! The production path uses the current Gemini **Interactions API** TTS shape:
//! `POST .../interactions` with `model`, `input`, `response_format:{type:"audio"}`
//! and `generation_config.speech_config`. Audio is returned as a base64 audio
//! content block. The TTS model chooses its supported audio encoding when no
//! MIME type is forced; we decode the returned block and wrap raw PCM in a
//! canonical WAV header (the exact bytes the runtime's
//! `AudioStreamWAV.load_from_file` already plays), so nothing downstream
//! changes. The decoder still understands the older generateContent inlineData
//! shape so recorded fixtures and rollback tests remain compatible.
//!
//! SEC-030: the API key is the router-supplied `credential`, read from the
//! `CredentialStore` at call time and passed straight through `TtsAdapter` —
//! this adapter never stores or logs it, and it rides the `x-goog-api-key`
//! header, never the URL.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::Value;

use crate::adapter::{
    ProviderError, StreamingAudioFormat, StreamingSynthesizer, Synthesized, Synthesizer,
};

const DEFAULT_BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";
/// Economy default; the 3.1 preview remains an explicit streaming option.
pub const DEFAULT_MODEL: &str = "gemini-2.5-flash-preview-tts";
pub const STREAMING_MODEL: &str = "gemini-3.1-flash-tts-preview";
const RATE_LIMIT_COOLDOWN: Duration = Duration::from_secs(60);
static RATE_LIMITED_UNTIL: LazyLock<Mutex<HashMap<String, Instant>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
/// A prebuilt voice persona (30 exist, all language-independent — the persona
/// speaks whatever language the text is in).
pub const DEFAULT_VOICE: &str = "Kore";

#[must_use]
pub fn supported_model(value: &str) -> &'static str {
    if value.trim() == STREAMING_MODEL {
        STREAMING_MODEL
    } else {
        DEFAULT_MODEL
    }
}

#[must_use]
pub fn is_streaming_model(value: &str) -> bool {
    supported_model(value) == STREAMING_MODEL
}

fn rate_limit_active(model: &str) -> bool {
    RATE_LIMITED_UNTIL
        .lock()
        .ok()
        .and_then(|deadlines| deadlines.get(model).copied())
        .is_some_and(|deadline| Instant::now() < deadline)
}

fn mark_rate_limited(model: &str) {
    if let Ok(mut deadlines) = RATE_LIMITED_UNTIL.lock() {
        deadlines.insert(model.to_owned(), Instant::now() + RATE_LIMIT_COOLDOWN);
    }
}

/// Backend-agnostic voice preference for a companion — the "gender toggle" a
/// settings menu exposes. Each synthesizer maps it to a concrete voice in its
/// own catalog (Gemini names below; a future os-tts mapping would pick an
/// installed SAPI voice). The gender→voice labels are **our curation**: Gemini
/// publishes only a tone per voice, not a gender. Lives in this module for now;
/// it moves to a shared voice module once a second backend gains voice
/// selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VoiceGender {
    Male,
    Female,
    #[default]
    Neutral,
}

impl VoiceGender {
    /// Parse a settings/CLI token (`male`/`female`/`neutral`, case-insensitive,
    /// single-letter accepted) — the value a menu or the kernel's `/voice`
    /// command supplies.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "male" | "m" => Some(Self::Male),
            "female" | "f" => Some(Self::Female),
            "neutral" | "n" => Some(Self::Neutral),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VoiceAge {
    Child,
    #[default]
    Adult,
}

impl VoiceAge {
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "child" | "kid" | "young" => Some(Self::Child),
            "adult" => Some(Self::Adult),
            _ => None,
        }
    }
}

/// Provider-neutral companion voice presentation. The fields describe the
/// desired voice, not the character's gender identity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VoiceProfile {
    pub gender: VoiceGender,
    pub age: VoiceAge,
}

impl VoiceProfile {
    #[must_use]
    pub fn parse(setting: &str) -> Option<Self> {
        let normalized = setting.trim().to_ascii_lowercase();
        let profile = normalized.strip_prefix("profile:").unwrap_or(&normalized);
        let mut parts = profile.split(':');
        let gender = VoiceGender::parse(parts.next()?)?;
        let age = parts.next().and_then(VoiceAge::parse).unwrap_or_default();
        (parts.next().is_none()).then_some(Self { gender, age })
    }
}

/// Map a neutral gender to a concrete Gemini voice persona (curated from
/// listening — `Puck` reads male, `Kore` female, `Autonoe` mid/bright). The
/// kernel constructs a `GeminiSynthesizer` with this voice for the companion's
/// configured gender.
#[must_use]
pub fn voice_for(gender: VoiceGender) -> &'static str {
    voice_for_profile(VoiceProfile {
        gender,
        age: VoiceAge::Adult,
    })
}

#[must_use]
pub fn voice_for_profile(profile: VoiceProfile) -> &'static str {
    match (profile.gender, profile.age) {
        (VoiceGender::Male, VoiceAge::Adult) => "Puck",
        (VoiceGender::Female, VoiceAge::Adult) => "Kore",
        (VoiceGender::Neutral, VoiceAge::Adult) => "Autonoe",
        (VoiceGender::Male, VoiceAge::Child) => "Fenrir",
        (VoiceGender::Female, VoiceAge::Child) => "Leda",
        (VoiceGender::Neutral, VoiceAge::Child) => "Zephyr",
    }
}

/// All 30 Gemini TTS prebuilt voices currently published by Google. Keeping
/// this catalog in the provider layer lets the UI expose the real vendor
/// choices without coupling the Godot layer to Gemini-specific wire details.
pub const GEMINI_VOICES: &[(&str, &str)] = &[
    ("Zephyr", "Bright"),
    ("Puck", "Upbeat"),
    ("Charon", "Informative"),
    ("Kore", "Firm"),
    ("Fenrir", "Excitable"),
    ("Leda", "Youthful"),
    ("Orus", "Firm"),
    ("Aoede", "Breezy"),
    ("Callirrhoe", "Easy-going"),
    ("Autonoe", "Bright"),
    ("Enceladus", "Breathy"),
    ("Iapetus", "Clear"),
    ("Umbriel", "Easy-going"),
    ("Algieba", "Smooth"),
    ("Despina", "Smooth"),
    ("Erinome", "Clear"),
    ("Algenib", "Gravelly"),
    ("Rasalgethi", "Informative"),
    ("Laomedeia", "Upbeat"),
    ("Achernar", "Soft"),
    ("Alnilam", "Firm"),
    ("Schedar", "Even"),
    ("Gacrux", "Mature"),
    ("Pulcherrima", "Forward"),
    ("Achird", "Friendly"),
    ("Zubenelgenubi", "Casual"),
    ("Vindemiatrix", "Gentle"),
    ("Sadachbia", "Lively"),
    ("Sadaltager", "Knowledgeable"),
    ("Sulafat", "Warm"),
];

#[must_use]
pub fn voice_from_setting(setting: &str) -> &'static str {
    let normalized = setting.trim();
    if let Some((name, _)) = GEMINI_VOICES
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case(normalized))
    {
        return name;
    }
    if let Some(profile) = VoiceProfile::parse(normalized) {
        return voice_for_profile(profile);
    }
    "Autonoe"
}
/// Documented Gemini TTS output rate; used only as a fallback if the response's
/// mimeType omits `rate=`.
const FALLBACK_RATE_HZ: u32 = 24_000;

/// A Gemini cloud TTS voice. One instance = one (model, voice) pairing; the
/// account is supplied per-call as the credential (SEC-030), so a single
/// instance serves whatever key the router hands it.
pub struct GeminiSynthesizer {
    agent: ureq::Agent,
    base_url: String,
    model: String,
    voice: String,
}

impl GeminiSynthesizer {
    /// Real Gemini endpoint with the given model/voice. `timeout` bounds the
    /// whole request (cloud TTS is slower than the OS voice — allow a few
    /// seconds).
    #[must_use]
    pub fn new(model: impl Into<String>, voice: impl Into<String>, timeout: Duration) -> Self {
        Self::with_base_url(DEFAULT_BASE_URL, model, voice, timeout)
    }

    /// Same, but with an overridable base URL (tests / a proxy). Uses the exact
    /// native-tls + `PlatformVerifier` pairing every real adapter in this crate
    /// uses (see the `ureq` dependency comment for why `WebPki` silently fails
    /// here).
    #[must_use]
    pub fn with_base_url(
        base_url: impl Into<String>,
        model: impl Into<String>,
        voice: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .proxy(ureq::Proxy::try_from_env())
            // Keep HTTP status responses readable so provider diagnostics can
            // surface Google's sanitized error message instead of only `400`.
            // Transport/TLS failures are still returned as ureq::Error.
            .http_status_as_error(false)
            .tls_config(
                ureq::tls::TlsConfig::builder()
                    .provider(ureq::tls::TlsProvider::NativeTls)
                    .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                    .build(),
            )
            .build();
        Self {
            agent: config.new_agent(),
            base_url: base_url.into(),
            model: model.into(),
            voice: voice.into(),
        }
    }
}

impl GeminiSynthesizer {
    /// Stream Gemini 3.1 TTS audio as it is generated. The callback receives
    /// raw signed-16-bit little-endian mono PCM at 24 kHz.
    fn stream_synthesize_inner<F>(
        &self,
        text: &str,
        credential: Option<&str>,
        mut on_audio: F,
    ) -> Result<(), ProviderError>
    where
        F: FnMut(&[u8]) -> Result<(), ProviderError>,
    {
        let Some(key) = credential else {
            return Err(ProviderError::Unreachable);
        };
        if rate_limit_active(&self.model) {
            eprintln!("[gemini-tts] provider cooldown active after short-term rate limit");
            return Err(ProviderError::RateLimited);
        }
        let url = format!("{}/interactions", self.base_url.trim_end_matches('/'));
        let mut body = request_body(&self.model, text, &self.voice);
        if let Value::Object(ref mut object) = body {
            object.insert("stream".to_owned(), Value::Bool(true));
        }
        let mut response = self
            .agent
            .post(&url)
            .header("x-goog-api-key", key)
            .header("Api-Revision", "2026-05-20")
            .header("Accept", "text/event-stream")
            .send_json(body)
            .map_err(|e| {
                eprintln!("[gemini-tts] streaming request failed: {e}");
                map_error(&e)
            })?;

        let status = response.status();
        if !status.is_success() {
            let body = response.body_mut().read_to_string().unwrap_or_default();
            let json = serde_json::from_str::<Value>(&body).ok();
            let provider_error = classify_provider_error(status.as_u16(), json.as_ref());
            if provider_error == ProviderError::RateLimited {
                mark_rate_limited(&self.model);
            }
            let message = json
                .as_ref()
                .and_then(|json| find_error_message(json).map(str::to_owned))
                .unwrap_or_else(|| "Gemini streaming TTS request rejected".to_owned());
            eprintln!(
                "[gemini-tts] streaming http {}: {}",
                status.as_u16(),
                message
            );
            return Err(provider_error);
        }

        use std::io::Read;
        let mut reader = response.body_mut().as_reader();
        let mut read_buffer = [0_u8; 16 * 1024];
        let mut pending = String::new();
        let mut saw_audio = false;

        loop {
            let count = reader
                .read(&mut read_buffer)
                .map_err(|_| ProviderError::ElevatedErrorRate)?;
            if count == 0 {
                break;
            }
            pending.push_str(&String::from_utf8_lossy(&read_buffer[..count]));
            while let Some(newline) = pending.find('\n') {
                let line = pending[..newline].trim_end_matches('\r').trim().to_owned();
                pending.drain(..=newline);
                let data = line.strip_prefix("data:").map(str::trim).unwrap_or(&line);
                if data.is_empty() || data == "[DONE]" {
                    continue;
                }
                let Ok(event) = serde_json::from_str::<Value>(data) else {
                    continue;
                };
                if event
                    .get("event_type")
                    .and_then(Value::as_str)
                    .is_some_and(|kind| kind == "error")
                {
                    let provider_error = classify_provider_error(429, Some(&event));
                    if provider_error == ProviderError::RateLimited {
                        mark_rate_limited(&self.model);
                    }
                    return Err(provider_error);
                }
                if let Some(audio) = decode_interaction_stream_audio(&event)? {
                    saw_audio = true;
                    on_audio(&audio)?;
                }
            }
        }

        if !pending.trim().is_empty() {
            let data = pending
                .trim()
                .strip_prefix("data:")
                .map(str::trim)
                .unwrap_or(pending.trim());
            if let Ok(event) = serde_json::from_str::<Value>(data) {
                if event
                    .get("event_type")
                    .and_then(Value::as_str)
                    .is_some_and(|kind| kind == "error")
                {
                    let provider_error = classify_provider_error(429, Some(&event));
                    if provider_error == ProviderError::RateLimited {
                        mark_rate_limited(&self.model);
                    }
                    return Err(provider_error);
                }
                if let Some(audio) = decode_interaction_stream_audio(&event)? {
                    saw_audio = true;
                    on_audio(&audio)?;
                }
            }
        }
        if saw_audio {
            Ok(())
        } else {
            Err(ProviderError::ElevatedErrorRate)
        }
    }
}

impl StreamingSynthesizer for GeminiSynthesizer {
    fn stream_format(&self) -> StreamingAudioFormat {
        StreamingAudioFormat {
            sample_rate: 24_000,
            channels: 1,
            sample_width: 2,
        }
    }

    fn stream_synthesize(
        &self,
        text: &str,
        credential: Option<&str>,
        on_audio: &mut dyn FnMut(&[u8]) -> Result<(), ProviderError>,
    ) -> Result<(), ProviderError> {
        self.stream_synthesize_inner(text, credential, |audio| on_audio(audio))
    }
}

impl Synthesizer for GeminiSynthesizer {
    fn synthesize(
        &self,
        text: &str,
        credential: Option<&str>,
    ) -> Result<Synthesized, ProviderError> {
        // SEC-030: a cloud provider needs a key — bail before any network call
        // (Unreachable → Failed → the router falls to the OS-voice tail) rather
        // than making a request we already know will be rejected.
        let Some(key) = credential else {
            return Err(ProviderError::Unreachable);
        };
        if rate_limit_active(&self.model) {
            eprintln!("[gemini-tts] provider cooldown active after short-term rate limit");
            return Err(ProviderError::RateLimited);
        }

        let url = format!("{}/interactions", self.base_url.trim_end_matches('/'));
        // Default `http_status_as_error` (true): a 4xx/5xx (bad key, quota,
        // malformed request) comes back as `Err(StatusCode)` → `map_error` →
        // `ElevatedErrorRate`, so the router degrades this provider and falls
        // back to the OS voice for this turn. Log only the transport/status
        // error; the API key is in a header and is never included in this text.
        let mut response = self
            .agent
            .post(&url)
            .header("x-goog-api-key", key)
            .header("Api-Revision", "2026-05-20")
            .send_json(request_body(&self.model, text, &self.voice))
            .map_err(|e| {
                eprintln!("[gemini-tts] request failed: {e}");
                map_error(&e)
            })?;

        let status = response.status();
        let body = response
            .body_mut()
            .read_to_string()
            .map_err(|_| ProviderError::ElevatedErrorRate)?;
        if !status.is_success() {
            let json = serde_json::from_str::<Value>(&body).ok();
            let provider_error = classify_provider_error(status.as_u16(), json.as_ref());
            if provider_error == ProviderError::RateLimited {
                mark_rate_limited(&self.model);
            }
            let message = json
                .as_ref()
                .and_then(|json| find_error_message(json).map(str::to_owned))
                .unwrap_or_else(|| {
                    let compact = body.replace(['\r', '\n'], " ");
                    let preview: String = compact.chars().take(500).collect();
                    if preview.trim().is_empty() {
                        "Gemini API rejected the TTS request (empty response body)".to_owned()
                    } else {
                        format!("Gemini API rejected the TTS request: {preview}")
                    }
                });
            eprintln!("[gemini-tts] http {}: {}", status.as_u16(), message);
            return Err(provider_error);
        }
        let json: Value = serde_json::from_str(&body).map_err(|_| {
            eprintln!("[gemini-tts] response was not valid JSON");
            ProviderError::ElevatedErrorRate
        })?;
        let (audio, rate, is_wav) = extract_audio(&json)?;
        if audio.is_empty() {
            eprintln!("[gemini-tts] provider returned an empty audio payload");
            return Err(ProviderError::ElevatedErrorRate);
        }

        if is_wav {
            let duration_ms = ocp_os_tts::wav_duration_ms(&audio).unwrap_or(0);
            if duration_ms == 0 {
                eprintln!("[gemini-tts] provider returned a zero-duration WAV payload");
                return Err(ProviderError::ElevatedErrorRate);
            }
            return Ok(Synthesized {
                bytes: audio,
                format: ocp_audio_store::AudioFormat::Wav,
                duration_ms,
            });
        }

        let bytes = pcm_to_wav(&audio, rate, 1, 16);
        Ok(Synthesized {
            bytes,
            format: ocp_audio_store::AudioFormat::Wav,
            duration_ms: duration_ms(audio.len(), rate, 1, 16),
        })
    }
}

/// Current single-speaker Interactions API body. Follow Google's documented
/// TTS request shape exactly: select audio output and let the model choose its
/// native PCM representation. The returned audio bytes are already suitable
/// for writing directly as 24 kHz / 16-bit / mono PCM.
fn request_body(model: &str, text: &str, voice: &str) -> Value {
    serde_json::json!({
        "model": model,
        "input": text,
        "response_format": { "type": "audio" },
        "generation_config": { "speech_config": [{ "voice": voice }] }
    })
}

fn decode_interaction_stream_audio(event: &Value) -> Result<Option<Vec<u8>>, ProviderError> {
    let is_audio_delta = event
        .get("event_type")
        .and_then(Value::as_str)
        .is_some_and(|kind| kind == "step.delta")
        && event
            .pointer("/delta/type")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind == "audio");
    if !is_audio_delta {
        return Ok(None);
    }

    let delta = &event["delta"];
    if let Some(mime) = delta
        .get("mime_type")
        .or_else(|| delta.get("mimeType"))
        .and_then(Value::as_str)
    {
        if !mime.eq_ignore_ascii_case("audio/l16") {
            eprintln!("[gemini-tts] unsupported streaming audio mime type: {mime}");
            return Err(ProviderError::ElevatedErrorRate);
        }
    }
    let rate = delta
        .get("sample_rate")
        .or_else(|| delta.get("sampleRate"))
        .and_then(Value::as_u64)
        .unwrap_or(u64::from(FALLBACK_RATE_HZ));
    let channels = delta.get("channels").and_then(Value::as_u64).unwrap_or(1);
    if rate != u64::from(FALLBACK_RATE_HZ) || channels != 1 {
        eprintln!(
            "[gemini-tts] unsupported streaming audio format: rate={rate} channels={channels}"
        );
        return Err(ProviderError::ElevatedErrorRate);
    }

    let Some(encoded) = delta.get("data").and_then(Value::as_str) else {
        return Ok(None);
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| ProviderError::ElevatedErrorRate)?;
    if bytes.is_empty() {
        return Ok(None);
    }
    Ok(Some(bytes))
}

/// Map the provider's documented machine-readable error code before falling
/// back to HTTP status. A generic 429 is treated as a short-term rate limit;
/// only an explicit `quota_exceeded` code is allowed to trigger daily-quota UX.
fn classify_provider_error(status: u16, value: Option<&Value>) -> ProviderError {
    let code = value
        .and_then(find_error_code)
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    match code.as_str() {
        "quota_exceeded" => ProviderError::QuotaExceeded,
        "rate_limit_exceeded" | "too_many_requests" => ProviderError::RateLimited,
        "authentication" | "authentication_error" | "invalid_api_key" | "api_key_invalid" => {
            ProviderError::AuthFailed
        }
        _ => match status {
            401 | 403 => ProviderError::AuthFailed,
            429 => ProviderError::RateLimited,
            _ => ProviderError::ElevatedErrorRate,
        },
    }
}

fn find_error_code(value: &Value) -> Option<&str> {
    match value {
        Value::Object(map) => {
            if let Some(error) = map.get("error") {
                if let Some(code) = error.get("code").and_then(Value::as_str) {
                    return Some(code);
                }
                if let Some(code) = find_error_code(error) {
                    return Some(code);
                }
            }
            if let Some(code) = map.get("code").and_then(Value::as_str) {
                return Some(code);
            }
            map.values().find_map(find_error_code)
        }
        Value::Array(values) => values.iter().find_map(find_error_code),
        _ => None,
    }
}

/// Transport faults become `Unreachable`; authentication and quota statuses
/// stay distinct so Runtime can expose bounded remediation codes. Other HTTP
/// or JSON faults degrade and fall back. A 200-with-wrong-shape is handled in
/// `extract_audio`, not here.
fn map_error(err: &ureq::Error) -> ProviderError {
    match err {
        ureq::Error::Timeout(_) => ProviderError::Timeout,
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed | ureq::Error::Io(_) => {
            ProviderError::Unreachable
        }
        ureq::Error::StatusCode(401 | 403) => ProviderError::AuthFailed,
        // Without a response body there is no evidence that 429 means the
        // daily/project quota. Treat it as a retryable short-term limit.
        ureq::Error::StatusCode(429) => ProviderError::RateLimited,
        ureq::Error::StatusCode(_) | ureq::Error::Json(_) => ProviderError::ElevatedErrorRate,
        _ => ProviderError::Unreachable,
    }
}

/// Google error responses can be either an object or a one-element array
/// depending on the edge/API surface. Find a nested `error.message` without
/// ever including request headers or credentials in diagnostics.
fn find_error_message(value: &Value) -> Option<&str> {
    match value {
        Value::Object(map) => {
            if let Some(error) = map.get("error") {
                if let Some(message) = error.get("message").and_then(Value::as_str) {
                    return Some(message);
                }
                if let Some(message) = find_error_message(error) {
                    return Some(message);
                }
            }
            map.values().find_map(find_error_message)
        }
        Value::Array(values) => values.iter().find_map(find_error_message),
        _ => None,
    }
}

/// Pull base64 audio out of the current Interactions response, while retaining
/// compatibility with the older generateContent `inlineData` response used by
/// fixtures and rollback tests. Returns `(bytes, sample_rate, is_wav)`.
fn extract_audio(json: &Value) -> Result<(Vec<u8>, u32, bool), ProviderError> {
    if let Some((b64, mime, sample_rate)) = find_interaction_audio(json) {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|_| ProviderError::ElevatedErrorRate)?;
        if bytes.is_empty() {
            return Err(ProviderError::ElevatedErrorRate);
        }
        let mime = mime.unwrap_or("audio/l16");
        let rate = sample_rate.unwrap_or_else(|| sample_rate_from_mime(mime));
        let is_wav = mime.eq_ignore_ascii_case("audio/wav")
            || (bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE");
        return Ok((bytes, rate, is_wav));
    }

    let inline = &json["candidates"][0]["content"]["parts"][0]["inlineData"];
    let b64 = inline["data"]
        .as_str()
        .ok_or(ProviderError::ElevatedErrorRate)?;
    let mime = inline["mimeType"]
        .as_str()
        .unwrap_or("audio/L16;codec=pcm;rate=24000");
    let rate = sample_rate_from_mime(mime);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|_| ProviderError::ElevatedErrorRate)?;
    if bytes.is_empty() {
        return Err(ProviderError::ElevatedErrorRate);
    }
    let is_wav = mime.to_ascii_lowercase().contains("wav")
        || (bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE");
    Ok((bytes, rate, is_wav))
}

fn find_interaction_audio(value: &Value) -> Option<(&str, Option<&str>, Option<u32>)> {
    match value {
        Value::Object(map) => {
            let is_audio = map
                .get("type")
                .and_then(Value::as_str)
                .is_some_and(|kind| kind.eq_ignore_ascii_case("audio"));
            if is_audio {
                if let Some(data) = map.get("data").and_then(Value::as_str) {
                    let mime = map
                        .get("mime_type")
                        .or_else(|| map.get("mimeType"))
                        .and_then(Value::as_str);
                    let rate = map
                        .get("sample_rate")
                        .or_else(|| map.get("sampleRate"))
                        .and_then(Value::as_u64)
                        .and_then(|value| u32::try_from(value).ok());
                    return Some((data, mime, rate));
                }
            }
            map.values().find_map(find_interaction_audio)
        }
        Value::Array(values) => values.iter().find_map(find_interaction_audio),
        _ => None,
    }
}

/// `audio/L16;codec=pcm;rate=24000` → 24000, defaulting if absent.
fn sample_rate_from_mime(mime: &str) -> u32 {
    mime.split(';')
        .find_map(|p| p.trim().strip_prefix("rate="))
        .and_then(|r| r.parse::<u32>().ok())
        .unwrap_or(FALLBACK_RATE_HZ)
}

/// Clip length in ms from raw PCM size (integer math, no float rounding drift).
fn duration_ms(pcm_len: usize, rate: u32, channels: u16, bits: u16) -> u32 {
    let byte_rate = u64::from(rate) * u64::from(channels) * u64::from(bits / 8);
    if byte_rate == 0 {
        return 0;
    }
    u32::try_from(pcm_len as u64 * 1000 / byte_rate).unwrap_or(u32::MAX)
}

/// Wrap raw little-endian 16-bit PCM in a canonical 44-byte WAV/RIFF header —
/// the exact fields `ocp_os_tts::wav_duration_ms` parses and the runtime's
/// `AudioStreamWAV.load_from_file` plays.
fn pcm_to_wav(pcm: &[u8], sample_rate: u32, channels: u16, bits: u16) -> Vec<u8> {
    let block_align = channels * bits / 8;
    let byte_rate = sample_rate * u32::from(block_align);
    let data_len = u32::try_from(pcm.len()).unwrap_or(u32::MAX);
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes()); // PCM fmt chunk size
    wav.extend_from_slice(&1u16.to_le_bytes()); // audioFormat = 1 (PCM)
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn economy_is_default_and_only_the_allowlisted_quality_model_streams() {
        assert_eq!(DEFAULT_MODEL, "gemini-2.5-flash-preview-tts");
        assert_eq!(supported_model("unknown"), DEFAULT_MODEL);
        assert!(!is_streaming_model(DEFAULT_MODEL));
        assert!(is_streaming_model(STREAMING_MODEL));
    }

    #[test]
    fn rate_limit_cooldown_is_scoped_per_model() {
        mark_rate_limited(STREAMING_MODEL);
        assert!(rate_limit_active(STREAMING_MODEL));
        assert!(!rate_limit_active(DEFAULT_MODEL));
        if let Ok(mut deadlines) = RATE_LIMITED_UNTIL.lock() {
            deadlines.clear();
        }
        assert!(!rate_limit_active(STREAMING_MODEL));
    }

    #[test]
    fn wraps_pcm_into_a_wav_os_tts_can_parse() {
        // 24000 Hz, 16-bit mono: 48000 bytes = 1000 ms of audio.
        let pcm = vec![0u8; 48_000];
        let wav = pcm_to_wav(&pcm, 24_000, 1, 16);

        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(wav.len(), 44 + pcm.len(), "44-byte header + data");
        // Cross-check against the *independent* WAV parser in ocp-os-tts: the
        // header we write is one that path already understands.
        assert_eq!(
            ocp_os_tts::wav_duration_ms(&wav),
            Some(1000),
            "the os-tts parser reads back the duration we intended"
        );
        assert_eq!(duration_ms(pcm.len(), 24_000, 1, 16), 1000);
    }

    #[test]
    fn extracts_legacy_base64_pcm_and_rate_for_rollback_compatibility() {
        let pcm = b"\x01\x02\x03\x04".to_vec();
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pcm);
        let json = serde_json::json!({
            "candidates": [{
                "content": { "parts": [{
                    "inlineData": { "mimeType": "audio/L16;codec=pcm;rate=16000", "data": b64 }
                }]}
            }]
        });

        let (got_pcm, rate, is_wav) =
            extract_audio(&json).expect("well-shaped legacy response parses");
        assert_eq!(got_pcm, pcm);
        assert_eq!(rate, 16_000, "rate read from the mimeType, not the default");
        assert!(!is_wav);
    }

    #[test]
    fn extracts_interactions_audio_content_recursively() {
        let pcm = b"\x01\x02\x03\x04".to_vec();
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pcm);
        let json = serde_json::json!({
            "id": "interaction-test",
            "outputs": [{
                "type": "model_output",
                "content": [{
                    "type": "audio",
                    "data": b64,
                    "mime_type": "audio/l16",
                    "sample_rate": 24000,
                    "channels": 1
                }]
            }]
        });

        let (got_pcm, rate, is_wav) =
            extract_audio(&json).expect("Interactions audio response parses");
        assert_eq!(got_pcm, pcm);
        assert_eq!(rate, 24_000);
        assert!(!is_wav);
    }

    #[test]
    fn interactions_request_uses_documented_audio_schema_for_both_tts_models() {
        for model in [STREAMING_MODEL, DEFAULT_MODEL] {
            let body = request_body(model, "สวัสดี", "Kore");
            assert_eq!(body["model"], model);
            assert_eq!(body["input"], "สวัสดี");
            assert_eq!(body["response_format"]["type"], "audio");
            assert!(
                body["response_format"].get("mime_type").is_none(),
                "Gemini TTS docs use response_format.type=audio without forcing a MIME"
            );
            assert_eq!(
                body["generation_config"]["speech_config"][0]["voice"],
                "Kore"
            );
        }
    }

    #[test]
    fn interaction_stream_pcm_preserves_provider_byte_order() {
        // Gemini's documented TTS examples write decoded audio bytes directly
        // into a 24 kHz / 16-bit / mono WAV without byte swapping. Preserve the
        // provider bytes exactly before Godot consumes the PCM stream.
        let provider_pcm = [0x00, 0x10, 0x00, 0xF0];
        let event = serde_json::json!({
            "event_type": "step.delta",
            "delta": {
                "type": "audio",
                "mime_type": "audio/l16",
                "sample_rate": 24000,
                "channels": 1,
                "data": base64::engine::general_purpose::STANDARD.encode(provider_pcm)
            }
        });
        let pcm = decode_interaction_stream_audio(&event)
            .expect("valid audio delta")
            .expect("audio bytes");
        assert_eq!(pcm, provider_pcm);
        assert_eq!(i16::from_le_bytes([pcm[0], pcm[1]]), 4096);
        assert_eq!(i16::from_le_bytes([pcm[2], pcm[3]]), -4096);
    }

    #[test]
    fn interaction_non_streaming_pcm_is_preserved_before_wav_wrapping() {
        let provider_pcm = [0x00, 0x20, 0x00, 0xE0];
        let encoded = base64::engine::general_purpose::STANDARD.encode(provider_pcm);
        let json = serde_json::json!({
            "outputs": [{
                "type": "model_output",
                "content": [{
                    "type": "audio",
                    "data": encoded,
                    "mime_type": "audio/l16",
                    "sample_rate": 24000
                }]
            }]
        });
        let (pcm, rate, is_wav) = extract_audio(&json).expect("interaction audio");
        assert_eq!(rate, 24_000);
        assert!(!is_wav);
        assert_eq!(pcm, provider_pcm);
    }

    #[test]
    fn empty_audio_payload_is_a_degradable_error() {
        let pcm = Vec::<u8>::new();
        let b64 = base64::engine::general_purpose::STANDARD.encode(&pcm);
        let json = serde_json::json!({
            "outputs": [{
                "type": "model_output",
                "content": [{
                    "type": "audio",
                    "data": b64,
                    "mime_type": "audio/l16"
                }]
            }]
        });
        assert_eq!(
            extract_audio(&json),
            Err(ProviderError::ElevatedErrorRate),
            "empty provider audio must degrade instead of creating a silent WAV"
        );
    }

    #[test]
    fn an_unexpected_200_shape_is_a_degradable_error_not_a_panic() {
        // 200 OK but no audio (e.g. the documented occasional text-token return)
        // must degrade + fall back, never crash.
        let json =
            serde_json::json!({ "candidates": [{ "content": { "parts": [{ "text": "oops" }] } }] });
        assert_eq!(extract_audio(&json), Err(ProviderError::ElevatedErrorRate));
    }

    #[test]
    fn synthesizing_without_a_credential_is_unreachable_before_any_call() {
        let synth = GeminiSynthesizer::new(DEFAULT_MODEL, DEFAULT_VOICE, Duration::from_secs(5));
        assert!(
            matches!(
                synth.synthesize("สวัสดี", None),
                Err(ProviderError::Unreachable)
            ),
            "no key -> no network call -> router falls to the OS-voice tail"
        );
    }

    #[test]
    fn extracts_google_error_message_from_array_wrapped_response() {
        let json = serde_json::json!([{
            "error": {
                "code": 400,
                "message": "API key not valid. Please pass a valid API key.",
                "status": "INVALID_ARGUMENT"
            }
        }]);
        assert_eq!(
            find_error_message(&json),
            Some("API key not valid. Please pass a valid API key.")
        );
    }

    #[test]
    fn rate_parsing_falls_back_when_the_mime_has_no_rate() {
        assert_eq!(
            sample_rate_from_mime("audio/L16;codec=pcm"),
            FALLBACK_RATE_HZ
        );
        assert_eq!(
            sample_rate_from_mime("audio/L16;codec=pcm;rate=8000"),
            8_000
        );
    }

    #[test]
    fn gender_maps_to_a_voice_and_parses_from_settings_tokens() {
        assert_eq!(voice_for(VoiceGender::Male), "Puck");
        assert_eq!(voice_for(VoiceGender::Female), "Kore");
        assert_ne!(
            voice_for(VoiceGender::Male),
            voice_for(VoiceGender::Female),
            "male and female must resolve to distinct voices"
        );
        assert_eq!(VoiceGender::parse("MALE"), Some(VoiceGender::Male));
        assert_eq!(VoiceGender::parse(" female "), Some(VoiceGender::Female));
        assert_eq!(VoiceGender::parse("f"), Some(VoiceGender::Female));
        assert_eq!(VoiceGender::parse("robot"), None);
    }

    #[test]
    fn profile_maps_age_and_preserves_a_concrete_vendor_voice() {
        assert_eq!(
            VoiceProfile::parse("profile:female:child"),
            Some(VoiceProfile {
                gender: VoiceGender::Female,
                age: VoiceAge::Child,
            })
        );
        assert_eq!(voice_from_setting("profile:female:child"), "Leda");
        assert_eq!(voice_from_setting("profile:male:adult"), "Puck");
        assert_eq!(voice_from_setting("kOrE"), "Kore");
    }

    #[test]
    fn exposes_all_current_gemini_prebuilt_voices() {
        assert_eq!(GEMINI_VOICES.len(), 30);
        assert_eq!(voice_from_setting("Puck"), "Puck");
        assert_eq!(voice_from_setting("female"), "Kore");
        assert_eq!(voice_from_setting("unknown-voice"), "Autonoe");
    }
}
