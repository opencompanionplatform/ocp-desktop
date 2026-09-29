//! `MemoryStore` — MEMORY_API §2's six operations as one trait, plus
//! [`certify`], the CS-MEM swap-test harness (PDD_MEMORY_LAYER.md's
//! "provider-swap test (alternative backend stub honors same contract)",
//! same role as `ocp_runtime_api::certify` for NFR-001): passing it
//! certifies any backend for the contract. `InMemoryStore` (this slice) and
//! a future real SQLite backend (ADR-0010, next slice) must both pass it
//! identically.

use uuid::Uuid;

use crate::types::{
    Caller, DeleteOutcome, ExportRequest, ExportResponse, ListRequest, ListResponse, MemoryError,
    MemoryScope, PurgeOutcome, PurgeTrigger, RecallRequest, RecallResponse, WriteOutcome,
    WriteRequest, DEFAULT_COMPANION_ID,
};

/// The only interface through which any component writes, recalls, lists,
/// deletes, exports, or purges memory (MEMORY_API's own opening line).
/// Callers never touch a store's actual backing (file, table, in-memory
/// map) directly — everything happens through here, so scope authorization
/// (SEC-020) and the deletion cascade (SEC-021) are enforced in exactly one
/// place regardless of which backend is plugged in (ADR-0010/Constitution
/// Article 3: the Memory Provider is replaceable by contract).
pub trait MemoryStore {
    /// MEMORY_API §2.1. The store assigns `id`/`createdAt` and forces
    /// `sensitive = true` for `UserProfile` scope regardless of the
    /// request (§1's stated default) — never trusts the caller's flag
    /// there. Rejects (`Err`) rather than silently downgrading an
    /// unauthorized scope (SEC-020).
    fn write(&mut self, caller: &Caller, req: WriteRequest) -> Result<WriteOutcome, MemoryError>;

    /// MEMORY_API §2.2. Requested `scopes` are **intersected** with what
    /// `caller` is authorized to read (§2.2's own wording) — scopes the
    /// caller can't see are silently dropped from the search, not an
    /// error; the `budget` is enforced by the store even if the caller
    /// asks for more (§2.2), never trusted from the caller's own count.
    fn recall(
        &mut self,
        caller: &Caller,
        req: RecallRequest,
    ) -> Result<RecallResponse, MemoryError>;

    /// MEMORY_API §2.3. Unlike `recall`'s multi-scope intersection, `list`
    /// names exactly one scope — requesting one the caller isn't
    /// authorized for is a hard `Unauthorized` error, not a silent empty
    /// result (there is nothing to "intersect" a single scope down to).
    fn list(&mut self, caller: &Caller, req: ListRequest) -> Result<ListResponse, MemoryError>;

    /// MEMORY_API §2.4. Returns one `Result` **per requested id, in the
    /// same order** — a batch of 5 ids where one is unauthorized and one
    /// doesn't exist still processes and reports on the other 3
    /// (SEC-004-style containment: one bad id in a batch never aborts the
    /// rest). Each `Ok` cascades to embeddings + summaries (SEC-021)
    /// before it is returned.
    fn delete(
        &mut self,
        caller: &Caller,
        record_ids: &[Uuid],
    ) -> Vec<Result<DeleteOutcome, MemoryError>>;

    /// MEMORY_API §2.5. Like `recall`, requested `scopes` are intersected
    /// with what `caller` may read — export never returns a scope the
    /// caller couldn't otherwise list.
    fn export(
        &mut self,
        caller: &Caller,
        req: ExportRequest,
    ) -> Result<ExportResponse, MemoryError>;

    /// MEMORY_API §2.6. Full SEC-021 cascade semantics of `delete`, applied
    /// to every record in `scope` at once.
    fn purge(
        &mut self,
        caller: &Caller,
        scope: &MemoryScope,
        trigger: PurgeTrigger,
    ) -> Result<PurgeOutcome, MemoryError>;
}

