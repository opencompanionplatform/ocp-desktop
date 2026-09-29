//! `InMemoryStore` — the reference `MemoryStore` implementation for this
//! slice, same role `LocalEchoAdapter`/`ScriptedAdapter` played for I5 and
//! `runtime-stub::StubRuntime` played for I2: proves the contract logic
//! (scope authorization, budget enforcement, deletion cascade, retention
//! structure) exhaustively before a real, heavier backend (SQLite +
//! SQLCipher, ADR-0010/0012) exists. Not itself the ADR-0010 default —
//! that is the next slice.

use std::collections::HashMap;

use chrono::Utc;
use uuid::Uuid;

use crate::store::MemoryStore;
use crate::types::{
    Caller, CascadeCounts, ContentType, DeleteOutcome, ExportManifest, ExportRequest,
    ExportResponse, ListRequest, ListResponse, MemoryError, MemoryRecord, MemoryScope,
    PurgeOutcome, PurgeTrigger, RecallBudget, RecallRequest, RecallResponse, WriteOutcome,
    WriteRequest, DEFAULT_COMPANION_ID,
};

#[derive(Default)]
pub struct InMemoryStore {
    records: HashMap<Uuid, MemoryRecord>,
    /// record id -> embedding ref ids derived from it (SEC-021 cascade
    /// bookkeeping). Real embeddings come from the AI Router in a later
    /// slice; see `attach_embedding_for_test`.
    embeddings_of: HashMap<Uuid, Vec<String>>,
    /// record id -> its embedding vector, for semantic recall
    /// (`recall_by_vector`, ADR-0010 vector search). Populated by
    /// [`attach_embedding`](Self::attach_embedding); in production the vector
    /// comes from the AI Router (`Embedder`), here from any `Embedder`
    /// (the `DeterministicEmbedder` in tests). Cascade-deleted with its record
    /// (SEC-021) exactly like the ref bookkeeping above.
    embedding_vectors: HashMap<Uuid, Vec<f32>>,
    /// record id -> summary record ids derived from it. Real summaries
    /// come from a behavior-triggered summarizer pipeline in a later
    /// slice (ADR-0010: "not a hidden background process"); see
    /// `attach_summary_for_test`.
    summaries_of: HashMap<Uuid, Vec<Uuid>>,
}

