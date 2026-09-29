//! Provider credential lookup (SEC-030): "provider API keys live in the OS
//! keystore (DPAPI / Keychain / Secret Service) only — never in config
//! files, the store, or the repository. The router reads them at call time;
//! they never appear in events, logs, or error messages."
//!
//! `OsKeystoreCredentialStore` (below) is the real implementation, backed by
//! the `keyring` crate's `v1` API — it selects Windows Credential Manager /
//! macOS Keychain Services / Linux Secret Service automatically per
//! platform, with no unsafe code in this crate (`keyring`'s own per-platform
//! backends carry that, not us; `#![forbid(unsafe_code)]`/SEC-042 stays
//! intact). This is a thin trait impl over an already-safe cross-platform
//! dependency, unlike `packages/os-sensors`' raw per-OS FFI — so it didn't
//! need its own crate the way I4's sensors did.
//! `Router::route` reads a credential immediately before calling the
//! adapter and never stores or logs it (see `router.rs`'s
//! `credentials_never_appear_in_any_emitted_envelope` coverage in
//! `tests/cs_aip.rs`) — that discipline is unchanged by which
//! `CredentialStore` impl is plugged in.

use std::sync::{Mutex, OnceLock};

pub trait CredentialStore: Send + Sync {
    /// Returns `None` if the provider has no stored credential (e.g. a
    /// local provider that needs none).
    fn get(&self, provider_id: &str) -> Option<String>;
}

/// Reference/test implementation — an in-memory map, deliberately **not**
/// suitable for production (see module doc: real credentials belong in the
/// OS keystore, never a plain in-process map that could be memory-dumped or
/// serialized by accident).
#[derive(Debug, Clone, Default)]
pub struct InMemoryCredentialStore {
    credentials: std::collections::HashMap<String, String>,
}

impl InMemoryCredentialStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&mut self, provider_id: &str, credential: impl Into<String>) {
        self.credentials
            .insert(provider_id.to_owned(), credential.into());
    }
}

impl CredentialStore for InMemoryCredentialStore {
    fn get(&self, provider_id: &str) -> Option<String> {
        self.credentials.get(provider_id).cloned()
    }
}

/// Real OS-keystore-backed implementation (SEC-030). Each provider's
/// credential is one keystore entry, keyed by `(service, provider_id)` —
/// `service` namespaces every entry this store writes so it never collides
/// with another application's (or another OCP install's) credentials in the
/// same OS keystore.
pub struct OsKeystoreCredentialStore {
    service: String,
}

// keyring's platform store is process-wide. Serializing first-touch and
// operations prevents concurrent Runtime/Electron requests from racing the
// Windows Credential Manager backend initialization and surfacing a generic
// `NoDefaultStore`/keystore-unavailable result.
fn keystore_operation_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

impl OsKeystoreCredentialStore {
    /// `service` is typically a fixed constant for the whole app (e.g.
    /// `"ocp-ai-provider"`) — pass the same value every time so `set`/`get`/
    /// `delete` all address the same keystore entries.
    #[must_use]
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }

    fn entry(&self, provider_id: &str) -> Result<keyring::v1::Entry, keyring::v1::Error> {
        keyring::v1::Entry::new(&self.service, provider_id)
    }

    /// Writes (or overwrites) `provider_id`'s stored credential. Not part of
    /// the `CredentialStore` trait — SEC-030 only requires the router to
    /// *read* at call time; writing is a setup-time operation (a human via
    /// `examples/store_credential.rs`, or a future onboarding/settings flow),
    /// never something `Router::route` itself does.
    pub fn set(&self, provider_id: &str, credential: &str) -> Result<(), keyring::v1::Error> {
        let _guard = keystore_operation_lock()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        self.entry(provider_id)?.set_password(credential)
    }

    /// Removes `provider_id`'s stored credential. `Ok(())` even if there was
    /// nothing stored (`NoEntry` is treated as already-absent, matching
    /// `get`'s "no credential" behaviour below, not surfaced as an error).
    pub fn delete(&self, provider_id: &str) -> Result<(), keyring::v1::Error> {
        let _guard = keystore_operation_lock()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        match self.entry(provider_id)?.delete_credential() {
            Ok(()) | Err(keyring::v1::Error::NoEntry) => Ok(()),
            Err(e) => Err(e),
        }
    }
}