fn core(component: &str) -> Caller {
    Caller::Core {
        component: component.to_owned(),
    }
}

fn plugin(id: &str) -> Caller {
    Caller::Plugin {
        id: id.to_owned(),
        extra_grants: Vec::new(),
    }
}

/// CS-MEM's generic conformance script. Contract-level assertions only —
/// deliberately does not assert any particular recall *ranking*, since
/// MEMORY_API §2.2 requires ranking by relevance but not a specific
/// algorithm, and a future embedding-backed store's ranking will
/// legitimately differ from `InMemoryStore`'s lexical one.
pub fn certify<S: MemoryStore>(store: &mut S) -> Result<(), String> {
    write_assigns_id_and_forces_user_profile_sensitive(store)?;
    write_authorization_is_enforced(store)?;
    recall_intersects_authorized_scopes_and_enforces_budget(store)?;
    list_rejects_an_unauthorized_scope(store)?;
    delete_cascades_and_is_scoped_per_id(store)?;
    export_returns_only_authorized_scopes_with_a_matching_manifest(store)?;
    purge_removes_every_record_in_scope_and_nothing_else(store)?;
    Ok(())
}

fn write_assigns_id_and_forces_user_profile_sensitive<S: MemoryStore>(
    store: &mut S,
) -> Result<(), String> {
    let out = store
        .write(
            &core("companion"),
            WriteRequest {
                scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
                content: "likes tea".to_owned(),
                content_type: crate::types::ContentType::TextPlain,
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .map_err(|e| format!("companion-scope write must be authorized: {e}"))?;
    if out.sensitive {
        return Err("companion scope must not be forced sensitive".to_owned());
    }

    let out = store
        .write(
            &core("companion"),
            WriteRequest {
                scope: MemoryScope::UserProfile,
                content: "prefers dark mode".to_owned(),
                content_type: crate::types::ContentType::TextPlain,
                sensitive: false, // deliberately wrong, to prove the store overrides it
                source: "companion".to_owned(),
            },
        )
        .map_err(|e| format!("user-profile write must be authorized: {e}"))?;
    if !out.sensitive {
        return Err(
            "user-profile scope must be forced sensitive regardless of the request (MEMORY_API §1)"
                .to_owned(),
        );
    }
    Ok(())
}

fn write_authorization_is_enforced<S: MemoryStore>(store: &mut S) -> Result<(), String> {
    let req = |scope: MemoryScope| WriteRequest {
        scope,
        content: "x".to_owned(),
        content_type: crate::types::ContentType::TextPlain,
        sensitive: false,
        source: "test".to_owned(),
    };

    if store
        .write(
            &core("companion"),
            req(MemoryScope::Plugin("widget".to_owned())),
        )
        .is_ok()
    {
        return Err("Core must not be authorized to write into a plugin's own scope".to_owned());
    }
    if store
        .write(
            &plugin("widget"),
            req(MemoryScope::Plugin("widget".to_owned())),
        )
        .is_err()
    {
        return Err("a plugin must be authorized to write its own scope".to_owned());
    }
    if store
        .write(
            &plugin("widget"),
            req(MemoryScope::Plugin("other-plugin".to_owned())),
        )
        .is_ok()
    {
        return Err("a plugin must not be authorized to write another plugin's scope".to_owned());
    }
    if store
        .write(
            &plugin("widget"),
            req(MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())),
        )
        .is_ok()
    {
        return Err(
            "a plugin must not be authorized to write a non-plugin scope without an explicit grant"
                .to_owned(),
        );
    }
    Ok(())
}

fn recall_intersects_authorized_scopes_and_enforces_budget<S: MemoryStore>(
    store: &mut S,
) -> Result<(), String> {
    // `certify()`'s sub-checks deliberately share one running `store`
    // across the whole harness (exercising realistic cross-operation state,
    // not a fresh fixture per check) -- so this check's query marker must
    // be unique among everything any other sub-check writes, or an earlier
    // check's unrelated record could accidentally match here too. Do not
    // reuse a common word like "tea" that another sub-check's content might
    // also contain.
    const MARKER: &str = "cs-mem-recall-budget-probe";
    for i in 0..3 {
        store
            .write(
                &core("companion"),
                WriteRequest {
                    scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
                    content: format!("{MARKER} fact {i}"),
                    content_type: crate::types::ContentType::TextPlain,
                    sensitive: false,
                    source: "companion".to_owned(),
                },
            )
            .map_err(|e| format!("setup write failed: {e}"))?;
    }

    let small = store
        .recall(
            &core("companion"),
            RecallRequest {
                query: MARKER.to_owned(),
                scopes: vec![MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())],
                budget: crate::types::RecallBudget {
                    max_excerpts: 2,
                    max_chars: 4000,
                },
            },
        )
        .map_err(|e| format!("recall must succeed: {e}"))?;
    if small.excerpts.len() != 2 {
        return Err(format!(
            "budget of 2 must be enforced even though 3 records match, got {}",
            small.excerpts.len()
        ));
    }
    if !small.truncated {
        return Err(
            "truncated must be true when more matches existed than the budget allowed".to_owned(),
        );
    }

    let full = store
        .recall(
            &core("companion"),
            RecallRequest {
                query: MARKER.to_owned(),
                scopes: vec![MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())],
                budget: crate::types::RecallBudget {
                    max_excerpts: 10,
                    max_chars: 4000,
                },
            },
        )
        .map_err(|e| format!("recall must succeed: {e}"))?;
    if full.excerpts.len() != 3 {
        return Err(format!(
            "expected all 3 matches under a generous budget, got {}",
            full.excerpts.len()
        ));
    }
    if full.truncated {
        return Err("truncated must be false when the budget was never hit".to_owned());
    }

    // A plugin recalling a scope it doesn't own must not see it -- silent
    // intersection, not an error, per §2.2's own wording.
    let unauthorized_intersected = store
        .recall(
            &plugin("widget"),
            RecallRequest {
                query: MARKER.to_owned(),
                scopes: vec![MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())],
                budget: crate::types::RecallBudget {
                    max_excerpts: 10,
                    max_chars: 4000,
                },
            },
        )
        .map_err(|e| format!("recall itself must not error on an unauthorized scope: {e}"))?;
    if !unauthorized_intersected.excerpts.is_empty() {
        return Err(
            "a plugin must never recall a scope it isn't authorized for (SEC-020/024)".to_owned(),
        );
    }
    Ok(())
}

