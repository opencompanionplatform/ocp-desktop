//! Manual, live demonstration that `Router::route` really walks a fallback
//! chain across four *real* wire adapters (OpenAI, Claude, OpenRouter,
//! Ollama) -- not just the in-process `ScriptedAdapter`/`LocalEchoAdapter`
//! reference doubles CS-AIP already certifies the chain-walking logic
//! against (`tests/cs_aip.rs`). This is that same logic's live-network
//! residual: same class of gap `ollama_live.rs` closed for one adapter in
//! isolation, this closes for the whole `Router::route` path across all
//! four at once.
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example fallback_live -- [question] [timeout_secs]
//!
//! Credentials come from two sources, checked in this order (I5 slice 6
//! residual, closed): an environment variable, for quick throwaway testing
//! you don't want to persist --
//!   OPENAI_API_KEY, ANTHROPIC_API_KEY, OPENROUTER_API_KEY
//! -- and otherwise the real OS keystore, under the same `ocp-ai-provider`
//! service namespace `examples/store_credential.rs` writes to (run `cargo
//! run -p ocp-llm-router --example store_credential -- set openai-cloud`
//! once, then this example picks it up on every future run with no env var
//! needed). Ollama needs neither (local, matches SEC-031/034). **This demo
//! works and still proves real fallback with zero keys set anywhere**:
//! every adapter's own `invoke` rejects a missing credential with
//! `ProviderError::Unreachable` before any network call (the same real code
//! path `missing_credential_is_rejected_before_any_network_call` exercises
//! in isolation for each adapter) -- so an unconfigured cloud hop fails for
//! a genuine reason, not a fake one, and the chain still walks all the way
//! down to the real local Ollama call. Store or export any subset of the
//! three provider credentials to see those hops actually reach the network
//! instead, and with a *real, working* key, this is now the way to observe
//! a fully authenticated cloud completion end-to-end (I5 exit review
//! residual 1).
//!
//! Chain order (openai -> claude -> openrouter -> ollama) is this demo's own
//! illustrative policy choice -- AI_PROVIDER_API doesn't mandate an
//! ordering, only that each route has one. Ollama is deliberately last: the
//! free, always-reachable-if-running local fallback every other hop can
//! fail down to.

use std::time::Duration;

use ocp_event_bus::InProcessBus;
use ocp_llm_router::providers::claude::ClaudeAdapter;
use ocp_llm_router::providers::ollama::OllamaAdapter;
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

const CHAIN: [&str; 4] = [
    "openai-cloud",
    "claude-cloud",
    "openrouter-cloud",
    "ollama-local",
];

/// Same service namespace `examples/store_credential.rs` writes real
/// provider keys to -- deliberately the same constant so the two examples
/// stay wired to the same real-world credentials.
const KEYSTORE_SERVICE: &str = "ocp-ai-provider";

/// Env var wins when set (quick, throwaway testing without touching the
/// real keystore); otherwise falls back to whatever's actually stored in
/// the OS keystore for this `provider_id`. Returns the source alongside the
/// value -- **a real, confirmed source of confusion in this project's own
/// session history**: this demo once reported all three cloud providers as
/// "configured" when only one had actually been stored via
/// `store_credential` -- the other two were silently coming from stale env
/// vars left over from much earlier testing (before the OS keystore even
/// existed), not from the keystore at all. Reporting the source explicitly
/// instead of just "found" closes that ambiguity for good.
fn load_credential(
    keystore: &OsKeystoreCredentialStore,
    env_var: &str,
    provider_id: &str,
) -> Option<(String, String)> {
    std::env::var(env_var)
        .ok()
        .map(|k| (k, format!("env var {env_var}")))
        .or_else(|| {
            keystore
                .get(provider_id)
                .map(|k| (k, "OS keystore".to_owned()))
        })
}

