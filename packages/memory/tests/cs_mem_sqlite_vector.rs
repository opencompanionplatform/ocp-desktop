//! CS-MEM vector search on the real ADR-0010 backend (slice 2): `SqliteStore`
//! ranking by sqlite-vec's `vec_distance_cosine` in SQL. Mirrors
//! `cs_mem_vector.rs` (the `InMemoryStore` slice) and adds the key slice-2
//! guarantee: **the two backends recall the same records for the same data**
//! (brute-force in-memory cosine and sqlite-vec's SQL cosine agree), so
//! swapping the ADR-0010 backend in doesn't change recall behavior.

use ocp_memory::{
    Caller, ContentType, InMemoryStore, MemoryScope, MemoryStore, RecallBudget, SqliteStore,
    WriteOutcome, WriteRequest, DEFAULT_COMPANION_ID,
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

fn req(scope: MemoryScope, content: &str) -> WriteRequest {
    WriteRequest {
        scope,
        content: content.to_owned(),
        content_type: ContentType::TextPlain,
        sensitive: false,
        source: "companion".to_owned(),
    }
}

fn write_sqlite(store: &mut SqliteStore, scope: MemoryScope, content: &str) -> WriteOutcome {
    store
        .write(&core("companion"), req(scope, content))
        .expect("write must succeed")
}

#[test]
fn sqlite_store_vector_recall_ranks_by_cosine_and_drops_orthogonal() {
    let mut store = SqliteStore::open_in_memory().expect("in-memory SQLite must open");
    let identical = write_sqlite(&mut store, companion_scope(), "record A").record_id;
    store.attach_embedding(identical, &[1.0, 0.0, 0.0]).unwrap();
    let close = write_sqlite(&mut store, companion_scope(), "record B").record_id;
    store.attach_embedding(close, &[0.9, 0.1, 0.0]).unwrap();
    let orthogonal = write_sqlite(&mut store, companion_scope(), "record C").record_id;
    store
        .attach_embedding(orthogonal, &[0.0, 0.0, 1.0])
        .unwrap();

    let query = [1.0f32, 0.0, 0.0];
    let response = store
        .recall_by_vector(
            &core("companion"),
            &[companion_scope()],
            &query,
            &budget(10),
        )
        .unwrap();

    let ids: Vec<_> = response.excerpts.iter().map(|e| e.record_id).collect();
    assert_eq!(
        ids,
        vec![identical, close],
        "identical first, close second, orthogonal (distance 1.0) dropped"
    );
    assert!(
        response.excerpts[0].score > response.excerpts[1].score,
        "scores strictly descending"
    );
    assert!(
        (response.excerpts[0].score - 1.0).abs() < 1e-4,
        "cosine distance 0 -> similarity ~1"
    );
}

#[test]
fn sqlite_and_in_memory_agree_on_vector_recall() {
    // (content, embedding) — deliberately separable so the ranking is unambiguous.
    let data: [(&str, &[f32]); 3] = [
        ("the user enjoys mountain hiking", &[1.0, 0.0, 0.0]),
        ("mountain trails nearby", &[0.9, 0.1, 0.0]),
        ("quarterly tax filing", &[0.0, 0.0, 1.0]),
    ];
    let query = [1.0f32, 0.0, 0.0];

    let mut im = InMemoryStore::new();
    for (content, vector) in data {
        let id = im
            .write(&core("companion"), req(companion_scope(), content))
            .unwrap()
            .record_id;
        im.attach_embedding(id, vector).unwrap();
    }
    let im_contents: Vec<String> = im
        .recall_by_vector(
            &core("companion"),
            &[companion_scope()],
            &query,
            &budget(10),
        )
        .excerpts
        .into_iter()
        .map(|e| e.excerpt)
        .collect();

    let mut sq = SqliteStore::open_in_memory().unwrap();
    for (content, vector) in data {
        let id = sq
            .write(&core("companion"), req(companion_scope(), content))
            .unwrap()
            .record_id;
        sq.attach_embedding(id, vector).unwrap();
    }
    let sq_contents: Vec<String> = sq
        .recall_by_vector(
            &core("companion"),
            &[companion_scope()],
            &query,
            &budget(10),
        )
        .unwrap()
        .excerpts
        .into_iter()
        .map(|e| e.excerpt)
        .collect();

    assert_eq!(
        im_contents,
        vec![
            "the user enjoys mountain hiking".to_owned(),
            "mountain trails nearby".to_owned()
        ],
        "sanity: the two mountain records rank in, the tax record (orthogonal) is dropped"
    );
    assert_eq!(
        sq_contents, im_contents,
        "SqliteStore (sqlite-vec) and InMemoryStore must recall the same records in the same order"
    );
}

#[test]
fn sqlite_store_vector_recall_enforces_scope_authorization() {
    let mut store = SqliteStore::open_in_memory().unwrap();
    let record = write_sqlite(
        &mut store,
        MemoryScope::UserProfile,
        "the user lives in Berlin",
    )
    .record_id;
    store.attach_embedding(record, &[1.0, 0.0]).unwrap();

    let plugin = Caller::Plugin {
        id: "weather".to_owned(),
        extra_grants: vec![],
    };
    let response = store
        .recall_by_vector(
            &plugin,
            &[MemoryScope::UserProfile],
            &[1.0f32, 0.0],
            &budget(10),
        )
        .unwrap();
    assert!(
        response.excerpts.is_empty(),
        "a plugin must not recall user-profile memory it isn't granted (SEC-020)"
    );
}

#[test]
fn sqlite_store_vector_recall_respects_the_excerpt_budget() {
    let mut store = SqliteStore::open_in_memory().unwrap();
    for content in ["m one", "m two", "m three", "m four"] {
        let id = write_sqlite(&mut store, companion_scope(), content).record_id;
        store.attach_embedding(id, &[1.0, 0.0]).unwrap();
    }

    let response = store
        .recall_by_vector(
            &core("companion"),
            &[companion_scope()],
            &[1.0f32, 0.0],
            &budget(2),
        )
        .unwrap();
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
fn sqlite_store_vector_recall_only_returns_records_from_the_requested_scopes() {
    let mut store = SqliteStore::open_in_memory().unwrap();
    // Core can read every scope, but the query asks for the companion scope
    // only — a user-profile record with the same vector must NOT leak in.
    let companion = write_sqlite(&mut store, companion_scope(), "companion note").record_id;
    store.attach_embedding(companion, &[1.0, 0.0]).unwrap();
    let profile = write_sqlite(&mut store, MemoryScope::UserProfile, "profile note").record_id;
    store.attach_embedding(profile, &[1.0, 0.0]).unwrap();

    let response = store
        .recall_by_vector(
            &core("companion"),
            &[companion_scope()],
            &[1.0f32, 0.0],
            &budget(10),
        )
        .unwrap();
    let ids: Vec<_> = response.excerpts.iter().map(|e| e.record_id).collect();
    assert_eq!(
        ids,
        vec![companion],
        "only the requested scope is returned, not every scope the caller may read (SEC-020)"
    );
    assert!(!ids.contains(&profile));
}

#[test]
fn deleting_a_record_removes_it_from_sqlite_vector_recall() {
    let mut store = SqliteStore::open_in_memory().unwrap();
    let id = write_sqlite(&mut store, companion_scope(), "mountain hiking trip").record_id;
    store.attach_embedding(id, &[1.0, 0.0]).unwrap();
    let query = [1.0f32, 0.0];

    assert!(
        !store
            .recall_by_vector(
                &core("companion"),
                &[companion_scope()],
                &query,
                &budget(10)
            )
            .unwrap()
            .excerpts
            .is_empty(),
        "recallable before deletion"
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
            .unwrap()
            .excerpts
            .is_empty(),
        "SEC-021: a deleted record's vector must not survive in sqlite-vec recall"
    );
}
