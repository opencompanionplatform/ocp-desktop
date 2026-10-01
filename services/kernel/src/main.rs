//! ocp-kernel — minimal Native Core Service (I2 walking skeleton).
//!
//! This is deliberately tiny: it exists so the Desktop Runtime has a real
//! process to talk to (ADR-0005 tier 2). It binds the local socket
//! (`ocp_ipc::transport::Listener`), authenticates peers (SEC-040), routes
//! connections on their declared handshake `intent`, and lets you drive the
//! RUNTIME_API request-facts from stdin while logging the outcome facts the
//! runtime sends back (NFR-004 correlation visible on the console).
//!
//! Kernel-integration slice (post-I6.5): this binary now composes the
//! library-proven components into one running process —
//! - **Companion Manager** (ADR-0013): every inbound fact routes through
//!   targeted-never-broadcast addressing to per-companion Actors; the
//!   staggered `tick()` drives one Behavior Engine **per companion**
//!   (`EngineHandler`), replacing I3's single shared engine.
//! - **Activity Context Engine** (RFC-0005/I11): consumes the OS-telemetry
//!   signal family and emits `ocp.activity.state-changed`, which reaches
//!   companions via their family subscriptions like any other trigger.
//! - **OS sampling** (`ocp-os-sensors`): a kernel-side loop samples
//!   foreground process + mouse idle every few seconds and publishes the
//!   cataloged `ocp.plugin.os-telemetry-*-changed` facts. Interpretive,
//!   flagged: the sampler stamps `pluginId: "ocp-kernel-sampler"` (the
//!   catalog's mandatory field normally names a granted plugin; here the
//!   kernel itself is the sampling principal) and deliberately omits
//!   `windowTitle` (optional in the schema; `default_interpreters()` only
//!   matches `processName`, and the title is higher-sensitivity payload).
//! - Reactions coming out of a companion's engine are **stamped with that
//!   `companionId`** when their payload lacks one — interpretive, flagged:
//!   Behavior `Action` data carries no companion field yet (a contract
//!   question for the UX-Graph/I8 era), and without the stamp every
//!   reaction would render on the default sprite.
//!
//! I7 Voice V1 kernel AI slice: the kernel now **hosts the AI Router** — the
//! "kernel doesn't host the router" gap flagged since I4 — for the `tts` route.
//! `/speech <text>` routes through a local OS-voice `tts` provider, mirrors the
//! synthesized WAV into the shared audio dir, and emits
//! `ocp.behavior.speech-requested{audioRef}` so the runtime plays real audio.
//! No cloud, no credential: the demo's voice is the OS voice.
//!
//! Still NOT here, named honestly: the Plugin Host (needs install/manifest
//! infrastructure and signed packages — its own slice), and the AI
//! TurnScheduler / **chat** routing (needs real cloud credentials + the
//! turn-taking front layer — the router is hosted, but only the `tts` chain is
//! wired; `chat` arrives with the first kernel chat slice).
//!
//! Usage:
//!   cargo run -p ocp-kernel
//! Environment:
//!   OCP_IPC_SOCKET  socket name (default "ocp-runtime")
//!   OCP_IPC_TOKEN   session token (default: freshly generated and printed)

#![forbid(unsafe_code)] // SEC-042

use std::collections::HashMap;
use std::io::BufRead;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use base64::Engine as _;
use chrono::Utc;
use ocp_activity_context::{default_interpreters, ActivityContextEngine};
use ocp_audio_store::AudioStore;
use ocp_behavior_api::RulesEngine;
use ocp_behavior_engine::DeterministicEngine;
use ocp_character_package::{parse_and_resolve, ResolvedCharacter};
use ocp_companion_manager::{ActorHandler, CompanionManager, RouteOutcome};
use ocp_desktop_physics::WalkEdgeBehavior;
use ocp_event_bus::InProcessBus;
use ocp_ipc::transport::{Connection, Listener};
use ocp_ipc::{generate_token, recv_envelope, send_envelope, IpcError, INTENT_SUBSCRIBE};
use ocp_kernel::companion_physics_binding::{
    CompanionMovementCommand, CompanionPhysicsBindings, CompanionPhysicsBodyConfig,
};
use ocp_llm_router::adapter::{
    ProviderAdapter, StreamingSynthesizer, Synthesizer, TtsAdapter, WindowsSynthesizer,
};
use ocp_llm_router::providers::gemini_asr::{
    start_live_asr, GeminiAsrEvent, GeminiLiveAsrControl, LIVE_TRANSCRIBE_MODEL,
    LIVE_TRANSCRIBE_SAMPLE_RATE,
};
use ocp_llm_router::providers::gemini_live_voice::{
    start_live_voice, GeminiLiveVoiceControl, GeminiLiveVoiceEvent, LIVE_VOICE_INPUT_RATE,
    LIVE_VOICE_MODEL, LIVE_VOICE_OUTPUT_RATE,
};
use ocp_llm_router::providers::gemini_tts::{self, GeminiSynthesizer, VoiceGender};
use ocp_llm_router::providers::openrouter::OpenRouterAdapter;
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, LatencyClass, Limits, Locality, Message,
    ModelInfo, ProviderCapabilities, Role, RoutePolicy, RouterRequest,
};
use ocp_llm_router::{
    CredentialStore, InMemoryConsentStore, InMemoryCredentialStore, OsKeystoreCredentialStore,
    Router,
};
use ocp_memory::{
    Caller as MemoryCaller, ContentType as MemoryContentType, ListRequest as MemoryListRequest,
    MemoryScope, MemoryStore, OsKeystoreKeyStore, SqliteStore, WriteRequest as MemoryWriteRequest,
};
use ocp_package_loader::{load as load_package, TrustStore};
use ocp_shared_types::{Envelope, Point2};
use ocp_voice::{synthesize_speech_request, SpeakRequest};
use serde_json::json;
use uuid::Uuid;

/// The shared audio directory the kernel mirrors synthesized clips into, byte-
/// identical to the runtime bridge's `audio_clip_path` (`OCP_AUDIO_DIR`, else
/// `<temp>/ocp-audio`) so a co-located runtime reads exactly the file the
/// kernel wrote — the file-backed `audioRef` transport (I7 V1, no binary IPC
/// path for V1). Both processes must agree on this dir; keeping the derivation
/// literally the same in both crates is that agreement.
fn audio_dir() -> std::path::PathBuf {
    std::env::var_os("OCP_AUDIO_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("ocp-audio"))
}

/// Capability descriptor for the local OS-voice `tts` provider (Free, Local —
/// no cloud, no credential). The offline / fallback tail of the chain.
fn os_tts_caps() -> ProviderCapabilities {
    ProviderCapabilities {
        provider_id: "os-tts".to_owned(),
        locality: Locality::Local,
        capabilities: vec![Capability::Tts],
        streaming: false,
        context_window: 0,
        latency_class: LatencyClass::Interactive,
        cost_class: CostClass::Free,
        models: vec![ModelInfo {
            model_id: "os-tts-system-voice".to_owned(),
            capabilities: vec![Capability::Tts],
            streaming: false,
        }],
    }
}

/// Capability descriptor for the Gemini cloud `tts` provider (Metered, Cloud —
/// needs a credential). The *preferred* head of the chain: it speaks Thai,
/// which the local OS voice can't.
fn gemini_tts_caps() -> ProviderCapabilities {
    gemini_tts_caps_for("gemini-tts", gemini_tts::DEFAULT_MODEL)
}

fn gemini_tts_caps_for(provider_id: &str, model: &str) -> ProviderCapabilities {
    ProviderCapabilities {
        provider_id: provider_id.to_owned(),
        locality: Locality::Cloud,
        capabilities: vec![Capability::Tts],
        streaming: gemini_tts::is_streaming_model(model),
        context_window: 0,
        latency_class: LatencyClass::Interactive,
        cost_class: CostClass::Metered,
        models: vec![ModelInfo {
            model_id: gemini_tts::supported_model(model).to_owned(),
            capabilities: vec![Capability::Tts],
            streaming: gemini_tts::is_streaming_model(model),
        }],
    }
}

/// Build the kernel's AI Router hosting the `tts` chain on `Tts`/`Metered`.
/// When `gemini_key` is present, the Gemini cloud voice is the preferred head
/// of the chain (it speaks Thai) and the local OS voice (`local_synth`) is the
/// offline fallback tail; without a key it's OS-voice-only. `local_synth` is
/// injected so `main` uses the real [`WindowsSynthesizer`] while tests use the
/// deterministic reference one.
fn build_voice_router(
    store: Arc<AudioStore>,
    local_synth: Box<dyn Synthesizer>,
    gemini_key: Option<String>,
    gender: VoiceGender,
) -> Router {
    build_voice_router_for_model(
        store,
        local_synth,
        gemini_key,
        gender,
        gemini_tts::DEFAULT_MODEL,
    )
}

fn build_voice_router_for_model(
    store: Arc<AudioStore>,
    local_synth: Box<dyn Synthesizer>,
    gemini_key: Option<String>,
    gender: VoiceGender,
    model: &str,
) -> Router {
    build_voice_router_for_voice_setting(
        store,
        local_synth,
        gemini_key,
        gemini_tts::voice_for(gender),
        model,
    )
}

fn build_voice_router_for_voice_setting(
    store: Arc<AudioStore>,
    local_synth: Box<dyn Synthesizer>,
    gemini_key: Option<String>,
    voice_setting: &str,
    model: &str,
) -> Router {
    // SEC-030: the router reads the credential for `gemini-tts` at call time.
    // Seed it from the resolved key (env or keystore, see `main`). For the demo
    // an in-memory store is fine; a production kernel would hand the router an
    // `OsKeystoreCredentialStore` directly instead of copying the key here.
    let mut credentials = InMemoryCredentialStore::new();
    if let Some(ref key) = gemini_key {
        credentials.set("gemini-tts", key.clone());
    }

    let mut router = Router::new(
        InProcessBus::new(),
        Box::new(InMemoryConsentStore::new()),
        Box::new(credentials),
    );

    let mut chain: Vec<&str> = Vec::new();
    if gemini_key.is_some() {
        router.register_provider(Box::new(TtsAdapter::new(
            gemini_tts_caps(),
            Arc::clone(&store),
            Box::new(GeminiSynthesizer::new(
                gemini_tts::supported_model(model),
                gemini_tts::voice_from_setting(voice_setting),
                Duration::from_secs(30),
            )),
        )));
        chain.push("gemini-tts");
    }
    router.register_provider(Box::new(TtsAdapter::new(os_tts_caps(), store, local_synth)));
    chain.push("os-tts");

    router.register_chain(Capability::Tts, CostClass::Metered, &chain);
    router
}

/// Runtime Chat voice routing is stricter than the developer `/speech` path:
/// automatic cloud voice may fall back only to another configured cloud model.
/// Windows TTS is registered only when the user explicitly selected `system`.
fn build_runtime_voice_router_for_voice_setting(
    store: Arc<AudioStore>,
    local_synth: Box<dyn Synthesizer>,
    gemini_key: Option<String>,
    voice_setting: &str,
    model: &str,
    provider_id: &str,
) -> Router {
    let mut credentials = InMemoryCredentialStore::new();
    if let Some(ref key) = gemini_key {
        credentials.set("gemini-tts-primary", key.clone());
        credentials.set("gemini-tts-fallback", key.clone());
    }
    let mut router = Router::new(
        InProcessBus::new(),
        Box::new(InMemoryConsentStore::new()),
        Box::new(credentials),
    );
    let mut chain: Vec<&str> = Vec::new();
    if provider_id == "system" {
        router.register_provider(Box::new(TtsAdapter::new(os_tts_caps(), store, local_synth)));
        chain.push("os-tts");
    } else if gemini_key.is_some() {
        let primary_model = gemini_tts::supported_model(model);
        router.register_provider(Box::new(TtsAdapter::new(
            gemini_tts_caps_for("gemini-tts-primary", primary_model),
            Arc::clone(&store),
            Box::new(GeminiSynthesizer::new(
                primary_model,
                gemini_tts::voice_from_setting(voice_setting),
                Duration::from_secs(30),
            )),
        )));
        chain.push("gemini-tts-primary");
        if primary_model == gemini_tts::STREAMING_MODEL {
            router.register_provider(Box::new(TtsAdapter::new(
                gemini_tts_caps_for("gemini-tts-fallback", gemini_tts::DEFAULT_MODEL),
                store,
                Box::new(GeminiSynthesizer::new(
                    gemini_tts::DEFAULT_MODEL,
                    gemini_tts::voice_from_setting(voice_setting),
                    Duration::from_secs(30),
                )),
            )));
            chain.push("gemini-tts-fallback");
        }
    }
    router.register_chain(Capability::Tts, CostClass::Metered, &chain);
    router
}

/// Resolve the vendor-specific streaming voice behind a provider-neutral seam.
/// Today Gemini is the only streaming adapter, but Kernel/Runtime no longer
/// depend on its concrete type. Adding OpenAI later is an adapter/factory change
/// rather than another speech lifecycle implementation.
fn streaming_tts_synthesizer(
    provider_id: &str,
    model: &str,
    voice_setting: &str,
) -> Option<Box<dyn StreamingSynthesizer>> {
    match provider_id {
        "auto" | "cloud" | "gemini" | "gemini-tts" if gemini_tts::is_streaming_model(model) => {
            Some(Box::new(GeminiSynthesizer::new(
                gemini_tts::supported_model(model),
                gemini_tts::voice_from_setting(voice_setting),
                Duration::from_secs(30),
            )))
        }
        _ => None,
    }
}

/// Streaming delivery is opt-in. Quality-first whole-clip synthesis is the
/// default because it lets the provider complete/validate the audio container
/// before Godot playback. The experimental low-latency path can still be
/// requested explicitly with `deliveryMode=streaming`.
fn runtime_tts_streaming_requested(env: &Envelope) -> bool {
    env.data
        .get("deliveryMode")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "streaming" | "realtime" | "low-latency"
            )
        })
}

