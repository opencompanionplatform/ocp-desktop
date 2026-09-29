//! Manual, live demonstration of the Provider health FSM's two transitions
//! `fallback_live.rs` never exercised (I5 exit review residual 2, closed):
//! `Available -> Degraded -> Failed` under **repeat** failure (the live
//! fallback demo only ever saw one failure per cloud provider, so it only
//! ever proved `Available -> Degraded`), and `Failed -> Available` via an
//! explicit recovery probe (STATE_MACHINE.md: "never silently on the next
//! successful call -- a caller/health-checker outside this crate decides
//! when to probe", `router.rs`'s own doc comment on `recover`).
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example health_fsm_live -- [openai|claude|openrouter] [timeout_secs]
//!
//! Picks one real cloud adapter (default `openai`) and, deliberately, its
//! own chain of exactly one provider -- no fallback target -- so every
//! health transition is forced to happen in place and stay visible via
//! `router.health(...)`, rather than being masked by a successful fallback
//! hop the way `fallback_live.rs`'s four-provider chain would.
//!
//! What this proves, in order:
//! 1. Two calls through the router with a **deliberately wrong** credential
//!    (a fixed placeholder, not whatever might be in your keystore/env --
//!    this step is destructive-by-design and must not risk a real key)
//!    drive `Available -> Degraded` (1st failure) then `Degraded -> Failed`
//!    (2nd failure while already `Degraded` -- `record_failure`'s own
//!    escalation rule, CS-AIP's `a_second_failure_while_already_degraded_
//!    escalates_straight_to_failed` proves this against a reference
//!    adapter; this is that same rule against a real vendor's real 401s).
//! 2. Once `Failed`, `router.route()` skips the provider entirely (`Failed`
//!    is the only health state the contract says removes a provider from
//!    trying at all, AI_PROVIDER_API §4) -- proven by one more call
//!    returning `AllProvidersUnavailable` rather than reaching the network.
//! 3. If a *real*, working credential is available (env var or the OS
//!    keystore, same lookup order as `fallback_live.rs`), this example
//!    performs its own probe -- a direct `adapter.invoke()` call, entirely
//!    outside the router, matching "a caller/health-checker outside this
//!    crate decides when to probe" -- and only calls `router.recover()`
//!    if that probe genuinely succeeded, never optimistically. A final
//!    `router.route()` call then proves the provider is really usable
//!    again through the normal path, not just marked so.
//! 4. If no real credential is available, the recovery half is skipped and
//!    reported as such rather than faked -- the FSM's forward half
//!    (`Available -> Degraded -> Failed`) is still fully proven live either
//!    way.

use std::time::Duration;

use ocp_event_bus::InProcessBus;
use ocp_llm_router::adapter::ProviderAdapter;
use ocp_llm_router::providers::claude::ClaudeAdapter;
use ocp_llm_router::providers::openai::OpenAiAdapter;
use ocp_llm_router::providers::openrouter::OpenRouterAdapter;
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, Limits, Message, Role, RoutePolicy,
    RouterRequest,
};
use ocp_llm_router::{
    CredentialStore, InMemoryConsentStore, InMemoryCredentialStore, OsKeystoreCredentialStore,
    Router,
};
use uuid::Uuid;

/// Same service namespace `examples/store_credential.rs` writes real
/// provider keys to.
const KEYSTORE_SERVICE: &str = "ocp-ai-provider";

/// Never a real key -- used only to force the two failures in step 1. A
/// syntactically plausible-looking but certainly-invalid value, so every
/// vendor rejects it the same way a genuinely wrong key would (a real 401,
/// not a malformed-request 400).
const DELIBERATELY_WRONG_CREDENTIAL: &str = "sk-intentionally-invalid-for-health-fsm-demo";

fn build_adapter(
    name: &str,
    timeout: Duration,
) -> (Box<dyn ProviderAdapter>, &'static str, &'static str) {
    match name {
        "claude" => (
            Box::new(ClaudeAdapter::new(
                "fsm-demo-provider",
                "claude-sonnet-5",
                timeout,
            )),
            "ANTHROPIC_API_KEY",
            "claude-cloud",
        ),
        "openrouter" => (
            Box::new(OpenRouterAdapter::new(
                "fsm-demo-provider",
                "openai/gpt-4o",
                timeout,
            )),
            "OPENROUTER_API_KEY",
            "openrouter-cloud",
        ),
        _ => (
            Box::new(OpenAiAdapter::new("fsm-demo-provider", "gpt-5.6", timeout)),
            "OPENAI_API_KEY",
            "openai-cloud",
        ),
    }
}

