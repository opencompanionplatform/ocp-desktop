//! ADR-0012 key material and key management for the encrypted `SqliteStore`.
//!
//! ADR-0012 ("SQLCipher-class full-database encryption ... database key
//! wrapped by the OS keystore") has two halves, both here:
//!
//! - [`SqliteKey`] — the raw 256-bit per-profile database key itself. It is
//!   generated with the OS CSPRNG ([`SqliteKey::generate`]) and rendered as a
//!   SQLCipher raw-key hex string only at the moment it is handed to a
//!   connection's `PRAGMA key` (see `sqlite_store.rs`). It is `ZeroizeOnDrop`
//!   so the key bytes don't linger in this crate's process memory after the
//!   store closes (ADR-0012: "the plaintext key exists only in Memory Layer
//!   process memory").
//! - [`ProfileKeyStore`] — the "wrapped by the OS keystore" half. The real
//!   implementation ([`OsKeystoreKeyStore`]) stores each profile's key in the
//!   platform keystore (DPAPI / Keychain / Secret Service) via the `keyring`
//!   crate — the exact same mechanism I5's `OsKeystoreCredentialStore` already
//!   uses for provider credentials (SEC-030), and the exact stores ADR-0012's
//!   own key-management paragraph names. [`InMemoryKeyStore`] is the
//!   test-only fake that lets the generate-or-load control flow in
//!   [`SqliteStore::open_profile`](crate::SqliteStore::open_profile) be
//!   exercised without touching a real keystore — the same role
//!   `InMemoryStore` plays for `MemoryStore` and I5's reference adapters play
//!   for the router.
//!
//! **Named residuals, not hidden** (same honesty bar as the rest of this
//! crate): (1) the *user-passphrase upgrade* (Argon2id-class second wrap,
//! ADR-0012's optional mode) is not implemented — this slice ships the
//! OS-keystore-only default. (2) `SqliteKey`'s own bytes are zeroized, but
//! the transient plaintext *copies* the key necessarily becomes — the
//! `PRAGMA key = "x'...'"` SQL string and the hex string handed to `keyring`
//! — are ordinary `String`s and are not themselves zeroized; guaranteeing
//! that would mean a `Zeroizing<String>` wrapper threaded through the PRAGMA
//! call and the keystore API, flagged for a follow-up rather than silently
//! skipped.

use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::types::MemoryError;

/// A raw 256-bit SQLCipher database key for one companion profile.
///
/// Constructed either freshly ([`generate`](Self::generate), at profile
/// creation) or reconstituted from its keystore-stored hex form
/// ([`from_hex`](Self::from_hex)). Never `Debug`/`Display`/`Serialize` — the
/// only way key material leaves this type is [`to_hex`](Self::to_hex), used at
/// exactly two call sites (the `PRAGMA key` string and the keystore write),
/// so an accidental log line or event payload cannot leak it.
#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct SqliteKey {
    bytes: [u8; 32],
}

impl SqliteKey {
    /// Generates a fresh random key from the OS CSPRNG (`getrandom`, the same
    /// OS entropy source `uuid`/`rand` draw from). Fails only if the OS RNG
    /// itself is unavailable — surfaced as a `Backend` error rather than a
    /// panic, so profile creation degrades to a clean failure.
    pub fn generate() -> Result<Self, MemoryError> {
        let mut bytes = [0u8; 32];
        getrandom::getrandom(&mut bytes).map_err(|e| {
            MemoryError::Backend(format!(
                "OS CSPRNG unavailable while generating a profile key: {e}"
            ))
        })?;
        Ok(Self { bytes })
    }