/// Stream one RuntimeV3 chat TTS request through the selected provider adapter.
/// The first audio delta creates the normal `speech-requested` lifecycle, then
/// each subsequent decoded PCM delta is forwarded using a vendor-neutral audio
/// envelope. If streaming was not explicitly requested or the provider cannot
/// stream, the caller uses the whole-clip quality route instead.
fn runtime_tts_request_streaming(env: &Envelope, presentation: &Presentation) -> bool {
    if env.event_type != "ocp.runtime.tts-requested" || !runtime_tts_streaming_requested(env) {
        return false;
    }
    let text = env
        .data
        .get("text")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    if text.is_empty() {
        return false;
    }
    let provider_id = env
        .data
        .get("providerId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("auto")
        .to_ascii_lowercase();
    if provider_id == "system" {
        return false;
    }
    let model = env
        .data
        .get("modelId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(gemini_tts::DEFAULT_MODEL);
    let voice_setting = env
        .data
        .get("voice")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("auto");
    let Some(synthesizer) = streaming_tts_synthesizer(&provider_id, model, voice_setting) else {
        return false;
    };
    // Gemini is the only streaming provider in this slice. Credential lookup
    // remains provider-side in Kernel so the Runtime never receives a secret.
    let Some(key) = gemini_key() else {
        eprintln!("[kernel] [voice-stream] provider credential unavailable; fallback=router");
        return false;
    };
    let format = synthesizer.stream_format();
    let companion_id = env
        .data
        .get("companionId")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("default");
    let message_id = env
        .data
        .get("messageId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let chunk_index = env
        .data
        .get("chunkIndex")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0);
    let final_chunk = env
        .data
        .get("final")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let speech_id = uuid::Uuid::now_v7();
    println!(
        "[kernel] [voice-stream] start provider={} model={} voice={} text_chars={} message={} chunk={}",
        provider_id,
        model,
        voice_setting,
        text.chars().count(),
        message_id,
        chunk_index,
    );
    let mut started = false;
    let mut sequence = 0_i64;
    let mut on_audio = |audio: &[u8]| {
        if !started {
            let speech = Envelope::new(
                "ocp.behavior.speech-requested",
                "kernel",
                serde_json::json!({
                    "speechId": speech_id,
                    "companionId": companion_id,
                    "text": text,
                    "subtitle": true,
                    "streaming": true,
                    "messageId": message_id,
                    "chunkIndex": chunk_index,
                    "final": final_chunk,
                }),
            )
            .map_err(|_| ocp_llm_router::adapter::ProviderError::ElevatedErrorRate)?;
            push(presentation, &speech);
            started = true;
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(audio);
        let event = Envelope::new(
            "ocp.behavior.speech-audio-chunk",
            "kernel",
            serde_json::json!({
                "speechId": speech_id,
                "companionId": companion_id,
                "messageId": message_id,
                "chunkIndex": chunk_index,
                "sequence": sequence,
                "audioBase64": encoded,
                "sampleRate": format.sample_rate,
                "channels": format.channels,
                "sampleWidth": format.sample_width,
            }),
        )
        .map_err(|_| ocp_llm_router::adapter::ProviderError::ElevatedErrorRate)?;
        push(presentation, &event);
        sequence += 1;
        Ok(())
    };
    let result = synthesizer.stream_synthesize(text, Some(key.as_str()), &mut on_audio);

    if !started {
        eprintln!(
            "[kernel] [voice-stream] no audio delta; fallback=router message={} chunk={}",
            message_id, chunk_index
        );
        return false;
    }

    let outcome = if result.is_ok() {
        "finished"
    } else {
        "stream-error"
    };
    if outcome != "finished" {
        eprintln!(
            "[kernel] [voice-stream] stream-error speech={} message={} chunk={}",
            speech_id, message_id, chunk_index
        );
    }
    if let Ok(event) = Envelope::new(
        "ocp.behavior.speech-audio-finished",
        "kernel",
        serde_json::json!({
            "speechId": speech_id,
            "companionId": companion_id,
            "messageId": message_id,
            "chunkIndex": chunk_index,
            "final": final_chunk,
            "outcome": outcome,
        }),
    ) {
        push(presentation, &event);
    }
    true
}

/// Convert one RuntimeV3 chat TTS chunk into the existing behavior speech
/// envelope. The runtime never receives provider credentials; it sends only
/// text + voice/provider preference. A fresh router per serialized chunk keeps
/// the accept-loop thread ownership simple while reusing the production cloud
/// chain (Gemini 3.1 -> Gemini 2.5) or the explicitly selected Windows voice,
/// plus the same file-backed AudioStore.
fn runtime_tts_request_to_speech(
    env: &Envelope,
    audio_store: &Arc<AudioStore>,
) -> Option<Envelope> {
    // Resolve on every RuntimeV3 request so a key saved/replaced from the
    // Control Center becomes effective immediately without restarting Kernel.
    // The secret remains kernel-side and never crosses IPC back to Godot.
    let gemini = gemini_key();
    let voice_setting = env
        .data
        .get("voice")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("profile:neutral:adult");
    runtime_tts_request_to_speech_with_synth(
        env,
        audio_store,
        &gemini,
        Box::new(WindowsSynthesizer::from_voice_setting(voice_setting)),
    )
}

fn runtime_voice_route_reason(
    text: &str,
    voice: &str,
    provider_id: &str,
    cloud_voice_configured: bool,
    route_audit: &[String],
) -> &'static str {
    if provider_id != "system" && !cloud_voice_configured {
        return "provider-credential-required";
    }
    let cloud_unreachable = cloud_voice_configured
        && route_audit
            .iter()
            .any(|entry| entry.contains("PROVIDER gemini-tts") && entry.contains("(Unreachable)"));
    if cloud_unreachable {
        "dns-unreachable"
    } else if cloud_voice_configured
        && route_audit
            .iter()
            .any(|entry| entry.contains("PROVIDER gemini-tts") && entry.contains("(AuthFailed)"))
    {
        "provider-auth-failed"
    } else if cloud_voice_configured
        && route_audit
            .iter()
            .any(|entry| entry.contains("PROVIDER gemini-tts") && entry.contains("(QuotaExceeded)"))
    {
        "provider-quota-exceeded"
    } else if cloud_voice_configured
        && route_audit
            .iter()
            .any(|entry| entry.contains("PROVIDER gemini-tts") && entry.contains("(RateLimited)"))
    {
        "provider-rate-limited"
    } else if provider_id == "system" {
        WindowsSynthesizer::failure_reason(text, voice)
    } else {
        "tts-unavailable"
    }
}

fn runtime_tts_request_to_speech_with_synth(
    env: &Envelope,
    audio_store: &Arc<AudioStore>,
    gemini: &Option<String>,
    local_synth: Box<dyn Synthesizer>,
) -> Option<Envelope> {
    if env.event_type != "ocp.runtime.tts-requested" {
        return None;
    }
    let text = env
        .data
        .get("text")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    if text.is_empty() {
        eprintln!("[kernel] [voice] rejected empty runtime TTS request");
        return None;
    }
    let companion_id = env
        .data
        .get("companionId")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("default");
    let voice = env
        .data
        .get("voice")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("neutral");
    let provider_id = env
        .data
        .get("providerId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("auto")
        .to_ascii_lowercase();
    let selected_gemini = if provider_id == "system" {
        None
    } else {
        gemini.clone()
    };
    if provider_id != "system" && selected_gemini.is_none() {
        eprintln!("[kernel] [voice] cloud TTS requested without Gemini credential; local fallback disabled");
    }

    let model = gemini_tts::supported_model(
        env.data
            .get("modelId")
            .and_then(serde_json::Value::as_str)
            .unwrap_or(gemini_tts::DEFAULT_MODEL),
    );
    let cloud_voice_configured = selected_gemini.is_some();
    let mut router = build_runtime_voice_router_for_voice_setting(
        Arc::clone(audio_store),
        local_synth,
        selected_gemini,
        voice,
        model,
        &provider_id,
    );
    let audit_before = router.audit_log().len();
    let mut speech = synthesize_speech_request(
        &mut router,
        audio_store,
        &SpeakRequest {
            companion_id: companion_id.to_owned(),
            correlation_id: env.id,
            text: text.to_owned(),
            subtitle: true,
            interruptible: true,
            voice_id: None,
        },
    );
    let route_audit = &router.audit_log()[audit_before..];
    if speech.data["audioRef"].is_null() {
        let reason = runtime_voice_route_reason(
            text,
            voice,
            &provider_id,
            cloud_voice_configured,
            route_audit,
        );
        if let Some(data) = speech.data.as_object_mut() {
            data.insert(
                "routeReason".to_owned(),
                serde_json::Value::String(reason.to_owned()),
            );
        }
    }
    for entry in route_audit {
        println!("[kernel] [route] {entry}");
    }
    let message_id = env
        .data
        .get("messageId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let chunk_index = env
        .data
        .get("chunkIndex")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0);
    let final_chunk = env
        .data
        .get("final")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if let Some(data) = speech.data.as_object_mut() {
        data.insert(
            "messageId".to_owned(),
            serde_json::Value::String(message_id.to_owned()),
        );
        data.insert("chunkIndex".to_owned(), serde_json::json!(chunk_index));
        data.insert("final".to_owned(), serde_json::json!(final_chunk));
    }
    println!(
        "[kernel] [voice] runtime TTS message={message_id} chunk={chunk_index} audio={} voice={}",
        !speech.data["audioRef"].is_null(),
        gemini_tts::voice_from_setting(voice),
    );
    Some(speech)
}

/// Run one secure OpenAI-compatible chat turn for RuntimeV3. The API key is
/// resolved in Kernel from the OS keystore and never crosses IPC into Godot.
/// The wire contract intentionally uses the widely-supported Chat Completions
/// shape through `OpenRouterAdapter::with_base_url`, so OpenAI-compatible
/// gateways can be selected by base URL + model without adding vendor code to
/// the presentation layer.
fn runtime_cloud_ai_request_to_response(env: &Envelope) -> Option<Envelope> {
    if env.event_type != "ocp.runtime.ai-requested" {
        return None;
    }
    let provider_id = env
        .data
        .get("providerId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("openai-compatible")
        .trim()
        .to_ascii_lowercase();
    let credential = std::env::var("OPENAI_COMPATIBLE_API_KEY")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| OsKeystoreCredentialStore::new("ocp-ai-provider").get(&provider_id));
    runtime_cloud_ai_request_to_response_with_credential(env, credential.as_deref())
}

fn runtime_cloud_ai_request_to_response_with_credential(
    env: &Envelope,
    credential: Option<&str>,
) -> Option<Envelope> {
    if env.event_type != "ocp.runtime.ai-requested" {
        return None;
    }
    let message_id = env
        .data
        .get("messageId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let prompt = env
        .data
        .get("prompt")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let system_prompt = env
        .data
        .get("systemPrompt")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let provider_id = env
        .data
        .get("providerId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("openai-compatible")
        .trim()
        .to_ascii_lowercase();
    let base_url = env
        .data
        .get("baseUrl")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let model = env
        .data
        .get("model")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let timeout_seconds = env
        .data
        .get("timeoutSeconds")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(45)
        .clamp(5, 300);
    let max_output_tokens = env
        .data
        .get("maxOutputTokens")
        .and_then(serde_json::Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .unwrap_or(1024)
        .clamp(16, 16_384);

    let failure = |error: String| {
        Envelope::new(
            "ocp.runtime.ai-response",
            "kernel",
            json!({
                "messageId": message_id,
                "providerId": provider_id,
                "model": model,
                "ok": false,
                "error": error,
            }),
        )
        .ok()
        .map(|response| response.with_correlation(env.id))
    };

    if message_id.is_empty() || prompt.is_empty() {
        return failure("Cloud AI request is missing message id or prompt".to_owned());
    }
    if base_url.is_empty() || model.is_empty() {
        return failure("OpenAI-compatible Base URL and model are required".to_owned());
    }
    if !base_url.to_ascii_lowercase().starts_with("https://") {
        return failure("OpenAI-compatible cloud Base URL must use HTTPS".to_owned());
    }
    let Some(token) = credential.filter(|value| !value.trim().is_empty()) else {
        return failure("OpenAI-compatible API key is not configured".to_owned());
    };

    let adapter = OpenRouterAdapter::with_base_url(
        provider_id.clone(),
        base_url,
        model,
        Duration::from_secs(timeout_seconds),
    );
    let request = RouterRequest {
        request_id: uuid::Uuid::now_v7(),
        correlation_id: env.id,
        capability: Capability::Chat,
        messages: {
            let mut messages = Vec::with_capacity(if system_prompt.is_empty() { 1 } else { 2 });
            if !system_prompt.is_empty() {
                messages.push(Message {
                    role: Role::System,
                    content: vec![ContentPart::Text {
                        value: system_prompt.to_owned(),
                    }],
                });
            }
            messages.push(Message {
                role: Role::User,
                content: vec![ContentPart::Text {
                    value: prompt.to_owned(),
                }],
            });
            messages
        },
        memory_excerpts: vec![],
        tools: vec![],
        caller_context: CallerContext {
            context_id: "runtime-v3-chat".to_owned(),
            granted_capabilities: vec![],
        },
        policy: RoutePolicy {
            max_cost_class: CostClass::Metered,
            allow_cloud: true,
        },
        streaming: false,
        foreground: true,
        limits: Limits { max_output_tokens },
    };

    match adapter.invoke(&request, Some(token)) {
        Ok(response) => {
            let text = response
                .content
                .iter()
                .filter_map(|part| match part {
                    ContentPart::Text { value } => Some(value.as_str()),
                    ContentPart::Image { .. } | ContentPart::Audio { .. } => None,
                })
                .collect::<Vec<_>>()
                .join("\n")
                .trim()
                .to_owned();
            if text.is_empty() {
                return failure("OpenAI-compatible provider returned an empty response".to_owned());
            }
            Envelope::new(
                "ocp.runtime.ai-response",
                "kernel",
                json!({
                    "messageId": message_id,
                    "providerId": provider_id,
                    "model": response.model_id,
                    "ok": true,
                    "text": text,
                }),
            )
            .ok()
            .map(|reply| reply.with_correlation(env.id))
        }
        Err(error) => failure(format!("OpenAI-compatible request failed: {error:?}")),
    }
}

fn runtime_memory_db_path() -> std::path::PathBuf {
    if let Some(explicit) = std::env::var_os("OCP_MEMORY_DB") {
        return std::path::PathBuf::from(explicit);
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        return std::path::PathBuf::from(local)
            .join("OCP")
            .join("memory")
            .join("companion-memory.db");
    }
    if let Some(home) = std::env::var_os("HOME") {
        return std::path::PathBuf::from(home)
            .join(".ocp")
            .join("memory")
            .join("companion-memory.db");
    }
    std::env::temp_dir()
        .join("ocp")
        .join("memory")
        .join("companion-memory.db")
}

fn open_runtime_memory_store() -> Result<SqliteStore, String> {
    let path = runtime_memory_db_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("create memory directory failed: {error}"))?;
    }
    let mut key_store = OsKeystoreKeyStore::new("ocp-memory");
    SqliteStore::open_profile(&path, "default", &mut key_store)
        .map_err(|error| format!("open memory store failed: {error}"))
}

fn runtime_memory_caller() -> MemoryCaller {
    MemoryCaller::Core {
        component: "runtime-v3-chat".to_owned(),
    }
}

fn ensure_runtime_memory_store(
    store: &mut Option<SqliteStore>,
) -> Result<&mut SqliteStore, String> {
    if store.is_none() {
        *store = Some(open_runtime_memory_store()?);
    }
    store
        .as_mut()
        .ok_or_else(|| "memory store is unavailable".to_owned())
}

fn bounded_memory_text(value: &str, max_chars: usize) -> String {
    value.trim().chars().take(max_chars).collect()
}

fn normalized_runtime_memory_companion_id(value: &str) -> Result<String, String> {
    let normalized = if value.trim().is_empty() {
        "default"
    } else {
        value.trim()
    };
    if !valid_companion_id(normalized) {
        return Err("invalid companion id for memory request".to_owned());
    }
    Ok(normalized.to_owned())
}

fn bounded_memory_content_for_transport(content: &str) -> String {
    let trimmed = content.trim();
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if value.get("kind").and_then(serde_json::Value::as_str) == Some("conversation-turn") {
            return json!({
                "kind": "conversation-turn",
                "messageId": bounded_memory_text(
                    value.get("messageId").and_then(serde_json::Value::as_str).unwrap_or_default(),
                    160,
                ),
                "user": bounded_memory_text(
                    value.get("user").and_then(serde_json::Value::as_str).unwrap_or_default(),
                    600,
                ),
                "assistant": bounded_memory_text(
                    value.get("assistant").and_then(serde_json::Value::as_str).unwrap_or_default(),
                    900,
                ),
            })
            .to_string();
        }
    }
    bounded_memory_text(trimmed, 2400)
}

fn runtime_memory_recent_response(
    env: &Envelope,
    memory_store: &mut Option<SqliteStore>,
) -> Option<Envelope> {
    if env.event_type != "ocp.runtime.memory-recent-requested" {
        return None;
    }
    let request_id = env
        .data
        .get("requestId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let raw_companion_id = env
        .data
        .get("companionId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("default");
    let limit = env
        .data
        .get("limit")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(8)
        .clamp(1, 12) as usize;
    let companion_id = match normalized_runtime_memory_companion_id(raw_companion_id) {
        Ok(value) => value,
        Err(error) => {
            let response_data = json!({
                "requestId": request_id,
                "companionId": raw_companion_id,
                "ok": false,
                "error": error,
                "records": [],
            });
            return Envelope::new("ocp.runtime.memory-recent", "kernel", response_data)
                .ok()
                .map(|reply| reply.with_correlation(env.id));
        }
    };
    let scope = MemoryScope::Companion(companion_id.clone());

    let response_data = match ensure_runtime_memory_store(memory_store).and_then(|store| {
        store
            .list(
                &runtime_memory_caller(),
                MemoryListRequest {
                    scope,
                    after: None,
                    limit: 256,
                },
            )
            .map_err(|error| format!("list recent memory failed: {error}"))
    }) {
        Ok(listed) => {
            let mut recent = listed.records;
            if recent.len() > limit {
                recent.drain(0..recent.len() - limit);
            }
            let records = recent
                .into_iter()
                .map(|record| {
                    json!({
                        "recordId": record.id,
                        "content": bounded_memory_content_for_transport(&record.content),
                        "createdAt": record.created_at,
                    })
                })
                .collect::<Vec<_>>();
            json!({
                "requestId": request_id,
                "companionId": companion_id,
                "ok": true,
                "records": records,
            })
        }
        Err(error) => json!({
            "requestId": request_id,
            "companionId": companion_id,
            "ok": false,
            "error": error,
            "records": [],
        }),
    };

    Envelope::new("ocp.runtime.memory-recent", "kernel", response_data)
        .ok()
        .map(|reply| reply.with_correlation(env.id))
}

fn runtime_memory_turn_write_response(
    env: &Envelope,
    memory_store: &mut Option<SqliteStore>,
) -> Option<Envelope> {
    if env.event_type != "ocp.runtime.memory-turn-write" {
        return None;
    }
    let message_id = env
        .data
        .get("messageId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    let raw_companion_id = env
        .data
        .get("companionId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("default");
    let companion_id = match normalized_runtime_memory_companion_id(raw_companion_id) {
        Ok(value) => value,
        Err(error) => {
            let response_data = json!({
                "messageId": message_id,
                "companionId": raw_companion_id,
                "ok": false,
                "error": error,
            });
            return Envelope::new("ocp.runtime.memory-turn-written", "kernel", response_data)
                .ok()
                .map(|reply| reply.with_correlation(env.id));
        }
    };
    let user_text = bounded_memory_text(
        env.data
            .get("userText")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default(),
        2400,
    );
    let assistant_text = bounded_memory_text(
        env.data
            .get("assistantText")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default(),
        4000,
    );
    let scope = MemoryScope::Companion(companion_id.clone());

    let write_result = if message_id.is_empty() || user_text.is_empty() || assistant_text.is_empty()
    {
        Err("memory turn is missing message id, user text, or assistant text".to_owned())
    } else {
        let content = json!({
            "kind": "conversation-turn",
            "messageId": message_id,
            "user": user_text,
            "assistant": assistant_text,
        })
        .to_string();
        ensure_runtime_memory_store(memory_store).and_then(|store| {
            store
                .write(
                    &runtime_memory_caller(),
                    MemoryWriteRequest {
                        scope,
                        content,
                        content_type: MemoryContentType::ApplicationJson,
                        sensitive: false,
                        source: "runtime-v3-chat".to_owned(),
                    },
                )
                .map_err(|error| format!("write memory turn failed: {error}"))
        })
    };

    let response_data = match write_result {
        Ok(outcome) => json!({
            "messageId": message_id,
            "companionId": companion_id,
            "ok": true,
            "recordId": outcome.record_id,
        }),
        Err(error) => json!({
            "messageId": message_id,
            "companionId": companion_id,
            "ok": false,
            "error": error,
        }),
    };
    Envelope::new("ocp.runtime.memory-turn-written", "kernel", response_data)
        .ok()
        .map(|reply| reply.with_correlation(env.id))
}

/// The shared character dir the runtime renders from (`OCP_CHARACTER_DIR`, else
/// `<temp>/ocp-character`) — the kernel extracts a package's assets here, the
/// runtime reads them (co-located, same pattern as the audio dir).
fn character_dir() -> std::path::PathBuf {
    std::env::var_os("OCP_CHARACTER_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("ocp-character"))
}

/// DEMO trust anchor: `pack_character` signs the sample `aiko.ocp` with a fixed
/// dev seed. **Real trust comes from the registry/keystore (I8D)**; this lets the
/// demo verify its own signed package end to end.
fn demo_trust() -> TrustStore {
    let mut trust = TrustStore::new();
    trust.add_key(
        "ed25519:demo-1",
        ed25519_dalek::SigningKey::from_bytes(&[7u8; 32]).verifying_key(),
    );
    trust
}

fn read_zip_asset(
    archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>,
    name: &str,
) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut f = archive
        .by_name(name)
        .map_err(|e| format!("asset {name}: {e}"))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)
        .map_err(|e| format!("read {name}: {e}"))?;
    Ok(buf)
}

/// Load + verify a signed `.ocp` (package-loader: archive/digest/Ed25519),
/// validate its `character/1` or `character/2` interior, and
/// extract its assets into `char_dir` so the runtime renders it. The entry lands
/// at `<char_dir>/character.json` (the runtime's fixed entry name); every other
/// asset keeps its in-package path (`<char_dir>/assets/...`, matching the entry's
/// asset references). Returns the resolved character contract.
fn extract_character_package(
    ocp_bytes: &[u8],
    char_dir: &std::path::Path,
) -> Result<ResolvedCharacter, String> {
    let pkg = load_package(ocp_bytes, &demo_trust()).map_err(|e| format!("load: {e}"))?;
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(ocp_bytes))
        .map_err(|e| format!("archive: {e}"))?;

    let entry_bytes = read_zip_asset(&mut archive, &pkg.manifest.entry)?;
    let declared: Vec<&str> = pkg
        .manifest
        .assets
        .iter()
        .map(|a| a.path.as_str())
        .collect();
    let resolved = parse_and_resolve(&entry_bytes, &declared).map_err(|e| format!("entry: {e}"))?;

    std::fs::create_dir_all(char_dir.join("assets")).map_err(|e| format!("mkdir: {e}"))?;
    std::fs::write(char_dir.join("character.json"), &entry_bytes)
        .map_err(|e| format!("write entry: {e}"))?;
    for asset in &pkg.manifest.assets {
        if asset.path == pkg.manifest.entry {
            continue;
        }
        let data = read_zip_asset(&mut archive, &asset.path)?;
        let output_path = char_dir.join(&asset.path);
        if let Some(parent) = output_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
        }
        std::fs::write(&output_path, data).map_err(|e| format!("write {}: {e}", asset.path))?;
    }
    Ok(resolved)
}

/// Startup wrapper: if `OCP_CHARACTER_PACKAGE` points at a `.ocp`, extract it so
/// the runtime renders it. Any failure is logged and non-fatal — the runtime
/// falls back to its placeholder character.
fn load_character_package() -> Option<ResolvedCharacter> {
    let path = std::env::var_os("OCP_CHARACTER_PACKAGE")?;
    match std::fs::read(&path) {
        Ok(bytes) => match extract_character_package(&bytes, &character_dir()) {
            Ok(character) => {
                println!(
                    "[kernel] character package `{}` ({}) verified + extracted to {}",
                    character.name,
                    character.source_schema,
                    character_dir().display()
                );
                Some(character)
            }
            Err(e) => {
                eprintln!("[kernel] character package rejected: {e} (runtime uses placeholder)");
                None
            }
        },
        Err(e) => {
            eprintln!("[kernel] cannot read OCP_CHARACTER_PACKAGE: {e}");
            None
        }
    }
}

/// Resolve the Gemini API key (SEC-030): the `GEMINI_API_KEY` env var wins (the
/// spike path), else the OS keystore entry `gemini-cloud`. `None` = no cloud
/// voice, OS voice only.
fn gemini_key() -> Option<String> {
    match std::env::var("GEMINI_API_KEY") {
        Ok(k) if !k.is_empty() => Some(k),
        _ => OsKeystoreCredentialStore::new("ocp-ai-provider").get("gemini-cloud"),
    }
}

/// The one live subscribe connection (kernel → runtime). A new subscribe
/// handshake replaces the previous one — deterministic across runtime
/// restarts, no guessing from connect order.
type Presentation = Arc<Mutex<Option<Connection>>>;

const RUNTIME_ASR_MAX_PCM_BYTES: usize = 64 * 1024;

fn runtime_asr_session_id(env: &Envelope) -> Option<String> {
    let value = env
        .data
        .get("sessionId")
        .and_then(serde_json::Value::as_str)?
        .trim();
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    {
        return None;
    }
    Some(value.to_owned())
}

fn runtime_asr_language_codes(env: &Envelope) -> Vec<String> {
    env.data
        .get("languageCodes")
        .and_then(serde_json::Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty() && value.len() <= 32)
                .take(4)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn runtime_asr_event_envelope(
    session_id: &str,
    correlation_id: Uuid,
    event: &GeminiAsrEvent,
) -> Option<Envelope> {
    let (event_type, data) = match event {
        GeminiAsrEvent::Ready => (
            "ocp.voice.asr-ready",
            json!({
                "sessionId": session_id,
                "providerId": "gemini-live",
                "modelId": LIVE_TRANSCRIBE_MODEL,
                "sampleRate": LIVE_TRANSCRIBE_SAMPLE_RATE,
            }),
        ),
        GeminiAsrEvent::Interim(text) => (
            "ocp.voice.asr-interim",
            json!({"sessionId": session_id, "text": text}),
        ),
        GeminiAsrEvent::Final(text) => (
            "ocp.voice.asr-final",
            json!({"sessionId": session_id, "text": text}),
        ),
        GeminiAsrEvent::TurnComplete => (
            "ocp.voice.asr-turn-complete",
            json!({"sessionId": session_id}),
        ),
        GeminiAsrEvent::Interrupted => (
            "ocp.voice.asr-interrupted",
            json!({"sessionId": session_id}),
        ),
        GeminiAsrEvent::Error(reason) => (
            "ocp.voice.asr-error",
            json!({"sessionId": session_id, "reasonCode": reason}),
        ),
        GeminiAsrEvent::Closed => ("ocp.voice.asr-closed", json!({"sessionId": session_id})),
    };
    Envelope::new(event_type, "kernel", data)
        .ok()
        .map(|envelope| envelope.with_correlation(correlation_id))
}

fn push_runtime_asr_error(
    presentation: &Presentation,
    session_id: &str,
    correlation_id: Uuid,
    reason_code: &'static str,
) {
    if let Ok(envelope) = Envelope::new(
        "ocp.voice.asr-error",
        "kernel",
        json!({"sessionId": session_id, "reasonCode": reason_code}),
    ) {
        push(presentation, &envelope.with_correlation(correlation_id));
    }
}

fn start_runtime_asr(
    env: &Envelope,
    presentation: &Presentation,
) -> Option<(String, GeminiLiveAsrControl)> {
    let Some(session_id) = runtime_asr_session_id(env) else {
        push_runtime_asr_error(presentation, "invalid", env.id, "invalid-session-id");
        return None;
    };
    let Some(api_key) = gemini_key() else {
        push_runtime_asr_error(
            presentation,
            &session_id,
            env.id,
            "provider-credential-required",
        );
        return None;
    };
    let language_codes = runtime_asr_language_codes(env);
    let Ok((control, events)) = start_live_asr(api_key, language_codes) else {
        push_runtime_asr_error(presentation, &session_id, env.id, "asr-start-failed");
        return None;
    };

    let pump_control = control.clone();
    let pump_presentation = Arc::clone(presentation);
    let pump_session_id = session_id.clone();
    let correlation_id = env.id;
    let spawn = thread::Builder::new()
        .name("ocp-runtime-asr-events".to_owned())
        .spawn(move || {
            while let Some(event) = events.recv() {
                // Live transcription's inputTranscription is the finalized
                // utterance. Some sessions do not emit turnComplete after a
                // final transcript, so Final must terminate the provider turn
                // as well or the worker/socket can remain open unnecessarily.
                let terminal = matches!(
                    event,
                    GeminiAsrEvent::Final(_)
                        | GeminiAsrEvent::TurnComplete
                        | GeminiAsrEvent::Error(_)
                        | GeminiAsrEvent::Closed
                );
                if let Some(envelope) =
                    runtime_asr_event_envelope(&pump_session_id, correlation_id, &event)
                {
                    push(&pump_presentation, &envelope);
                }
                if terminal {
                    let _ = pump_control.close();
                    break;
                }
            }
            events.join();
        });
    if spawn.is_err() {
        let _ = control.close();
        push_runtime_asr_error(presentation, &session_id, env.id, "asr-pump-start-failed");
        return None;
    }
    let _ = control.activity_start();
    Some((session_id, control))
}

fn runtime_asr_audio(env: &Envelope, active: &Option<(String, GeminiLiveAsrControl)>) -> bool {
    let Some(session_id) = runtime_asr_session_id(env) else {
        return false;
    };
    let Some((active_id, control)) = active else {
        return false;
    };
    if active_id != &session_id
        || env
            .data
            .get("sampleRate")
            .and_then(serde_json::Value::as_u64)
            != Some(u64::from(LIVE_TRANSCRIBE_SAMPLE_RATE))
    {
        return false;
    }
    let Some(encoded) = env
        .data
        .get("pcmBase64")
        .and_then(serde_json::Value::as_str)
    else {
        return false;
    };
    let Ok(pcm) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
        return false;
    };
    if pcm.is_empty() || pcm.len() > RUNTIME_ASR_MAX_PCM_BYTES || pcm.len() % 2 != 0 {
        return false;
    }
    control.send_pcm16(pcm)
}

fn runtime_asr_end(env: &Envelope, active: &Option<(String, GeminiLiveAsrControl)>) -> bool {
    let Some(session_id) = runtime_asr_session_id(env) else {
        return false;
    };
    let Some((active_id, control)) = active else {
        return false;
    };
    active_id == &session_id && control.activity_end()
}

const RUNTIME_LIVE_VOICE_MAX_PCM_BYTES: usize = 64 * 1024;
const RUNTIME_LIVE_VOICE_AUDIO_EVENT_BYTES: usize = 32 * 1024;

fn runtime_live_voice_instruction(env: &Envelope) -> String {
    env.data
        .get("systemInstruction")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .unwrap_or_default()
        .chars()
        .take(2400)
        .collect()
}

fn runtime_live_voice_event_envelopes(
    session_id: &str,
    correlation_id: Uuid,
    event: &GeminiLiveVoiceEvent,
) -> Vec<Envelope> {
    let mut out = Vec::new();
    let mut push_one = |event_type: &str, data: serde_json::Value| {
        if let Ok(envelope) = Envelope::new(event_type, "kernel", data) {
            out.push(envelope.with_correlation(correlation_id));
        }
    };
    match event {
        GeminiLiveVoiceEvent::Ready => push_one(
            "ocp.voice.live-ready",
            json!({
                "sessionId": session_id,
                "modelId": LIVE_VOICE_MODEL,
                "inputSampleRate": LIVE_VOICE_INPUT_RATE,
                "outputSampleRate": LIVE_VOICE_OUTPUT_RATE,
            }),
        ),
        GeminiLiveVoiceEvent::InputTranscript(text) => push_one(
            "ocp.voice.live-input-transcript",
            json!({"sessionId": session_id, "text": text}),
        ),
        GeminiLiveVoiceEvent::OutputTranscript(text) => push_one(
            "ocp.voice.live-output-transcript",
            json!({"sessionId": session_id, "text": text}),
        ),
        GeminiLiveVoiceEvent::Audio(audio) => {
            for chunk in audio.chunks(RUNTIME_LIVE_VOICE_AUDIO_EVENT_BYTES) {
                push_one(
                    "ocp.voice.live-audio-chunk",
                    json!({
                        "sessionId": session_id,
                        "audioBase64": base64::engine::general_purpose::STANDARD.encode(chunk),
                        "sampleRate": LIVE_VOICE_OUTPUT_RATE,
                    }),
                );
            }
        }
        GeminiLiveVoiceEvent::TurnComplete => push_one(
            "ocp.voice.live-turn-complete",
            json!({"sessionId": session_id}),
        ),
        GeminiLiveVoiceEvent::Interrupted => push_one(
            "ocp.voice.live-interrupted",
            json!({"sessionId": session_id}),
        ),
        GeminiLiveVoiceEvent::Error(reason) => push_one(
            "ocp.voice.live-error",
            json!({"sessionId": session_id, "reasonCode": reason}),
        ),
        GeminiLiveVoiceEvent::Closed => {
            push_one("ocp.voice.live-closed", json!({"sessionId": session_id}))
        }
    }
    out
}

fn push_runtime_live_voice_error(
    presentation: &Presentation,
    session_id: &str,
    correlation_id: Uuid,
    reason_code: &'static str,
) {
    if let Ok(envelope) = Envelope::new(
        "ocp.voice.live-error",
        "kernel",
        json!({"sessionId": session_id, "reasonCode": reason_code}),
    ) {
        push(presentation, &envelope.with_correlation(correlation_id));
    }
}

fn start_runtime_live_voice(
    env: &Envelope,
    presentation: &Presentation,
) -> Option<(String, GeminiLiveVoiceControl)> {
    let Some(session_id) = runtime_asr_session_id(env) else {
        push_runtime_live_voice_error(presentation, "invalid", env.id, "invalid-live-session-id");
        return None;
    };
    let Some(api_key) = gemini_key() else {
        push_runtime_live_voice_error(
            presentation,
            &session_id,
            env.id,
            "provider-credential-required",
        );
        return None;
    };
    let instruction = runtime_live_voice_instruction(env);
    let Ok((control, events)) = start_live_voice(api_key, instruction) else {
        push_runtime_live_voice_error(presentation, &session_id, env.id, "live-voice-start-failed");
        return None;
    };

    let pump_presentation = Arc::clone(presentation);
    let pump_session_id = session_id.clone();
    let correlation_id = env.id;
    let spawn = thread::Builder::new()
        .name("ocp-runtime-live-voice-events".to_owned())
        .spawn(move || {
            while let Some(event) = events.recv() {
                let terminal = matches!(
                    event,
                    GeminiLiveVoiceEvent::Error(_) | GeminiLiveVoiceEvent::Closed
                );
                for envelope in
                    runtime_live_voice_event_envelopes(&pump_session_id, correlation_id, &event)
                {
                    push(&pump_presentation, &envelope);
                }
                if terminal {
                    break;
                }
            }
            events.join();
        });
    if spawn.is_err() {
        let _ = control.close();
        push_runtime_live_voice_error(
            presentation,
            &session_id,
            env.id,
            "live-voice-pump-start-failed",
        );
        return None;
    }
    Some((session_id, control))
}

fn runtime_live_voice_audio(
    env: &Envelope,
    active: &Option<(String, GeminiLiveVoiceControl)>,
) -> bool {
    let Some(session_id) = runtime_asr_session_id(env) else {
        return false;
    };
    let Some((active_id, control)) = active else {
        return false;
    };
    if active_id != &session_id
        || env
            .data
            .get("sampleRate")
            .and_then(serde_json::Value::as_u64)
            != Some(u64::from(LIVE_VOICE_INPUT_RATE))
    {
        return false;
    }
    let Some(encoded) = env
        .data
        .get("pcmBase64")
        .and_then(serde_json::Value::as_str)
    else {
        return false;
    };
    let Ok(pcm) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
        return false;
    };
    if pcm.is_empty() || pcm.len() > RUNTIME_LIVE_VOICE_MAX_PCM_BYTES || pcm.len() % 2 != 0 {
        return false;
    }
    control.send_pcm16(pcm)
}

fn runtime_live_voice_activity(
    env: &Envelope,
    active: &Option<(String, GeminiLiveVoiceControl)>,
    start: bool,
) -> bool {
    let Some(session_id) = runtime_asr_session_id(env) else {
        return false;
    };
    let Some((active_id, control)) = active else {
        return false;
    };
    if active_id != &session_id {
        return false;
    }
    if start {
        control.activity_start()
    } else {
        control.activity_end()
    }
}

/// One Behavior Engine per companion, created lazily on first delivery —
/// ADR-0013 §2's "many logical state machines multiplexed through one
/// engine loop", realized as one `DeterministicEngine` instance per actor.
struct EngineHandler {
    engines: HashMap<String, DeterministicEngine>,
}

impl EngineHandler {
    fn new() -> Self {
        Self {
            engines: HashMap::new(),
        }
    }
}

impl ActorHandler for EngineHandler {
    fn on_event(&mut self, companion_id: &str, event: &Envelope) -> Vec<Envelope> {
        self.engines
            .entry(companion_id.to_owned())
            .or_insert_with(|| DeterministicEngine::new(ocp_behavior_engine::demo_rules()))
            .handle(event)
            .into_iter()
            // The handler is the one place that knows which actor produced a
            // reaction — stamp it here so aiko's engine visibly animates
            // aiko, not the default sprite (see module doc, interpretive).
            .map(|reaction| stamp_companion(reaction, companion_id))
            .collect()
    }
}

/// Everything the event pipeline needs, shared across the accept/drain/
/// sampler/stdin threads. One mutex over the whole pipeline state keeps
/// ordering deterministic (single-threaded event model, ADR-0005/ADR-0013 §2
/// — the threads only exist for I/O, never for concurrent event processing).
struct Pipeline {
    manager: CompanionManager,
    handler: EngineHandler,
    activity: ActivityContextEngine,
}

type SharedPipeline = Arc<Mutex<Pipeline>>;

/// Stamp a companion's reactions with its id when the payload lacks one
/// (interpretive, flagged in the module doc): without this, every engine
/// reaction renders on the default sprite regardless of which companion's
/// actor produced it.
fn stamp_companion(mut env: Envelope, companion_id: &str) -> Envelope {
    if let Some(obj) = env.data.as_object_mut() {
        obj.entry("companionId")
            .or_insert_with(|| json!(companion_id));
    }
    env
}

/// The integrated event pipeline: mirror lifecycle outcomes, interpret
/// telemetry into activity state, route targeted/subscribed deliveries, and
/// drive the staggered scheduler until quiet — pushing every emitted fact to
/// the runtime.
fn process_fact(env: &Envelope, presentation: &Presentation, pipeline: &SharedPipeline) {
    let mut p = pipeline.lock().expect("pipeline lock");

    // 1. Lifecycle outcome mirroring (spawned/slept/woken/... — ADR-0013).
    p.manager.ingest_outcome(env);

    // 2. Raw telemetry → semantic activity (RFC-0005). The emitted
    //    state-changed fact is routed like any other event AND pushed to the
    //    runtime log for visibility.
    if env.event_type.starts_with("ocp.plugin.os-telemetry-") {
        if let Some(state_ev) = p.activity.handle_signal(env, Utc::now()) {
            println!(
                "[kernel] [activity] -> {} data={}",
                state_ev.event_type, state_ev.data
            );
            route_one(&mut p, presentation, &state_ev);
        }
    }

    // 3. Route the fact itself.
    route_one(&mut p, presentation, env);

    // 4. Drive the staggered scheduler until quiet (bounded — each tick
    //    processes at most one event of one actor, ADR-0013 §4). An empty
    //    reaction list does NOT mean the queues are drained (an event may
    //    legitimately produce no reaction), so progress is measured by the
    //    pending-mail count; mail held by sleeping actors is not progress
    //    and ends the loop.
    for _ in 0..64 {
        let before = p.manager.pending_mail();
        if before == 0 {
            break;
        }
        let reactions = {
            let Pipeline {
                manager, handler, ..
            } = &mut *p;
            manager.tick(handler)
        };
        for reaction in &reactions {
            println!(
                "[kernel] [behavior-engine] -> {} ({})",
                reaction.event_type, reaction.id
            );
            push(presentation, reaction);
        }
        if p.manager.pending_mail() == before && reactions.is_empty() {
            break; // no progress: remaining mail is held by sleeping actors
        }
    }
}

/// Route one event through the Companion Manager, honoring wake-on-request.
fn route_one(p: &mut Pipeline, presentation: &Presentation, env: &Envelope) {
    match p.manager.route(env) {
        RouteOutcome::Delivered(_) => {}
        RouteOutcome::WakeRequested { wake_request, .. } => {
            println!(
                "[kernel] [manager] wake-on-request -> {}",
                wake_request.event_type
            );
            push(presentation, &wake_request);
        }
        RouteOutcome::Unroutable { companion_id } => {
            println!("[kernel] [manager] unroutable: no companion `{companion_id}` (audited)");
        }
    }
}

fn main() {
    let socket = std::env::var("OCP_IPC_SOCKET").unwrap_or_else(|_| "ocp-runtime".to_owned());
    let (token, generated) = match std::env::var("OCP_IPC_TOKEN") {
        Ok(t) if !t.is_empty() => (t, false),
        _ => (generate_token(), true),
    };

    let listener = match Listener::bind(&socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[kernel] cannot bind socket '{socket}': {e}");
            eprintln!("[kernel] another kernel already running, or a stale socket holds the name");
            std::process::exit(1);
        }
    };

    println!("[kernel] listening on local socket '{socket}'");
    if generated {
        println!(
            "[kernel] session token (set this in the runtime's environment BEFORE launching it):"
        );
        println!();
        println!("  $env:OCP_IPC_SOCKET = \"{socket}\"");
        println!("  $env:OCP_IPC_TOKEN  = \"{token}\"");
        println!();
    } else {
        println!("[kernel] using OCP_IPC_TOKEN from environment");
    }
    println!("[kernel] waiting for the runtime to subscribe...");

    let presentation: Presentation = Arc::new(Mutex::new(None));
    let pipeline: SharedPipeline = Arc::new(Mutex::new(Pipeline {
        manager: CompanionManager::new(),
        handler: EngineHandler::new(),
        activity: ActivityContextEngine::new(default_interpreters()),
    }));
    println!(
        "[kernel] integrated pipeline online: Companion Manager (ADR-0013) + per-companion Behavior Engines (I3) + Activity Context (I11) + OS sampler"
    );
    // PHASE-6.5.2C: DESKTOP-WORLD-BOOT
    // Kernel owns exactly one Desktop World Runtime lifecycle.
    let desktop_world_bus = InProcessBus::new();
    let world_event_rx = desktop_world_bus.subscribe("ocp.world.");
    let surface_event_rx = desktop_world_bus.subscribe("ocp.surface.");
    let world_lifecycle_rx = desktop_world_bus.subscribe("ocp.runtime.desktop-world-");
    let physics_event_rx = desktop_world_bus.subscribe("ocp.physics.");
    let character_motion_rx = desktop_world_bus.subscribe("ocp.character.");
    let physics_lifecycle_rx = desktop_world_bus.subscribe("ocp.runtime.desktop-physics-");
    let companion_physics_rx = desktop_world_bus.subscribe("ocp.runtime.companion-physics-");
    let companion_moved_rx = desktop_world_bus.subscribe("ocp.runtime.companion-moved");
    let companion_presentation_rx =
        desktop_world_bus.subscribe("ocp.runtime.companion-presentation-state");
    let mut desktop_world_host = match ocp_kernel::desktop_world_boot::boot_platform(
        desktop_world_bus.clone(),
        ocp_kernel::desktop_world_boot::KernelDesktopWorldConfig::from_env(),
    ) {
        Ok(host) => {
            println!(
                "[kernel] Desktop World lifecycle: {}",
                host.state().as_str()
            );
            Some(host)
        }
        Err(error) => {
            eprintln!("[kernel] Desktop World degraded: {error}");
            None
        }
    };

    let desktop_world_snapshot_store = desktop_world_host
        .as_ref()
        .map(ocp_kernel::desktop_world_boot::KernelDesktopWorldHost::snapshot_store);
    let desktop_world_lifecycle_replay = desktop_world_host
        .as_ref()
        .map(|host| (host.world_id(), host.state()));

    // PHASE-6.5.3I: PRODUCTION-DESKTOP-PHYSICS-BOOT
    // Physics shares the canonical Kernel event bus and consumes the latest
    // immutable Desktop World snapshot through the snapshot store.
    let mut desktop_physics_loop =
        desktop_world_snapshot_store
            .as_ref()
            .and_then(|snapshot_store| {
                match ocp_kernel::desktop_physics_boot::KernelDesktopPhysicsLoop::start(
                    desktop_world_bus.clone(),
                    ocp_kernel::desktop_physics_host::KernelDesktopPhysicsConfig::from_env(),
                    ocp_kernel::desktop_physics_boot::KernelDesktopPhysicsLoopConfig::from_env(),
                    Arc::clone(snapshot_store),
                ) {
                    Ok(runtime) => {
                        println!(
                            "[kernel] Desktop Physics lifecycle: {}",
                            runtime.state().as_str()
                        );
                        Some(runtime)
                    }
                    Err(error) => {
                        eprintln!("[kernel] Desktop Physics degraded: {error}");
                        None
                    }
                }
            });
    let desktop_physics_lifecycle_replay =
        desktop_physics_loop.as_ref().map(|runtime| runtime.state());
    let desktop_physics_handle = desktop_physics_loop
        .as_ref()
        .map(|runtime| runtime.handle());
    let resolved_character = load_character_package();
    let mut companion_body_config = CompanionPhysicsBodyConfig::from_env();
    if let Some(character) = resolved_character.as_ref() {
        companion_body_config = companion_body_config
            .with_collision_half_extents(character.body_profile.collision_half_extents);
        println!(
            "[kernel] character body profile: half_extents=({:.1},{:.1}) source={}",
            companion_body_config.half_width,
            companion_body_config.half_height,
            character.source_schema,
        );
    }
    let companion_physics_bindings =
        CompanionPhysicsBindings::new(desktop_world_bus.clone(), companion_body_config);
    // Presentation must retain the concrete surface kind for every Physics
    // movement. Without the live handle the bridge cannot distinguish a
    // WindowTop landing from the desktop floor, so do not start a lossy
    // bridge in the degraded/no-physics configuration.
    let _companion_motion_bridge = desktop_physics_handle
        .clone()
        .map(|handle| companion_physics_bindings.start_motion_bridge(handle));

    for receiver in [
        world_event_rx,
        surface_event_rx,
        world_lifecycle_rx,
        physics_event_rx,
        character_motion_rx,
        physics_lifecycle_rx,
        companion_physics_rx,
        companion_moved_rx,
        companion_presentation_rx,
    ] {
        let presentation = Arc::clone(&presentation);
        thread::spawn(move || {
            while let Ok(event) = receiver.recv() {
                push(&presentation, &event);
            }
        });
    }

    // Developer `/speech` keeps the legacy Gemini -> OS fallback route for
    // terminal diagnostics. Runtime Chat/Read Aloud uses the stricter router
    // above: cloud models may fall back only to another cloud model, while
    // Windows TTS is registered only when the user explicitly selects System.
    // Both routes share the file-backed audio store below.
    let audio_store: Arc<AudioStore> = match AudioStore::with_dir(audio_dir()) {
        Ok(store) => Arc::new(store),
        Err(e) => {
            eprintln!(
                "[kernel] cannot open audio dir {}: {e} — voice degrades to subtitle (no clip on disk)",
                audio_dir().display()
            );
            Arc::new(AudioStore::new())
        }
    };
    let gemini = gemini_key();
    // The companion's voice preference (gender toggle). `/voice <male|female|
    // neutral>` changes it and rebuilds the router; slice B's settings menu
    // sends the same intent. Single-companion for now — a per-companion voice
    // map arrives with the request-threaded multi-companion voice slice.
    let mut voice_gender = VoiceGender::default();
    let mut voice_router = build_voice_router(
        Arc::clone(&audio_store),
        Box::new(WindowsSynthesizer::new()),
        gemini.clone(),
        voice_gender,
    );
    let developer_voice_chain = if gemini.is_some() {
        "Gemini cloud -> OS voice fallback"
    } else {
        "OS voice only (developer route)"
    };
    println!(
        "[kernel] developer voice: `/speech <text>` -> [{developer_voice_chain}] voice={voice_gender:?}({}) -> {}\\\\<id>.wav -> speech-requested{{audioRef}}",
        gemini_tts::voice_for(voice_gender),
        audio_dir().display()
    );
    println!(
        "[kernel] runtime Chat voice policy: cloud={} -> {}; Windows=explicit System only; voice=resolved per request from character profile; cloud_configured={}",
        gemini_tts::STREAMING_MODEL,
        gemini_tts::DEFAULT_MODEL,
        gemini.is_some()
    );
    println!("[kernel]   /voice <male|female|neutral>   change the companion's voice");

    // Kernel-side OS telemetry sampler (module doc: interpretive pluginId,
    // windowTitle deliberately omitted). Publishes every 5s so Activity
    // Context's dwell logic sees a sustained signal stream, matching the I4
    // host sampling-loop pattern.
    {
        let presentation = Arc::clone(&presentation);
        let pipeline = Arc::clone(&pipeline);
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(5));
            if let Some((_title, process_name)) = ocp_os_sensors::foreground_window() {
                if let Ok(env) = Envelope::new(
                    "ocp.plugin.os-telemetry-foreground-changed",
                    "kernel-os-sampler",
                    json!({ "pluginId": "ocp-kernel-sampler", "processName": process_name }),
                ) {
                    process_fact(&env, &presentation, &pipeline);
                }
            }
            if let Some(idle_ms) = ocp_os_sensors::mouse_idle_ms() {
                let state = if idle_ms >= 60_000 { "idle" } else { "active" };
                if let Ok(env) = Envelope::new(
                    "ocp.plugin.os-telemetry-mouse-changed",
                    "kernel-os-sampler",
                    json!({ "pluginId": "ocp-kernel-sampler", "state": state, "idleMs": idle_ms }),
                ) {
                    process_fact(&env, &presentation, &pipeline);
                }
            }
        });
    }

    // Accept loop: subscribe connections become THE presentation channel;
    // everything else (publish / no intent) is drained for outcome facts,
    // each routed through the Behavior Engine.
    {
        let presentation = Arc::clone(&presentation);
        let pipeline = Arc::clone(&pipeline);
        let token = token.clone();
        let subscribe_physics_handle = desktop_physics_handle.clone();
        let subscribe_physics_bindings = companion_physics_bindings.clone();
        let runtime_tts_audio_store = Arc::clone(&audio_store);
        thread::spawn(move || loop {
            match listener.accept_authenticated_hello(&token) {
                Ok((conn, hello)) => {
                    if hello.intent.as_deref() == Some(INTENT_SUBSCRIBE) {
                        println!("[kernel] runtime subscribed — type text to show a bubble,");
                        println!(
                            "[kernel]   /speech <text>   /emotion <name> [companionId]   /anim <name> [companionId]   /quit"
                        );
                        println!("[kernel]   /window <transparent|opaque> <ontop|normal> <never|outside-sprite|always>");
                        println!("[kernel]   /spawn <id> [x y]   /despawn <id>   /sleep <id> <on|off>   (I6.5 §8.2)");
                        println!("[kernel]   /show <id>   /hide <id>   /focus <id>   /follow <id> <leader> <on|off>   /look <id>   /say <id> <text>");
                        println!("[kernel]   /walk <id> <left|right> [stop|off]   /jump <id> <up|left|right>");
                        println!("[kernel]   /climb <id> <up|down>   /hang <id> <left|right>");
                        println!("[kernel]   /stop <id>   /detach <id>   /ledge <id>");
                        println!("[kernel]   (click in the running game -> that companion's own Behavior Engine reacts)");
                        let replaced = presentation.lock().expect("lock").replace(conn);
                        if replaced.is_some() {
                            println!("[kernel] (previous subscribe connection replaced)");
                        }
                        greet(&presentation, &pipeline);
                        // Phase 6.5.3K RC19: Runtime subscription establishes
                        // Physics ownership immediately. Binding publishes an
                        // authoritative-snap movement snapshot, so the active
                        // character is visible before the first user command.
                        if let Some(handle) = subscribe_physics_handle.as_ref() {
                            if subscribe_physics_bindings.binding("default").is_none() {
                                match subscribe_physics_bindings.bind("default", None, handle) {
                                    Ok(_) => println!(
                                        "[kernel] [physics] bound `default` on runtime subscribe"
                                    ),
                                    Err(error) => eprintln!(
                                        "[kernel] [physics] subscribe bind failed: {error}"
                                    ),
                                }
                            }
                        }
                        if let Some((world_id, state)) = desktop_world_lifecycle_replay {
                            if let Err(error) =
                                ocp_kernel::desktop_world_boot::publish_lifecycle_replay(
                                    world_id,
                                    state,
                                    &desktop_world_bus,
                                )
                            {
                                eprintln!(
                                    "[kernel] Desktop World lifecycle replay failed: {error}"
                                );
                            }
                        }
                        if let Some(snapshot_store) = desktop_world_snapshot_store.as_ref() {
                            if let Err(error) =
                                ocp_kernel::desktop_world_boot::publish_snapshot_replay_from_store(
                                    snapshot_store,
                                    &desktop_world_bus,
                                )
                            {
                                eprintln!("[kernel] Desktop World replay failed: {error}");
                            }
                        }
                        if let Some(state) = desktop_physics_lifecycle_replay {
                            if let Err(error) =
                                ocp_kernel::desktop_physics_host::publish_lifecycle_replay(
                                    state,
                                    &desktop_world_bus,
                                )
                            {
                                eprintln!(
                                    "[kernel] Desktop Physics lifecycle replay failed: {error}"
                                );
                            }
                        }
                    } else {
                        let presentation = Arc::clone(&presentation);
                        let pipeline = Arc::clone(&pipeline);
                        let outcome_physics_handle = subscribe_physics_handle.clone();
                        let outcome_physics_bindings = subscribe_physics_bindings.clone();
                        let outcome_tts_audio_store = Arc::clone(&runtime_tts_audio_store);
                        thread::spawn(move || {
                            drain_outcomes(
                                conn,
                                presentation,
                                pipeline,
                                outcome_physics_handle,
                                outcome_physics_bindings,
                                outcome_tts_audio_store,
                            )
                        });
                    }
                }
                // SEC-040: reject reveals nothing; keep serving other peers.
                Err(e) => eprintln!("[kernel] connection rejected: {e}"),
            }
        });
    }

    // Interactive loop: each line becomes a request-fact.
    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('/') && line[1..].contains('/') {
            eprintln!(
                "[kernel] multiple commands detected; enter exactly one slash command per line"
            );
            continue;
        }
        if line == "/quit" {
            break;
        }

        // Lifecycle commands go through the Companion Manager (ADR-0013):
        // the manager registers/tracks the actor and builds the request —
        // hand-built lifecycle envelopes are gone from this binary.
        if let Some(handled) = handle_lifecycle_command(
            line,
            &presentation,
            &pipeline,
            desktop_physics_handle.as_ref(),
            &companion_physics_bindings,
        ) {
            if !handled {
                eprintln!("[kernel] lifecycle command failed (see message above)");
            }
            continue;
        }

        if let Some(handled) = handle_physics_command(
            line,
            desktop_physics_handle.as_ref(),
            &companion_physics_bindings,
        ) {
            if !handled {
                eprintln!("[kernel] Physics command failed (see message above)");
            }
            continue;
        }

        // /voice <male|female|neutral> — the companion's voice preference (the
        // gender toggle a settings menu exposes). Changing it rebuilds the voice
        // router so the next /speech uses the new gender's voice.
        if let Some(arg) = line.strip_prefix("/voice ") {
            match VoiceGender::parse(arg) {
                Some(g) => {
                    voice_gender = g;
                    voice_router = build_voice_router(
                        Arc::clone(&audio_store),
                        Box::new(WindowsSynthesizer::new()),
                        gemini.clone(),
                        voice_gender,
                    );
                    println!(
                        "[kernel] [voice] companion voice -> {voice_gender:?} ({})",
                        gemini_tts::voice_for(voice_gender)
                    );
                }
                None => eprintln!("[kernel] usage: /voice <male|female|neutral>"),
            }
            continue;
        }

        // /speech <text> — route real TTS through the hosted router. Unlike the
        // other stdin verbs (which hand-build an envelope), the speech envelope
        // is produced by the voice orchestration: it routes the text through the
        // `tts` chain, mirrors the WAV to the shared audio dir, and stamps the
        // resulting `audioRef` onto `ocp.behavior.speech-requested`. On any TTS
        // failure the envelope still goes out with no `audioRef` (subtitle-only).
        if let Some(text) = line.strip_prefix("/speech ") {
            let audit_before = voice_router.audit_log().len();
            let env = synthesize_speech_request(
                &mut voice_router,
                &audio_store,
                &SpeakRequest {
                    companion_id: "default".to_owned(),
                    correlation_id: uuid::Uuid::now_v7(),
                    text: text.to_owned(),
                    subtitle: true,
                    interruptible: true,
                    voice_id: None,
                },
            );
            // Surface the routing decisions for this turn so a silent fallback
            // to the OS voice (which can't speak Thai) is visible, not a mystery.
            for entry in &voice_router.audit_log()[audit_before..] {
                println!("[kernel] [route] {entry}");
            }
            if env.data["audioRef"].is_null() {
                println!("[kernel] [voice] tts-unavailable -> subtitle only (no clip on disk)");
            } else {
                println!(
                    "[kernel] [voice] synthesized clip in {}",
                    audio_dir().display()
                );
            }
            push(&presentation, &env);
            continue;
        }

        let env = if let Some(rest) = line.strip_prefix("/window ") {
            // /window <transparent|opaque> <ontop|normal> <never|outside-sprite|always>
            let parts: Vec<&str> = rest.split_whitespace().collect();
            let transparent = parts.first().copied() == Some("transparent");
            let always_on_top = parts.get(1).copied() == Some("ontop");
            let click_through = parts.get(2).copied().unwrap_or("never");
            Envelope::new(
                "ocp.companion.window-policy-changed",
                "companion",
                json!({
                    "transparent": transparent,
                    "alwaysOnTop": always_on_top,
                    "clickThrough": click_through,
                }),
            )
        } else if let Some(rest) = line.strip_prefix("/emotion ") {
            // /emotion <name> [companionId] — id defaults to the single-
            // companion "default" (RUNTIME_API §8.1) instead of the previous
            // throwaway uuid, so the tint lands on an addressable sprite.
            let parts: Vec<&str> = rest.split_whitespace().collect();
            let emotion = parts.first().copied().unwrap_or("neutral");
            let companion_id = parts.get(1).copied().unwrap_or("default");
            Envelope::new(
                "ocp.behavior.emotion-changed",
                "behavior",
                json!({
                    "companionId": companion_id,
                    "from": "neutral",
                    "to": emotion,
                }),
            )
        } else if let Some(rest) = line.strip_prefix("/anim ") {
            // /anim <animationId> [companionId] — request a §7 animation directly;
            // ask for one the character package lacks (e.g. `/anim thinking`) to
            // see the missing-asset fallback.
            let parts: Vec<&str> = rest.split_whitespace().collect();
            let animation_id = parts.first().copied().unwrap_or("wave");
            let companion_id = parts.get(1).copied().unwrap_or("default");
            Envelope::new(
                "ocp.behavior.animation-requested",
                "behavior",
                json!({
                    "companionId": companion_id,
                    "animationId": animation_id,
                    "looped": false,
                    "priority": "reactive",
                    "blendMs": 120,
                }),
            )
        } else if let Some(rest) = line.strip_prefix("/follow ") {
            // /follow <id> <leader> <on|off>
            let parts: Vec<&str> = rest.split_whitespace().collect();
            let id = parts.first().copied().unwrap_or("aiko");
            let leader = parts.get(1).copied().unwrap_or("default");
            let active = parts.get(2).copied() != Some("off");
            Envelope::new(
                "ocp.behavior.companion-follow-requested",
                "behavior",
                json!({
                    "companionId": id,
                    "leaderCompanionId": leader,
                    "active": active,
                    "distancePx": 140,
                }),
            )
        } else if let Some(id) = line.strip_prefix("/look ") {
            Envelope::new(
                "ocp.behavior.look-at-cursor-requested",
                "behavior",
                json!({ "companionId": id.trim(), "durationMs": 800 }),
            )
        } else if let Some(rest) = line.strip_prefix("/say ") {
            // /say <id> <text> — an addressed bubble (§8.1)
            let (id, text) = rest.split_once(' ').unwrap_or((rest, "..."));
            Envelope::new(
                "ocp.behavior.bubble-requested",
                "behavior",
                json!({
                    "bubbleId": uuid::Uuid::now_v7(),
                    "companionId": id,
                    "text": text,
                    "tone": "neutral",
                    "anchor": "companion",
                }),
            )
        } else {
            Envelope::new(
                "ocp.behavior.bubble-requested",
                "behavior",
                json!({
                    "bubbleId": uuid::Uuid::now_v7(),
                    "text": line,
                    "tone": "neutral",
                    "anchor": "companion",
                }),
            )
        };
        match env {
            Ok(env) => push(&presentation, &env),
            Err(e) => eprintln!("[kernel] refusing to send invalid envelope: {e}"),
        }
    }
    // PHASE-6.5.3I: DESKTOP-PHYSICS-SHUTDOWN
    // Physics must stop before Desktop World so it never reads a World store
    // whose producer has already terminated.
    if let Some(runtime) = desktop_physics_loop.as_mut() {
        match runtime.shutdown() {
            Ok(health) => println!(
                "[kernel] Desktop Physics stopped: ticks={} events={} bodies={}",
                health.host.completed_ticks, health.host.published_events, health.host.body_count
            ),
            Err(error) => {
                eprintln!("[kernel] Desktop Physics shutdown failed: {error}");
            }
        }
    }

    // PHASE-6.5.2C: DESKTOP-WORLD-SHUTDOWN
    if let Some(host) = desktop_world_host.as_mut() {
        match host.shutdown() {
            Ok(Some(summary)) => println!(
                "[kernel] Desktop World stopped: ticks={} revision={}",
                summary.completed_ticks,
                summary.final_revision.value()
            ),
            Ok(None) => {}
            Err(error) => eprintln!("[kernel] Desktop World shutdown failed: {error}"),
        }
    }
    println!("[kernel] bye");
}

