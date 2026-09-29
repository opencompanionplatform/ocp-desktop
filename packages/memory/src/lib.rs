//! OCP Memory Layer (I6, MEMORY_API). "The only interface through which any
//! component writes, recalls, lists, deletes, exports, or purges memory" —
//! MEMORY_API's own opening line, enforced here as a Rust type-system fact,
//! not just a policy statement: nothing in this crate exposes a raw
//! record map, a SQL connection, or a file handle to callers. Every
//! operation goes through [`MemoryStore`], which enforces scope
//! authorization (SEC-020) and the deletion cascade (SEC-021) itself, on
//! every call, matching MEMORY_API §2's own wording exactly.
//!
//! ## Slice 1 (contract + reference implementation)
//!
//! Contract types ([`MemoryRecord`], the six operations' request/response/
//! outcome shapes), the [`MemoryStore`] trait, [`certify`] (the CS-MEM
//! swap-test harness), and [`InMemoryStore`] (the reference implementation
//! CS-MEM runs against). This mirrors I5's own first slice exactly: prove
//! the contract logic exhaustively against an in-process reference
//! implementation before building the real, heavier backend.
//!
//! ## Slice 2 (ADR-0010 real backend)
//!
//! [`SqliteStore`]: SQLite via `rusqlite`, WAL journal mode, a forced
//! checkpoint after every delete/purge (SEC-021's literal "forces a WAL
//! checkpoint" requirement). Passes the exact same [`certify`] harness as
//! `InMemoryStore` — the actual swap-test proof, not just "both compile."
//! See `sqlite_store.rs`'s own module doc for a flagged, considered
//! deviation from ADR-0010's literal "tables per scope" wording (one table
//! with a `scope` column, not four/N physical tables), and this crate's
//! shared [`ranking`] module for why both backends rank recall results
//! identically rather than each re-implementing their own scoring.
//!
//! ## Slice 3 (ADR-0012 encryption at rest)
//!
//! [`SqliteStore::open_encrypted`] / [`SqliteStore::open_profile`] open a
//! SQLCipher full-database-encrypted store (SEC-022): every page — records,
//! embeddings, summaries, and the WAL — encrypted with a per-profile
//! [`SqliteKey`] wrapped in the OS keystore via [`ProfileKeyStore`] /
//! [`OsKeystoreKeyStore`] (the same `keyring` mechanism I5 uses for provider
//! credentials, SEC-030). The plaintext `open`/`open_in_memory` constructors
//! remain for tests and for the forensic *deletion* test that must read
//! cleartext bytes — a SQLCipher build opens an unkeyed database as ordinary
//! plaintext, so those paths are unchanged. `certify()` passes identically
//! against an encrypted store: encryption does not alter the `MemoryStore`
//! contract. See `crypto.rs` for named residuals (user-passphrase upgrade;
//! zeroizing the transient PRAGMA/keystore key copies).
//!
//! ## Deliberately deferred to a later slice (named here, not hidden)
//!
//! - **Real embeddings via the AI Router** (ADR-0010) and **a real
//!   behavior-triggered summarizer pipeline**: both stores have test-only
//!   stand-ins (`attach_embedding_for_test`/`attach_summary_for_test`) so
//!   SEC-021's cascade has something real to cascade in CS-MEM, but this
//!   crate does not itself talk to the AI Router or Behavior Engine.
//! - **Automatic retention enforcement** (MEMORY_API §3: session-end
//!   expiry, `ocp.memory.record-expired`): `MemoryStore::purge` is the
//!   mechanism a scheduler calls; this crate has no internal timer, same
//!   stance every other engine in this workspace takes (e.g.
//!   `ActivityContextEngine::mark_unknown`, I11).
//!
//! ## Vector search (ADR-0010), slices 1–2
//!
//! **Slice 1** proved the recall mechanism on the reference [`InMemoryStore`]:
//! an [`Embedder`] seam (the real impl is an AI-Router `Capability::Embedding`
//! call, injected — this crate ships only [`DeterministicEmbedder`]), a shared
//! cosine ranker (`ranking::vector_rank_and_budget`, budgeted and
//! scope-authorized identically to lexical recall), and
//! `InMemoryStore::recall_by_vector`.
//!
//! **Slice 2** backs [`SqliteStore`] with real sqlite-vec: its
//! `attach_embedding` stores each vector as a `vec_f32` float32 blob, and
//! `recall_by_vector` ranks by `vec_distance_cosine` **in SQL**, then reuses
//! the same `ranking::apply_budget` and `<= 0`-similarity drop as the
//! in-memory path (so the two backends recall the same records). The one
//! `unsafe` needed to register sqlite-vec lives in its own crate
//! `ocp-sqlite-vec` (safe `register()`, called from every `SqliteStore` open),
//! keeping this crate `#![forbid(unsafe_code)]` — the `os-sensors` boundary
//! pattern. Spike-proven to build + register + rank on Windows ARM64 +
//! SQLCipher before wiring in.
//!
//! **Still deferred** (named, not hidden): the sqlite-vec `vec0` ANN *index*
//! as a performance optimization over the current brute-force
//! `vec_distance_cosine` scan (ADR-0010: brute force is adequate for
//! personal-scale memory); the real AI-Router embedder; and promoting
//! `recall_by_vector`/`attach_embedding` to the `MemoryStore` trait so
//! `certify()` covers both backends in one harness (a content-level parity
//! test stands in until then). Lexical `recall` is unchanged; `certify()`
//! still never asserts a specific order.

#![forbid(unsafe_code)] // SEC-042 -- rusqlite's own FFI/unsafe lives inside
                        // that dependency, same as `wasmtime`/`ureq`/
                        // `keyring` elsewhere in this workspace; this
                        // crate's own code stays unsafe-free.

mod crypto;
mod embedding;
mod in_memory;
mod ranking;
mod sqlite_store;
mod store;
mod types;

pub use crypto::{InMemoryKeyStore, OsKeystoreKeyStore, ProfileKeyStore, SqliteKey};
pub use embedding::{cosine_similarity, DeterministicEmbedder, Embedder};
pub use in_memory::InMemoryStore;
pub use sqlite_store::SqliteStore;
pub use store::{certify, MemoryStore};
pub use types::{
    Caller, CascadeCounts, ContentType, DeleteOutcome, Excerpt, ExportManifest, ExportRequest,
    ExportResponse, ListRequest, ListResponse, MemoryError, MemoryRecord, MemoryScope,
    PurgeOutcome, PurgeTrigger, RecallBudget, RecallRequest, RecallResponse, WriteOutcome,
    WriteRequest, DEFAULT_COMPANION_ID,
};
