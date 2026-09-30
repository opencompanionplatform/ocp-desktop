//! I7 Voice V1 slice 4a: the kernel-side "speak" orchestration.
//!
//! [`synthesize_speech_request`] turns a reply's text into an
//! `ocp.behavior.speech-requested` envelope (RUNTIME_API §2.6) by routing a
//! **TTS** request through the AI Router (VOICE.md's "voice is routed
//! intelligence"). On success the synthesized clip's `audioRef` rides the
//! event so the runtime plays real audio; on any TTS failure the envelope
//! still goes out with `text`/`subtitle` and **no** `audioRef`, so the runtime
//! degrades to its own voice or a subtitle — never silence (`tts-unavailable`).
//!
//! Pure orchestration — router + audio store + event shape — so it is
//! unit-tested with the reference synthesizer, no real voice and no live
//! runtime. The Godot side (resolve the ref, play it, emit real
//! `speech-completed` timing) is slice 4b, proven live in the runtime.

#![forbid(unsafe_code)]

pub mod vad;
pub use vad::{
    pcm16_energy, VadConfig, VadDecision, VadState, VadTransition, VoiceActivityDetector,
};

use ocp_audio_store::AudioStore;
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, Limits, Message, Role, RoutePolicy,
    RouterRequest,
};
use ocp_llm_router::Router;
use ocp_shared_types::Envelope;
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

/// Envelope `source` for everything this crate emits.
pub const SOURCE: &str = "voice";

/// The IPC request the runtime sends the kernel to fetch an `audioRef`'s bytes
/// for playback (VOICE.md §3.1 single-consumer resolution). Small + JSON-safe;
/// the **bytes** travel back over the IPC binary transport (packages/ipc
/// framing), never a ≤1 MiB JSON envelope.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AudioResolveRequest {
    pub audio_ref_id: Uuid,
}

/// Kernel-side handler for [`AudioResolveRequest`]: resolve the ref **once**
/// (single-consumer — playing a clip consumes it) and return its bytes, or
/// `None` if the id is unknown, already played, or expired. The kernel frames
/// the `Some(bytes)` back to the runtime over IPC; `None` becomes a
/// `tts-unavailable`-style degradation (the runtime shows the subtitle it
/// already has from `speech-requested`).
#[must_use]
pub fn resolve_audio(store: &AudioStore, req: &AudioResolveRequest) -> Option<Vec<u8>> {
    store.take(req.audio_ref_id)
}

/// One spoken turn (RUNTIME_API §2.6 `speech-requested`).
pub struct SpeakRequest {
    /// Which companion is speaking (required on every behavior/runtime event,
    /// ADR-0013 multi-companion addendum). A **string** id (RUNTIME_API §8.1:
    /// `"default"`, `"aiko"`, ...) — the same addressing the rest of the
    /// platform uses, so the runtime plays the clip on the right sprite and the
    /// deferred `speech-completed` routes back to that companion's actor.
    pub companion_id: String,
    /// The causing user turn / behavior event, for tracing (NFR-004).
    pub correlation_id: Uuid,
    pub text: String,
    /// Show a subtitle alongside/instead of audio.
    pub subtitle: bool,
    /// May this clip be interrupted (barge-in, already in the schema).
    pub interruptible: bool,
    /// `None` = runtime default voice.
    pub voice_id: Option<String>,
}

/// Routes `req.text` through the AI Router's `tts` chain and returns the
/// `ocp.behavior.speech-requested` envelope for the kernel to publish. The
/// `audioRef` is present iff a `tts` provider served the request; otherwise the
/// runtime falls back to subtitle/its own voice.
#[must_use]
pub fn synthesize_speech_request(
    router: &mut Router,
    store: &AudioStore,
    req: &SpeakRequest,
) -> Envelope {
    // Route TTS; resolve the returned ref's metadata (peek, non-consuming — the
    // runtime later `take`s the bytes). Any failure along the way (no route,
    // provider failure, a non-audio response) collapses to `None` = no audio.
    let audio_ref_json = router
        .route(&tts_request(&req.text, req.correlation_id))
        .ok()
        .and_then(|response| match response.content.as_slice() {
            [ContentPart::Audio { value }] => Uuid::parse_str(value).ok(),
            _ => None,
        })
        .and_then(|audio_id| store.peek(audio_id))
        .map(|a| json!({ "id": a.id, "format": a.format, "durationMs": a.duration_ms, "sha256": a.sha256 }));

    let data = json!({
        "companionId": req.companion_id,
        "speechId": Uuid::now_v7(),
        "text": req.text,
        "voiceId": req.voice_id,
        "subtitle": req.subtitle,
        "interruptible": req.interruptible,
        "audioRef": audio_ref_json, // null when TTS was unavailable
    });

    Envelope::new("ocp.behavior.speech-requested", SOURCE, data)
        .expect("ocp.behavior.speech-requested is a valid envelope type")
        .with_correlation(req.correlation_id)
}

