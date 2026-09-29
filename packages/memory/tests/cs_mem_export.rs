//! CS-MEM export file format (MEMORY_API §2.5 / SEC-023): the portable
//! `ocp-memory-export/1.0` JSON-Lines format itself, not just the in-memory
//! `ExportResponse` shape (which `cs_mem.rs` already covers for
//! manifest/recordCount). Proves three things end to end:
//!
//! 1. `to_jsonl()` renders a manifest header line followed by exactly one
//!    `MemoryRecord` JSON object per line, and every line parses back
//!    independently (the format is genuinely portable/machine-readable);
//! 2. a caller can write those bytes to a real file and read them back with
//!    no loss (the caller/CLI half of the split);
//! 3. the export of an **encrypted** store is plaintext on disk — the
//!    documented ADR-0012 / SEC-023 recovery path (encrypted at rest, but an
//!    export deliberately is not, which is why SEC-023 gates it behind
//!    deletion-level confirmation).

use ocp_memory::{
    Caller, ContentType, ExportManifest, ExportRequest, InMemoryStore, MemoryRecord, MemoryScope,
    MemoryStore, SqliteKey, SqliteStore, WriteRequest, DEFAULT_COMPANION_ID,
};

const EXPORT_FORMAT: &str = "ocp-memory-export/1.0";

fn core(component: &str) -> Caller {
    Caller::Core {
        component: component.to_owned(),
    }
}

fn companion_scope() -> MemoryScope {
    MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())
}

fn write_record(store: &mut impl MemoryStore, scope: MemoryScope, content: &str) {
    store
        .write(
            &core("companion"),
            WriteRequest {
                scope,
                content: content.to_owned(),
                content_type: ContentType::TextPlain,
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .expect("write must succeed");
}

#[test]
fn export_renders_a_manifest_line_then_one_record_per_line() {
    let mut store = InMemoryStore::new();
    for content in ["fact one", "fact two", "fact three"] {
        write_record(&mut store, companion_scope(), content);
    }

    let response = store
        .export(
            &core("companion"),
            ExportRequest {
                scopes: vec![companion_scope()],
                format: EXPORT_FORMAT.to_owned(),
            },
        )
        .expect("export must succeed");
    let jsonl = response.to_jsonl();

    assert!(
        jsonl.ends_with('\n'),
        "the file must end in a newline so append stays well-formed"
    );
    let lines: Vec<&str> = jsonl.lines().collect();
    assert_eq!(
        lines.len(),
        1 + 3,
        "one manifest header line + one line per record"
    );

    // Line 1 is the manifest and parses on its own.
    let manifest: ExportManifest =
        serde_json::from_str(lines[0]).expect("the first line must be the manifest");
    assert_eq!(manifest.format, EXPORT_FORMAT);
    assert_eq!(manifest.record_count, 3);
    assert!(manifest.scopes.contains(&companion_scope()));

    // Every subsequent line parses back independently as a MemoryRecord.
    let mut recovered_contents = Vec::new();
    for line in &lines[1..] {
        let record: MemoryRecord =
            serde_json::from_str(line).expect("each record line must parse as a MemoryRecord");
        assert_eq!(record.scope, companion_scope());
        recovered_contents.push(record.content);
    }
    for expected in ["fact one", "fact two", "fact three"] {
        assert!(
            recovered_contents.iter().any(|c| c == expected),
            "record {expected:?} must survive the round trip"
        );
    }
}

#[test]
fn exported_bytes_round_trip_through_a_real_file() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let path = dir.path().join("memory-export.jsonl");

    let mut store = InMemoryStore::new();
    write_record(
        &mut store,
        MemoryScope::UserProfile,
        "the user prefers dark mode",
    );

    let response = store
        .export(
            &core("companion"),
            ExportRequest {
                scopes: vec![MemoryScope::UserProfile],
                format: EXPORT_FORMAT.to_owned(),
            },
        )
        .expect("export must succeed");

    // The caller writes the export to disk (the caller/CLI half of the split).
    std::fs::write(&path, response.to_jsonl()).expect("writing the export file must succeed");

    let read_back = std::fs::read_to_string(&path).expect("the export file must be readable");
    let lines: Vec<&str> = read_back.lines().collect();
    let manifest: ExportManifest =
        serde_json::from_str(lines[0]).expect("manifest line parses after a real file round trip");
    assert_eq!(manifest.record_count, 1);
    let record: MemoryRecord =
        serde_json::from_str(lines[1]).expect("record line parses after a real file round trip");
    assert_eq!(record.content, "the user prefers dark mode");
    assert!(
        record.sensitive,
        "user-profile records are sensitive (MEMORY_API §1) and that flag survives export"
    );
}

/// **ADR-0012 / SEC-023 recovery path**: the store is SQLCipher-encrypted at
/// rest, but its export is plaintext — that is the whole point of the export
/// being the recommended recovery mechanism (and why it needs deletion-level
/// confirmation).
#[test]
fn export_of_an_encrypted_store_is_plaintext_for_recovery() {
    let dir = tempfile::tempdir().expect("tempdir must be creatable");
    let db_path = dir.path().join("encrypted.db");
    let export_path = dir.path().join("recovery-export.jsonl");
    let key =
        SqliteKey::from_hex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
            .unwrap();
    let marker = "recoveryMarker_zZ9Unmistakable";

    {
        let mut store =
            SqliteStore::open_encrypted(&db_path, &key).expect("encrypted store must open");
        write_record(
            &mut store,
            MemoryScope::UserProfile,
            &format!("the recovery secret is {marker}"),
        );
        store
            .checkpoint_for_test()
            .expect("checkpoint must succeed");
    }

    // Reopen and export.
    let mut store =
        SqliteStore::open_encrypted(&db_path, &key).expect("encrypted store must reopen");
    let response = store
        .export(
            &core("companion"),
            ExportRequest {
                scopes: vec![MemoryScope::UserProfile],
                format: EXPORT_FORMAT.to_owned(),
            },
        )
        .expect("export must succeed");
    std::fs::write(&export_path, response.to_jsonl())
        .expect("writing the export file must succeed");

    let db_bytes = std::fs::read(&db_path).expect("db file readable");
    assert!(
        !contains_bytes(&db_bytes, marker.as_bytes()),
        "the encrypted store must NOT hold the marker in cleartext (ADR-0012)"
    );
    let export_bytes = std::fs::read(&export_path).expect("export file readable");
    assert!(
        contains_bytes(&export_bytes, marker.as_bytes()),
        "the export IS plaintext — the documented recovery path (ADR-0012/SEC-023), which is exactly why it needs deletion-level confirmation"
    );
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return needle.is_empty();
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}
