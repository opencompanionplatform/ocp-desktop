//! CS-MEM encryption-at-rest conformance (ADR-0012 / SEC-022).
//!
//! The counterpart to `cs_mem_sqlite.rs`'s forensic *deletion* test: where
//! that one reads cleartext bytes to prove deleted content is gone, these
//! read the raw file to prove *live* content is unreadable without the key.
//! Two independent facts are asserted against the real on-disk file, not a
//! mock: (1) the marker never appears in cleartext, and (2) the SQLite header
//! magic itself is encrypted — a SQLCipher database does not begin with
//! "SQLite format 3\0", which is the crisp difference between an encrypted
//! store and a plaintext one that merely happens not to contain the marker
//! yet. `certify()` is then run against an encrypted store to prove
//! encryption does not change the `MemoryStore` contract at all.

use ocp_memory::{
    certify, Caller, ContentType, InMemoryKeyStore, ListRequest, MemoryScope, MemoryStore,
    ProfileKeyStore, SqliteKey, SqliteStore, WriteRequest, DEFAULT_COMPANION_ID,
};

fn core(component: &str) -> Caller {
    Caller::Core {
        component: component.to_owned(),
    }
}

fn companion_scope() -> MemoryScope {
    MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())
}

/// A fixed, valid 256-bit test key — deterministic so wrong-key tests can pick
/// a *different* fixed key and know it differs. Real profiles use
/// `SqliteKey::generate()`; a hardcoded key in a test is not a security
/// concern (there is nothing real to protect in a tempdir).
fn key_a() -> SqliteKey {
    SqliteKey::from_hex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff").unwrap()
}

fn key_b() -> SqliteKey {
    SqliteKey::from_hex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100").unwrap()
}

fn write_marker(store: &mut SqliteStore, marker: &str) {
    store
        .write(
            &core("companion"),
            WriteRequest {
                scope: companion_scope(),
                content: marker.to_owned(),
                content_type: ContentType::TextPlain,
                sensitive: true,
                source: "companion".to_owned(),
            },
        )
        .expect("write must succeed");
}

/// The swap-test, unchanged, against an encrypted on-disk store: encryption
/// must not alter the `MemoryStore` contract in any observable way.
#[test]
fn encrypted_store_passes_the_generic_cs_mem_swap_test() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("enc-certify.db");
    let mut store =
        SqliteStore::open_encrypted(&path, &key_a()).expect("encrypted store must open");
    certify(&mut store).expect("turning encryption on must not change the MemoryStore contract");
}

/// **ADR-0012 / SEC-022, the core proof**: written content is ciphertext on
/// disk, and even the SQLite header is encrypted.
#[test]
fn content_is_ciphertext_on_disk_including_the_sqlite_header() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("enc-forensic.db");
    let secret = "xJ7qUnmistakableEncryptedMarker9f2Content";

    {
        let mut store =
            SqliteStore::open_encrypted(&path, &key_a()).expect("encrypted store must open");
        write_marker(&mut store, secret);
        // Force pages onto disk before reading the file behind the store's back.
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    } // drop closes the connection, flushing everything.

    let db_bytes = std::fs::read(&path).expect("db file must be readable");
    assert!(
        !contains_bytes(&db_bytes, secret.as_bytes()),
        "content must be encrypted at rest — the plaintext marker must NOT appear in the file (SEC-022/ADR-0012)"
    );
    assert!(
        !db_bytes.starts_with(b"SQLite format 3\0"),
        "an encrypted SQLCipher database must not expose the plaintext SQLite header magic — its presence would mean the file is not actually encrypted"
    );

    // The WAL must be encrypted too (ADR-0012 names the WAL explicitly).
    let wal_path = path.with_extension("db-wal");
    if wal_path.exists() {
        let wal_bytes = std::fs::read(&wal_path).expect("wal file must be readable if present");
        assert!(
            !contains_bytes(&wal_bytes, secret.as_bytes()),
            "the WAL must also be encrypted (ADR-0012)"
        );
    }
}

