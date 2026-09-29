//! SEC-035 consent gate against a **real MEMORY_API user-profile excerpt**.
//!
//! `cs_aip.rs` already proves the generic strip-on-no-consent mechanism, but
//! with a hand-built `MemoryExcerpt` (`sensitive: true` set by the test). The
//! I5 exit review left one half of the consent bullet open precisely because
//! no test drove the gate with a *genuine* user-profile excerpt — MEMORY_API's
//! real data didn't exist until I6 landed. It does now, so this test closes
//! the gap end-to-end across the crate boundary:
//!
//! 1. write a record into the real Memory Layer (`ocp-memory`) under
//!    `MemoryScope::UserProfile`, deliberately passing `sensitive: false`;
//! 2. recall it back through the real MEMORY_API `recall` path;
//! 3. map the real `ocp_memory::Excerpt` to the router's `MemoryExcerpt`
//!    request field — exactly the translation the kernel does when it builds
//!    an AI request from recalled memory;
//! 4. route it and assert the excerpt is stripped before any unconsented
//!    cloud call, reaches a consented cloud provider intact, and is *not*
//!    stripped for a local provider (the gate is cloud-specific, SEC-035).
//!
//! The point that makes this more than a duplicate of `cs_aip.rs`: nothing
//! here sets `sensitive` by hand. The `sensitive` flag that drives the gate
//! originates inside the Memory Layer, which forces it `true` for every
//! `user-profile` record regardless of the write flag (MEMORY_API §1) — so
//! this proves the two contracts actually agree at the boundary.

use std::sync::Arc;

use ocp_event_bus::InProcessBus;
use ocp_llm_router::adapter::{ProviderAdapter, ProviderError, ScriptedAdapter, ScriptedOutcome};
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, LatencyClass, Limits, Locality,
    MemoryExcerpt, Message, ModelInfo, ProviderCapabilities, Role, RoutePolicy, RouterRequest,
    RouterResponse,
};
use ocp_llm_router::{InMemoryConsentStore, InMemoryCredentialStore, Router};
use uuid::Uuid;

use ocp_memory::{
    Caller as MemCaller, ContentType, InMemoryStore, MemoryScope, MemoryStore, RecallBudget,
    RecallRequest, WriteRequest,
};

/// The literal street address written into memory — used both as the recall
/// query target and as the string that must never surface at a cloud provider
/// without consent.
const HOME_ADDRESS: &str = "123 Fake St";

// --- local test harness (test helpers are not shared across test files) -----

fn caps(id: &str, locality: Locality) -> ProviderCapabilities {
    ProviderCapabilities {
        provider_id: id.to_owned(),
        locality,
        capabilities: vec![Capability::Chat],
        streaming: false,
        context_window: 8_000,
        latency_class: LatencyClass::Interactive,
        cost_class: CostClass::Metered,
        models: vec![ModelInfo {
            model_id: format!("{id}-model"),
            capabilities: vec![Capability::Chat],
            streaming: false,
        }],
    }
}

fn caller() -> CallerContext {
    CallerContext {
        context_id: "companion".to_owned(),
        granted_capabilities: vec![],
    }
}

/// A `ScriptedAdapter` behind an `Arc` so the same instance can be registered
/// into the router (which takes ownership via `Box`) and inspected afterwards
/// via `last_request()`. Identical to `cs_aip.rs`'s helper — test-local
/// helpers can't be imported across test binaries.
struct ArcAdapter(Arc<ScriptedAdapter>);
impl ProviderAdapter for ArcAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        self.0.capabilities()
    }
    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        self.0.invoke(request, credential)
    }
}

/// The contract-boundary mapping under test: a real MEMORY_API `Excerpt`
/// (§2.2 recall output) → the router's `MemoryExcerpt` request field. The only
/// per-field difference is `scope` (a typed `MemoryScope` on the memory side,
/// its wire string on the router side) — the `sensitive` flag passes straight
/// through, which is the whole point.
fn to_router_excerpt(e: &ocp_memory::Excerpt) -> MemoryExcerpt {
    MemoryExcerpt {
        record_id: e.record_id,
        scope: e.scope.as_wire_string(),
        excerpt: e.excerpt.clone(),
        sensitive: e.sensitive,
    }
}

/// Writes a user-profile record into a real `ocp-memory` store and recalls it,
/// returning the router-shaped excerpts. Deliberately writes `sensitive:
/// false` and then asserts the Memory Layer forced it `true` anyway — the
/// MEMORY_API §1 rule that makes the SEC-035 gate fire without any caller
/// having to opt in.
fn recall_real_user_profile_excerpts() -> Vec<MemoryExcerpt> {
    let mut store = InMemoryStore::new();
    let core = MemCaller::Core {
        component: "companion".to_owned(),
    };

    store
        .write(
            &core,
            WriteRequest {
                scope: MemoryScope::UserProfile,
                content: format!("the user's home address is {HOME_ADDRESS}"),
                content_type: ContentType::TextPlain,
                // Deliberately NOT flagged sensitive by the caller — the layer
                // must force it, purely from the user-profile scope.
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .expect("writing a user-profile record must succeed");

    let recalled = store
        .recall(
            &core,
            RecallRequest {
                query: "home address".to_owned(),
                scopes: vec![MemoryScope::UserProfile],
                budget: RecallBudget {
                    max_excerpts: 10,
                    max_chars: 4096,
                },
            },
        )
        .expect("recall must succeed");

    assert!(
        !recalled.excerpts.is_empty(),
        "the user-profile record must be recalled"
    );
    assert!(
        recalled.excerpts.iter().all(|e| e.sensitive),
        "MEMORY_API §1: every user-profile excerpt must be sensitive even though we wrote sensitive=false"
    );
    assert!(
        recalled
            .excerpts
            .iter()
            .all(|e| e.scope == MemoryScope::UserProfile),
        "recall must only return the requested user-profile scope"
    );

    recalled.excerpts.iter().map(to_router_excerpt).collect()
}

fn request_with(excerpts: Vec<MemoryExcerpt>) -> RouterRequest {
    RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
        capability: Capability::Chat,
        messages: vec![Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "what's my home address?".to_owned(),
            }],
        }],
        memory_excerpts: excerpts,
        tools: vec![],
        caller_context: caller(),
        policy: RoutePolicy {
            max_cost_class: CostClass::Metered,
            allow_cloud: true,
        },
        streaming: false,
        foreground: true,
        limits: Limits {
            max_output_tokens: 256,
        },
    }
}