fn list_rejects_an_unauthorized_scope<S: MemoryStore>(store: &mut S) -> Result<(), String> {
    let ok = store.list(
        &core("inspection-ui"),
        ListRequest {
            scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
            after: None,
            limit: 100,
        },
    );
    if ok.is_err() {
        return Err(
            "Core must be authorized to list any scope (inspection UI, MEMORY_API §2.3)".to_owned(),
        );
    }
    let denied = store.list(
        &plugin("widget"),
        ListRequest {
            scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
            after: None,
            limit: 100,
        },
    );
    if denied.is_ok() {
        return Err(
            "a plugin listing a scope it doesn't own must be Unauthorized, not silently empty"
                .to_owned(),
        );
    }
    Ok(())
}

fn delete_cascades_and_is_scoped_per_id<S: MemoryStore>(store: &mut S) -> Result<(), String> {
    let written = store
        .write(
            &core("companion"),
            WriteRequest {
                scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
                content: "to be deleted".to_owned(),
                content_type: crate::types::ContentType::TextPlain,
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .map_err(|e| format!("setup write failed: {e}"))?;

    let fake_id = uuid::Uuid::now_v7();
    let results = store.delete(&core("companion"), &[written.record_id, fake_id]);
    if results.len() != 2 {
        return Err(format!(
            "delete must return one Result per requested id, got {}",
            results.len()
        ));
    }
    if results[0].is_err() {
        return Err("deleting a real record the caller owns must succeed".to_owned());
    }
    if results[1].is_ok() {
        return Err(
            "deleting a nonexistent id must report NotFound, not silently succeed".to_owned(),
        );
    }

    let after = store.list(
        &core("companion"),
        ListRequest {
            scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
            after: None,
            limit: 100,
        },
    );
    let after = after.map_err(|e| format!("list after delete failed: {e}"))?;
    if after.records.iter().any(|r| r.id == written.record_id) {
        return Err("a deleted record must not still be listable".to_owned());
    }
    Ok(())
}

fn export_returns_only_authorized_scopes_with_a_matching_manifest<S: MemoryStore>(
    store: &mut S,
) -> Result<(), String> {
    store
        .write(
            &core("companion"),
            WriteRequest {
                scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
                content: "exportable".to_owned(),
                content_type: crate::types::ContentType::TextPlain,
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .map_err(|e| format!("setup write failed: {e}"))?;

    let exported = store
        .export(
            &core("inspection-ui"),
            ExportRequest {
                scopes: vec![MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())],
                format: "ocp-memory-export/1.0".to_owned(),
            },
        )
        .map_err(|e| format!("export by Core must succeed: {e}"))?;
    if exported.manifest.record_count != exported.records.len() {
        return Err(
            "manifest recordCount must match the actual number of exported records".to_owned(),
        );
    }
    if exported.records.is_empty() {
        return Err("export must actually return the records it counted".to_owned());
    }

    let denied = store.export(
        &plugin("widget"),
        ExportRequest {
            scopes: vec![MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned())],
            format: "ocp-memory-export/1.0".to_owned(),
        },
    );
    let denied = denied
        .map_err(|e| format!("export itself must not hard-error on an unauthorized scope: {e}"))?;
    if !denied.records.is_empty() {
        return Err("a plugin exporting a scope it doesn't own must get nothing back (intersected, same as recall)".to_owned());
    }
    Ok(())
}

fn purge_removes_every_record_in_scope_and_nothing_else<S: MemoryStore>(
    store: &mut S,
) -> Result<(), String> {
    for i in 0..2 {
        store
            .write(
                &core("companion"),
                WriteRequest {
                    scope: MemoryScope::Session,
                    content: format!("session fact {i}"),
                    content_type: crate::types::ContentType::TextPlain,
                    sensitive: false,
                    source: "companion".to_owned(),
                },
            )
            .map_err(|e| format!("setup write failed: {e}"))?;
    }
    store
        .write(
            &core("companion"),
            WriteRequest {
                scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
                content: "must survive the session purge".to_owned(),
                content_type: crate::types::ContentType::TextPlain,
                sensitive: false,
                source: "companion".to_owned(),
            },
        )
        .map_err(|e| format!("setup write failed: {e}"))?;

    let outcome = store
        .purge(
            &core("session-manager"),
            &MemoryScope::Session,
            PurgeTrigger::SessionEnd,
        )
        .map_err(|e| format!("purge by Core must succeed: {e}"))?;
    if outcome.record_count < 2 {
        return Err(format!(
            "expected at least 2 session records purged, got {}",
            outcome.record_count
        ));
    }

    let session_after = store
        .list(
            &core("session-manager"),
            ListRequest {
                scope: MemoryScope::Session,
                after: None,
                limit: 100,
            },
        )
        .map_err(|e| format!("list after purge failed: {e}"))?;
    if !session_after.records.is_empty() {
        return Err("session scope must be empty after purge".to_owned());
    }

    let companion_after = store
        .list(
            &core("companion"),
            ListRequest {
                scope: MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
                after: None,
                limit: 100,
            },
        )
        .map_err(|e| format!("list of an unrelated scope failed: {e}"))?;
    if companion_after.records.is_empty() {
        return Err(
            "purging session scope must not touch companion scope (scope isolation)".to_owned(),
        );
    }
    Ok(())
}