impl InMemoryStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// **Test/demo-only, not part of the `MemoryStore` contract.** Stands
    /// in for the real AI-Router-driven embedding pipeline (MEMORY_API
    /// §2.1: "schedules embedding via the AI Router"), not implemented in
    /// this slice, so SEC-021 cascade-delete has a real derived artifact to
    /// cascade rather than only ever counting zero.
    pub fn attach_embedding_for_test(&mut self, record_id: Uuid) -> String {
        let embedding_ref = format!("emb-{}", Uuid::now_v7());
        self.embeddings_of
            .entry(record_id)
            .or_default()
            .push(embedding_ref.clone());
        if let Some(r) = self.records.get_mut(&record_id) {
            r.embedding_ref = Some(embedding_ref.clone());
        }
        embedding_ref
    }

    /// Attaches a real embedding `vector` to an existing record, enabling it
    /// to be found by [`recall_by_vector`](Self::recall_by_vector). In
    /// production a background task computes the vector via the AI Router
    /// ([`Embedder`](crate::Embedder), MEMORY_API §2.1: "schedules embedding
    /// via the AI Router" — never blocking `write`); tests attach a
    /// deterministic vector directly. No-op if the record doesn't exist. The
    /// vector is cascade-deleted with its record (SEC-021).
    ///
    /// Unlike `attach_embedding_for_test` (which only registers a ref-id for
    /// cascade *counting*), this stores the actual vector used for ranking.
    pub fn attach_embedding(&mut self, record_id: Uuid, vector: &[f32]) -> Result<(), MemoryError> {
        if self.records.contains_key(&record_id) {
            self.embedding_vectors.insert(record_id, vector.to_vec());
        }
        Ok(()) // never fails in-memory; `Result` matches SqliteStore for the eventual trait
    }

    /// **ADR-0010 vector search.** Semantic recall: rank the caller's
    /// authorized, embedded records by cosine similarity to `query_embedding`
    /// and return excerpts within `budget`. Scope authorization (SEC-020) and
    /// budgeting are identical to lexical [`recall`](MemoryStore::recall);
    /// only records that actually have an attached vector participate. Kept an
    /// inherent method this slice (reference implementation), to be promoted
    /// to the `MemoryStore` trait alongside the `SqliteStore` + sqlite-vec
    /// backing in a later slice.
    pub fn recall_by_vector(
        &mut self,
        caller: &Caller,
        scopes: &[MemoryScope],
        query_embedding: &[f32],
        budget: &RecallBudget,
    ) -> RecallResponse {
        let authorized: Vec<&MemoryScope> = scopes.iter().filter(|s| caller.can_read(s)).collect();
        // Explicit loop over two disjoint fields of `self` (records + vectors)
        // — simpler for the borrow checker than a chained closure, and only
        // records that are both scope-authorized and actually embedded
        // participate.
        let mut scored: Vec<(MemoryRecord, Vec<f32>)> = Vec::new();
        for record in self.records.values() {
            if authorized.contains(&&record.scope) {
                if let Some(vector) = self.embedding_vectors.get(&record.id) {
                    scored.push((record.clone(), vector.clone()));
                }
            }
        }
        crate::ranking::vector_rank_and_budget(scored, query_embedding, budget)
    }

    /// **Test/demo-only, not part of the `MemoryStore` contract.** Stands
    /// in for the real behavior-triggered summarizer pipeline, not
    /// implemented in this slice.
    pub fn attach_summary_for_test(
        &mut self,
        source_record_id: Uuid,
        summary_content: &str,
    ) -> Uuid {
        let scope = self.records.get(&source_record_id).map_or_else(
            || MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()),
            |r| r.scope.clone(),
        );
        let summary = MemoryRecord {
            id: Uuid::now_v7(),
            scope,
            content: summary_content.to_owned(),
            content_type: ContentType::TextPlain,
            embedding_ref: None,
            sensitive: false,
            created_at: Utc::now(),
            source: "summarizer".to_owned(),
        };
        let id = summary.id;
        self.records.insert(id, summary);
        self.summaries_of
            .entry(source_record_id)
            .or_default()
            .push(id);
        id
    }

    fn delete_one(&mut self, caller: &Caller, id: Uuid) -> Result<DeleteOutcome, MemoryError> {
        let Some(record) = self.records.get(&id) else {
            return Err(MemoryError::NotFound { record_id: id });
        };
        if !caller.can_delete(&record.scope) {
            return Err(MemoryError::Unauthorized {
                requester: caller.requester_id(),
                scope: record.scope.clone(),
                op: "delete",
            });
        }
        let scope = record.scope.clone();
        self.records.remove(&id);
        self.embedding_vectors.remove(&id); // SEC-021: the ranking vector goes too
        let embeddings = self.embeddings_of.remove(&id).map_or(0, |v| v.len());
        let summary_ids = self.summaries_of.remove(&id).unwrap_or_default();
        for sid in &summary_ids {
            self.records.remove(sid);
        }
        Ok(DeleteOutcome {
            record_id: id,
            scope,
            cascaded: CascadeCounts {
                embeddings,
                summaries: summary_ids.len(),
            },
        })
    }
}

impl MemoryStore for InMemoryStore {
    fn write(&mut self, caller: &Caller, req: WriteRequest) -> Result<WriteOutcome, MemoryError> {
        if !caller.can_write(&req.scope) {
            return Err(MemoryError::Unauthorized {
                requester: caller.requester_id(),
                scope: req.scope,
                op: "write",
            });
        }
        if req.content.is_empty() {
            return Err(MemoryError::EmptyContent);
        }
        // MEMORY_API §1: "all user-profile scope records are sensitive by
        // default" -- ORed in, never overridden down by the request.
        let sensitive = req.sensitive || matches!(req.scope, MemoryScope::UserProfile);
        let record = MemoryRecord {
            id: Uuid::now_v7(),
            scope: req.scope,
            content: req.content,
            content_type: req.content_type,
            embedding_ref: None,
            sensitive,
            created_at: Utc::now(),
            source: req.source.clone(),
        };
        let outcome = WriteOutcome {
            record_id: record.id,
            scope: record.scope.clone(),
            sensitive,
            written_by: req.source,
        };
        self.records.insert(record.id, record);
        Ok(outcome)
    }