/// Reopening with the correct key must transparently decrypt: the data
/// written in a previous session is readable again.
#[test]
fn data_round_trips_when_reopened_with_the_correct_key() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("enc-roundtrip.db");
    let secret = "roundTripMarker_A1B2C3";

    {
        let mut store =
            SqliteStore::open_encrypted(&path, &key_a()).expect("encrypted store must open");
        write_marker(&mut store, secret);
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    }

    let mut store = SqliteStore::open_encrypted(&path, &key_a())
        .expect("reopening with the same key must succeed");
    let listed = store
        .list(
            &core("companion"),
            ListRequest {
                scope: companion_scope(),
                after: None,
                limit: 100,
            },
        )
        .expect("list must succeed");
    assert!(
        listed.records.iter().any(|r| r.content == secret),
        "the record written in the first session must be readable after reopening with the correct key"
    );
}

/// Opening an existing encrypted store with the *wrong* key must fail cleanly
/// (not return an empty-but-usable store, not panic).
#[test]
fn wrong_key_cannot_open_the_store() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("enc-wrongkey.db");

    {
        let mut store =
            SqliteStore::open_encrypted(&path, &key_a()).expect("encrypted store must open");
        write_marker(&mut store, "secret content that key_b must never reach");
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    }

    let result = SqliteStore::open_encrypted(&path, &key_b());
    assert!(
        result.is_err(),
        "opening an encrypted store with the wrong key must fail, not silently succeed"
    );
}

/// Opening an encrypted store with *no* key (the plaintext constructor) must
/// also fail — a copied database file is useless without the key (ADR-0012's
/// "single-file backup property is preserved").
#[test]
fn opening_an_encrypted_store_as_plaintext_fails() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("enc-noplaintext.db");

    {
        let mut store =
            SqliteStore::open_encrypted(&path, &key_a()).expect("encrypted store must open");
        write_marker(&mut store, "encrypted-only content");
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    }

    let result = SqliteStore::open(&path);
    assert!(
        result.is_err(),
        "an encrypted file must not open as a plaintext SQLite database"
    );
}

/// **ADR-0012 key-management flow**: first `open_profile` generates and stores
/// a key (profile creation); a second `open_profile` on the same profile
/// reuses that stored key and reads the same data.
#[test]
fn open_profile_generates_a_key_then_reuses_it_from_the_keystore() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("aiko-profile.db");
    let mut key_store = InMemoryKeyStore::new();
    let secret = "aikoOnlyMemory_9x8y7z";

    assert!(
        key_store.load("aiko").unwrap().is_none(),
        "no key should exist before the profile is first opened"
    );

    {
        let mut store = SqliteStore::open_profile(&path, "aiko", &mut key_store)
            .expect("first open_profile must create the profile");
        write_marker(&mut store, secret);
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    }

    assert!(
        key_store.load("aiko").unwrap().is_some(),
        "opening the profile must have stored its generated key"
    );

    let mut store = SqliteStore::open_profile(&path, "aiko", &mut key_store)
        .expect("reopening the profile must reuse the stored key");
    let listed = store
        .list(
            &core("companion"),
            ListRequest {
                scope: companion_scope(),
                after: None,
                limit: 100,
            },
        )
        .expect("list must succeed");
    assert!(
        listed.records.iter().any(|r| r.content == secret),
        "the same key must be reused, so the data is readable"
    );
}

/// A *different* profile gets a *different* generated key, so it cannot open
/// another profile's database file — the storage separation ADR-0013's
/// memory split and ADR-0010's "one database file per companion profile" both
/// rely on.
#[test]
fn a_different_profile_gets_a_different_key_and_cannot_open_another_profiles_file() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("shared-path.db");
    let mut key_store = InMemoryKeyStore::new();

    {
        let mut store = SqliteStore::open_profile(&path, "aiko", &mut key_store)
            .expect("aiko's profile must be created");
        write_marker(&mut store, "aiko private memory");
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    }

    // "nova" is a new profile: open_profile generates a fresh key for it, then
    // tries to open aiko's existing encrypted file with nova's key -> fail.
    let result = SqliteStore::open_profile(&path, "nova", &mut key_store);
    assert!(result.is_err(), "a second profile's freshly-generated key must not be able to open the first profile's file");
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return needle.is_empty();
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}
