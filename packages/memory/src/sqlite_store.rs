//! `SqliteStore` — the ADR-0010 default `MemoryStore` backend: SQLite via
//! `rusqlite`, one connection per open store (ADR-0010: "one database file
//! per companion profile"). Same `MemoryStore` contract `InMemoryStore`
//! implements — `certify()` runs against both.
//!
//! **A considered deviation from ADR-0010's literal wording, flagged for
//! review rather than assumed**: the ADR says "tables per scope (session /
//! companion / user-profile / plugin:<id>)", which read as four separate
//! physical SQL tables would require either enumerating an unbounded,
//! dynamically-arriving set of `plugin:<id>` tables (fragile dynamic DDL,
//! and a real SQL-injection surface if a table name were ever built from a
//! plugin id string) or a fifth shared table for plugin scopes anyway. This
//! implementation instead uses **one `records` table with a `scope` TEXT
//! column**, indexed. SEC-020's actual requirement — "scope enforcement in
//! the Memory Layer, not in callers" — is satisfied identically either way:
//! every query here is scope-filtered by this crate's own Rust code
//! (`Caller::can_read`/`can_write`/`can_delete`), never delegated to SQL
//! grants or table boundaries. A single table also keeps record ids
//! globally unique and lookups (`delete` by id alone) simple, without a
//! per-scope-table id-ambiguity problem four separate tables would
//! introduce. If a future review prefers literal per-scope tables, this
//! module is the only place that would need to change — the `MemoryStore`
//! trait and every caller are unaffected either way.
//!
//! **ADR-0012 (SQLCipher-class encryption at rest) is implemented** as of the
//! I6 encryption slice: [`SqliteStore::open_encrypted`] and
//! [`SqliteStore::open_profile`] open a full-database-encrypted store, every
//! page (records, embeddings, summaries, and the WAL) encrypted by SQLCipher
//! with a per-profile key wrapped in the OS keystore (see `crypto.rs`). The
//! plaintext [`open`](SqliteStore::open) / [`open_in_memory`](
//! SqliteStore::open_in_memory) constructors remain for tests and for
//! callers that explicitly do not want encryption (e.g. the forensic
//! *deletion* test, which must read cleartext bytes to prove deletion) — a
//! SQLCipher-compiled SQLite still opens an unkeyed database as ordinary
//! plaintext SQLite, so those paths are unchanged. **Do not use the plaintext
//! constructors for real user data** — use `open_profile`.

use chrono::{DateTime, Utc};
use rusqlite::OptionalExtension;
use uuid::Uuid;

use crate::crypto::{ProfileKeyStore, SqliteKey};
use crate::store::MemoryStore;
use crate::types::{
    Caller, CascadeCounts, ContentType, DeleteOutcome, ExportManifest, ExportRequest,
    ExportResponse, ListRequest, ListResponse, MemoryError, MemoryRecord, MemoryScope,
    PurgeOutcome, PurgeTrigger, RecallBudget, RecallRequest, RecallResponse, WriteOutcome,
    WriteRequest, DEFAULT_COMPANION_ID,
};