/// Handle a §8.2 lifecycle stdin command through the Companion Manager.
/// Returns `None` if the line is not a lifecycle command, `Some(success)`
/// otherwise.
fn handle_lifecycle_command(
    line: &str,
    presentation: &Presentation,
    pipeline: &SharedPipeline,
    physics: Option<&ocp_kernel::desktop_physics_boot::KernelDesktopPhysicsHandle>,
    bindings: &CompanionPhysicsBindings,
) -> Option<bool> {
    use ocp_companion_manager::CompanionPosition;

    #[derive(Clone)]
    enum PhysicsLifecycle {
        Bind {
            companion_id: String,
            position: Option<CompanionPosition>,
        },
        Unbind {
            companion_id: String,
        },
        None,
    }

    let mut p = pipeline.lock().expect("pipeline lock");
    let (result, physics_lifecycle) = if let Some(rest) = line.strip_prefix("/spawn ") {
        let parts: Vec<&str> = rest.split_whitespace().collect();
        let id = parts.first().copied().unwrap_or("aiko");
        let position = match (
            parts.get(1).and_then(|value| value.parse::<i64>().ok()),
            parts.get(2).and_then(|value| value.parse::<i64>().ok()),
        ) {
            (Some(x), Some(y)) => Some(CompanionPosition {
                x,
                y,
                monitor_id: None,
            }),
            _ => None,
        };
        let result = p
            .manager
            .spawn(id, "character.placeholder", position.clone())
            .inspect(|_| {
                let _ = p.manager.subscribe(id, "ocp.activity.");
            });
        (
            result,
            PhysicsLifecycle::Bind {
                companion_id: id.to_owned(),
                position,
            },
        )
    } else if let Some(id) = line.strip_prefix("/despawn ") {
        let companion_id = id.trim().to_owned();
        (
            p.manager.despawn(&companion_id),
            PhysicsLifecycle::Unbind { companion_id },
        )
    } else if let Some(rest) = line.strip_prefix("/sleep ") {
        let parts: Vec<&str> = rest.split_whitespace().collect();
        let id = parts.first().copied().unwrap_or("default");
        let active = parts.get(1).copied() != Some("off");
        (p.manager.request_sleep(id, active), PhysicsLifecycle::None)
    } else if let Some(id) = line.strip_prefix("/show ") {
        (
            p.manager.request_visibility(id.trim(), true),
            PhysicsLifecycle::None,
        )
    } else if let Some(id) = line.strip_prefix("/hide ") {
        (
            p.manager.request_visibility(id.trim(), false),
            PhysicsLifecycle::None,
        )
    } else {
        let id = line.strip_prefix("/focus ")?;
        (p.manager.request_focus(id.trim()), PhysicsLifecycle::None)
    };
    drop(p);

    match result {
        Ok(request) => {
            if let Some(handle) = physics {
                let physics_result = match physics_lifecycle {
                    PhysicsLifecycle::Bind {
                        companion_id,
                        position,
                    } => bindings.bind(&companion_id, position, handle).map(|_| ()),
                    PhysicsLifecycle::Unbind { companion_id } => {
                        bindings.unbind(&companion_id, handle).map(|_| ())
                    }
                    PhysicsLifecycle::None => Ok(()),
                };

                if let Err(error) = physics_result {
                    eprintln!("[kernel] companion Physics lifecycle failed: {error}");
                    return Some(false);
                }
            }

            push(presentation, &request);
            Some(true)
        }
        Err(error) => {
            eprintln!("[kernel] [manager] {error}");
            Some(false)
        }
    }
}

