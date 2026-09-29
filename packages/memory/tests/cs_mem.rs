//! CS-MEM — Memory Layer conformance (MEMORY_API, PDD_MEMORY_LAYER.md).
//! `certify()` is the generic swap-test harness (same role as
//! `ocp_runtime_api::certify` for NFR-001); everything else here is
//! `InMemoryStore`-specific: the SEC-021 cascade against a *real* derived
//! artifact (not just a vacuous zero count), event-building shapes against
//! EVENT_CATALOG.md's frozen schemas, wire round trips, and pagination.

use ocp_memory::{
    certify, Caller, ContentType, InMemoryStore, ListRequest, MemoryScope, MemoryStore,
    PurgeTrigger, RecallBudget, RecallRequest, WriteRequest, DEFAULT_COMPANION_ID,
};

/// Shorthand for this test file's usual companion scope -- most tests here
/// don't care about a specific companion instance, just "the" companion
/// scope, so they all use the same default id (ADR-0013 §6).
fn companion_scope() -> MemoryScope {
    MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())
}

fn core(component: &str) -> Caller {
    Caller::Core {
        component: component.to_owned(),
    }
}

fn write_req(scope: MemoryScope, content: &str) -> WriteRequest {
    WriteRequest {
        scope,
        content: content.to_owned(),
        content_type: ContentType::TextPlain,
        sensitive: false,
        source: "test".to_owned(),
    }
}

#[test]
fn in_memory_store_passes_the_generic_cs_mem_swap_test() {
    let mut store = InMemoryStore::new();
    certify(&mut store).expect("InMemoryStore must satisfy the generic MemoryStore contract");
}

// --- SEC-021 cascade against a real derived artifact ------------------------

#[test]
fn deleting_a_record_cascades_a_real_embedding_and_summary() {
    let mut store = InMemoryStore::new();
    let written = store
        .write(
            &core("companion"),
            write_req(companion_scope(), "source fact"),
        )
        .unwrap();

    let embedding_ref = store.attach_embedding_for_test(written.record_id);
    let summary_id =
        store.attach_summary_for_test(written.record_id, "a summary of the source fact");
    assert!(!embedding_ref.is_empty());

    // The summary is itself a listable record before deletion (it's a real
    // MemoryRecord, not a side-channel) -- confirms the cascade has
    // something genuine to remove, not an artifact of the test's own setup.
    let before = store
        .list(
            &core("companion"),
            ListRequest {
                scope: companion_scope(),
                after: None,
                limit: 100,
            },
        )
        .unwrap();
    assert!(before.records.iter().any(|r| r.id == summary_id));

    let results = store.delete(&core("companion"), &[written.record_id]);
    assert_eq!(results.len(), 1);
    let outcome = results[0]
        .as_ref()
        .expect("delete of an owned, existing record must succeed");
    assert_eq!(
        outcome.cascaded.embeddings, 1,
        "the attached embedding must be counted"
    );
    assert_eq!(
        outcome.cascaded.summaries, 1,
        "the attached summary must be counted"
    );

    // Forensic-equivalent check for an in-memory backend (no file to grep,
    // see lib.rs's module doc): every trace of the deleted id and its
    // derived summary must be gone from internal state, observable only
    // through the store's own public API (list), not by reaching into
    // private fields.
    let after = store
        .list(
            &core("companion"),
            ListRequest {
                scope: companion_scope(),
                after: None,
                limit: 100,
            },
        )
        .unwrap();
    assert!(
        !after.records.iter().any(|r| r.id == written.record_id),
        "source record must be gone"
    );
    assert!(
        !after.records.iter().any(|r| r.id == summary_id),
        "cascaded summary must be gone too, not orphaned"
    );
}

#[test]
fn purge_cascades_embeddings_and_summaries_for_every_record_in_scope() {
    let mut store = InMemoryStore::new();
    let a = store
        .write(
            &core("companion"),
            write_req(MemoryScope::Session, "session fact a"),
        )
        .unwrap();
    let b = store
        .write(
            &core("companion"),
            write_req(MemoryScope::Session, "session fact b"),
        )
        .unwrap();
    store.attach_embedding_for_test(a.record_id);
    store.attach_embedding_for_test(b.record_id);
    store.attach_summary_for_test(a.record_id, "summary of a");

    let outcome = store
        .purge(
            &core("session-manager"),
            &MemoryScope::Session,
            PurgeTrigger::SessionEnd,
        )
        .unwrap();
    // 3, not 2: `attach_summary_for_test` gives the summary the same scope
    // as its source record (a summary of a Session fact is itself a
    // Session-scope record), so purging Session correctly sweeps it up too
    // as its own top-level record, on top of being cascade-counted via `a`.
    assert_eq!(outcome.record_count, 3);
    assert_eq!(outcome.cascaded.embeddings, 2);
    assert_eq!(outcome.cascaded.summaries, 1);
}

