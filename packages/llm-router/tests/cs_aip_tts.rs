//! I7 Voice V1 slice 2: the routed-TTS + `audioRef` path, proven in-process
//! with the reference `tts` adapter (no real synthesizer, no runtime) — the
//! audio-side analogue of `cs_aip.rs` proving the router logic with
//! `LocalEchoAdapter`. Exercises the just-approved contracts end to end:
//! `capability: "tts"` routes through the ordinary fallback chain, the adapter
//! `put`s a clip into the kernel-owned `AudioStore` and returns a response
//! whose audio content part carries the `audioRef` id (AI_PROVIDER_API §2a),
//! and the id resolves — peek for metadata, then a single-consumer take for
//! the bytes.

use std::sync::Arc;

use ocp_audio_store::{AudioFormat, AudioStore};
use ocp_event_bus::InProcessBus;
use ocp_llm_router::adapter::{ReferenceSynthesizer, TtsAdapter};
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, LatencyClass, Limits, Locality, Message,
    ModelInfo, ProviderCapabilities, Role, RoutePolicy, RouterRequest,
};
use ocp_llm_router::{InMemoryConsentStore, InMemoryCredentialStore, Router};
use uuid::Uuid;

fn tts_caps(id: &str) -> ProviderCapabilities {
    ProviderCapabilities {
        provider_id: id.to_owned(),
        locality: Locality::Local, // OS/local voice — no SEC-035 cloud consent gate
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

fn tts_request(text: &str) -> RouterRequest {
    RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
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
            max_cost_class: CostClass::Free,
            allow_cloud: true,
        },
        streaming: false,
        foreground: true,
        limits: Limits {
            max_output_tokens: 0,
        },
    }
}

#[test]
fn a_tts_request_routes_to_an_audioref_that_resolves_to_the_synthesized_clip() {
    let bus = InProcessBus::new();
    let store = Arc::new(AudioStore::new());
    let mut router = Router::new(
        bus,
        Box::new(InMemoryConsentStore::new()),
        Box::new(InMemoryCredentialStore::new()),
    );
    router.register_provider(Box::new(TtsAdapter::new(
        tts_caps("tts-reference"),
        store.clone(),
        Box::new(ReferenceSynthesizer::new()),
    )));
    router.register_chain(Capability::Tts, CostClass::Free, &["tts-reference"]);

    let response = router
        .route(&tts_request("hello world"))
        .expect("a tts request routes like any other");

    // The response carries exactly one audio content part = an audioRef id,
    // never inline bytes (AI_PROVIDER_API §2a).
    let id_str = match response.content.as_slice() {
        [ContentPart::Audio { value }] => value.clone(),
        other => panic!("expected a single audio content part, got {other:?}"),
    };
    let audio_id = Uuid::parse_str(&id_str).expect("the audio part's value must be an audioRef id");

    // Metadata is readable without consuming (what the kernel needs to build
    // the speech-requested event).
    let audio_ref = store
        .peek(audio_id)
        .expect("the audioRef must be resolvable in the store");
    assert_eq!(
        audio_ref.format,
        AudioFormat::Wav,
        "V1 audio format is wav/PCM"
    );
    assert_eq!(audio_ref.sha256.len(), 64);
    assert_eq!(
        audio_ref.duration_ms,
        "hello world".len() as u32,
        "reference duration is 1ms/byte of the spoken text"
    );

    // The bytes resolve exactly once (the runtime's playback take).
    let bytes = store
        .take(audio_id)
        .expect("the clip's bytes must resolve once");
    assert_eq!(
        bytes, b"hello world",
        "the reference tts stored the spoken text as the placeholder clip"
    );
    assert!(
        store.take(audio_id).is_none(),
        "single-consumer: the runtime resolves each clip exactly once"
    );
}

#[test]
fn tts_falls_back_across_the_chain_like_any_capability() {
    // A dead first provider then the reference tts: proves `tts` is just a
    // capability through the ordinary fallback machinery (I5), nothing special.
    use ocp_llm_router::adapter::{ProviderError, ScriptedAdapter, ScriptedOutcome};

    let bus = InProcessBus::new();
    let store = Arc::new(AudioStore::new());
    let mut router = Router::new(
        bus,
        Box::new(InMemoryConsentStore::new()),
        Box::new(InMemoryCredentialStore::new()),
    );
    router.register_provider(Box::new(ScriptedAdapter::new(
        tts_caps("tts-primary"),
        vec![ScriptedOutcome::Err(ProviderError::Unreachable)],
    )));
    router.register_provider(Box::new(TtsAdapter::new(
        tts_caps("tts-reference"),
        store.clone(),
        Box::new(ReferenceSynthesizer::new()),
    )));
    router.register_chain(
        Capability::Tts,
        CostClass::Free,
        &["tts-primary", "tts-reference"],
    );

    let response = router
        .route(&tts_request("fallback please"))
        .expect("falls through to the reference tts");
    assert_eq!(response.provider_id, "tts-reference");
    assert_eq!(
        response.fallback_depth, 1,
        "one provider was skipped before success"
    );
    assert!(matches!(
        response.content.as_slice(),
        [ContentPart::Audio { .. }]
    ));
}

/// The **real OS voice** through the full router → `audioRef` path. Windows-only
/// (System.Speech) and headless — the V1 "the companion talks" bar minus the
/// runtime's actual playback (slice 4). Proves the same routing yields a
/// genuine, resolvable WAV clip, not just a reference stand-in.
///
/// This is opt-in because System.Speech can block on a Windows host without a
/// usable voice provider. Run explicitly with:
/// `cargo test -p ocp-llm-router --test cs_aip_tts -- --ignored`
#[cfg(windows)]
#[test]
#[ignore = "requires an opt-in Windows System.Speech voice host"]
fn the_windows_os_voice_routes_to_a_real_wav_audioref() {
    use ocp_llm_router::adapter::WindowsSynthesizer;

    let bus = InProcessBus::new();
    let store = Arc::new(AudioStore::new());
    let mut router = Router::new(
        bus,
        Box::new(InMemoryConsentStore::new()),
        Box::new(InMemoryCredentialStore::new()),
    );
    router.register_provider(Box::new(TtsAdapter::new(
        tts_caps("tts-windows"),
        store.clone(),
        Box::new(WindowsSynthesizer::new()),
    )));
    router.register_chain(Capability::Tts, CostClass::Free, &["tts-windows"]);

    let response = router
        .route(&tts_request("Open Companion Platform voice online."))
        .expect("the windows tts routes");
    let id_str = match response.content.as_slice() {
        [ContentPart::Audio { value }] => value.clone(),
        other => panic!("expected an audio content part, got {other:?}"),
    };
    let audio_id = Uuid::parse_str(&id_str).unwrap();

    let audio_ref = store.peek(audio_id).expect("the real clip is in the store");
    assert_eq!(audio_ref.format, AudioFormat::Wav);
    assert!(
        audio_ref.duration_ms > 0,
        "a real spoken clip has a non-zero duration"
    );

    let wav = store.take(audio_id).expect("the clip's bytes resolve once");
    assert!(
        wav.len() > 44 && &wav[0..4] == b"RIFF" && &wav[8..12] == b"WAVE",
        "the OS voice produced a genuine WAV clip routed all the way to an audioRef"
    );
}
