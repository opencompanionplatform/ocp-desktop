//! CS-MEM against the real ADR-0010 backend. `certify()` is identical to
//! `cs_mem.rs`'s use of it against `InMemoryStore` -- the actual swap-test
//! proof (PDD_MEMORY_LAYER.md's "provider-swap test (alternative backend
//! stub honors same contract)"), not just "both compile." The forensic
//! deletion test is the one CS-MEM requirement `InMemoryStore` structurally
//! cannot satisfy (no file to grep) -- this is where it actually runs.

use ocp_memory::{
    certify, Caller, ContentType, MemoryScope, MemoryStore, SqliteStore, WriteRequest,
    DEFAULT_COMPANION_ID,
};

fn core(component: &str) -> Caller {
    Caller::Core {
        component: component.to_owned(),
    }
}

/// Shorthand for this test file's usual companion scope, same as `cs_mem.rs`.
fn companion_scope() -> MemoryScope {
    MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())
}

#[test]
fn sqlite_store_passes_the_generic_cs_mem_swap_test() {
    let mut store = SqliteStore::open_in_memory().expect("in-memory SQLite must open");
    certify(&mut store)
        .expect("SqliteStore must satisfy the identical MemoryStore contract InMemoryStore does");
}

#[test]
fn sqlite_store_cascade_delete_matches_in_memory_stores_behavior() {
    let mut store = SqliteStore::open_in_memory().expect("in-memory SQLite must open");
    let written = store
        .write(
            &core("companion"),
            WriteRequest {
                scope: companion_scope(),
                content: "source fact".to_owned(),
                content_type: ContentType::TextPlain,
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .unwrap();

    store.attach_embedding_for_test(written.record_id).unwrap();
    let summary_id = store
        .attach_summary_for_test(written.record_id, "a summary of the source fact")
        .unwrap();

    let results = store.delete(&core("companion"), &[written.record_id]);
    let outcome = results[0]
        .as_ref()
        .expect("delete of an owned, existing record must succeed");
    assert_eq!(outcome.cascaded.embeddings, 1);
    assert_eq!(outcome.cascaded.summaries, 1);

    let after = store
        .list(
            &core("companion"),
            ocp_memory::ListRequest {
                scope: companion_scope(),
                after: None,
                limit: 100,
            },
        )
        .unwrap();
    assert!(!after.records.iter().any(|r| r.id == written.record_id));
    assert!(
        !after.records.iter().any(|r| r.id == summary_id),
        "cascaded summary must be gone too, not orphaned"
    );
}

/// **The literal PDD_MEMORY_LAYER.md requirement**: "forensic deletion test
/// (grep the DB file + WAL for deleted content)". Real file, real bytes,
/// checked with no interpretation layer in between.
#[test]
fn forensic_deletion_removes_content_from_the_db_file_and_wal() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("forensic-test-profile.db");
    let mut store = SqliteStore::open(&path).expect("SQLite file must open");

    // A long, unmistakable marker -- not a common word -- so a false
    // "still present" match can't be explained by anything other than the
    // actual record content.
    let secret = "xJ7qUnmistakableForensicMarker9f2Content";
    let written = store
        .write(
            &core("companion"),
            WriteRequest {
                scope: companion_scope(),
                content: secret.to_owned(),
                content_type: ContentType::TextPlain,
                sensitive: true,
                source: "companion".to_owned(),
            },
        )
        .expect("write must succeed");

    // Force the write onto disk deterministically before the sanity check
    // below -- a fresh write can otherwise still be sitting only in SQLite's
    // in-process page cache / WAL, not yet flushed to the main file.
    store
        .checkpoint_for_test()
        .expect("checkpoint must succeed");

    let db_bytes_before = std::fs::read(&path).expect("db file must be readable");
    assert!(
        contains_bytes(&db_bytes_before, secret.as_bytes()),
        "sanity check failed: the marker must actually be findable on disk before deletion, or this test proves nothing"
    );

    let results = store.delete(&core("companion"), &[written.record_id]);
    assert!(results[0].is_ok(), "delete must succeed");

    let db_bytes_after = std::fs::read(&path).expect("db file must be readable");
    assert!(
        !contains_bytes(&db_bytes_after, secret.as_bytes()),
        "deleted content must not survive in the main DB file (SEC-021)"
    );

    // SQLite's own WAL naming convention: "<db-filename>-wal", appended to
    // the full original filename including its own extension.
    let wal_path = path.with_extension("db-wal");
    if wal_path.exists() {
        let wal_bytes = std::fs::read(&wal_path).expect("wal file must be readable if present");
        assert!(
            !contains_bytes(&wal_bytes, secret.as_bytes()),
            "deleted content must not survive in the WAL (SEC-021)"
        );
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return needle.is_empty();
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}