    fn recall(
        &mut self,
        caller: &Caller,
        req: RecallRequest,
    ) -> Result<RecallResponse, MemoryError> {
        let authorized_scopes: Vec<MemoryScope> = req
            .scopes
            .into_iter()
            .filter(|s| caller.can_read(s))
            .collect();
        let candidates: Vec<MemoryRecord> = self
            .records
            .values()
            .filter(|r| authorized_scopes.contains(&r.scope))
            .cloned()
            .collect();
        Ok(crate::ranking::rank_and_budget(
            candidates,
            &req.query,
            &req.budget,
        ))
    }

    fn list(&mut self, caller: &Caller, req: ListRequest) -> Result<ListResponse, MemoryError> {
        if !caller.can_read(&req.scope) {
            return Err(MemoryError::Unauthorized {
                requester: caller.requester_id(),
                scope: req.scope,
                op: "list",
            });
        }
        let mut matching: Vec<&MemoryRecord> = self
            .records
            .values()
            .filter(|r| r.scope == req.scope)
            .collect();
        matching.sort_by_key(|a| a.id);

        let start = match &req.after {
            Some(after_id) => matching
                .iter()
                .position(|r| r.id == *after_id)
                .map_or(0, |i| i + 1),
            None => 0,
        };
        let page: Vec<MemoryRecord> = matching
            .into_iter()
            .skip(start)
            .take(req.limit)
            .cloned()
            .collect();
        let next_after = if page.len() == req.limit {
            page.last().map(|r| r.id)
        } else {
            None
        };
        Ok(ListResponse {
            records: page,
            next_after,
        })
    }

    fn delete(
        &mut self,
        caller: &Caller,
        record_ids: &[Uuid],
    ) -> Vec<Result<DeleteOutcome, MemoryError>> {
        record_ids
            .iter()
            .map(|id| self.delete_one(caller, *id))
            .collect()
    }

    fn export(
        &mut self,
        caller: &Caller,
        req: ExportRequest,
    ) -> Result<ExportResponse, MemoryError> {
        let authorized_scopes: Vec<MemoryScope> = req
            .scopes
            .into_iter()
            .filter(|s| caller.can_read(s))
            .collect();
        let mut records: Vec<MemoryRecord> = self
            .records
            .values()
            .filter(|r| authorized_scopes.contains(&r.scope))
            .cloned()
            .collect();
        records.sort_by_key(|a| a.id);
        let manifest = ExportManifest {
            format: req.format,
            scopes: authorized_scopes,
            record_count: records.len(),
            exported_at: Utc::now(),
        };
        Ok(ExportResponse { manifest, records })
    }

    fn purge(
        &mut self,
        caller: &Caller,
        scope: &MemoryScope,
        trigger: PurgeTrigger,
    ) -> Result<PurgeOutcome, MemoryError> {
        if !caller.can_delete(scope) {
            return Err(MemoryError::Unauthorized {
                requester: caller.requester_id(),
                scope: scope.clone(),
                op: "purge",
            });
        }
        let ids: Vec<Uuid> = self
            .records
            .values()
            .filter(|r| &r.scope == scope)
            .map(|r| r.id)
            .collect();
        let mut embeddings_total = 0;
        let mut summaries_total = 0;
        for id in &ids {
            self.records.remove(id);
            self.embedding_vectors.remove(id); // SEC-021: purge the ranking vector too
            embeddings_total += self.embeddings_of.remove(id).map_or(0, |v| v.len());
            if let Some(summary_ids) = self.summaries_of.remove(id) {
                summaries_total += summary_ids.len();
                for sid in &summary_ids {
                    self.records.remove(sid);
                }
            }
        }
        Ok(PurgeOutcome {
            scope: scope.clone(),
            trigger,
            record_count: ids.len(),
            cascaded: CascadeCounts {
                embeddings: embeddings_total,
                summaries: summaries_total,
            },
        })
    }
}