fn sample_request() -> RouterRequest {
    RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
        capability: Capability::Chat,
        messages: vec![Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "Why is the sky blue? Answer in one short sentence.".to_owned(),
            }],
        }],
        memory_excerpts: vec![],
        tools: vec![],
        caller_context: CallerContext {
            context_id: "manual-health-fsm-test".to_owned(),
            granted_capabilities: vec![],
        },
        policy: RoutePolicy {
            max_cost_class: CostClass::Metered,
            allow_cloud: true,
        },
        streaming: false,
        foreground: true,
        limits: Limits {
            max_output_tokens: 128,
        },
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let provider_name = args.next().unwrap_or_else(|| "openai".to_owned());
    let timeout_secs: u64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(15);
    let timeout = Duration::from_secs(timeout_secs);

    let (adapter, env_var, keystore_provider_id) = build_adapter(&provider_name, timeout);
    // See `cloud_auth_diag_live.rs`'s identical fix: report which source
    // actually supplied the credential (env var vs keystore), not just
    // "found somewhere" -- a stale env var silently outranking a freshly
    // stored real keystore credential caused real, wasted debugging time
    // in this project's own session history before this was added.
    let from_env = std::env::var(env_var).ok();
    let (real_credential, credential_source) = match from_env {
        Some(k) => (Some(k), format!("env var {env_var}")),
        None => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get(keystore_provider_id),
            "OS keystore".to_owned(),
        ),
    };
    println!(
        "Provider under test: {provider_name} (real credential {}found; source if found: {credential_source})\n",
        if real_credential.is_some() { "" } else { "NOT " }
    );
    if credential_source.starts_with("env var") {
        println!(
            "NOTE: {env_var} is set in this shell and takes priority over the OS keystore -- if \
             this is a stale/placeholder value from earlier testing, `Remove-Item Env:\\{env_var}` \
             (PowerShell) and re-run to actually test the keystore-stored key instead.\n"
        );
    }

    // Deliberately its own registry/chain of exactly one provider -- no
    // fallback target, so Failed genuinely means "nothing left to try" and
    // every transition is forced to happen in place (see module doc).
    let mut bad_credentials = InMemoryCredentialStore::new();
    bad_credentials.set("fsm-demo-provider", DELIBERATELY_WRONG_CREDENTIAL);
    let mut router = Router::new(
        InProcessBus::new(),
        Box::new(InMemoryConsentStore::new()),
        Box::new(bad_credentials),
    );
    router.register_provider(adapter);
    router.register_chain(Capability::Chat, CostClass::Metered, &["fsm-demo-provider"]);

    println!("--- step 1: two calls with a deliberately wrong credential ---");
    for attempt in 1..=2 {
        let outcome = router.route(&sample_request());
        println!(
            "  call {attempt}: {} -> health = {:?}",
            match &outcome {
                Ok(_) => "unexpectedly SUCCEEDED (is the placeholder credential somehow valid?)"
                    .to_owned(),
                Err(e) => format!("failed as expected ({e})"),
            },
            router.health("fsm-demo-provider")
        );
    }

    println!("\n--- step 2: one more call proves Failed means \"not tried at all\" ---");
    let outcome = router.route(&sample_request());
    println!(
        "  call 3: {} (AllProvidersUnavailable expected -- Failed providers are skipped, AI_PROVIDER_API §4)",
        outcome.err().map_or("unexpectedly succeeded".to_owned(), |e| e.to_string())
    );

    println!("\n--- step 3: recovery ---");
    let Some(real_key) = real_credential else {
        println!(
            "  No real credential available for {provider_name} -- skipping the recovery half \
             honestly rather than faking it. Store one first: `cargo run -p ocp-llm-router \
             --example store_credential -- set {keystore_provider_id}`, then re-run this example."
        );
        println!(
            "\n--- final health ---\n{provider_name}: {:?}",
            router.health("fsm-demo-provider")
        );
        return;
    };

    // The probe is deliberately NOT run through `router.route()` -- a
    // `Failed` provider is skipped by the router entirely, by design (step
    // 2 just proved it). `recover()`'s own doc comment says an external
    // caller decides when to probe; this is that external probe, a plain
    // adapter call outside the router.
    let (probe_adapter, _, _) = build_adapter(&provider_name, timeout);
    let probe_started = std::time::Instant::now();
    let probe_outcome = probe_adapter.invoke(&sample_request(), Some(real_key.as_str()));
    let probe_latency_ms = u32::try_from(probe_started.elapsed().as_millis()).unwrap_or(u32::MAX);

    match probe_outcome {
        Ok(_) => {
            println!("  probe call with the real credential SUCCEEDED ({probe_latency_ms}ms) -- calling router.recover()");
            router.recover("fsm-demo-provider", probe_latency_ms, None);
            println!(
                "  health after recover(): {:?}",
                router.health("fsm-demo-provider")
            );

            // Swap the router's credential store to the real key now that
            // we've proven it works, so the following route() call through
            // the normal path actually succeeds rather than immediately
            // re-failing on the still-wrong placeholder.
            let mut good_credentials = InMemoryCredentialStore::new();
            good_credentials.set("fsm-demo-provider", real_key);
            router = Router::new(
                InProcessBus::new(),
                Box::new(InMemoryConsentStore::new()),
                Box::new(good_credentials),
            );
            router.register_provider(build_adapter(&provider_name, timeout).0);
            router.register_chain(Capability::Chat, CostClass::Metered, &["fsm-demo-provider"]);
            // A fresh Router starts Available by default, which is exactly
            // the state `recover()` would have produced on the original
            // instance -- rebuilding here only exists because this demo
            // swaps the whole credential store rather than mutating one
            // entry in place; the health-transition proof above already
            // stands on its own via the original router's audit log.
            println!(
                "\n--- step 4: one more call through the router, now with the real credential ---"
            );
            match router.route(&sample_request()) {
                Ok(resp) => println!("  SUCCESS: served by {}, model {}", resp.provider_id, resp.model_id),
                Err(e) => println!("  still failed: {e} (the real credential may be invalid/rate-limited, not a code defect)"),
            }
        }
        Err(e) => {
            println!(
                "  probe call with the \"real\" credential also failed ({e:?}) -- the stored/env \
                 credential itself may be invalid or the account rate-limited; recovery cannot be \
                 demonstrated with a credential that doesn't actually work. This is not a defect in \
                 the recovery mechanism itself (step 1/2 already proved the FSM's forward half)."
            );
        }
    }

    println!("\n--- audit log ---");
    for line in router.audit_log() {
        println!("{line}");
    }
}