// --- Event-building shapes match EVENT_CATALOG.md's frozen schemas ---------

#[test]
fn write_outcome_builds_the_exact_record_written_event_shape() {
    let mut store = InMemoryStore::new();
    // `writtenBy` (MEMORY_API's provenance field) comes from the request's
    // own `source`, not from the authorization `caller` -- they're allowed
    // to differ (e.g. a scheduler `Caller` writing a record `source`d as
    // `"summarizer"`), so this test sets `source` explicitly rather than
    // reusing `write_req`'s generic `"test"` default.
    let req = WriteRequest {
        scope: companion_scope(),
        content: "likes tea".to_owned(),
        content_type: ContentType::TextPlain,
        sensitive: false,
        source: "behavior-engine".to_owned(),
    };
    let out = store.write(&core("behavior-engine"), req).unwrap();
    let event = out.to_event();
    assert_eq!(event.event_type, "ocp.memory.record-written");
    assert_eq!(event.source, "memory-layer");
    assert_eq!(event.data["recordId"], out.record_id.to_string());
    assert_eq!(event.data["scope"], "companion:default");
    assert_eq!(event.data["sensitive"], false);
    assert_eq!(event.data["writtenBy"], "behavior-engine");
    event.validate().expect("must be a valid envelope (CS-EVT)");
}

#[test]
fn recall_response_builds_one_recalled_event_per_scope_actually_represented() {
    let mut store = InMemoryStore::new();
    store
        .write(
            &core("companion"),
            write_req(companion_scope(), "tea preference"),
        )
        .unwrap();
    store
        .write(
            &core("companion"),
            write_req(MemoryScope::UserProfile, "tea allergy note"),
        )
        .unwrap();

    let response = store
        .recall(
            &core("behavior-engine"),
            RecallRequest {
                query: "tea".to_owned(),
                scopes: vec![companion_scope(), MemoryScope::UserProfile],
                budget: RecallBudget {
                    max_excerpts: 10,
                    max_chars: 4000,
                },
            },
        )
        .unwrap();
    assert_eq!(response.excerpts.len(), 2);

    let events = response.to_events("behavior-engine");
    assert_eq!(
        events.len(),
        2,
        "one event per scope represented, per EVENT_CATALOG's singular `scope` field"
    );
    for event in &events {
        assert_eq!(event.event_type, "ocp.memory.recalled");
        assert_eq!(event.data["requesterId"], "behavior-engine");
        assert_eq!(event.data["excerptCount"], 1);
        event.validate().expect("must be a valid envelope (CS-EVT)");
    }
}

#[test]
fn delete_outcome_and_purge_outcome_build_the_exact_cascade_event_shapes() {
    let mut store = InMemoryStore::new();
    let written = store
        .write(&core("companion"), write_req(companion_scope(), "x"))
        .unwrap();
    let del = store.delete(&core("companion"), &[written.record_id]);
    let del_event = del[0].as_ref().unwrap().to_event();
    assert_eq!(del_event.event_type, "ocp.memory.record-deleted");
    assert_eq!(del_event.data["cascaded"]["embeddings"], 0);
    assert_eq!(del_event.data["cascaded"]["summaries"], 0);
    del_event
        .validate()
        .expect("must be a valid envelope (CS-EVT)");

    store
        .write(&core("companion"), write_req(MemoryScope::Session, "y"))
        .unwrap();
    let purge_outcome = store
        .purge(
            &core("session-manager"),
            &MemoryScope::Session,
            PurgeTrigger::SessionEnd,
        )
        .unwrap();
    let purge_event = purge_outcome.to_event();
    assert_eq!(purge_event.event_type, "ocp.memory.scope-purged");
    assert_eq!(purge_event.data["trigger"], "session-end");
    assert_eq!(purge_event.data["recordCount"], 1);
    purge_event
        .validate()
        .expect("must be a valid envelope (CS-EVT)");
}