#[test]
fn real_user_profile_excerpt_is_stripped_before_an_unconsented_cloud_call() {
    let bus = InProcessBus::new();
    let mut router = Router::new(
        bus,
        Box::new(InMemoryConsentStore::new()), // nobody has consent
        Box::new(InMemoryCredentialStore::new()),
    );
    let cloud = Arc::new(ScriptedAdapter::new(
        caps("cloud-a", Locality::Cloud),
        vec![ScriptedOutcome::Ok("ok")],
    ));
    router.register_provider(Box::new(ArcAdapter(cloud.clone())));
    router.register_chain(Capability::Chat, CostClass::Metered, &["cloud-a"]);

    let excerpts = recall_real_user_profile_excerpts();
    assert!(
        excerpts.iter().any(|e| e.excerpt.contains(HOME_ADDRESS)),
        "sanity: the real recalled excerpt carries the address before routing, or this test proves nothing"
    );

    let req = request_with(excerpts);
    router
        .route(&req)
        .expect("the cloud provider itself succeeds; the gate only strips content, never blocks");

    let seen = cloud.last_request().expect("cloud-a was called");
    assert!(
        seen.memory_excerpts.is_empty(),
        "SEC-035: a real user-profile MEMORY_API excerpt must be stripped before an unconsented cloud call"
    );
    // Belt-and-braces: the address must not survive in *any* field the cloud
    // provider received (the excerpt was its only carrier, but assert the
    // whole request to catch any future field that might leak it).
    let seen_json = serde_json::to_string(&seen).expect("request serializes");
    assert!(
        !seen_json.contains(HOME_ADDRESS),
        "the user's home address must not reach the cloud provider in any request field (SEC-035)"
    );
}

#[test]
fn real_user_profile_excerpt_reaches_a_consented_cloud_provider_intact() {
    let bus = InProcessBus::new();
    let mut consent = InMemoryConsentStore::new();
    consent.grant("cloud-a");
    let mut router = Router::new(
        bus,
        Box::new(consent),
        Box::new(InMemoryCredentialStore::new()),
    );
    let cloud = Arc::new(ScriptedAdapter::new(
        caps("cloud-a", Locality::Cloud),
        vec![ScriptedOutcome::Ok("ok")],
    ));
    router.register_provider(Box::new(ArcAdapter(cloud.clone())));
    router.register_chain(Capability::Chat, CostClass::Metered, &["cloud-a"]);

    let req = request_with(recall_real_user_profile_excerpts());
    router
        .route(&req)
        .expect("consented cloud provider succeeds");

    let seen = cloud.last_request().expect("cloud-a was called");
    assert_eq!(
        seen.memory_excerpts.len(),
        1,
        "consent granted: the real user-profile excerpt is not stripped"
    );
    assert!(
        seen.memory_excerpts[0].sensitive,
        "the excerpt keeps its layer-forced sensitive flag"
    );
    assert_eq!(seen.memory_excerpts[0].scope, "user-profile");
    assert!(
        seen.memory_excerpts[0].excerpt.contains(HOME_ADDRESS),
        "with consent, the consented provider receives the real recalled content"
    );
}

#[test]
fn real_user_profile_excerpt_still_reaches_a_local_provider_without_consent() {
    // SEC-035 gates *cloud* transmission specifically — a local provider is
    // the user's own machine, so a user-profile excerpt reaching it is not a
    // disclosure. Proving this guards against the gate being over-broad
    // (stripping everywhere) rather than precisely cloud-scoped.
    let bus = InProcessBus::new();
    let mut router = Router::new(
        bus,
        Box::new(InMemoryConsentStore::new()), // no consent anywhere
        Box::new(InMemoryCredentialStore::new()),
    );
    let local = Arc::new(ScriptedAdapter::new(
        caps("ollama-local", Locality::Local),
        vec![ScriptedOutcome::Ok("ok")],
    ));
    router.register_provider(Box::new(ArcAdapter(local.clone())));
    router.register_chain(Capability::Chat, CostClass::Metered, &["ollama-local"]);

    let req = request_with(recall_real_user_profile_excerpts());
    router.route(&req).expect("local provider succeeds");

    let seen = local.last_request().expect("the local provider was called");
    assert_eq!(
        seen.memory_excerpts.len(),
        1,
        "SEC-035 gates cloud only: a local provider still receives the user-profile excerpt, no consent needed"
    );
    assert!(seen.memory_excerpts[0].excerpt.contains(HOME_ADDRESS));
}