fn handle_physics_command(
    line: &str,
    physics: Option<&ocp_kernel::desktop_physics_boot::KernelDesktopPhysicsHandle>,
    bindings: &CompanionPhysicsBindings,
) -> Option<bool> {
    let (companion_id, command) = if let Some(rest) = line.strip_prefix("/walk ") {
        let parts: Vec<&str> = rest.split_whitespace().collect();
        let companion_id = parts.first().copied().unwrap_or("default");
        let edge_behavior = match parts.get(2).copied() {
            Some("off") | Some("walk-off") => WalkEdgeBehavior::WalkOff,
            _ => WalkEdgeBehavior::StopAtEdge,
        };
        let command = match parts.get(1).copied() {
            Some("left") => CompanionMovementCommand::WalkLeft { edge_behavior },
            Some("right") => CompanionMovementCommand::WalkRight { edge_behavior },
            _ => {
                eprintln!("[kernel] usage: /walk <id> <left|right> [stop|off]");
                return Some(false);
            }
        };
        (companion_id, command)
    } else if let Some(rest) = line.strip_prefix("/jump ") {
        let parts: Vec<&str> = rest.split_whitespace().collect();
        let companion_id = parts.first().copied().unwrap_or("default");
        let command = match parts.get(1).copied() {
            Some("left") => CompanionMovementCommand::JumpLeft,
            Some("right") => CompanionMovementCommand::JumpRight,
            Some("up") | Some("vertical") => CompanionMovementCommand::JumpVertical,
            _ => {
                eprintln!("[kernel] usage: /jump <id> <up|left|right>");
                return Some(false);
            }
        };
        (companion_id, command)
    } else if let Some(rest) = line.strip_prefix("/hang ") {
        let parts: Vec<&str> = rest.split_whitespace().collect();
        let companion_id = parts.first().copied().unwrap_or("default");
        let command = match parts.get(1).copied() {
            Some("left") => CompanionMovementCommand::HangLeft,
            Some("right") => CompanionMovementCommand::HangRight,
            _ => {
                eprintln!("[kernel] usage: /hang <id> <left|right>");
                return Some(false);
            }
        };
        (companion_id, command)
    } else if let Some(rest) = line.strip_prefix("/climb ") {
        let parts: Vec<&str> = rest.split_whitespace().collect();
        let companion_id = parts.first().copied().unwrap_or("default");
        let command = match parts.get(1).copied() {
            Some("up") => CompanionMovementCommand::ClimbUp,
            Some("down") => CompanionMovementCommand::ClimbDown,
            _ => {
                eprintln!("[kernel] usage: /climb <id> <up|down>");
                return Some(false);
            }
        };
        (companion_id, command)
    } else if let Some(id) = line.strip_prefix("/stop ") {
        (id.trim(), CompanionMovementCommand::Stop)
    } else if let Some(id) = line.strip_prefix("/detach ") {
        (id.trim(), CompanionMovementCommand::Detach)
    } else {
        let id = line.strip_prefix("/ledge ")?;
        (id.trim(), CompanionMovementCommand::TransferLedge)
    };

    if !valid_companion_id(companion_id) {
        eprintln!("[kernel] invalid companion id: `{companion_id}`");
        return Some(false);
    }

    let Some(handle) = physics else {
        eprintln!("[kernel] Desktop Physics is unavailable");
        return Some(false);
    };

    if bindings.binding(companion_id).is_none() {
        if let Err(error) = bindings.bind(companion_id, None, handle) {
            eprintln!("[kernel] [physics] lazy bind failed: {error}");
            return Some(false);
        }
        println!("[kernel] [physics] lazy-bound `{companion_id}` at configured initial position");
    }

    match bindings.enqueue(companion_id, command, handle) {
        Ok(()) => {
            println!("[kernel] [physics] queued {command:?} for `{companion_id}`");
            Some(true)
        }
        Err(error) => {
            eprintln!("[kernel] [physics] {error}");
            Some(false)
        }
    }
}