#[test]
fn export_response_builds_the_scopes_and_recordcount_only_event_never_content() {
    let mut store = InMemoryStore::new();
    store
        .write(
            &core("companion"),
            write_req(companion_scope(), "sensitive-looking content"),
        )
        .unwrap();
    let exported = store
        .export(
            &core("inspection-ui"),
            ocp_memory::ExportRequest {
                scopes: vec![companion_scope()],
                format: "ocp-memory-export/1.0".to_owned(),
            },
        )
        .unwrap();
    let event = exported.to_event();
    assert_eq!(event.event_type, "ocp.memory.store-exported");
    assert_eq!(event.data["recordCount"], 1);
    assert_eq!(event.data["format"], "ocp-memory-export/1.0");
    // "counts and scopes only, never content" (MEMORY_API §2.5) -- the
    // event payload must not even structurally contain a content-shaped
    // field.
    assert!(event.data.get("content").is_none());
    assert!(event.data.get("records").is_none());
    event.validate().expect("must be a valid envelope (CS-EVT)");
}

// --- MemoryScope / ContentType wire round trips -----------------------------

#[test]
fn memory_scope_round_trips_including_plugin_id() {
    for (scope, wire) in [
        (MemoryScope::Session, "session".to_owned()),
        (
            MemoryScope::Companion("aiko".to_owned()),
            "companion:aiko".to_owned(),
        ),
        (MemoryScope::UserProfile, "user-profile".to_owned()),
        (
            MemoryScope::Plugin("weather-widget".to_owned()),
            "plugin:weather-widget".to_owned(),
        ),
    ] {
        assert_eq!(scope.as_wire_string(), wire);
        assert_eq!(MemoryScope::parse(&wire), Some(scope));
    }
}

#[test]
fn memory_scope_rejects_an_empty_plugin_or_companion_id() {
    assert_eq!(
        MemoryScope::parse("plugin:"),
        None,
        "an empty plugin id can never be a real verified plugin identity"
    );
    assert_eq!(
        MemoryScope::parse("companion:"),
        None,
        "an empty companion id can never be a real companion instance (ADR-0013)"
    );
    assert_eq!(MemoryScope::parse("not-a-scope"), None);
}

#[test]
fn memory_scope_companion_is_parameterized_per_instance() {
    // ADR-0013 §6: two different companion ids are different scopes
    // entirely -- this is what actually makes "Aiko-only" memory distinct
    // from "shared across every companion" possible.
    let aiko = MemoryScope::Companion("aiko".to_owned());
    let miku = MemoryScope::Companion("miku".to_owned());
    assert_ne!(aiko, miku);
    assert_eq!(aiko.as_wire_string(), "companion:aiko");
    assert_eq!(miku.as_wire_string(), "companion:miku");
}

#[test]
fn content_type_round_trips_and_rejects_unknown_values() {
    let value = serde_json::to_value(ContentType::ApplicationJson).unwrap();
    assert_eq!(value, serde_json::json!("application/json"));
    let back: ContentType = serde_json::from_value(value).unwrap();
    assert_eq!(back, ContentType::ApplicationJson);
    let bad: Result<ContentType, _> = serde_json::from_value(serde_json::json!("text/html"));
    assert!(
        bad.is_err(),
        "an unregistered contentType must not silently deserialize"
    );
}

// --- Pagination (MEMORY_API §2.3 page.after/limit) --------------------------

#[test]
fn list_pagination_walks_the_full_scope_without_skipping_or_repeating() {
    let mut store = InMemoryStore::new();
    let mut written_ids = Vec::new();
    for i in 0..5 {
        let out = store
            .write(
                &core("companion"),
                write_req(companion_scope(), &format!("fact {i}")),
            )
            .unwrap();
        written_ids.push(out.record_id);
    }
    written_ids.sort();

    let mut seen = Vec::new();
    let mut after = None;
    loop {
        let page = store
            .list(
                &core("companion"),
                ListRequest {
                    scope: companion_scope(),
                    after,
                    limit: 2,
                },
            )
            .unwrap();
        seen.extend(page.records.iter().map(|r| r.id));
        after = page.next_after;
        if after.is_none() {
            break;
        }
    }
    seen.sort();
    assert_eq!(
        seen, written_ids,
        "pagination must visit every record exactly once"
    );
}
