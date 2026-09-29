//! CS-MEM vector search (ADR-0010), slice 1: the recall-by-cosine mechanism on
//! the reference `InMemoryStore`. The embedder itself (and the cosine helper)
//! are unit-tested in `embedding.rs`; here the store-level ranking assertions
//! use **hand-crafted vectors** so ordering is fully deterministic and never
//! depends on a hash landing in a particular bucket. One test exercises the
//! real `Embedder` seam end to end using the same-text-embeds-to-cosine-1.0
//! property, which is collision-robust by construction.
//!
//! Scope authorization (SEC-020), the excerpt budget, and SEC-021 cascade of
//! the ranking vector are all covered so the semantic path matches the lexical
//! one's guarantees.

use ocp_memory::{
    Caller, ContentType, DeterministicEmbedder, Embedder, InMemoryStore, MemoryScope, MemoryStore,
    RecallBudget, WriteOutcome, WriteRequest, DEFAULT_COMPANION_ID,
};

fn core(component: &str) -> Caller {
    Caller::Core {
        component: component.to_owned(),
    }
}

fn companion_scope() -> MemoryScope {
    MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())
}

fn budget(max_excerpts: usize) -> RecallBudget {
    RecallBudget {
        max_excerpts,
        max_chars: 100_000,
    }
}

/// Writes a record (no embedding yet) and returns its outcome so the caller
/// can grab `.record_id`.
fn write(store: &mut InMemoryStore, scope: MemoryScope, content: &str) -> WriteOutcome {
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
        .expect("write must succeed")
}

#[test]
fn recall_by_vector_ranks_by_cosine_and_drops_orthogonal_records() {
    let mut store = InMemoryStore::new();
    let identical = write(&mut store, companion_scope(), "record A").record_id;
    store.attach_embedding(identical, &[1.0, 0.0, 0.0]).unwrap();
    let close = write(&mut store, companion_scope(), "record B").record_id;
    store.attach_embedding(close, &[0.8, 0.2, 0.0]).unwrap();
    let orthogonal = write(&mut store, companion_scope(), "record C").record_id;
    store
        .attach_embedding(orthogonal, &[0.0, 0.0, 1.0])
        .unwrap();

    let query = vec![1.0, 0.0, 0.0];
    let response = store.recall_by_vector(
        &core("companion"),
        &[companion_scope()],
        &query,
        &budget(10),
    );

    let ids: Vec<_> = response.excerpts.iter().map(|e| e.record_id).collect();
    assert_eq!(
        ids,
        vec![identical, close],
        "identical vector ranks first, the close one second, the orthogonal one is dropped (cosine 0)"
    );
    assert!(
        response.excerpts[0].score > response.excerpts[1].score,
        "scores must be strictly descending here"
    );
    assert!(
        (response.excerpts[0].score - 1.0).abs() < 1e-6,
        "the identical vector scores cosine 1.0"
    );
}

#[test]
fn recall_by_vector_finds_a_record_through_the_embedder_seam() {
    let embedder = DeterministicEmbedder::new(256);
    let mut store = InMemoryStore::new();

    let target = write(
        &mut store,
        companion_scope(),
        "the user enjoys mountain hiking",
    )
    .record_id;
    store
        .attach_embedding(
            target,
            &embedder.embed("the user enjoys mountain hiking").unwrap(),
        )
        .unwrap();
    let other = write(
        &mut store,
        companion_scope(),
        "quarterly tax filing reminder",
    )
    .record_id;
    store
        .attach_embedding(
            other,
            &embedder.embed("quarterly tax filing reminder").unwrap(),
        )
        .unwrap();

    // Query embedded with the SAME embedder; identical text embeds to an
    // identical vector -> cosine 1.0, the maximum, so `target` must rank first
    // regardless of where any token happens to hash.
    let query = embedder.embed("the user enjoys mountain hiking").unwrap();
    let response = store.recall_by_vector(
        &core("companion"),
        &[companion_scope()],
        &query,
        &budget(10),
    );

    assert_eq!(
        response.excerpts.first().map(|e| e.record_id),
        Some(target),
        "the record whose exact text the query embeds must rank first"
    );
    assert!(
        response.excerpts[0].score > 0.99,
        "identical text -> (near-)identical vectors -> cosine ~1"
    );
}