fn parse_autonomous_movement_request(
    data: &serde_json::Value,
) -> Option<(&str, CompanionMovementCommand)> {
    if data
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
        != Some(1)
        || data.get("source").and_then(serde_json::Value::as_str) != Some("offline-presence")
        || data.get("edgeBehavior").and_then(serde_json::Value::as_str) != Some("stop-at-edge")
    {
        return None;
    }
    let companion_id = data.get("companionId")?.as_str()?;
    if !valid_companion_id(companion_id) {
        return None;
    }
    let command = match data.get("action")?.as_str()? {
        "walk-left" => CompanionMovementCommand::WalkLeft {
            edge_behavior: WalkEdgeBehavior::StopAtEdge,
        },
        "walk-right" => CompanionMovementCommand::WalkRight {
            edge_behavior: WalkEdgeBehavior::StopAtEdge,
        },
        "climb-up" => CompanionMovementCommand::ClimbUp,
        "climb-down" => CompanionMovementCommand::ClimbDown,
        "hang-left" => CompanionMovementCommand::HangLeft,
        "hang-right" => CompanionMovementCommand::HangRight,
        "hang-to-center" => CompanionMovementCommand::HangToCenter,
        "hang-to-far-edge" => CompanionMovementCommand::HangToFarEdge,
        "hang-to-climb-down-edge" => CompanionMovementCommand::HangToClimbDownEdge,
        "detach" => CompanionMovementCommand::Detach,
        "teleport-current-monitor" => CompanionMovementCommand::TeleportCurrentMonitor,
        "stop" => CompanionMovementCommand::Stop,
        _ => return None,
    };
    Some((companion_id, command))
}

