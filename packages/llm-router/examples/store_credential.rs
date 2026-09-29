//! Setup-time CLI for `credentials::OsKeystoreCredentialStore` (I5 slice 6,
//! SEC-030). This is how a human actually gets a real provider API key into
//! the OS keystore -- the router itself only ever *reads* (`Router::route`
//! calls `CredentialStore::get` immediately before each adapter call and
//! never writes), so writing has to live somewhere else. This example is
//! that "somewhere else" until there's a real onboarding/settings UI.
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example store_credential -- set openai-cloud
//!   cargo run -p ocp-llm-router --example store_credential -- get openai-cloud
//!   cargo run -p ocp-llm-router --example store_credential -- peek openai-cloud
//!   cargo run -p ocp-llm-router --example store_credential -- delete openai-cloud
//!   cargo run -p ocp-llm-router --example store_credential -- list openai-cloud claude-cloud openrouter-cloud
//!
//! `set` prompts for the secret with `rpassword` (input hidden at the
//! terminal, never echoed, never passed as a CLI argument -- an argument
//! would land in shell history and the OS process list, exactly what
//! SEC-030 rules out) and trims leading/trailing whitespace before storing
//! (a real, observed gotcha: some terminals include a trailing newline or
//! space on paste, silently turning a correct key into an `invalid_api_key`
//! rejection indistinguishable, from the router's side, from a genuinely
//! wrong key). `get` deliberately never prints the credential itself, only
//! whether one is stored, matching "they never appear in events, logs, or
//! error messages" -- this CLI is a setup tool, not a debugging one. `peek`
//! is the one deliberate, narrow exception: it prints a **masked** preview
//! (first 8 characters + total length only) so a human can visually compare
//! what's actually stored against what they meant to paste, without ever
//! showing the full secret -- for exactly the situation that motivated it:
//! a stored key failing auth and needing to rule out "wrong value stored"
//! vs. "the key itself is bad," without pasting the real key anywhere
//! (least of all into a chat transcript). `list` is `get` repeated over
//! several provider ids, for checking overall setup state at a glance.
//!
//! `provider_id` here should match whatever id the real `Router` is
//! configured with for that provider (e.g. `"openai-cloud"` in
//! `examples/fallback_live.rs`'s `CHAIN`) -- this store is keyed by
//! `(service, provider_id)`, and `Router::route` looks credentials up by
//! the same provider id it routes to.

use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};

/// Fixed service namespace for every real OCP provider credential this CLI
/// writes -- keeps these entries isolated from `ocp-llm-router-tests`'
/// throwaway ones (see `credentials.rs`'s own test module) and from any
/// other application's entries in the same OS keystore.
const SERVICE: &str = "ocp-ai-provider";

fn main() {
    let mut args = std::env::args().skip(1);
    let command = args.next();
    let store = OsKeystoreCredentialStore::new(SERVICE);

    match command.as_deref() {
        Some("set") => {
            let Some(provider_id) = args.next() else {
                eprintln!("usage: store_credential set <provider_id>");
                std::process::exit(2);
            };
            let raw = rpassword::prompt_password(format!("API key for '{provider_id}': "))
                .expect("failed to read from the terminal");
            let secret = raw.trim();
            if secret.is_empty() {
                eprintln!("empty input, nothing stored");
                std::process::exit(1);
            }
            if secret.len() != raw.len() {
                eprintln!(
                    "note: trimmed {} leading/trailing whitespace character(s) from the pasted \
                     input before storing (a common paste artifact, not part of a real key)",
                    raw.len() - secret.len()
                );
            }
            match store.set(&provider_id, secret) {
                Ok(()) => println!("stored a credential for '{provider_id}' in the OS keystore"),
                Err(e) => {
                    eprintln!("failed to store credential for '{provider_id}': {e}");
                    std::process::exit(1);
                }
            }
        }
        Some("get") => {
            let Some(provider_id) = args.next() else {
                eprintln!("usage: store_credential get <provider_id>");
                std::process::exit(2);
            };
            print_presence(&store, &provider_id);
        }
        Some("peek") => {
            let Some(provider_id) = args.next() else {
                eprintln!("usage: store_credential peek <provider_id>");
                std::process::exit(2);
            };
            match store.get(&provider_id) {
                Some(value) => {
                    let prefix: String = value.chars().take(8).collect();
                    println!(
                        "{provider_id}: {prefix}... (length: {} chars) -- compare this against \
                         what you meant to paste; if it looks truncated, has the wrong prefix, or \
                         the length looks off, re-run `set` with a freshly copied value",
                        value.chars().count()
                    );
                }
                None => println!("{provider_id}: no credential stored"),
            }
        }
        Some("delete") => {
            let Some(provider_id) = args.next() else {
                eprintln!("usage: store_credential delete <provider_id>");
                std::process::exit(2);
            };
            match store.delete(&provider_id) {
                Ok(()) => println!("removed any stored credential for '{provider_id}'"),
                Err(e) => {
                    eprintln!("failed to delete credential for '{provider_id}': {e}");
                    std::process::exit(1);
                }
            }
        }
        Some("list") => {
            let provider_ids: Vec<String> = args.collect();
            if provider_ids.is_empty() {
                eprintln!("usage: store_credential list <provider_id> [provider_id ...]");
                std::process::exit(2);
            }
            for provider_id in provider_ids {
                print_presence(&store, &provider_id);
            }
        }
        _ => {
            eprintln!(
                "usage:\n  \
                 store_credential set <provider_id>\n  \
                 store_credential get <provider_id>\n  \
                 store_credential peek <provider_id>\n  \
                 store_credential delete <provider_id>\n  \
                 store_credential list <provider_id> [provider_id ...]\n\n\
                 provider_id should match the id the real Router chain uses, e.g.:\n  \
                 openai-cloud, claude-cloud, openrouter-cloud"
            );
            std::process::exit(2);
        }
    }
}

/// Reports only presence, deliberately never the credential value itself
/// (see module doc).
fn print_presence(store: &OsKeystoreCredentialStore, provider_id: &str) {
    match store.get(provider_id) {
        Some(_) => println!("{provider_id}: credential present"),
        None => println!("{provider_id}: no credential stored"),
    }
}