fn tts_request(text: &str, correlation_id: Uuid) -> RouterRequest {
    RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id,
        capability: Capability::Tts,
        messages: vec![Message {
            role: Role::Assistant,
            content: vec![ContentPart::Text {
                value: text.to_owned(),
            }],
        }],
        memory_excerpts: vec![],
        tools: vec![],
        caller_context: CallerContext {
            context_id: "companion".to_owned(),
            granted_capabilities: vec![],
        },
        policy: RoutePolicy {
            // A spoken turn may use a paid cloud voice (a language the local OS
            // voice can't speak — Thai on this Windows ARM64 box), so allow up
            // to metered cost; the chain still falls back to the free OS voice.
            max_cost_class: CostClass::Metered,
            allow_cloud: true,
        },
        streaming: false,
        foreground: true,
        limits: Limits {
            max_output_tokens: 0,
        },
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use ocp_audio_store::AudioFormat;
    use ocp_event_bus::InProcessBus;
    use ocp_llm_router::adapter::{ReferenceSynthesizer, TtsAdapter};
    use ocp_llm_router::types::{LatencyClass, Locality, ModelInfo, ProviderCapabilities};
    use ocp_llm_router::{InMemoryConsentStore, InMemoryCredentialStore};

    use super::*;

    fn tts_caps(id: &str) -> ProviderCapabilities {
        ProviderCapabilities {
            provider_id: id.to_owned(),
            locality: Locality::Local,
            capabilities: vec![Capability::Tts],
            streaming: false,
            context_window: 0,
            latency_class: LatencyClass::Interactive,
            cost_class: CostClass::Free,
            models: vec![ModelInfo {
                model_id: format!("{id}-model"),
                capabilities: vec![Capability::Tts],
                streaming: false,
            }],
        }
    }

    fn router_without_tts() -> Router {
        Router::new(
            InProcessBus::new(),
            Box::new(InMemoryConsentStore::new()),
            Box::new(InMemoryCredentialStore::new()),
        )
    }

    #[test]
    fn speaking_produces_a_speech_requested_envelope_with_a_resolvable_audioref() {
        let store = Arc::new(AudioStore::new());
        let mut router = router_without_tts();
        router.register_provider(Box::new(TtsAdapter::new(
            tts_caps("tts-reference"),
            store.clone(),
            Box::new(ReferenceSynthesizer::new()),
        )));
        router.register_chain(Capability::Tts, CostClass::Metered, &["tts-reference"]);

        let companion = "default";
        let correlation = Uuid::now_v7();
        let env = synthesize_speech_request(
            &mut router,
            &store,
            &SpeakRequest {
                companion_id: companion.to_owned(),
                correlation_id: correlation,
                text: "hello there".to_owned(),
                subtitle: true,
                interruptible: true,
                voice_id: None,
            },
        );

        assert_eq!(env.event_type, "ocp.behavior.speech-requested");
        assert_eq!(
            env.correlation_id,
            Some(correlation),
            "the causing turn is traceable (NFR-004)"
        );
        assert_eq!(env.data["companionId"], json!(companion));
        assert_eq!(env.data["text"], json!("hello there"));
        assert_eq!(env.data["subtitle"], json!(true));

        let audio = &env.data["audioRef"];
        assert!(
            !audio.is_null(),
            "TTS succeeded, so an audioRef rides the event"
        );
        assert_eq!(audio["format"], json!("wav"));
        assert!(audio["durationMs"].as_u64().unwrap() > 0);

        let id = Uuid::parse_str(audio["id"].as_str().unwrap()).unwrap();
        let bytes = store
            .take(id)
            .expect("the audioRef resolves to real bytes for the runtime");
        assert_eq!(bytes, b"hello there", "the reference synthesizer's clip");
    }

    #[test]
    fn resolve_audio_hands_over_bytes_once_then_reports_absent() {
        let store = AudioStore::new();
        let audio = store.put(b"clip bytes".to_vec(), AudioFormat::Wav, 100);
        let req = AudioResolveRequest {
            audio_ref_id: audio.id,
        };

        assert_eq!(
            resolve_audio(&store, &req),
            Some(b"clip bytes".to_vec()),
            "the runtime gets the bytes to play"
        );
        assert_eq!(
            resolve_audio(&store, &req),
            None,
            "single-consumer: a replay must re-request, not double-resolve"
        );
        assert_eq!(
            resolve_audio(
                &store,
                &AudioResolveRequest {
                    audio_ref_id: Uuid::now_v7()
                }
            ),
            None,
            "an unknown/expired ref resolves to None -> runtime degrades to subtitle"
        );
    }

    #[test]
    fn audio_resolve_request_round_trips_through_json() {
        let req = AudioResolveRequest {
            audio_ref_id: Uuid::now_v7(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("audioRefId"), "camelCase wire field");
        let back: AudioResolveRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(back, req);
    }

    #[test]
    fn tts_unavailable_still_speaks_via_subtitle_with_no_audioref() {
        let store = Arc::new(AudioStore::new());
        let mut router = router_without_tts(); // no tts chain registered -> route fails

        let env = synthesize_speech_request(
            &mut router,
            &store,
            &SpeakRequest {
                companion_id: "default".to_owned(),
                correlation_id: Uuid::now_v7(),
                text: "no voice today".to_owned(),
                subtitle: true,
                interruptible: false,
                voice_id: Some("default".to_owned()),
            },
        );

        assert_eq!(env.event_type, "ocp.behavior.speech-requested");
        assert_eq!(env.data["text"], json!("no voice today"));
        assert_eq!(env.data["voiceId"], json!("default"));
        assert!(
            env.data["audioRef"].is_null(),
            "no tts provider -> no audioRef; the runtime degrades to subtitle/its own voice, never silence"
        );
        assert!(store.is_empty(), "nothing was synthesized");
    }
}