fn valid_companion_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 96
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// First bubble after a subscribe, so the walking skeleton shows life
/// without any typing. Also (integration slice) registers + spawns the
/// `default` companion through the manager, so legacy single-companion
/// traffic routes to a real actor: the runtime treats a duplicate spawn of
/// `default` as a visual no-op but still emits `companion-spawned`, which is
/// what flips the actor Active on mirror.
fn greet(presentation: &Presentation, pipeline: &SharedPipeline) {
    let spawn_req = {
        let mut p = pipeline.lock().expect("pipeline lock");
        match p.manager.spawn("default", "character.placeholder", None) {
            Ok(req) => {
                let _ = p.manager.subscribe("default", "ocp.activity.");
                Some(req)
            }
            Err(_) => None, // runtime reconnect: default already registered
        }
    };
    if let Some(req) = spawn_req {
        push(presentation, &req);
    }

    if let Ok(env) = Envelope::new(
        "ocp.behavior.bubble-requested",
        "behavior",
        json!({
            "bubbleId": uuid::Uuid::now_v7(),
            "companionId": "default",
            "text": "OCP integrated kernel online",
            "tone": "happy",
            "anchor": "companion",
        }),
    ) {
        push(presentation, &env);
    }
}

/// Send one envelope to the runtime; on failure drop the connection so the
/// runtime's reconnect (RUNTIME_API §4.4) re-subscribes cleanly.
fn push(presentation: &Presentation, env: &Envelope) {
    let mut slot = presentation.lock().expect("lock");
    match slot.as_mut() {
        Some(conn) => match send_envelope(conn, env) {
            Ok(()) => {
                if should_log_forwarded_event(&env.event_type) {
                    println!("[kernel] -> {} ({})", env.event_type, env.id);
                }
            }
            Err(e) => {
                if is_expected_runtime_disconnect(&e) {
                    println!("[kernel] runtime subscriber disconnected; waiting for reconnect");
                } else {
                    eprintln!(
                        "[kernel] send failed ({e}); dropping connection, runtime will reconnect"
                    );
                }
                *slot = None;
            }
        },
        None => {
            if should_log_missing_subscriber(&env.event_type) {
                println!("[kernel] no runtime subscribed yet — event not sent");
            }
        }
    }
}

