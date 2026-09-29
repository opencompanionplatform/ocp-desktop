//! Diagnostic-only (same philosophy as `tls_diagnostic.rs`, applied one
//! layer further in): `health_fsm_live`'s recovery probe just failed with
//! `ElevatedErrorRate` using the credential actually stored for
//! `openai-cloud` in the OS keystore. `ElevatedErrorRate` is deliberately
//! coarse -- `OpenAiAdapter::map_error` collapses **every** non-2xx HTTP
//! status into it (`ureq::Error::StatusCode(_)`), so a 401 (bad/expired
//! key), a 429 (quota/rate limit), and a 400 (malformed request -- i.e. a
//! bug in this adapter's own request-building, never yet confirmed against
//! a real 200) are all indistinguishable from inside the router. Guessing
//! which one it is would repeat the exact mistake the TLS bug's diagnosis
//! avoided -- this bypasses `map_error` and prints the real HTTP status and
//! OpenAI's own JSON error body (which names the failure directly, e.g.
//! `invalid_api_key` / `insufficient_quota` / a schema-validation message).
//!
//! Usage: `cargo run -p ocp-llm-router --example openai_auth_diag_live`
//!
//! **Real finding from this diagnostic's first run**: the first version of
//! this file used a plain `agent.get(url).call()`, and the 401 came back as
//! `Err(ureq::Error::StatusCode(401))` -- easy to misread as "no response
//! at all." It wasn't: ureq's `Error::StatusCode(u16)` doc is explicit that
//! this is produced *by default* whenever `http_status_as_error()` is true
//! (the default), for any 4xx/5xx, and it carries **only the numeric
//! code** -- no body, by design, so the printed `{e:?}` never had a chance
//! of showing OpenAI's actual JSON error message. Fixed by explicitly
//! setting `.http_status_as_error(false)` on this diagnostic's own agent
//! config, which makes ureq return `Ok(response)` even for 4xx/5xx and lets
//! the real body (OpenAI's error JSON, which names the failure directly)
//! be read out normally.
//!
//! Two checks, deliberately ordered to isolate auth from request-shape:
//! 1. `GET /v1/models` with the real key -- costs nothing, no tokens spent,
//!    and only tests whether the key itself authenticates at all. A 401
//!    here means the key is invalid/expired/revoked; a 200 means the key is
//!    good and the fault (if any) is downstream in the request this
//!    adapter actually builds.
//! 2. Only if check 1 returns 200: `POST /v1/responses` with the exact same
//!    request shape `providers::openai::build_request` produces (copied
//!    inline here rather than importing the private DTOs, since this is a
//!    diagnostic, not a consumer of the crate's public API) -- isolates
//!    whether this adapter's Responses-API request shape itself is valid
//!    against a real key, something no unit test can confirm since they all
//!    mock the adapter.

use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};
use std::time::Duration;

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";

fn agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(20)))
        // See the module doc's "real finding" note: without this, ureq
        // turns every 4xx/5xx into `Err(Error::StatusCode(code))` carrying
        // no body at all -- exactly what this diagnostic exists to read.
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

fn print_outcome(
    label: &str,
    result: Result<ureq::http::Response<ureq::Body>, ureq::Error>,
) -> Option<u16> {
    println!("--- {label} ---");
    match result {
        Ok(mut response) => {
            let status = response.status().as_u16();
            let body = response.body_mut().read_to_string().unwrap_or_default();
            let preview: String = body.chars().take(600).collect();
            println!("HTTP {status}\nbody: {preview}\n");
            Some(status)
        }
        Err(e) => {
            // With `http_status_as_error(false)` set above, reaching this
            // branch means a genuine transport-level failure (no HTTP
            // response at all), not a 4xx/5xx -- those now come through
            // `Ok(response)` instead.
            println!("transport-level failure (no HTTP response at all): {e:?}\n");
            None
        }
    }
}

fn main() {
    // See `cloud_auth_diag_live.rs`'s identical fix for why the source is
    // reported explicitly: an env var silently outranking a freshly-stored
    // keystore credential (e.g. a stale placeholder left over from earlier
    // testing) is exactly the kind of thing that looks like a systemic bug
    // but isn't -- happened for real in this project's own session history.
    let from_env = std::env::var("OPENAI_API_KEY").ok();
    let (key, source) = match from_env {
        Some(k) => (Some(k), "env var OPENAI_API_KEY".to_owned()),
        None => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get("openai-cloud"),
            "OS keystore".to_owned(),
        ),
    };
    let Some(key) = key else {
        eprintln!(
            "No openai-cloud credential found (checked OPENAI_API_KEY and the OS keystore). \
             Run `cargo run -p ocp-llm-router --example store_credential -- set openai-cloud` first."
        );
        std::process::exit(1);
    };
    println!("credential source: {source}");
    if source.starts_with("env var") {
        println!(
            "NOTE: OPENAI_API_KEY is set in this shell and takes priority over the OS keystore \
             -- if this is a stale/placeholder value from earlier testing, `Remove-Item \
             Env:\\OPENAI_API_KEY` (PowerShell) and re-run to actually test the keystore-stored \
             key instead."
        );
    }

    let agent = agent();

    let models_result = agent
        .get("https://api.openai.com/v1/models")
        .header("Authorization", format!("Bearer {key}").as_str())
        .call();
    let models_status = print_outcome(
        "check 1: GET /v1/models (does the key authenticate at all?)",
        models_result,
    );

    match models_status {
        Some(200) => println!("Key authenticates fine -- proceeding to check 2 (request shape).\n"),
        Some(status) => {
            println!(
                "Key did NOT authenticate (HTTP {status}) -- this is the actual cause of \
                 health_fsm_live's ElevatedErrorRate, not an adapter bug. Common causes: the key \
                 was mistyped/truncated when stored, it's been revoked, or the account has no \
                 quota/billing set up (OpenAI returns 401 for a bad key and 429 for quota issues \
                 -- the body above says which). Skipping check 2 since a bad key would fail it too \
                 for an unrelated reason."
            );
            return;
        }
        None => {
            println!("Transport itself failed -- see the error above; not an auth or request-shape issue.");
            return;
        }
    }

    // Mirrors `providers::openai::build_request`'s exact shape for a
    // minimal one-message request -- inlined rather than imported since
    // those DTOs are private to the adapter module.
    let body = serde_json::json!({
        "model": "gpt-5.6",
        "input": [{"role": "user", "content": "Say OK and nothing else."}],
        "max_output_tokens": 16,
        "stream": false
    });
    let responses_result = agent
        .post("https://api.openai.com/v1/responses")
        .header("Authorization", format!("Bearer {key}").as_str())
        .send_json(&body);
    let responses_status = print_outcome(
        "check 2: POST /v1/responses with this adapter's real request shape",
        responses_result,
    );

    match responses_status {
        Some(200) => println!(
            "SUCCESS -- the Responses API request shape this adapter builds is valid against a \
             real account. health_fsm_live's earlier failure was most likely transient (rate \
             limit / momentary network blip) rather than a code defect. Worth re-running \
             health_fsm_live once more."
        ),
        Some(400) => println!(
            "HTTP 400 with a valid key -- this IS a real bug in this adapter's request shape \
             (`providers::openai::build_request`), never before confirmed against a live 200. \
             Read the body above for the exact field OpenAI is rejecting."
        ),
        Some(status) => println!("HTTP {status} -- read the body above for the exact reason."),
        None => println!("Transport itself failed on the POST -- see the error above."),
    }
}