    /// Reconstructs a key from a 64-character lowercase-hex string (its
    /// keystore-stored form). Returns `None` for any string that is not
    /// exactly 32 bytes of valid hex, so a corrupt/truncated keystore entry
    /// fails closed rather than opening the store with a silently-wrong key.
    pub fn from_hex(hex: &str) -> Option<Self> {
        if hex.len() != 64 {
            return None;
        }
        let mut bytes = [0u8; 32];
        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()?;
        }
        Some(Self { bytes })
    }

    /// The key as a 64-character lowercase-hex string. This is both its
    /// keystore-stored form and (wrapped in `x'...'`) its SQLCipher raw-key
    /// form. Deliberately the *only* accessor that exposes key material.
    pub fn to_hex(&self) -> String {
        let mut s = String::with_capacity(64);
        for &byte in &self.bytes {
            // Lowercase, always two digits — the SQLCipher raw-key format
            // requires exactly 64 hex chars for a 256-bit key.
            s.push(char::from_digit(u32::from(byte >> 4), 16).expect("nibble is 0..=15"));
            s.push(char::from_digit(u32::from(byte & 0x0f), 16).expect("nibble is 0..=15"));
        }
        s
    }
}

/// The "wrapped by the OS keystore" half of ADR-0012: given a profile id,
/// load its stored database key (if the profile already exists) or accept a
/// freshly-generated one to store (at profile creation). A separate seam from
/// [`MemoryStore`](crate::MemoryStore) precisely because key custody is a
/// different trust concern from record storage — and so it can be faked in
/// tests exactly like every other real-resource boundary in this workspace.
pub trait ProfileKeyStore {
    /// Returns the profile's stored key, or `None` if the profile has never
    /// been created (no key stored yet). An `Err` is reserved for a real
    /// keystore failure (locked, backend error), never for "absent".
    fn load(&self, profile_id: &str) -> Result<Option<SqliteKey>, MemoryError>;

    /// Persists `key` as `profile_id`'s database key. Called exactly once per
    /// profile, at creation (`open_profile` only calls this on the `None`
    /// branch of `load`), never on every open.
    fn store(&mut self, profile_id: &str, key: &SqliteKey) -> Result<(), MemoryError>;
}

/// Test-only [`ProfileKeyStore`] backed by an in-process map. Lets the
/// generate-or-load flow in `SqliteStore::open_profile` be tested without a
/// real OS keystore — it provides **no** at-rest protection for the key
/// itself and must never be used for real profiles (mirrors `InMemoryStore`'s
/// own "reference implementation, not for real data" stance).
#[derive(Default)]
pub struct InMemoryKeyStore {
    keys: std::collections::HashMap<String, SqliteKey>,
}

impl InMemoryKeyStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl ProfileKeyStore for InMemoryKeyStore {
    fn load(&self, profile_id: &str) -> Result<Option<SqliteKey>, MemoryError> {
        Ok(self.keys.get(profile_id).cloned())
    }

    fn store(&mut self, profile_id: &str, key: &SqliteKey) -> Result<(), MemoryError> {
        self.keys.insert(profile_id.to_owned(), key.clone());
        Ok(())
    }
}

/// Real [`ProfileKeyStore`]: each profile's database key lives in the OS
/// keystore (Windows Credential Manager / macOS Keychain / Linux Secret
/// Service) via `keyring`'s `v1` API — the same crate, same API, and same
/// per-platform backends I5's `OsKeystoreCredentialStore` proved live against
/// real Windows Credential Manager entries. `service` namespaces every entry
/// this store writes (default `ocp-memory`) so a profile key can never
/// collide with an I5 provider credential in the shared keystore.
pub struct OsKeystoreKeyStore {
    service: String,
}

impl OsKeystoreKeyStore {
    /// `service` is the keystore namespace for every key this store writes.
    /// Real callers pass a fixed constant (`ocp-memory`); tests pass a
    /// dedicated throwaway namespace so they never touch a real profile key.
    pub fn new(service: impl Into<String>) -> Self {
        Self {
            service: service.into(),
        }
    }

    fn entry(&self, profile_id: &str) -> Result<keyring::v1::Entry, keyring::v1::Error> {
        keyring::v1::Entry::new(&self.service, profile_id)
    }