const SCHEMA_SQL: &str = "
CREATE TABLE IF NOT EXISTS records (
    id TEXT PRIMARY KEY,
    scope TEXT NOT NULL,
    content TEXT NOT NULL,
    content_type TEXT NOT NULL,
    embedding_ref TEXT,
    sensitive INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    source TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_records_scope ON records(scope);
CREATE TABLE IF NOT EXISTS embeddings (
    ref_id TEXT PRIMARY KEY,
    record_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_embeddings_record ON embeddings(record_id);
CREATE TABLE IF NOT EXISTS summary_links (
    summary_record_id TEXT PRIMARY KEY,
    source_record_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_summary_links_source ON summary_links(source_record_id);
-- ADR-0010 vector search: one embedding vector per record, stored as a
-- sqlite-vec float32 blob (`vec_f32(json)`). Cascade-deleted with its record
-- (SEC-021). Ranking is done by `vec_distance_cosine` in SQL, not here.
CREATE TABLE IF NOT EXISTS embedding_vectors (
    record_id TEXT PRIMARY KEY,
    embedding BLOB NOT NULL
);
";

pub struct SqliteStore {
    conn: rusqlite::Connection,
}

impl SqliteStore {
    /// Opens (creating if absent) a real on-disk **plaintext** database file.
    /// Kept for tests and for callers that explicitly do not want encryption
    /// (notably the forensic *deletion* test, which must read cleartext bytes
    /// to prove content is gone). **Not for real user data** — use
    /// [`open_profile`](Self::open_profile).
    pub fn open(path: &std::path::Path) -> Result<Self, MemoryError> {
        ocp_sqlite_vec::register();
        let conn = rusqlite::Connection::open(path).map_err(sqlite_err)?;
        Self::init(conn, None)
    }

    /// For tests: no file, no WAL (SQLite silently keeps `:memory:`
    /// databases on its in-memory journal mode regardless of the
    /// `journal_mode=WAL` pragma below — harmless, just not meaningful for
    /// an in-memory database).
    pub fn open_in_memory() -> Result<Self, MemoryError> {
        ocp_sqlite_vec::register();
        let conn = rusqlite::Connection::open_in_memory().map_err(sqlite_err)?;
        Self::init(conn, None)
    }

    /// **ADR-0012**: opens (creating if absent) a full-database-encrypted
    /// store using an explicit [`SqliteKey`]. Every page — records,
    /// embeddings, summaries, and the WAL — is SQLCipher-encrypted with this
    /// key; vector search (ADR-0010, a later slice) still operates on pages
    /// decrypted in memory, unaffected. Opening an existing store with the
    /// wrong key, or a plaintext file as encrypted, fails cleanly here rather
    /// than deep in a later query (see `init`'s eager key-check).
    ///
    /// Most callers should prefer [`open_profile`](Self::open_profile), which
    /// sources the key from the OS keystore per ADR-0012 rather than requiring
    /// the caller to hold raw key material. This lower-level entry point
    /// exists for tests and for callers managing key custody themselves.
    pub fn open_encrypted(path: &std::path::Path, key: &SqliteKey) -> Result<Self, MemoryError> {
        ocp_sqlite_vec::register();
        let conn = rusqlite::Connection::open(path).map_err(sqlite_err)?;
        Self::init(conn, Some(key))
    }

    /// **ADR-0012, the intended production entry point**: opens the encrypted
    /// store for `profile_id`, sourcing its per-profile database key from the
    /// OS keystore via `key_store`. If the profile has no key yet (first
    /// open = profile creation), a fresh random key is generated and stored
    /// before the database is opened with it — exactly ADR-0012's "a random
    /// per-profile database key is generated at profile creation and wrapped
    /// by the OS keystore." The plaintext key never leaves
    /// [`SqliteKey`](crate::SqliteKey)'s zeroized custody.
    pub fn open_profile(
        path: &std::path::Path,
        profile_id: &str,
        key_store: &mut dyn ProfileKeyStore,
    ) -> Result<Self, MemoryError> {
        let key = match key_store.load(profile_id)? {
            Some(key) => key,
            None => {
                let key = SqliteKey::generate()?;
                key_store.store(profile_id, &key)?;
                key
            }
        };
        Self::open_encrypted(path, &key)
    }

    fn init(conn: rusqlite::Connection, key: Option<&SqliteKey>) -> Result<Self, MemoryError> {
        if let Some(key) = key {
            // ADR-0012 / SQLCipher: `PRAGMA key` MUST be the very first
            // statement executed on the connection, before any other pragma
            // or query touches a page. The raw-key form `x'<64 hex>'` skips
            // SQLCipher's PBKDF2 (we already hold 256 bits of real CSPRNG key
            // material, not a passphrase to stretch).
            conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", key.to_hex()))
                .map_err(sqlite_err)?;
            // SQLCipher validates the key lazily — only on the first real page
            // read, never at PRAGMA-key time. Force that read now so a wrong
            // key (or opening a plaintext file as encrypted, or vice-versa)
            // surfaces here as one clean, attributable error instead of
            // erupting deep inside an unrelated later query.
            conn.query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(())).map_err(|_| {
                MemoryError::Backend(
                    "cannot open encrypted memory store: wrong key, or the file is not a SQLCipher database (ADR-0012)"
                        .to_owned(),
                )
            })?;
        }
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(sqlite_err)?;
        // SEC-021: without this, SQLite's DELETE only unlinks a row from
        // its page's free-list -- it does NOT zero the row's old bytes, so
        // deleted content silently keeps existing on disk until something
        // else happens to overwrite that page later (this is *the* classic
        // "recovering deleted rows from a SQLite file" technique). Found by
        // the forensic deletion test itself failing on first run, not
        // assumed in advance: the WAL-checkpoint requirement in MEMORY_API
        // §2.4 stops the deleted content from lingering in the WAL, but
        // says nothing about the main file's freed-but-unzeroed page, which
        // secure_delete is what actually addresses.
        conn.execute_batch("PRAGMA secure_delete=ON;")
            .map_err(sqlite_err)?;
        conn.execute_batch(SCHEMA_SQL).map_err(sqlite_err)?;
        Ok(Self { conn })
    }

    /// **Test-only.** Forces a WAL checkpoint outside of a delete/purge
    /// call, so a test can establish a deterministic on-disk baseline
    /// before exercising deletion (a fresh write may otherwise still be
    /// sitting only in the WAL, not yet in the main DB file).
    pub fn checkpoint_for_test(&self) -> Result<(), MemoryError> {
        checkpoint(&self.conn)
    }

    /// **Test/demo-only, not part of the `MemoryStore` contract** — same
    /// role as `InMemoryStore`'s identically-named method; stands in for
    /// the real AI-Router-driven embedding pipeline, not implemented here.
    pub fn attach_embedding_for_test(&mut self, record_id: Uuid) -> Result<String, MemoryError> {
        let embedding_ref = format!("emb-{}", Uuid::now_v7());
        let id_str = record_id.to_string();
        self.conn
            .execute(
                "INSERT INTO embeddings (ref_id, record_id) VALUES (?1, ?2)",
                rusqlite::params![embedding_ref, id_str],
            )
            .map_err(sqlite_err)?;
        self.conn
            .execute(
                "UPDATE records SET embedding_ref = ?1 WHERE id = ?2",
                rusqlite::params![embedding_ref, id_str],
            )
            .map_err(sqlite_err)?;
        Ok(embedding_ref)
    }

    /// **Test/demo-only, not part of the `MemoryStore` contract.** Stands
    /// in for a real behavior-triggered summarizer pipeline.
    pub fn attach_summary_for_test(
        &mut self,
        source_record_id: Uuid,
        summary_content: &str,
    ) -> Result<Uuid, MemoryError> {
        let source_id_str = source_record_id.to_string();
        let scope_str: Option<String> = self
            .conn
            .query_row(
                "SELECT scope FROM records WHERE id = ?1",
                rusqlite::params![source_id_str],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_err)?;
        let scope_str = scope_str.unwrap_or_else(|| {
            MemoryScope::Companion(DEFAULT_COMPANION_ID.to_owned()).as_wire_string()
        });

        let id = Uuid::now_v7();
        self.conn
            .execute(
                "INSERT INTO records (id, scope, content, content_type, embedding_ref, sensitive, created_at, source) \
                 VALUES (?1, ?2, ?3, ?4, NULL, 0, ?5, 'summarizer')",
                rusqlite::params![id.to_string(), scope_str, summary_content, ContentType::TextPlain.as_str(), Utc::now().to_rfc3339()],
            )
            .map_err(sqlite_err)?;
        self.conn
            .execute(
                "INSERT INTO summary_links (summary_record_id, source_record_id) VALUES (?1, ?2)",
                rusqlite::params![id.to_string(), source_id_str],
            )
            .map_err(sqlite_err)?;
        Ok(id)
    }

    /// **ADR-0010 vector search.** Attaches a real embedding `vector` to an
    /// existing record, stored as a sqlite-vec `vec_f32` float32 blob so
    /// [`recall_by_vector`](Self::recall_by_vector) can rank by cosine
    /// distance in SQL. No-op if the record doesn't exist (parity with
    /// `InMemoryStore::attach_embedding`). Cascade-deleted with its record
    /// (SEC-021). In production the vector comes from the AI Router
    /// ([`Embedder`](crate::Embedder)); tests attach a deterministic one.
    pub fn attach_embedding(&mut self, record_id: Uuid, vector: &[f32]) -> Result<(), MemoryError> {
        let id_str = record_id.to_string();
        let exists: Option<i64> = self
            .conn
            .query_row(
                "SELECT 1 FROM records WHERE id = ?1",
                rusqlite::params![id_str],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_err)?;
        if exists.is_none() {
            return Ok(());
        }
        self.conn
            .execute(
                "INSERT OR REPLACE INTO embedding_vectors (record_id, embedding) VALUES (?1, vec_f32(?2))",
                rusqlite::params![id_str, vector_to_json(vector)],
            )
            .map_err(sqlite_err)?;
        Ok(())
    }

    /// **ADR-0010 vector search**, the sqlite-vec-backed twin of
    /// `InMemoryStore::recall_by_vector`. Ranks the caller's authorized,
    /// embedded records by cosine similarity to `query_embedding` — the
    /// ranking is done in SQL via sqlite-vec's `vec_distance_cosine` (smaller
    /// distance = nearer) — then applies the *identical* shared budget
    /// (`ranking::apply_budget`) as every other recall path. Records whose
    /// cosine distance is `>= 1.0` (similarity `<= 0`, no shared signal) are
    /// dropped, exactly matching the in-memory path's `> 0` filter, so the two
    /// backends agree on which records a query recalls. Kept an inherent
    /// method this slice (to be promoted to the `MemoryStore` trait alongside
    /// its in-memory twin in a small follow-up).
    pub fn recall_by_vector(
        &mut self,
        caller: &Caller,
        scopes: &[MemoryScope],
        query_embedding: &[f32],
        budget: &RecallBudget,
    ) -> Result<RecallResponse, MemoryError> {
        // Only the requested scopes the caller may actually read (SEC-020) —
        // identical to `InMemoryStore::recall_by_vector`, so the two backends
        // agree on which records a scoped query returns, not just on ranking.
        let authorized: Vec<&MemoryScope> = scopes
            .iter()
            .filter(|scope| caller.can_read(scope))
            .collect();
        if authorized.is_empty() {
            return Ok(RecallResponse {
                excerpts: Vec::new(),
                truncated: false,
            });
        }
        let query_json = vector_to_json(query_embedding);
        // Rank every embedded record by cosine distance in SQL. Scope
        // authorization and the `< 1.0` (similarity > 0) filter are applied in
        // Rust below — cheap at personal scale (ADR-0010) and it keeps this one
        // parameter (`?1`) the only bind, avoiding dynamic scope placeholders.
        let sql = "SELECT r.id, r.scope, r.content, r.content_type, r.embedding_ref, r.sensitive, r.created_at, \
                   r.source, vec_distance_cosine(ev.embedding, vec_f32(?1)) AS distance \
                   FROM embedding_vectors ev JOIN records r ON r.id = ev.record_id ORDER BY distance ASC";
        let mut stmt = self.conn.prepare(sql).map_err(sqlite_err)?;
        let rows = stmt
            .query_map(rusqlite::params![query_json], |row| {
                let raw = RawRow {
                    id: row.get(0)?,
                    scope: row.get(1)?,
                    content: row.get(2)?,
                    content_type: row.get(3)?,
                    embedding_ref: row.get(4)?,
                    sensitive: row.get(5)?,
                    created_at: row.get(6)?,
                    source: row.get(7)?,
                };
                let distance: f64 = row.get(8)?;
                Ok((raw, distance))
            })
            .map_err(sqlite_err)?;

        // Candidates arrive already sorted best-first (distance ASC = cosine
        // similarity DESC); scope-filter and drop the orthogonal-or-worse ones,
        // preserving that order, then hand off to the shared budgeter.
        let mut candidates: Vec<(MemoryRecord, f64)> = Vec::new();
        for row in rows {
            let (raw, distance) = row.map_err(sqlite_err)?;
            if distance >= 1.0 {
                continue; // cosine similarity <= 0: no shared signal, dropped
            }
            let record = raw_to_record(raw)?;
            if authorized.contains(&&record.scope) {
                candidates.push((record, 1.0 - distance));
            }
        }
        Ok(crate::ranking::apply_budget(candidates, budget))
    }

    fn delete_one(&mut self, caller: &Caller, id: Uuid) -> Result<DeleteOutcome, MemoryError> {
        let id_str = id.to_string();
        let raws = query_raw_rows(
            &self.conn,
            SELECT_RECORD_COLUMNS_WHERE_ID,
            rusqlite::params![id_str],
        )?;
        let Some(raw) = raws.into_iter().next() else {
            return Err(MemoryError::NotFound { record_id: id });
        };
        let scope = MemoryScope::parse(&raw.scope)
            .ok_or_else(|| MemoryError::Backend(format!("corrupt scope: {}", raw.scope)))?;
        if !caller.can_delete(&scope) {
            return Err(MemoryError::Unauthorized {
                requester: caller.requester_id(),
                scope,
                op: "delete",
            });
        }

        let tx = self.conn.transaction().map_err(sqlite_err)?;
        let embeddings = tx
            .execute(
                "DELETE FROM embeddings WHERE record_id = ?1",
                rusqlite::params![id_str],
            )
            .map_err(sqlite_err)?;
        let summary_ids: Vec<String> = {
            let mut stmt = tx
                .prepare("SELECT summary_record_id FROM summary_links WHERE source_record_id = ?1")
                .map_err(sqlite_err)?;
            let rows = stmt
                .query_map(rusqlite::params![id_str], |row| row.get::<_, String>(0))
                .map_err(sqlite_err)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(sqlite_err)?
        };
        for sid in &summary_ids {
            tx.execute(
                "DELETE FROM records WHERE id = ?1",
                rusqlite::params![sid.as_str()],
            )
            .map_err(sqlite_err)?;
            tx.execute(
                "DELETE FROM embeddings WHERE record_id = ?1",
                rusqlite::params![sid.as_str()],
            )
            .map_err(sqlite_err)?;
            tx.execute(
                "DELETE FROM embedding_vectors WHERE record_id = ?1",
                rusqlite::params![sid.as_str()],
            )
            .map_err(sqlite_err)?;
        }
        tx.execute(
            "DELETE FROM summary_links WHERE source_record_id = ?1",
            rusqlite::params![id_str],
        )
        .map_err(sqlite_err)?;
        tx.execute(
            "DELETE FROM embedding_vectors WHERE record_id = ?1",
            rusqlite::params![id_str],
        )
        .map_err(sqlite_err)?;
        tx.execute(
            "DELETE FROM records WHERE id = ?1",
            rusqlite::params![id_str],
        )
        .map_err(sqlite_err)?;
        tx.commit().map_err(sqlite_err)?;

        // SEC-021 / MEMORY_API §2.4: "forces a WAL checkpoint so deleted
        // content does not survive in the SQLite write-ahead log."
        checkpoint(&self.conn)?;

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

const SELECT_RECORD_COLUMNS: &str = "SELECT id, scope, content, content_type, embedding_ref, sensitive, created_at, source FROM records";
const SELECT_RECORD_COLUMNS_WHERE_ID: &str = "SELECT id, scope, content, content_type, embedding_ref, sensitive, created_at, source FROM records WHERE id = ?1";

fn sqlite_err(e: rusqlite::Error) -> MemoryError {
    MemoryError::Backend(e.to_string())
}

fn checkpoint(conn: &rusqlite::Connection) -> Result<(), MemoryError> {
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
        .map_err(sqlite_err)
}

/// Renders an `&[f32]` as a JSON array string (`[f0,f1,...]`) for sqlite-vec's
/// `vec_f32(...)` constructor. `f32::to_string` is shortest-round-trippable, so
/// the stored vector is exactly the one passed in.
fn vector_to_json(vector: &[f32]) -> String {
    let mut s = String::with_capacity(vector.len() * 8 + 2);
    s.push('[');
    for (i, x) in vector.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&x.to_string());
    }
    s.push(']');
    s
}

struct RawRow {
    id: String,
    scope: String,
    content: String,
    content_type: String,
    embedding_ref: Option<String>,
    sensitive: i64,
    created_at: String,
    source: String,
}

fn query_raw_rows<P: rusqlite::Params>(
    conn: &rusqlite::Connection,
    sql: &str,
    params: P,
) -> Result<Vec<RawRow>, MemoryError> {
    let mut stmt = conn.prepare(sql).map_err(sqlite_err)?;
    let rows = stmt
        .query_map(params, |row| {
            Ok(RawRow {
                id: row.get(0)?,
                scope: row.get(1)?,
                content: row.get(2)?,
                content_type: row.get(3)?,
                embedding_ref: row.get(4)?,
                sensitive: row.get(5)?,
                created_at: row.get(6)?,
                source: row.get(7)?,
            })
        })
        .map_err(sqlite_err)?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(sqlite_err)
}

fn raw_to_record(raw: RawRow) -> Result<MemoryRecord, MemoryError> {
    Ok(MemoryRecord {
        id: Uuid::parse_str(&raw.id)
            .map_err(|e| MemoryError::Backend(format!("corrupt id: {e}")))?,
        scope: MemoryScope::parse(&raw.scope)
            .ok_or_else(|| MemoryError::Backend(format!("corrupt scope: {}", raw.scope)))?,
        content: raw.content,
        content_type: match raw.content_type.as_str() {
            "text/plain" => ContentType::TextPlain,
            "application/json" => ContentType::ApplicationJson,
            other => {
                return Err(MemoryError::Backend(format!(
                    "corrupt contentType: {other}"
                )))
            }
        },
        embedding_ref: raw.embedding_ref,
        sensitive: raw.sensitive != 0,
        created_at: DateTime::parse_from_rfc3339(&raw.created_at)
            .map_err(|e| MemoryError::Backend(format!("corrupt createdAt: {e}")))?
            .with_timezone(&Utc),
        source: raw.source,
    })
}

impl MemoryStore for SqliteStore {
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
        let sensitive = req.sensitive || matches!(req.scope, MemoryScope::UserProfile);
        let id = Uuid::now_v7();
        let created_at = Utc::now();
        self.conn
            .execute(
                "INSERT INTO records (id, scope, content, content_type, embedding_ref, sensitive, created_at, source) \
                 VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?6, ?7)",
                rusqlite::params![
                    id.to_string(),
                    req.scope.as_wire_string(),
                    req.content,
                    req.content_type.as_str(),
                    i64::from(sensitive),
                    created_at.to_rfc3339(),
                    req.source,
                ],
            )
            .map_err(sqlite_err)?;
        Ok(WriteOutcome {
            record_id: id,
            scope: req.scope,
            sensitive,
            written_by: req.source,
        })
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
        if authorized_scopes.is_empty() {
            return Ok(RecallResponse {
                excerpts: Vec::new(),
                truncated: false,
            });
        }
        let placeholders = authorized_scopes
            .iter()
            .map(|_| "?")
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!("{SELECT_RECORD_COLUMNS} WHERE scope IN ({placeholders})");
        let scope_strings: Vec<String> = authorized_scopes
            .iter()
            .map(MemoryScope::as_wire_string)
            .collect();
        let raws = query_raw_rows(
            &self.conn,
            &sql,
            rusqlite::params_from_iter(scope_strings.iter()),
        )?;
        let records = raws
            .into_iter()
            .map(raw_to_record)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(crate::ranking::rank_and_budget(
            records,
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
        let scope_str = req.scope.as_wire_string();
        let sql = format!("{SELECT_RECORD_COLUMNS} WHERE scope = ?1 ORDER BY id ASC");
        let raws = query_raw_rows(&self.conn, &sql, rusqlite::params![scope_str])?;
        let records = raws
            .into_iter()
            .map(raw_to_record)
            .collect::<Result<Vec<_>, _>>()?;

        let start = match &req.after {
            Some(after_id) => records
                .iter()
                .position(|r| r.id == *after_id)
                .map_or(0, |i| i + 1),
            None => 0,
        };
        let page: Vec<MemoryRecord> = records.into_iter().skip(start).take(req.limit).collect();
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
        let records = if authorized_scopes.is_empty() {
            Vec::new()
        } else {
            let placeholders = authorized_scopes
                .iter()
                .map(|_| "?")
                .collect::<Vec<_>>()
                .join(",");
            let sql =
                format!("{SELECT_RECORD_COLUMNS} WHERE scope IN ({placeholders}) ORDER BY id ASC");
            let scope_strings: Vec<String> = authorized_scopes
                .iter()
                .map(MemoryScope::as_wire_string)
                .collect();
            let raws = query_raw_rows(
                &self.conn,
                &sql,
                rusqlite::params_from_iter(scope_strings.iter()),
            )?;
            raws.into_iter()
                .map(raw_to_record)
                .collect::<Result<Vec<_>, _>>()?
        };
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
        let scope_str = scope.as_wire_string();
        let ids: Vec<String> = {
            let mut stmt = self
                .conn
                .prepare("SELECT id FROM records WHERE scope = ?1")
                .map_err(sqlite_err)?;
            let rows = stmt
                .query_map(rusqlite::params![scope_str], |row| row.get::<_, String>(0))
                .map_err(sqlite_err)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(sqlite_err)?
        };

        let tx = self.conn.transaction().map_err(sqlite_err)?;
        let mut embeddings_total = 0usize;
        let mut summaries_total = 0usize;
        for id in &ids {
            embeddings_total += tx
                .execute(
                    "DELETE FROM embeddings WHERE record_id = ?1",
                    rusqlite::params![id.as_str()],
                )
                .map_err(sqlite_err)?;
            let summary_ids: Vec<String> = {
                let mut stmt = tx
                    .prepare(
                        "SELECT summary_record_id FROM summary_links WHERE source_record_id = ?1",
                    )
                    .map_err(sqlite_err)?;
                let rows = stmt
                    .query_map(rusqlite::params![id.as_str()], |row| {
                        row.get::<_, String>(0)
                    })
                    .map_err(sqlite_err)?;
                rows.collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(sqlite_err)?
            };
            summaries_total += summary_ids.len();
            for sid in &summary_ids {
                tx.execute(
                    "DELETE FROM records WHERE id = ?1",
                    rusqlite::params![sid.as_str()],
                )
                .map_err(sqlite_err)?;
                tx.execute(
                    "DELETE FROM embeddings WHERE record_id = ?1",
                    rusqlite::params![sid.as_str()],
                )
                .map_err(sqlite_err)?;
                tx.execute(
                    "DELETE FROM embedding_vectors WHERE record_id = ?1",
                    rusqlite::params![sid.as_str()],
                )
                .map_err(sqlite_err)?;
            }
            tx.execute(
                "DELETE FROM summary_links WHERE source_record_id = ?1",
                rusqlite::params![id.as_str()],
            )
            .map_err(sqlite_err)?;
            tx.execute(
                "DELETE FROM embedding_vectors WHERE record_id = ?1",
                rusqlite::params![id.as_str()],
            )
            .map_err(sqlite_err)?;
            tx.execute(
                "DELETE FROM records WHERE id = ?1",
                rusqlite::params![id.as_str()],
            )
            .map_err(sqlite_err)?;
        }
        tx.commit().map_err(sqlite_err)?;
        checkpoint(&self.conn)?;

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