fn main() {
    let mut args = std::env::args().skip(1);
    let question = args
        .next()
        .unwrap_or_else(|| "Why is the sky blue? Answer in one short sentence.".to_owned());
    let timeout_secs: u64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(30);
    let timeout = Duration::from_secs(timeout_secs);

    let keystore = OsKeystoreCredentialStore::new(KEYSTORE_SERVICE);
    let mut credentials = InMemoryCredentialStore::new();
    let mut configured = Vec::new();
    let mut stale_env_vars = Vec::new();
    for (provider_id, env_var) in [
        ("openai-cloud", "OPENAI_API_KEY"),
        ("claude-cloud", "ANTHROPIC_API_KEY"),
        ("openrouter-cloud", "OPENROUTER_API_KEY"),
    ] {
        if let Some((key, source)) = load_credential(&keystore, env_var, provider_id) {
            configured.push(format!("{provider_id} (from {source})"));
            if source.starts_with("env var") {
                stale_env_vars.push(env_var);
            }
            credentials.set(provider_id, key);
        }
    }
    if !stale_env_vars.is_empty() {
        println!(
            "NOTE: {} {} set in this shell and take priority over the OS keystore for those \
             providers -- if any is a stale/placeholder value from earlier testing, \
             `Remove-Item Env:\\<NAME>` (PowerShell) and re-run to actually test the \
             keystore-stored key(s) instead.",
            stale_env_vars.join(", "),
            if stale_env_vars.len() == 1 {
                "is"
            } else {
                "are"
            }
        );
    }
    if configured.is_empty() {
        println!(
            "No cloud API keys found -- checked env vars (OPENAI_API_KEY / ANTHROPIC_API_KEY / \
             OPENROUTER_API_KEY) and the OS keystore (`ocp-ai-provider` namespace, same one \
             `examples/store_credential.rs` writes to). Every cloud hop will fail for a real \
             reason (missing credential, rejected before any network call) and the chain will \
             fall all the way through to the local Ollama call. Run `cargo run -p ocp-llm-router \
             --example store_credential -- set openai-cloud` (or claude-cloud/openrouter-cloud) \
             to store a real key once, or set an env var for a one-off run."
        );
    } else {
        println!("Credentials configured for: {}", configured.join(", "));
    }

    let mut router = Router::new(
        InProcessBus::new(),
        Box::new(InMemoryConsentStore::new()),
        Box::new(credentials),
    );

    router.register_provider(Box::new(OpenAiAdapter::new(
        "openai-cloud",
        "gpt-5.6",
        timeout,
    )));
    router.register_provider(Box::new(ClaudeAdapter::new(
        "claude-cloud",
        "claude-sonnet-5",
        timeout,
    )));
    router.register_provider(Box::new(OpenRouterAdapter::new(
        "openrouter-cloud",
        "openai/gpt-4o",
        timeout,
    )));
    router.register_provider(Box::new(OllamaAdapter::new(
        "ollama-local",
        "http://localhost:11434",
        "qwen2.5-coder:1.5b",
        timeout,
    )));

    router.register_chain(Capability::Chat, CostClass::Metered, &CHAIN);

    let request = RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
        capability: Capability::Chat,
        messages: vec![Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: question.clone(),
            }],
        }],
        memory_excerpts: vec![],
        tools: vec![],
        caller_context: CallerContext {
            context_id: "manual-live-fallback-test".to_owned(),
            granted_capabilities: vec![],
        },
        policy: RoutePolicy {
            max_cost_class: CostClass::Metered,
            allow_cloud: true,
        },
        streaming: false,
        foreground: true,
        limits: Limits {
            max_output_tokens: 256,
        },
    };

    println!("Question: {question}");
    println!("Chain: {}\n", CHAIN.join(" -> "));

    match router.route(&request) {
        Ok(response) => {
            println!(
                "--- SUCCESS: served by {} (fallback_depth={}) ---",
                response.provider_id, response.fallback_depth
            );
            println!("model:       {}", response.model_id);
            println!("stop_reason: {:?}", response.stop_reason);
            for part in &response.content {
                if let ContentPart::Text { value } = part {
                    println!("\nreply:\n{value}");
                }
            }
        }
        Err(e) => {
            eprintln!("--- ALL PROVIDERS FAILED: {e:?} ---");
            eprintln!(
                "(this only happens if Ollama itself is also unreachable -- check `ollama serve`)"
            );
        }
    }

    println!("\n--- health after this call ---");
    for id in CHAIN {
        println!("{id}: {:?}", router.health(id));
    }

    println!("\n--- router audit log (every routing/health decision made) ---");
    for line in router.audit_log() {
        println!("{line}");
    }
}
