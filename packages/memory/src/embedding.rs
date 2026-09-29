//! Embedding seam for semantic recall (ADR-0010: "embeddings computed through
//! the AI Router so the embedding provider is also swappable").
//!
//! Like `ProfileKeyStore`/`CredentialStore`, the real production implementation
//! (an AI-Router `Capability::Embedding` call) lives outside this crate — it is
//! injected through the [`Embedder`] trait, keeping `ocp-memory` decoupled from
//! `ocp-llm-router`. This module ships only the dependency-free
//! [`DeterministicEmbedder`], which plays the same reference-double role for
//! semantic recall that `InMemoryStore` plays for the `MemoryStore` contract:
//! it lets the recall *mechanism* (nearest-by-cosine ranking, budget, scope
//! authorization) be proven before the heavy real backend (sqlite-vec + a real
//! embedding model) exists. Real semantic quality arrives with the AI-Router
//! embedder and the sqlite-vec `vec0` index in a later slice.

use crate::types::MemoryError;

/// Turns text into a fixed-dimension embedding vector. The production impl
/// calls the AI Router (`Capability::Embedding`); the store never constructs
/// one itself, it is handed one — same injection pattern as every other
/// real-resource boundary in this crate.
pub trait Embedder {
    /// The dimensionality every vector this embedder returns must have. A
    /// store using it can size its index/column from this up front.
    fn dimensions(&self) -> usize;

    /// Embeds `text`. Errors only on a real backend failure (e.g. the AI
    /// Router being unreachable) — surfaced as `MemoryError::Backend`, never a
    /// panic. The [`DeterministicEmbedder`] never fails.
    fn embed(&self, text: &str) -> Result<Vec<f32>, MemoryError>;
}

/// A deterministic, dependency-free [`Embedder`] for tests and offline
/// reference runs: hashed bag-of-words into `dims` buckets, L2-normalized.
///
/// **Not a real semantic model** — it has no notion of synonyms — but texts
/// that share tokens get a higher cosine similarity, which is exactly enough
/// to prove the recall mechanism (that nearest-by-cosine actually ranks
/// token-overlapping records above unrelated ones), the same way
/// `InMemoryStore`'s substring-count score proved the lexical path without
/// claiming to be a real ranker. Same input always yields the same vector, so
/// tests are stable across runs.
pub struct DeterministicEmbedder {
    dims: usize,
}

impl DeterministicEmbedder {
    /// `dims` must be > 0. A few dozen buckets is plenty to keep small test
    /// vocabularies from colliding into the same dimension.
    #[must_use]
    pub fn new(dims: usize) -> Self {
        assert!(dims > 0, "an embedder must have at least one dimension");
        Self { dims }
    }
}

impl Embedder for DeterministicEmbedder {
    fn dimensions(&self) -> usize {
        self.dims
    }

    fn embed(&self, text: &str) -> Result<Vec<f32>, MemoryError> {
        let mut vector = vec![0f32; self.dims];
        for token in text
            .split(|c: char| !c.is_alphanumeric())
            .filter(|t| !t.is_empty())
        {
            // FNV-1a over the lowercased token -> a stable bucket index.
            let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
            for byte in token.to_lowercase().bytes() {
                hash ^= u64::from(byte);
                hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
            }
            let bucket = (hash % self.dims as u64) as usize;
            vector[bucket] += 1.0;
        }
        // L2-normalize so cosine similarity reduces to a dot product and every
        // non-empty text sits on the unit sphere; an empty text stays the zero
        // vector (no orientation), which `cosine_similarity` treats as
        // similar-to-nothing.
        let norm: f32 = vector.iter().map(|x| x * x).sum::<f32>().sqrt();
        if norm > 0.0 {
            for x in &mut vector {
                *x /= norm;
            }
        }
        Ok(vector)
    }
}

/// Cosine similarity of two vectors, in `[-1.0, 1.0]`. Returns `0.0` (treated
/// everywhere here as "no relationship") when the vectors differ in length or
/// either has zero magnitude — both are degenerate cases with no meaningful
/// orientation to compare, handled by returning the neutral score rather than
/// erroring or panicking.
#[must_use]
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let norm_a: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let norm_b: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm_a == 0.0 || norm_b == 0.0 {
        0.0
    } else {
        dot / (norm_a * norm_b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_embedder_is_stable_correct_dim_and_normalized() {
        let embedder = DeterministicEmbedder::new(64);
        let a = embedder.embed("the user loves mountain hiking").unwrap();
        let b = embedder.embed("the user loves mountain hiking").unwrap();
        assert_eq!(a.len(), 64, "vector must have the declared dimensionality");
        assert_eq!(a, b, "same text must always embed to the same vector");
        let norm: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!(
            (norm - 1.0).abs() < 1e-5,
            "a non-empty text must be L2-normalized to the unit sphere"
        );
    }

    #[test]
    fn empty_text_embeds_to_the_zero_vector() {
        let embedder = DeterministicEmbedder::new(16);
        let v = embedder.embed("   !!!  ").unwrap();
        assert!(
            v.iter().all(|x| *x == 0.0),
            "text with no alphanumeric tokens has no orientation"
        );
    }

    #[test]
    fn cosine_similarity_basics() {
        let v = vec![1.0, 2.0, 3.0];
        assert!(
            (cosine_similarity(&v, &v) - 1.0).abs() < 1e-6,
            "a vector is maximally similar to itself"
        );
        assert_eq!(
            cosine_similarity(&[1.0, 0.0], &[0.0, 1.0]),
            0.0,
            "orthogonal vectors have zero similarity"
        );
        assert_eq!(
            cosine_similarity(&[1.0, 0.0, 0.0], &[1.0, 0.0]),
            0.0,
            "a dimension mismatch is neutral, not a panic"
        );
        assert_eq!(
            cosine_similarity(&[0.0, 0.0], &[1.0, 1.0]),
            0.0,
            "a zero vector has no orientation"
        );
    }

    #[test]
    fn shared_tokens_raise_cosine_above_unrelated_text() {
        let embedder = DeterministicEmbedder::new(256);
        // The two "related" texts deliberately share four tokens
        // (hiking/in/the/mountains); the third shares none.
        let mountains_a = embedder.embed("I love hiking in the mountains").unwrap();
        let mountains_b = embedder
            .embed("hiking in the mountains is my hobby")
            .unwrap();
        let pizza = embedder.embed("my favorite food is pizza").unwrap();
        let related = cosine_similarity(&mountains_a, &mountains_b);
        let unrelated = cosine_similarity(&mountains_a, &pizza);
        assert!(
            related > unrelated,
            "token-overlapping texts must be more similar than unrelated ones"
        );
        assert!(
            related > 0.0,
            "four shared tokens must give a clearly positive similarity"
        );
    }
}
