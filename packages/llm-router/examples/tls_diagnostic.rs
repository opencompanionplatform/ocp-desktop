//! Diagnostic-only, not a provider adapter test. `fallback_live` just showed
//! all three cloud adapters (OpenAI, Claude, OpenRouter -- three unrelated
//! vendors) failing with `ProviderError::Unreachable` even with a
//! (placeholder) credential set. That specific variant only comes from
//! `ureq::Error::HostNotFound | ConnectionFailed | Io` in every adapter's
//! `map_error` -- notably **not** from `StatusCode`, which is what an
//! invalid-but-reachable key would produce (a real 401 JSON body). The
//! identical failure across three independently-hosted vendors is itself
//! evidence: it points at something in this machine's network/TLS path
//! (this workspace's `native-tls`/SChannel switch, or a proxy/firewall),
//! not three coincidental per-vendor outages.
//!
//! This bypasses every adapter and its narrowing `map_error` entirely,
//! making the exact same kind of `ureq` call our adapters do (same
//! `native-tls` `TlsConfig`), and prints the **full, unnarrowed** error
//! Debug output so the real underlying reason is visible instead of
//! collapsed into one of three `ProviderError` variants.
//!
//! Usage: `cargo run -p ocp-llm-router --example tls_diagnostic`
//!
//! Runs two checks:
//! 1. A well-known, always-up HTTPS host unrelated to any AI vendor
//!    (`https://www.google.com`) -- if this also fails, the problem is this
//!    machine's general HTTPS/TLS path, not anything OpenAI/Claude/
//!    OpenRouter-specific.
//! 2. `https://api.openai.com/v1/models` with no auth header at all -- a
//!    real reachable server should still respond (with a 401 JSON body,
//!    which is a **success** at the transport level, just an auth failure
//!    at the application level) rather than fail to connect.

use std::time::Duration;

fn agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .provider(ureq::tls::TlsProvider::NativeTls)
                // ROOT CAUSE, found by this exact diagnostic's first real
                // run: ureq's `RootCerts` default (`WebPki`) needs a cargo
                // feature this crate doesn't enable, so under `NativeTls` it
                // silently resolves to zero root certs -- explaining the
                // uniform "unable to find any user-specified roots" failure
                // across all four hosts. Fixed here and in every adapter by
                // making `PlatformVerifier` explicit (native-tls's own
                // default: the Windows Certificate Store via SChannel).
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .build();
    config.new_agent()
}

fn check(label: &str, url: &str) {
    println!("--- {label}: GET {url} ---");
    let agent = agent();
    match agent.get(url).call() {
        Ok(mut response) => {
            println!("OK: transport succeeded, HTTP status {}", response.status());
            let body = response.body_mut().read_to_string().unwrap_or_default();
            let preview: String = body.chars().take(200).collect();
            println!("body (first 200 chars): {preview}");
        }
        Err(e) => {
            println!("FAILED (full, unnarrowed error): {e:?}");
        }
    }
    println!();
}

fn main() {
    check(
        "general internet HTTPS (unrelated to any AI vendor)",
        "https://www.google.com",
    );
    check(
        "OpenAI (no auth header -- expect a real 401, not a connection failure)",
        "https://api.openai.com/v1/models",
    );
    check(
        "Anthropic (no auth header -- expect a real 401/400, not a connection failure)",
        "https://api.anthropic.com/v1/models",
    );
    check(
        "OpenRouter (no auth header -- expect a real 401, not a connection failure)",
        "https://openrouter.ai/api/v1/models",
    );

    println!(
        "Read: if check 1 (google.com) also fails, this is a general network/TLS-stack problem \
         on this machine (proxy, firewall, or the native-tls/schannel backend itself), not \
         anything specific to an AI vendor. If check 1 succeeds but 2-4 fail, it's something \
         about how these particular hosts are reached (DNS/firewall rules targeting them \
         specifically, less likely given all three failed identically in fallback_live). If all \
         four succeed here, the earlier fallback_live failure may have been transient -- worth \
         re-running fallback_live once more."
    );
}