fn is_expected_runtime_disconnect(error: &IpcError) -> bool {
    match error {
        IpcError::Io(error) => {
            matches!(
                error.kind(),
                std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::UnexpectedEof
            ) || matches!(error.raw_os_error(), Some(109 | 232 | 233))
        }
        _ => false,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RuntimeEventLogLevel {
    Off,
    Summary,
    Full,
}

fn runtime_event_log_level() -> RuntimeEventLogLevel {
    match std::env::var("OCP_WORLD_EVENT_LOG")
        .unwrap_or_else(|_| "summary".to_owned())
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "off" | "none" | "0" | "false" => RuntimeEventLogLevel::Off,
        "all" | "full" | "debug" => RuntimeEventLogLevel::Full,
        _ => RuntimeEventLogLevel::Summary,
    }
}

fn should_log_forwarded_event(event_type: &str) -> bool {
    match runtime_event_log_level() {
        RuntimeEventLogLevel::Off => false,
        RuntimeEventLogLevel::Full => true,
        RuntimeEventLogLevel::Summary => !is_high_frequency_event(event_type),
    }
}

fn should_log_received_event(event_type: &str) -> bool {
    match runtime_event_log_level() {
        RuntimeEventLogLevel::Off => false,
        RuntimeEventLogLevel::Full => true,
        RuntimeEventLogLevel::Summary => matches!(
            event_type,
            "ocp.runtime.companion-position-requested"
                | "ocp.runtime.companion-spawned"
                | "ocp.runtime.companion-despawned"
                | "ocp.runtime.bubble-shown"
                | "ocp.runtime.error"
        ),
    }
}

fn should_log_missing_subscriber(event_type: &str) -> bool {
    !is_desktop_world_event(event_type)
        && !matches!(
            event_type,
            "ocp.character.moved" | "ocp.runtime.companion-moved"
        )
}

fn is_desktop_world_event(event_type: &str) -> bool {
    event_type.starts_with("ocp.world.")
        || event_type.starts_with("ocp.surface.")
        || event_type.starts_with("ocp.runtime.desktop-world-")
}

fn is_high_frequency_event(event_type: &str) -> bool {
    event_type.starts_with("ocp.surface.")
        || matches!(
            event_type,
            "ocp.world.updated"
                | "ocp.world.changed"
                | "ocp.world.cursor-changed"
                | "ocp.character.moved"
                | "ocp.runtime.companion-moved"
                | "ocp.runtime.companion-presentation-state"
        )
}

/// Publish-side connection: read outcome facts until the peer hangs up.
/// Malformed envelopes are dropped, the connection survives (SEC-041). Every
/// fact runs the full integrated pipeline (`process_fact`): lifecycle
/// mirroring → activity interpretation → targeted routing → staggered
/// per-companion Behavior Engine reactions.
fn drain_outcomes(
    mut conn: Connection,
    presentation: Presentation,
    pipeline: SharedPipeline,
    physics: Option<ocp_kernel::desktop_physics_boot::KernelDesktopPhysicsHandle>,
    bindings: CompanionPhysicsBindings,
    audio_store: Arc<AudioStore>,
) {
    let mut runtime_asr: Option<(String, GeminiLiveAsrControl)> = None;
    let mut runtime_live_voice: Option<(String, GeminiLiveVoiceControl)> = None;
    // Lazy-open once per runtime connection. This avoids re-opening SQLCipher
    // and consulting the OS keystore on every chat turn while still reopening
    // the same encrypted profile after a Runtime reconnect/restart.
    let mut runtime_memory_store: Option<SqliteStore> = None;
    loop {
        match recv_envelope(&mut conn) {
            Ok(env) => {
                let corr = env
                    .correlation_id
                    .map(|c| format!(" corr={c}"))
                    .unwrap_or_default();
                if should_log_received_event(&env.event_type) {
                    println!("[kernel] <- {}{corr} data={}", env.event_type, env.data);
                }

                if env.event_type == "ocp.runtime.companion-position-requested" {
                    let companion_id = env
                        .data
                        .get("companionId")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    let position = env.data.get("position");
                    let valid_contract = position
                        .and_then(|value| value.get("space"))
                        .and_then(serde_json::Value::as_str)
                        == Some("desktop-logical")
                        && position
                            .and_then(|value| value.get("anchor"))
                            .and_then(serde_json::Value::as_str)
                            == Some("character-feet")
                        && env.data.get("mode").and_then(serde_json::Value::as_str)
                            == Some("authoritative-snap");

                    let x = position
                        .and_then(|value| value.get("x"))
                        .and_then(serde_json::Value::as_f64);
                    let y = position
                        .and_then(|value| value.get("y"))
                        .and_then(serde_json::Value::as_f64);

                    if !valid_contract || companion_id.is_empty() {
                        eprintln!("[kernel] [physics] rejected malformed drag commit");
                        continue;
                    }

                    let (Some(x), Some(y), Some(handle)) = (x, y, physics.as_ref()) else {
                        eprintln!("[kernel] [physics] drag commit unavailable");
                        continue;
                    };
                    if !x.is_finite() || !y.is_finite() {
                        eprintln!("[kernel] [physics] rejected non-finite drag commit");
                        continue;
                    }

                    match bindings.commit_authoritative_position(
                        companion_id,
                        Point2::new(x as f32, y as f32),
                        handle,
                    ) {
                        Ok(feet) => println!(
                            "[kernel] [physics] drag committed `{companion_id}` at ({:.1}, {:.1})",
                            feet.x, feet.y
                        ),
                        Err(error) => eprintln!(
                            "[kernel] [physics] drag commit failed for `{companion_id}`: {error}"
                        ),
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.companion-movement-requested" {
                    let Some((companion_id, command)) =
                        parse_autonomous_movement_request(&env.data)
                    else {
                        eprintln!(
                            "[kernel] [physics] rejected malformed autonomous movement request"
                        );
                        continue;
                    };
                    let Some(handle) = physics.as_ref() else {
                        eprintln!("[kernel] [physics] autonomous movement unavailable");
                        continue;
                    };
                    if bindings.binding(companion_id).is_none() {
                        if let Err(error) = bindings.bind(companion_id, None, handle) {
                            eprintln!(
                                "[kernel] [physics] autonomous movement bind failed: {error}"
                            );
                            continue;
                        }
                    }
                    match bindings.enqueue_autonomous_surface_action(companion_id, command, handle) {
                        Ok(()) => println!("[kernel] [physics] autonomous movement queued {command:?} for `{companion_id}`"),
                        Err(error) => eprintln!("[kernel] [physics] autonomous movement rejected for `{companion_id}`: {error}"),
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.live-voice-start" {
                    if let Some((_, previous)) = runtime_live_voice.take() {
                        let _ = previous.close();
                    }
                    if let Some((_, previous_asr)) = runtime_asr.take() {
                        let _ = previous_asr.close();
                    }
                    runtime_live_voice = start_runtime_live_voice(&env, &presentation);
                    continue;
                }

                if env.event_type == "ocp.runtime.live-voice-activity-start" {
                    if !runtime_live_voice_activity(&env, &runtime_live_voice, true) {
                        let session_id =
                            runtime_asr_session_id(&env).unwrap_or_else(|| "invalid".to_owned());
                        push_runtime_live_voice_error(
                            &presentation,
                            &session_id,
                            env.id,
                            "live-voice-session-unavailable",
                        );
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.live-voice-audio" {
                    if !runtime_live_voice_audio(&env, &runtime_live_voice) {
                        let session_id =
                            runtime_asr_session_id(&env).unwrap_or_else(|| "invalid".to_owned());
                        push_runtime_live_voice_error(
                            &presentation,
                            &session_id,
                            env.id,
                            "invalid-live-audio-frame",
                        );
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.live-voice-activity-end" {
                    if !runtime_live_voice_activity(&env, &runtime_live_voice, false) {
                        let session_id =
                            runtime_asr_session_id(&env).unwrap_or_else(|| "invalid".to_owned());
                        push_runtime_live_voice_error(
                            &presentation,
                            &session_id,
                            env.id,
                            "live-voice-session-unavailable",
                        );
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.live-voice-close" {
                    let session_id =
                        runtime_asr_session_id(&env).unwrap_or_else(|| "invalid".to_owned());
                    if let Some((active_id, control)) = runtime_live_voice.take() {
                        if active_id == session_id {
                            let _ = control.close();
                        } else {
                            runtime_live_voice = Some((active_id, control));
                        }
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.asr-start" {
                    if let Some((_, previous)) = runtime_asr.take() {
                        let _ = previous.close();
                    }
                    runtime_asr = start_runtime_asr(&env, &presentation);
                    continue;
                }

                if env.event_type == "ocp.runtime.asr-audio" {
                    if !runtime_asr_audio(&env, &runtime_asr) {
                        let session_id =
                            runtime_asr_session_id(&env).unwrap_or_else(|| "invalid".to_owned());
                        push_runtime_asr_error(
                            &presentation,
                            &session_id,
                            env.id,
                            "invalid-audio-frame",
                        );
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.asr-end" {
                    if !runtime_asr_end(&env, &runtime_asr) {
                        let session_id =
                            runtime_asr_session_id(&env).unwrap_or_else(|| "invalid".to_owned());
                        push_runtime_asr_error(
                            &presentation,
                            &session_id,
                            env.id,
                            "asr-session-unavailable",
                        );
                    } else {
                        // The event-pump thread owns a cloned control handle and
                        // keeps the provider session alive until TurnComplete.
                        // Clear the main-loop slot immediately so a new VAD turn
                        // can start without closing the previous turn before its
                        // final transcript arrives.
                        runtime_asr = None;
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.tts-requested" {
                    // Gemini 3.1 Flash TTS can stream audio deltas. Use that
                    // path first; only fall back to the existing whole-WAV
                    // router path when streaming could not produce its first
                    // audio delta (missing key, bad request, unavailable API).
                    if !runtime_tts_request_streaming(&env, &presentation) {
                        if let Some(speech) = runtime_tts_request_to_speech(&env, &audio_store) {
                            push(&presentation, &speech);
                        }
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.memory-recent-requested" {
                    if let Some(response) =
                        runtime_memory_recent_response(&env, &mut runtime_memory_store)
                    {
                        push(&presentation, &response);
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.memory-turn-write" {
                    if let Some(response) =
                        runtime_memory_turn_write_response(&env, &mut runtime_memory_store)
                    {
                        push(&presentation, &response);
                    }
                    continue;
                }

                if env.event_type == "ocp.runtime.ai-requested" {
                    if let Some(response) = runtime_cloud_ai_request_to_response(&env) {
                        push(&presentation, &response);
                    }
                    continue;
                }

                process_fact(&env, &presentation, &pipeline);
            }
            Err(IpcError::Io(_)) => break, // peer done
            Err(e) => eprintln!("[kernel] dropped bad frame (SEC-041): {e}"),
        }
    }
    if let Some((_, control)) = runtime_asr.take() {
        let _ = control.close();
    }
}

#[cfg(test)]
mod tests {
    use ocp_llm_router::adapter::ReferenceSynthesizer;

    use super::*;

    #[test]
    fn runtime_memory_companion_id_is_bounded_to_the_existing_id_contract() {
        assert_eq!(
            normalized_runtime_memory_companion_id("").expect("empty id uses default"),
            "default"
        );
        assert_eq!(
            normalized_runtime_memory_companion_id("character.nene-01").expect("safe companion id"),
            "character.nene-01"
        );
        assert!(normalized_runtime_memory_companion_id("../../escape").is_err());
        assert!(normalized_runtime_memory_companion_id("bad id").is_err());
    }

    #[test]
    fn runtime_memory_transport_keeps_conversation_json_valid_when_bounded() {
        let content = json!({
            "kind": "conversation-turn",
            "messageId": "m-1",
            "user": "u".repeat(2000),
            "assistant": "a".repeat(5000),
        })
        .to_string();
        let bounded = bounded_memory_content_for_transport(&content);
        let parsed: serde_json::Value =
            serde_json::from_str(&bounded).expect("bounded turn must remain valid JSON");
        assert_eq!(parsed["kind"], "conversation-turn");
        assert_eq!(parsed["user"].as_str().expect("user").chars().count(), 600);
        assert_eq!(
            parsed["assistant"]
                .as_str()
                .expect("assistant")
                .chars()
                .count(),
            900
        );
    }

    #[test]
    fn expected_runtime_disconnect_classifies_normal_pipe_closure() {
        for error in [
            IpcError::Io(std::io::Error::from(std::io::ErrorKind::BrokenPipe)),
            IpcError::Io(std::io::Error::from(std::io::ErrorKind::ConnectionReset)),
            IpcError::Io(std::io::Error::from(std::io::ErrorKind::ConnectionAborted)),
            IpcError::Io(std::io::Error::from(std::io::ErrorKind::NotConnected)),
            IpcError::Io(std::io::Error::from(std::io::ErrorKind::UnexpectedEof)),
            IpcError::Io(std::io::Error::from_raw_os_error(109)),
            IpcError::Io(std::io::Error::from_raw_os_error(232)),
            IpcError::Io(std::io::Error::from_raw_os_error(233)),
        ] {
            assert!(is_expected_runtime_disconnect(&error));
        }

        assert!(!is_expected_runtime_disconnect(&IpcError::Io(
            std::io::Error::from(std::io::ErrorKind::PermissionDenied),
        )));
        assert!(!is_expected_runtime_disconnect(
            &IpcError::HandshakeRejected
        ));
    }

    #[test]
    fn voice_route_diagnostics_distinguish_cloud_failures_from_explicit_local_voice() {
        let unreachable = vec![
            "PROVIDER gemini-tts-primary: Available -> Failed (Unreachable)".to_owned(),
            "PROVIDER gemini-tts-fallback: Available -> Failed (Unreachable)".to_owned(),
        ];
        assert_eq!(
            runtime_voice_route_reason(
                "สวัสดีค่ะ",
                "profile:female:adult",
                "auto",
                true,
                &unreachable
            ),
            "dns-unreachable"
        );
        assert_eq!(
            runtime_voice_route_reason("สวัสดีค่ะ", "profile:female:adult", "auto", false, &[]),
            "provider-credential-required"
        );
        let local_reason =
            runtime_voice_route_reason("สวัสดีค่ะ", "profile:female:adult", "system", false, &[]);
        assert!(
            matches!(
                local_reason,
                "local-voice-not-installed" | "tts-unavailable"
            ),
            "explicit system voice must remain a bounded local diagnostic, got {local_reason}"
        );
        assert_eq!(
            runtime_voice_route_reason(
                "สวัสดีค่ะ",
                "profile:female:adult",
                "auto",
                true,
                &["PROVIDER gemini-tts-primary: Available -> Failed (AuthFailed)".to_owned()],
            ),
            "provider-auth-failed"
        );
        assert_eq!(
            runtime_voice_route_reason(
                "สวัสดีค่ะ",
                "profile:female:adult",
                "auto",
                true,
                &["PROVIDER gemini-tts-primary: Available -> Failed (QuotaExceeded)".to_owned()],
            ),
            "provider-quota-exceeded"
        );
        assert_eq!(
            runtime_voice_route_reason(
                "สวัสดีค่ะ",
                "profile:female:adult",
                "auto",
                true,
                &["PROVIDER gemini-tts-primary: Available -> Degraded (RateLimited)".to_owned()],
            ),
            "provider-rate-limited"
        );
    }

    #[test]
    fn autonomous_surface_locomotion_contract_is_narrowly_allowlisted() {
        let request = serde_json::json!({
            "schemaVersion": 1,
            "companionId": "default",
            "action": "walk-left",
            "edgeBehavior": "stop-at-edge",
            "source": "offline-presence",
        });
        assert!(matches!(
            parse_autonomous_movement_request(&request),
            Some((
                "default",
                CompanionMovementCommand::WalkLeft {
                    edge_behavior: WalkEdgeBehavior::StopAtEdge
                }
            ))
        ));
        let climb = serde_json::json!({
            "schemaVersion": 1,
            "companionId": "default",
            "action": "climb-up",
            "edgeBehavior": "stop-at-edge",
            "source": "offline-presence",
        });
        assert!(matches!(
            parse_autonomous_movement_request(&climb),
            Some(("default", CompanionMovementCommand::ClimbUp))
        ));
        for (action, expected) in [
            ("hang-left", CompanionMovementCommand::HangLeft),
            ("hang-right", CompanionMovementCommand::HangRight),
            ("hang-to-center", CompanionMovementCommand::HangToCenter),
            ("hang-to-far-edge", CompanionMovementCommand::HangToFarEdge),
            (
                "hang-to-climb-down-edge",
                CompanionMovementCommand::HangToClimbDownEdge,
            ),
            ("climb-down", CompanionMovementCommand::ClimbDown),
            ("detach", CompanionMovementCommand::Detach),
            (
                "teleport-current-monitor",
                CompanionMovementCommand::TeleportCurrentMonitor,
            ),
            ("stop", CompanionMovementCommand::Stop),
        ] {
            let request = serde_json::json!({
                "schemaVersion": 1,
                "companionId": "default",
                "action": action,
                "edgeBehavior": "stop-at-edge",
                "source": "offline-presence",
            });
            assert_eq!(
                parse_autonomous_movement_request(&request),
                Some(("default", expected))
            );
        }
        for action in ["transfer-ledge", "jump-left"] {
            let request = serde_json::json!({
                "schemaVersion": 1,
                "companionId": "default",
                "action": action,
                "edgeBehavior": "stop-at-edge",
                "source": "offline-presence",
            });
            assert!(parse_autonomous_movement_request(&request).is_none());
        }
    }

    #[test]
    fn a_signed_character_package_is_verified_and_extracted_for_the_runtime() {
        use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};

        // Sign with the SAME dev seed `demo_trust()` trusts (and pack_character
        // uses), so the load-time signature check passes.
        let key = ed25519_dalek::SigningKey::from_bytes(&[7u8; 32]);
        let character_json = br#"{"schema":"character/1","name":"Aiko","renderer":"sprite-sheet-2d","sprites":[{"id":"body","path":"assets/sprite.png","frameSize":[96,96]}],"animations":{"idle":{"frames":[0,1],"fps":2,"loop":true}}}"#.to_vec();
        let request = BuildRequest {
            identity: PackageIdentity {
                id: "character.aiko".to_owned(),
                package_type: PackageType::Character,
                version: "1.0.0".to_owned(),
                publisher_id: "ocp.demo".to_owned(),
                key_id: "ed25519:demo-1".to_owned(),
                license: "CC-BY-4.0".to_owned(),
                entry: "assets/character.json".to_owned(),
            },
            asset_paths: vec![
                "assets/character.json".to_owned(),
                "assets/sprite.png".to_owned(),
            ],
            assets: vec![
                AssetInput {
                    path: "assets/character.json".to_owned(),
                    bytes: character_json,
                },
                AssetInput {
                    path: "assets/sprite.png".to_owned(),
                    bytes: b"\x89PNG\r\n\x1a\n".to_vec(),
                },
            ],
        };
        let ocp = build(&request, &key).expect("the demo package builds");

        let dir = tempfile::tempdir().expect("temp character dir");
        let character =
            extract_character_package(&ocp, dir.path()).expect("a signed package extracts");

        assert_eq!(character.name, "Aiko");
        assert_eq!(character.source_schema, "character/1");
        assert!(
            dir.path().join("character.json").exists(),
            "the entry lands at the runtime's fixed path"
        );
        assert!(
            dir.path().join("assets/sprite.png").exists(),
            "other assets keep their in-package path so the entry's refs resolve"
        );
    }

    #[test]
    fn a_signed_character_v2_package_exposes_its_canonical_body_profile() {
        use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};

        let key = ed25519_dalek::SigningKey::from_bytes(&[7u8; 32]);
        let character_json = br#"{
          "schema":"character/2",
          "id":"character.aiko-v2",
          "version":"2.0.0",
          "name":"Aiko V2",
          "renderer":"sprite-sheet-2d",
          "runtimeCompatibility":{"minimumRuntimeVersion":"0.1.0"},
          "capabilities":{"basicWalk":true,"jump":true},
          "bodyProfile":{
            "logicalSize":[128,128],
            "collisionHalfExtents":[48,62],
            "feetAnchor":[0.5,1.0]
          },
          "presentationProfile":{
            "baseScale":1.0,
            "minimumUserScale":0.5,
            "maximumUserScale":2.0
          },
          "sprites":[{"id":"body","path":"assets/sprite.png","frameSize":[96,96]}],
          "animations":{"idle":{"sprite":"body","frames":[0,1],"fps":2,"loop":true}}
        }"#
        .to_vec();
        let request = BuildRequest {
            identity: PackageIdentity {
                id: "character.aiko-v2".to_owned(),
                package_type: PackageType::Character,
                version: "2.0.0".to_owned(),
                publisher_id: "ocp.demo".to_owned(),
                key_id: "ed25519:demo-1".to_owned(),
                license: "CC-BY-4.0".to_owned(),
                entry: "assets/character.json".to_owned(),
            },
            asset_paths: vec![
                "assets/character.json".to_owned(),
                "assets/sprite.png".to_owned(),
            ],
            assets: vec![
                AssetInput {
                    path: "assets/character.json".to_owned(),
                    bytes: character_json,
                },
                AssetInput {
                    path: "assets/sprite.png".to_owned(),
                    bytes: b"\x89PNG\r\n\x1a\n".to_vec(),
                },
            ],
        };
        let ocp = build(&request, &key).expect("the signed character/2 package builds");

        let dir = tempfile::tempdir().expect("temp character dir");
        let character = extract_character_package(&ocp, dir.path()).expect("character/2 extracts");

        assert_eq!(character.source_schema, "character/2");
        assert_eq!(character.id.as_deref(), Some("character.aiko-v2"));
        assert_eq!(character.body_profile.collision_half_extents, [48.0, 62.0]);
        assert_eq!(
            character.collision_feet_from_center([640.0, 850.0]),
            [640.0, 912.0]
        );
    }

    #[test]
    fn a_signed_character_v3_package_exposes_preview_audio_and_effect_profiles() {
        use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};

        let key = ed25519_dalek::SigningKey::from_bytes(&[7u8; 32]);
        let character_json = br#"{
          "schema":"character/3",
          "id":"character.sabai-v3",
          "version":"3.0.0",
          "name":"Sabai V3",
          "renderer":"sprite-sheet-2d",
          "runtimeCompatibility":{"minimumRuntimeVersion":"0.1.0"},
          "bodyProfile":{
            "logicalSize":[128,128],
            "collisionHalfExtents":[42,62],
            "feetAnchor":[0.5,1.0]
          },
          "presentation":{"preview":{"path":"assets/preview.png"}},
          "voiceProfile":{"presentation":"female","age":"adult","thaiSpeechStyle":"feminine"},
          "sprites":[{"id":"idle","path":"assets/idle.png","frameSize":[512,512]}],
          "animations":{"idle":{"sprite":"idle","frames":[0],"fps":8,"loop":true}},
          "audioProfile":{
            "clips":[{"id":"sfx_happy","path":"assets/audio/happy.wav","loop":false,"gainDb":-3}],
            "bindings":{"happy":{"clip":"sfx_happy","start":"animation-start"}}
          },
          "effectsProfile":{
            "effects":[{
              "id":"aura","type":"sprite-sheet","path":"assets/effects/aura.png",
              "frameSize":[512,512],"fps":12,"frames":24,"loop":true,
              "layer":"behind-character","anchor":"body-center","scale":1.0,"offset":[0,0]
            }],
            "bindings":{"aura":{"effect":"aura"}},
            "teleport":{"mode":"runtime-default","effectId":"portal.blue","anchor":"below-feet","scale":1.0,"offset":[0,0]}
          }
        }"#
        .to_vec();
        let asset_paths = vec![
            "assets/character.json".to_owned(),
            "assets/idle.png".to_owned(),
            "assets/preview.png".to_owned(),
            "assets/audio/happy.wav".to_owned(),
            "assets/effects/aura.png".to_owned(),
        ];
        let assets = vec![
            AssetInput {
                path: "assets/character.json".to_owned(),
                bytes: character_json,
            },
            AssetInput {
                path: "assets/idle.png".to_owned(),
                bytes: b"PNG-IDLE".to_vec(),
            },
            AssetInput {
                path: "assets/preview.png".to_owned(),
                bytes: b"PNG-PREVIEW".to_vec(),
            },
            AssetInput {
                path: "assets/audio/happy.wav".to_owned(),
                bytes: b"RIFF-WAV".to_vec(),
            },
            AssetInput {
                path: "assets/effects/aura.png".to_owned(),
                bytes: b"PNG-AURA".to_vec(),
            },
        ];
        let request = BuildRequest {
            identity: PackageIdentity {
                id: "character.sabai-v3".to_owned(),
                package_type: PackageType::Character,
                version: "3.0.0".to_owned(),
                publisher_id: "ocp.demo".to_owned(),
                key_id: "ed25519:demo-1".to_owned(),
                license: "Private-Test".to_owned(),
                entry: "assets/character.json".to_owned(),
            },
            asset_paths,
            assets,
        };
        let ocp = build(&request, &key).expect("the signed character/3 package builds");
        let dir = tempfile::tempdir().expect("temp character dir");
        let character = extract_character_package(&ocp, dir.path()).expect("character/3 extracts");

        assert_eq!(character.source_schema, "character/3");
        assert_eq!(character.id.as_deref(), Some("character.sabai-v3"));
        assert_eq!(
            character
                .presentation
                .as_ref()
                .and_then(|value| value.preview.as_ref())
                .map(|value| value.path.as_str()),
            Some("assets/preview.png")
        );
        assert_eq!(
            character
                .audio_profile
                .as_ref()
                .map(|value| value.clips.len()),
            Some(1)
        );
        assert_eq!(
            character
                .effects_profile
                .as_ref()
                .map(|value| value.effects.len()),
            Some(1)
        );
        assert!(dir.path().join("assets/preview.png").exists());
        assert!(dir.path().join("assets/audio/happy.wav").exists());
        assert!(dir.path().join("assets/effects/aura.png").exists());
    }

    #[test]
    fn a_tampered_or_untrusted_package_is_rejected_not_extracted() {
        // Random bytes are not a valid signed .ocp -> extraction fails, and the
        // runtime is left to its placeholder (load_character_package logs + continues).
        let dir = tempfile::tempdir().expect("temp character dir");
        assert!(extract_character_package(b"not an ocp archive", dir.path()).is_err());
        assert!(!dir.path().join("character.json").exists());
    }

    /// The kernel AI slice's contract with the runtime: `/speech` routes through
    /// the hosted `tts` chain and the synthesized clip is on disk **at the exact
    /// path the runtime bridge derives from `audioRef.id`** before the
    /// `speech-requested` event is even sent. Uses the deterministic reference
    /// synthesizer (no OS voice in unit tests) and a temp audio dir; the real
    /// binary swaps in `WindowsSynthesizer` and the shared `audio_dir()` — the
    /// wiring under test (`build_tts_router` + `synthesize_speech_request` +
    /// the file-backed store) is identical.
    #[test]
    fn speech_routes_through_tts_and_writes_the_clip_to_the_shared_audio_dir() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        // No gemini key in the unit test -> OS-voice-only chain, with the
        // deterministic reference synth standing in for the OS voice.
        let mut router = build_voice_router(
            Arc::clone(&store),
            Box::new(ReferenceSynthesizer::new()),
            None,
            VoiceGender::default(),
        );

        let env = synthesize_speech_request(
            &mut router,
            &store,
            &SpeakRequest {
                companion_id: "default".to_owned(),
                correlation_id: uuid::Uuid::now_v7(),
                text: "hello from the kernel".to_owned(),
                subtitle: true,
                interruptible: true,
                voice_id: None,
            },
        );

        assert_eq!(env.event_type, "ocp.behavior.speech-requested");
        assert_eq!(
            env.data["companionId"],
            json!("default"),
            "the demo companion is addressed by its §8.1 string id, not a uuid"
        );
        let audio = &env.data["audioRef"];
        assert!(
            !audio.is_null(),
            "the hosted tts chain served the request, so an audioRef rides the event"
        );

        // The runtime bridge's `audio_clip_path` joins the shared dir with
        // `<audioRef.id>.wav`; reproduce that join and require the file to
        // already exist — this is the whole file-backed transport contract.
        let id = uuid::Uuid::parse_str(audio["id"].as_str().unwrap()).unwrap();
        let expected = dir.path().join(format!("{id}.wav"));
        assert!(
            expected.exists(),
            "the clip the runtime will read must already be on disk at {expected:?}"
        );
    }

    #[test]
    fn runtime_cloud_ai_rejects_insecure_base_url_before_using_credential() {
        let request = Envelope::new(
            "ocp.runtime.ai-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud-http",
                "prompt": "hello",
                "providerId": "openai-compatible",
                "baseUrl": "http://example.invalid/v1",
                "model": "test-model",
                "timeoutSeconds": 5
            }),
        )
        .expect("valid cloud AI request");
        let response = runtime_cloud_ai_request_to_response_with_credential(
            &request,
            Some("credential-that-must-never-be-sent-over-http"),
        )
        .expect("insecure URL still returns a failure response");
        assert_eq!(response.event_type, "ocp.runtime.ai-response");
        assert_eq!(response.correlation_id, Some(request.id));
        assert_eq!(response.data["ok"], json!(false));
        assert_eq!(
            response.data["error"],
            json!("OpenAI-compatible cloud Base URL must use HTTPS")
        );
    }

    #[test]
    fn runtime_cloud_ai_request_without_credential_fails_safely_and_keeps_correlation() {
        let request = Envelope::new(
            "ocp.runtime.ai-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud",
                "prompt": "hello",
                "providerId": "openai-compatible",
                "baseUrl": "https://example.invalid/v1",
                "model": "test-model",
                "timeoutSeconds": 5
            }),
        )
        .expect("valid cloud AI request");
        let response = runtime_cloud_ai_request_to_response_with_credential(&request, None)
            .expect("missing credential still returns a failure response");
        assert_eq!(response.event_type, "ocp.runtime.ai-response");
        assert_eq!(response.correlation_id, Some(request.id));
        assert_eq!(response.data["ok"], json!(false));
        assert_eq!(
            response.data["error"],
            json!("OpenAI-compatible API key is not configured")
        );
    }

    #[test]
    fn runtime_cloud_voice_without_key_never_silently_falls_back_to_windows() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud-only",
                "chunkIndex": 0,
                "text": "สวัสดีค่ะ",
                "voice": "profile:female:adult",
                "providerId": "auto",
                "modelId": "gemini-3.1-flash-tts-preview",
                "final": true,
                "companionId": "default"
            }),
        )
        .expect("valid runtime tts request");

        let speech = runtime_tts_request_to_speech_with_synth(
            &request,
            &store,
            &None,
            Box::new(ReferenceSynthesizer::new()),
        )
        .expect("runtime TTS request should degrade to subtitle envelope");

        assert!(speech.data["audioRef"].is_null());
        assert_eq!(
            speech.data["routeReason"],
            json!("provider-credential-required")
        );
    }

    #[test]
    fn runtime_auto_cloud_voice_never_falls_back_to_windows_without_a_gemini_credential() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud-no-key",
                "chunkIndex": 0,
                "text": "สวัสดีค่ะ",
                "voice": "profile:female:adult",
                "providerId": "auto",
                "modelId": "gemini-3.1-flash-tts-preview",
                "final": true,
                "companionId": "default"
            }),
        )
        .expect("valid runtime tts request");

        let speech = runtime_tts_request_to_speech_with_synth(
            &request,
            &store,
            &None,
            Box::new(ReferenceSynthesizer::new()),
        )
        .expect("runtime TTS request should still produce a subtitle-only envelope");

        assert!(
            speech.data["audioRef"].is_null(),
            "auto/cloud voice must not silently invoke Windows fallback"
        );
        assert_eq!(
            speech.data["routeReason"],
            json!("provider-credential-required")
        );
        assert!(
            store.is_empty(),
            "no local synth audio should be written for automatic cloud voice"
        );
    }

    #[test]
    fn runtime_auto_cloud_voice_never_silently_falls_back_to_windows() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud-no-key",
                "chunkIndex": 0,
                "text": "สวัสดีค่ะ",
                "voice": "profile:female:adult",
                "providerId": "auto",
                "modelId": gemini_tts::STREAMING_MODEL,
                "final": true,
                "companionId": "default"
            }),
        )
        .expect("valid runtime tts request");

        let speech = runtime_tts_request_to_speech_with_synth(
            &request,
            &store,
            &None,
            Box::new(ReferenceSynthesizer::new()),
        )
        .expect("runtime TTS request should still produce a subtitle envelope");

        assert!(
            speech.data["audioRef"].is_null(),
            "auto cloud mode must not invoke the injected local/Windows synthesizer without explicit user selection"
        );
        assert_eq!(
            speech.data["routeReason"],
            json!("provider-credential-required")
        );
        assert!(
            store.is_empty(),
            "no local fallback audio may be synthesized"
        );
    }

    #[test]
    fn runtime_tts_defaults_to_quality_whole_clip_delivery() {
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "text": "quality first",
                "providerId": "auto",
                "modelId": gemini_tts::STREAMING_MODEL
            }),
        )
        .expect("valid runtime tts request");
        assert!(
            !runtime_tts_streaming_requested(&request),
            "streaming must be opt-in so normal Read aloud/Auto Speak use the stable whole-clip path"
        );
    }

    #[test]
    fn runtime_tts_streaming_remains_available_as_explicit_experimental_delivery() {
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "text": "low latency",
                "providerId": "auto",
                "modelId": gemini_tts::STREAMING_MODEL,
                "deliveryMode": "streaming"
            }),
        )
        .expect("valid runtime tts request");
        assert!(runtime_tts_streaming_requested(&request));
    }

    #[test]
    fn runtime_chat_tts_request_reuses_kernel_voice_pipeline_and_preserves_correlation() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-live",
                "chunkIndex": 2,
                "text": "hello from chat",
                "voice": "female",
                "providerId": "system",
                "modelId": "gemini-2.5-flash-preview-tts",
                "final": true,
                "companionId": "default"
            }),
        )
        .expect("valid runtime tts request");

        let speech = runtime_tts_request_to_speech_with_synth(
            &request,
            &store,
            &None,
            Box::new(ReferenceSynthesizer::new()),
        )
        .expect("runtime TTS request should produce speech envelope");

        assert_eq!(speech.event_type, "ocp.behavior.speech-requested");
        assert_eq!(speech.correlation_id, Some(request.id));
        assert_eq!(speech.data["text"], json!("hello from chat"));
        assert_eq!(speech.data["companionId"], json!("default"));
        assert_eq!(speech.data["messageId"], json!("msg-live"));
        assert_eq!(speech.data["chunkIndex"], json!(2));
        assert_eq!(speech.data["final"], json!(true));
        assert!(
            !speech.data["audioRef"].is_null(),
            "runtime chat TTS must use the same file-backed audio transport"
        );
    }

    #[test]
    fn runtime_auto_voice_without_cloud_credential_never_uses_local_fallback() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud-only",
                "chunkIndex": 0,
                "text": "cloud voice only",
                "voice": "profile:female:adult",
                "providerId": "auto",
                "modelId": "gemini-3.1-flash-tts-preview",
                "final": true,
                "companionId": "default"
            }),
        )
        .expect("valid runtime tts request");

        let speech = runtime_tts_request_to_speech_with_synth(
            &request,
            &store,
            &None,
            Box::new(ReferenceSynthesizer::new()),
        )
        .expect("runtime TTS request should still produce a subtitle envelope");

        assert!(
            speech.data["audioRef"].is_null(),
            "auto cloud voice must not use the injected local synthesizer"
        );
        assert_eq!(
            speech.data["routeReason"],
            json!("provider-credential-required")
        );
        assert!(
            store.is_empty(),
            "no local audio may be synthesized without explicit system selection"
        );
    }

    #[test]
    fn runtime_auto_cloud_voice_with_working_local_synth_still_requires_explicit_system() {
        let dir = tempfile::tempdir().expect("temp audio dir");
        let store = Arc::new(AudioStore::with_dir(dir.path()).expect("file-backed audio store"));
        let request = Envelope::new(
            "ocp.runtime.tts-requested",
            "runtime",
            json!({
                "schemaVersion": 1,
                "messageId": "msg-cloud-no-key",
                "chunkIndex": 0,
                "text": "สวัสดีค่ะ",
                "voice": "profile:female:adult",
                "providerId": "auto",
                "modelId": gemini_tts::STREAMING_MODEL,
                "final": true,
                "companionId": "default"
            }),
        )
        .expect("valid runtime tts request");

        // A working local synthesizer is deliberately injected. `auto` must
        // still remain cloud-only and surface the missing credential rather
        // than changing the character voice without user consent.
        let speech = runtime_tts_request_to_speech_with_synth(
            &request,
            &store,
            &None,
            Box::new(ReferenceSynthesizer::new()),
        )
        .expect("runtime TTS request should produce a subtitle-safe envelope");

        assert!(speech.data["audioRef"].is_null());
        assert_eq!(
            speech.data["routeReason"],
            json!("provider-credential-required")
        );
        assert!(
            store.is_empty(),
            "local TTS must not run for automatic cloud voice"
        );
    }

    /// When no `tts` provider is reachable the kernel must still emit
    /// `speech-requested` (subtitle-only, no `audioRef`) rather than going
    /// silent — the runtime shows the subtitle. Proven here by registering no
    /// chain at all.
    #[test]
    fn speech_without_a_tts_provider_degrades_to_subtitle_not_silence() {
        let store = Arc::new(AudioStore::new());
        let mut router = Router::new(
            InProcessBus::new(),
            Box::new(InMemoryConsentStore::new()),
            Box::new(InMemoryCredentialStore::new()),
        );

        let env = synthesize_speech_request(
            &mut router,
            &store,
            &SpeakRequest {
                companion_id: "default".to_owned(),
                correlation_id: uuid::Uuid::now_v7(),
                text: "no voice today".to_owned(),
                subtitle: true,
                interruptible: true,
                voice_id: None,
            },
        );

        assert_eq!(env.event_type, "ocp.behavior.speech-requested");
        assert_eq!(env.data["text"], json!("no voice today"));
        assert!(
            env.data["audioRef"].is_null(),
            "no tts route -> no audioRef -> runtime shows the subtitle, never silence"
        );
    }
}