    /// Removes a profile's stored key. `Ok(())` even if nothing was stored
    /// (`NoEntry` treated as already-absent), matching I5's
    /// `OsKeystoreCredentialStore::delete`. Not part of the trait — deleting a
    /// key is a profile-lifecycle operation, never something a store open does.
    pub fn delete(&self, profile_id: &str) -> Result<(), MemoryError> {
        match self.entry(profile_id).and_then(|e| e.delete_credential()) {
            Ok(()) | Err(keyring::v1::Error::NoEntry) => Ok(()),
            Err(e) => Err(MemoryError::Backend(format!("keystore delete failed: {e}"))),
        }
    }
}

impl ProfileKeyStore for OsKeystoreKeyStore {
    fn load(&self, profile_id: &str) -> Result<Option<SqliteKey>, MemoryError> {
        match self.entry(profile_id).and_then(|e| e.get_password()) {
            Ok(hex) => match SqliteKey::from_hex(&hex) {
                Some(key) => Ok(Some(key)),
                // A stored-but-corrupt key entry is a hard error, not a silent
                // "generate a new one" — regenerating would orphan the
                // existing encrypted database forever (its real key is the
                // corrupt one), so failing closed is the only safe choice.
                None => Err(MemoryError::Backend(format!(
                    "keystore entry for profile {profile_id:?} is not a valid 256-bit key"
                ))),
            },
            Err(keyring::v1::Error::NoEntry) => Ok(None),
            Err(e) => Err(MemoryError::Backend(format!("keystore read failed: {e}"))),
        }
    }

    fn store(&mut self, profile_id: &str, key: &SqliteKey) -> Result<(), MemoryError> {
        self.entry(profile_id)
            .and_then(|e| e.set_password(&key.to_hex()))
            .map_err(|e| MemoryError::Backend(format!("keystore write failed: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_and_is_64_lowercase_chars() {
        let key = SqliteKey::generate().expect("CSPRNG must be available in the test environment");
        let hex = key.to_hex();
        assert_eq!(hex.len(), 64, "a 256-bit raw key is exactly 64 hex chars");
        assert!(hex
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        let restored = SqliteKey::from_hex(&hex).expect("our own hex must parse back");
        assert_eq!(
            restored.to_hex(),
            hex,
            "from_hex(to_hex(k)) must be identity"
        );
    }

    #[test]
    fn from_hex_rejects_wrong_length_and_non_hex() {
        assert!(SqliteKey::from_hex("").is_none());
        assert!(
            SqliteKey::from_hex("abcd").is_none(),
            "too short must fail closed"
        );
        assert!(
            SqliteKey::from_hex(&"a".repeat(63)).is_none(),
            "63 chars is not a whole byte count"
        );
        assert!(SqliteKey::from_hex(&"a".repeat(65)).is_none());
        assert!(
            SqliteKey::from_hex(&"g".repeat(64)).is_none(),
            "non-hex digits must fail closed"
        );
    }

    #[test]
    fn generate_produces_distinct_keys() {
        let a = SqliteKey::generate().unwrap();
        let b = SqliteKey::generate().unwrap();
        assert_ne!(
            a.to_hex(),
            b.to_hex(),
            "two generated keys must not collide"
        );
    }

    #[test]
    fn in_memory_key_store_load_is_none_until_stored_then_reused() {
        let mut ks = InMemoryKeyStore::new();
        assert!(
            ks.load("aiko").unwrap().is_none(),
            "an unknown profile has no key"
        );
        let key = SqliteKey::generate().unwrap();
        ks.store("aiko", &key).unwrap();
        let loaded = ks.load("aiko").unwrap().expect("stored key must load back");
        assert_eq!(loaded.to_hex(), key.to_hex());
        assert!(
            ks.load("nova").unwrap().is_none(),
            "a different profile is still unknown"
        );
    }
}
