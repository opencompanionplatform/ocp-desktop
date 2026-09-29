//! Same diagnostic philosophy and lesson as `openai_auth_diag_live.rs`
//! (bypass `map_error`'s narrowing, disable `http_status_as_error` so a
//! real 4xx/5xx body can actually be read), generalized to whichever cloud
//! provider the Chief AI Architect wants to try next after OpenAI's stored
//! key turned out to be rejected (`invalid_api_key`, confirmed via that
//! diagnostic, most likely a billing/payment-method gap on that OpenAI
//! account rather than anything this project's code controls).
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example cloud_auth_diag_live -- claude
//!   cargo run -p ocp-llm-router --example cloud_auth_diag_live -- openrouter
//!   cargo run -p ocp-llm-router --example cloud_auth_diag_live -- openai
//!
//! Each provider's cheapest real authenticated GET, verified against that
//! vendor's own docs before writing this (same discipline as every adapter
//! -- not guessed by analogy):
//! - **openai**: `GET /v1/models` with `Authorization: Bearer <key>` -- free,
//!   no tokens spent.
//! - **claude**: `GET /v1/models` with `x-api-key: <key>` +
//!   `anthropic-version` -- confirmed via `tls_diagnostic.rs`'s earlier run
//!   that this endpoint requires auth (401 without any key at all), so a
//!   real key should get a real 200 model list.
//! - **openrouter**: `GET /v1/key` -- OpenRouter's own dedicated
//!   key-info endpoint (rate limit + spend info for the calling key), free,
//!   confirmed via OpenRouter's docs rather than assumed -- notably NOT
//!   `/v1/models`, which is public/unauthenticated on OpenRouter (confirmed
//!   live via `tls_diagnostic.rs` returning a real model catalog with no
//!   auth header at all), so it can't be used to test whether a key
//!   authenticates.

use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};
use std::time::Duration;

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";

fn agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(20)))
        // See `openai_auth_diag_live.rs`'s module doc "real finding" note:
        // without this, ureq turns every 4xx/5xx into
        // `Err(Error::StatusCode(code))` carrying no body at all.
        .http_status_as_error(false)
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .provider(ureq::tls::TlsProvider::NativeTls)
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .build();
    config.new_agent()
}

fn print_outcome(result: Result<ureq::http::Response<ureq::Body>, ureq::Error>) {
    match result {
        Ok(mut response) => {
            let status = response.status().as_u16();
            let body = response.body_mut().read_to_string().unwrap_or_default();
            let preview: String = body.chars().take(600).collect();
            println!("HTTP {status}\nbody: {preview}");
            // Real finding (2026-07-21): Anthropic reports a billing/credit
            // problem as a **400 `invalid_request_error`**, not a dedicated
            // status like OpenAI's 429 `insufficient_quota` -- a naive
            // "400 = malformed request, this adapter has a bug" reading
            // would have been wrong here. Scanning the body text for the
            // vendor's own wording is more reliable than assuming any one
            // status code always means the same thing across vendors.
            let lower = body.to_lowercase();
            let is_billing = lower.contains("credit balance")
                || lower.contains("billing")
                || lower.contains("quota")
                || lower.contains("insufficient_quota");
            match (status, is_billing) {
                (200, _) => println!(
                    "\nSUCCESS -- this key authenticates. Any router-level failure for this \
                     provider is not an auth problem."
                ),
                (_, true) => println!(
                    "\nBILLING/CREDIT issue on the account (HTTP {status}), not a bad key and not \
                     a request-shape bug -- the vendor's own wording above names it directly. This \
                     is an account-side gap this project's code cannot fix."
                ),
                (401, false) => println!(
                    "\nKey did not authenticate -- read the body above for the exact reason."
                ),
                (other, false) => {
                    println!("\nHTTP {other} -- read the body above for the exact reason.")
                }
            }
        }
        Err(e) => println!("transport-level failure (no HTTP response at all): {e:?}"),
    }
}

fn main() {
    let provider = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "openai".to_owned());
    let keystore = OsKeystoreCredentialStore::new(KEYSTORE_SERVICE);

    let (provider_id, env_var) = match provider.as_str() {
        "claude" => ("claude-cloud", "ANTHROPIC_API_KEY"),
        "openrouter" => ("openrouter-cloud", "OPENROUTER_API_KEY"),
        _ => ("openai-cloud", "OPENAI_API_KEY"),
    };
    // Real confusion this exact ambiguity caused (2026-07-21): three
    // independently-generated, freshly-verified keys (OpenAI/OpenRouter/
    // Claude) all failed auth, which looked like a systemic bug -- until
    // suspecting a stale env var left over from much earlier in this same
    // session (the original `fallback_live` placeholder-value run, before
    // the OS keystore even existed) silently taking priority over the real,
    // freshly-stored keystore value every time. Reporting the source
    // explicitly, not just "found", closes that ambiguity for good.
    let from_env = std::env::var(env_var).ok();
    let (key, source) = match from_env {
        Some(k) => (Some(k), format!("env var {env_var}")),
        None => (keystore.get(provider_id), "OS keystore".to_owned()),
    };
    let Some(key) = key else {
        eprintln!(
            "No {provider_id} credential found (checked {env_var} and the OS keystore). Run \
             `cargo run -p ocp-llm-router --example store_credential -- set {provider_id}` first."
        );
        std::process::exit(1);
    };

    let agent = agent();
    println!("--- checking {provider_id} (credential source: {source}) ---");
    if source.starts_with("env var") {
        println!(
            "NOTE: {env_var} is set in this shell and takes priority over the OS keystore -- if \
             this is a stale/placeholder value from earlier testing, `Remove-Item Env:\\{env_var}` \
             (PowerShell) and re-run to actually test the keystore-stored key instead.\n"
        );
    }
    let result = match provider.as_str() {
        "claude" => agent
            .get("https://api.anthropic.com/v1/models")
            .header("x-api-key", key.as_str())
            .header("anthropic-version", "2023-06-01")
            .call(),
        "openrouter" => agent
            .get("https://openrouter.ai/api/v1/key")
            .header("Authorization", format!("Bearer {key}").as_str())
            .call(),
        _ => agent
            .get("https://api.openai.com/v1/models")
            .header("Authorization", format!("Bearer {key}").as_str())
            .call(),
    };
    let auth_ok = matches!(&result, Ok(r) if r.status().as_u16() == 200);
    print_outcome(result);

    // Only Claude gets a check 2 here: OpenRouter's real completion shape
    // was already proven live via `health_fsm_live -- openrouter` /
    // `fallback_live` (a real reply came back), and OpenAI's was already
    // isolated via `openai_auth_diag_live`'s own check 2 (429
    // insufficient_quota, not 400 -- the shape is fine, only quota blocks
    // it). Claude's actual `/v1/messages` shape has never been exercised
    // live -- `fallback_live` reported it `ElevatedErrorRate` right after
    // OpenRouter succeeded, and that variant collapses too many real HTTP
    // statuses together to guess why, same reasoning as OpenAI's check 2.
    if provider == "claude" && auth_ok {
        println!("\n--- check 2: POST /v1/messages with ClaudeAdapter's real request shape ---");
        let body = serde_json::json!({
            "model": "claude-sonnet-5",
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "Say OK and nothing else."}],
            "stream": false
        });
        let result = agent
            .post("https://api.anthropic.com/v1/messages")
            .header("x-api-key", key.as_str())
            .header("anthropic-version", "2023-06-01")
            .send_json(&body);
        print_outcome(result);
    }
}