impl CredentialStore for OsKeystoreCredentialStore {
    fn get(&self, provider_id: &str) -> Option<String> {
        let _guard = keystore_operation_lock()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        // Every non-success outcome (no entry stored, keystore locked,
        // platform failure, ...) collapses to `None` here, matching the
        // trait's contract ("`None` if the provider has no stored
        // credential") — it's each adapter's `invoke`, not this store, that
        // decides whether a missing credential is fatal (compare e.g.
        // `ClaudeAdapter`'s `missing_credential_is_rejected_before_any_
        // network_call`, unchanged by which store is plugged in).
        self.entry(provider_id).ok()?.get_password().ok()
    }
}

#[cfg(test)]
mod os_keystore_tests {
    use super::*;
    use std::sync::Mutex;

    // A dedicated service namespace so these tests can never collide with
    // (or clobber) a real stored provider credential — deliberately not the
    // same `service` a real caller would pass to `new`. These tests write
    // into and read back from the *real* OS keystore on whatever machine
    // runs `cargo test` (there is no in-process fake for `keyring`'s
    // platform backends), and clean up after themselves.
    fn test_store() -> OsKeystoreCredentialStore {
        OsKeystoreCredentialStore::new("ocp-llm-router-tests")
    }

    // Real bug found running these live (SEC-030 slice, 2026-07-21): `cargo
    // test` runs this crate's tests on multiple OS threads by default, and
    // the *first* `keyring::v1::Entry::new` call in the process registers
    // that platform's default credential-store builder. When two of these
    // tests' first keystore touches land on different threads at the same
    // moment, the loser sometimes observed no default store yet and failed
    // with `Error::NoDefaultStore` (`set_overwrites_a_previous_value`, one
    // run in 28 tests) — not a `cargo test` flag or hardware issue, a real
    // one-time-init race in the `keyring`/`keyring-core` dependency this
    // store didn't have before. Since every one of these tests talks to the
    // one real, process-wide OS keystore anyway (a genuinely shared
    // resource, not a fixture each test gets its own copy of), serializing
    // them with this lock is the correct fix, not just a race workaround:
    // `.lock().unwrap_or_else(PoisonError::into_inner)` so one test's
    // panic-while-holding-the-lock (a real assertion failure) doesn't
    // cascade into spurious poisoned-lock panics on the tests after it.
    static KEYSTORE_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    #[ignore = "requires a configured real OS keystore; run with cargo test -- --ignored"]
    fn set_then_get_round_trips_through_the_real_os_keystore() {
        let _guard = KEYSTORE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let store = test_store();
        let provider_id = "test-provider-set-then-get";
        store
            .set(provider_id, "sk-test-12345")
            .expect("keystore write should succeed on a dev machine with a usable keystore");
        assert_eq!(store.get(provider_id).as_deref(), Some("sk-test-12345"));
        store
            .delete(provider_id)
            .expect("cleanup delete should succeed");
    }

    #[test]
    #[ignore = "requires a configured real OS keystore; run with cargo test -- --ignored"]
    fn get_returns_none_for_a_provider_that_was_never_stored() {
        let _guard = KEYSTORE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let store = test_store();
        assert_eq!(store.get("test-provider-never-stored-xyz"), None);
    }

    #[test]
    #[ignore = "requires a configured real OS keystore; run with cargo test -- --ignored"]
    fn delete_is_idempotent_ok_even_when_nothing_was_stored() {
        let _guard = KEYSTORE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let store = test_store();
        store
            .delete("test-provider-nothing-to-delete")
            .expect("deleting an absent entry should not error (NoEntry is treated as success)");
    }

    #[test]
    #[ignore = "requires a configured real OS keystore; run with cargo test -- --ignored"]
    fn set_overwrites_a_previous_value() {
        let _guard = KEYSTORE_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let store = test_store();
        let provider_id = "test-provider-overwrite";
        store
            .set(provider_id, "first")
            .expect("first write should succeed");
        store
            .set(provider_id, "second")
            .expect("overwrite should succeed");
        assert_eq!(store.get(provider_id).as_deref(), Some("second"));
        store
            .delete(provider_id)
            .expect("cleanup delete should succeed");
    }
}