#[test]
fn recall_by_vector_enforces_scope_authorization() {
    let mut store = InMemoryStore::new();
    let record = write(
        &mut store,
        MemoryScope::UserProfile,
        "the user lives in Berlin",
    )
    .record_id;
    store.attach_embedding(record, &[1.0, 0.0]).unwrap();

    // A plugin with no extra grants can read only its own Plugin scope (SEC-020).
    let plugin = Caller::Plugin {
        id: "weather".to_owned(),
        extra_grants: vec![],
    };
    let response = store.recall_by_vector(
        &plugin,
        &[MemoryScope::UserProfile],
        &[1.0, 0.0],
        &budget(10),
    );
    assert!(
        response.excerpts.is_empty(),
        "a plugin must not recall user-profile memory it isn't granted (SEC-020)"
    );
}

#[test]
fn recall_by_vector_respects_the_excerpt_budget() {
    let mut store = InMemoryStore::new();
    for content in ["m one", "m two", "m three", "m four"] {
        let id = write(&mut store, companion_scope(), content).record_id;
        store.attach_embedding(id, &[1.0, 0.0]).unwrap(); // all identical -> all cosine 1.0
    }

    let response = store.recall_by_vector(
        &core("companion"),
        &[companion_scope()],
        &[1.0, 0.0],
        &budget(2),
    );
    assert_eq!(
        response.excerpts.len(),
        2,
        "max_excerpts caps the result count"
    );
    assert!(
        response.truncated,
        "truncated must be set when the budget cut results off"
    );
}

#[test]
fn deleting_a_record_removes_it_from_vector_recall() {
    let mut store = InMemoryStore::new();
    let id = write(&mut store, companion_scope(), "mountain hiking trip").record_id;
    store.attach_embedding(id, &[1.0, 0.0]).unwrap();
    let query = vec![1.0, 0.0];

    assert!(
        !store
            .recall_by_vector(
                &core("companion"),
                &[companion_scope()],
                &query,
                &budget(10)
            )
            .excerpts
            .is_empty(),
        "the record is recallable before deletion"
    );
    store.delete(&core("companion"), &[id]);
    assert!(
        store
            .recall_by_vector(
                &core("companion"),
                &[companion_scope()],
                &query,
                &budget(10)
            )
            .excerpts
            .is_empty(),
        "SEC-021: a deleted record's ranking vector must not survive in recall"
    );
}

#[test]
fn recall_by_vector_only_returns_records_from_the_requested_scopes() {
    let mut store = InMemoryStore::new();
    // Core can read every scope; the query asks only for the companion scope.
    let companion = write(&mut store, companion_scope(), "companion note").record_id;
    store.attach_embedding(companion, &[1.0, 0.0]).unwrap();
    let profile = write(&mut store, MemoryScope::UserProfile, "profile note").record_id;
    store.attach_embedding(profile, &[1.0, 0.0]).unwrap();

    let response = store.recall_by_vector(
        &core("companion"),
        &[companion_scope()],
        &[1.0f32, 0.0],
        &budget(10),
    );
    let ids: Vec<_> = response.excerpts.iter().map(|e| e.record_id).collect();
    assert_eq!(
        ids,
        vec![companion],
        "the requested-scope filter applies, not just caller authorization (SEC-020)"
    );
    assert!(!ids.contains(&profile));
}

#[test]
fn records_without_an_attached_vector_do_not_participate() {
    let mut store = InMemoryStore::new();
    // written but never embedded
    write(&mut store, companion_scope(), "mountain unembedded");

    let response = store.recall_by_vector(
        &core("companion"),
        &[companion_scope()],
        &[1.0, 0.0],
        &budget(10),
    );
    assert!(
        response.excerpts.is_empty(),
        "only records with an attached vector participate in vector recall"
    );
}
