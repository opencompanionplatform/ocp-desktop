//! Shared recall ranking/budget logic (MEMORY_API §2.2), factored out so
//! every `MemoryStore` backend applies the *identical* ranking and budget
//! behavior once a backend has fetched its own authorized, scope-filtered
//! candidate records — only the fetch itself (a `HashMap` scan for
//! `InMemoryStore`, a SQL query for `SqliteStore`) is backend-specific.
//! Keeping this in one place is what actually makes `certify()` a
//! meaningful swap test for recall: two backends re-implementing their own
//! scoring independently could quietly drift apart in ways CS-MEM's
//! contract-level assertions wouldn't catch.

use std::cmp::Ordering;

use crate::embedding::cosine_similarity;
use crate::types::{Excerpt, MemoryRecord, RecallBudget, RecallResponse};

/// Deliberately a simple lexical relevance score (substring-occurrence
/// count), not a ranking claim: MEMORY_API §2.2 requires *ranking*, not any
/// specific algorithm — the embedding-backed score in [`vector_rank_and_budget`]
/// legitimately ranks differently. `certify()`'s own recall check asserts
/// counts and the `truncated` flag, never a specific order, for exactly this
/// reason.
#[must_use]
pub fn rank_and_budget(
    records: Vec<MemoryRecord>,
    query: &str,
    budget: &RecallBudget,
) -> RecallResponse {
    let query_lower = query.to_lowercase();

    let mut candidates: Vec<(MemoryRecord, f64)> = records
        .into_iter()
        .filter_map(|r| {
            let occurrences = r.content.to_lowercase().matches(&query_lower).count();
            if occurrences == 0 && !query_lower.is_empty() {
                None
            } else {
                Some((r, occurrences as f64 + 1.0))
            }
        })
        .collect();
    sort_best_first(&mut candidates);
    apply_budget(candidates, budget)
}

/// Semantic recall (MEMORY_API §2.2 ranking, ADR-0010 vector search): rank the
/// candidate records by cosine similarity of their stored embedding vector to
/// the query embedding, then apply the *identical* budget as lexical recall.
/// Records whose similarity is `<= 0` (orthogonal or opposite — no shared
/// signal with the query) are dropped, mirroring lexical recall dropping
/// zero-occurrence records, so an unrelated query returns nothing rather than
/// padding results with noise.
///
/// The score attached to each `Excerpt` here is the cosine similarity in
/// `[0.0, 1.0]`, not a lexical count — callers already treat `Excerpt::score`
/// as opaque relevance (see `certify()`, which never asserts a specific
/// value), so this stays contract-compatible with lexical recall.
#[must_use]
pub fn vector_rank_and_budget(
    scored: Vec<(MemoryRecord, Vec<f32>)>,
    query_embedding: &[f32],
    budget: &RecallBudget,
) -> RecallResponse {
    let mut candidates: Vec<(MemoryRecord, f64)> = scored
        .into_iter()
        .filter_map(|(record, vector)| {
            let similarity = f64::from(cosine_similarity(&vector, query_embedding));
            if similarity > 0.0 {
                Some((record, similarity))
            } else {
                None
            }
        })
        .collect();
    sort_best_first(&mut candidates);
    apply_budget(candidates, budget)
}

/// Highest score first, ties broken by record id for determinism across
/// repeated calls — the same discipline as every other arbitration in this
/// workspace (Behavior Engine rule arbitration, Activity Context interpreter
/// tie-break).
fn sort_best_first(candidates: &mut [(MemoryRecord, f64)]) {
    candidates.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.0.id.cmp(&b.0.id))
    });
}

/// Emit excerpts from already-ranked candidates until `max_excerpts` or
/// `max_chars` is reached, setting `truncated` accordingly. Shared by lexical
/// recall, in-memory vector recall, and `SqliteStore`'s sqlite-vec recall so
/// all paths budget identically — the same reason ranking lives in this one
/// module at all. `pub(crate)` so `SqliteStore`, which does its cosine ranking
/// in SQL (`vec_distance_cosine`) and arrives with candidates already sorted
/// best-first, can reuse the exact same budgeting.
pub(crate) fn apply_budget(
    candidates: Vec<(MemoryRecord, f64)>,
    budget: &RecallBudget,
) -> RecallResponse {
    let mut excerpts = Vec::new();
    let mut chars_used = 0usize;
    let mut truncated = false;
    for (record, score) in candidates {
        if excerpts.len() >= budget.max_excerpts {
            truncated = true;
            break;
        }
        if chars_used + record.content.len() > budget.max_chars {
            truncated = true;
            break;
        }
        chars_used += record.content.len();
        excerpts.push(Excerpt {
            record_id: record.id,
            scope: record.scope,
            excerpt: record.content,
            sensitive: record.sensitive,
            score,
        });
    }
    RecallResponse {
        excerpts,
        truncated,
    }
}
