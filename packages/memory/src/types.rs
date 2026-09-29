//! MEMORY_API §1 (`MemoryRecord`) and the request/response/outcome shapes
//! for each of §2's six operations, plus the `Caller`/authorization seam
//! (SEC-020) and event-building helpers (§4).

use chrono::{DateTime, Utc};
use ocp_shared_types::Envelope;
use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

// --- MemoryScope (MEMORY_API §1, MEMORY_PRIVACY's 4-scope table) -----------

/// Exactly one scope per record, always (MEMORY_PRIVACY principle 2: "no
/// scope-less memory"). `Plugin` carries its owning plugin's id — bound by
/// the Plugin Host from the verified package signature at write time
/// (SEC-020), never self-declared by the plugin itself; this type has no
/// opinion on *how* that id was verified, only that a `MemoryScope::Plugin`
/// value exists once it has been.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum MemoryScope {
    /// Current conversation state. Cleared at session end (MEMORY_PRIVACY).
    Session,
    /// Persona-relevant facts the user shared **with this specific
    /// companion instance** -- carries the owning companion's id
    /// (ADR-0013, Multi-Companion Actor Architecture; approved 2026-07-21).
    /// Parameterized the same way `Plugin(String)` already is, so "Aiko
    /// remembers the user likes LoFi" and "the user likes coffee" (which
    /// belongs in `UserProfile`, not here) are actually expressible as
    /// different scopes rather than colliding in one flat bucket. Until
    /// user deletes. **Not yet wired to any real companion-instance
    /// lifecycle** (that's I6.5's job) -- single-companion callers should
    /// use [`DEFAULT_COMPANION_ID`] rather than inventing their own
    /// placeholder id.
    Companion(String),
    /// Explicit user preferences. Until user deletes. Sensitive by default
    /// (MEMORY_API §1: "all `user-profile` scope records are sensitive by
    /// default"). Deliberately **not** parameterized by companion id --
    /// this is the "everyone knows" side of ADR-0013's Global-vs-Character
    /// memory split; `Companion(String)` is the "only this companion knows"
    /// side.
    UserProfile,
    /// Plugin-owned records, isolated per plugin. Plugin uninstall deletes.
    Plugin(String),
}

/// Fallback companion id for single-companion callers / tests that don't
/// care about a specific instance -- avoids every call site inventing its
/// own placeholder string (ADR-0013 §6 follow-up).
pub const DEFAULT_COMPANION_ID: &str = "default";

impl MemoryScope {
    #[must_use]
    pub fn as_wire_string(&self) -> String {
        match self {
            Self::Session => "session".to_owned(),
            Self::Companion(id) => format!("companion:{id}"),
            Self::UserProfile => "user-profile".to_owned(),
            Self::Plugin(id) => format!("plugin:{id}"),
        }
    }

    /// `None` for a malformed wire value (e.g. `"plugin:"` or `"companion:"`
    /// with an empty id) rather than silently accepting it — an empty
    /// plugin/companion id can never be a real verified identity (SEC-020).
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "session" => Some(Self::Session),
            "user-profile" => Some(Self::UserProfile),
            other => {
                if let Some(id) = other.strip_prefix("companion:") {
                    (!id.is_empty()).then(|| Self::Companion(id.to_owned()))
                } else if let Some(id) = other.strip_prefix("plugin:") {
                    (!id.is_empty()).then(|| Self::Plugin(id.to_owned()))
                } else {
                    None
                }
            }
        }
    }

    /// This record's default retention rule (MEMORY_API §3 table). Purely
    /// descriptive -- enforcing it is the caller's job (a scheduler for
    /// `Session`, the Plugin Host's uninstall hook for `Plugin`), same
    /// "no internal timer" stance every other engine in this workspace
    /// takes; see `PurgeTrigger`.
    #[must_use]
    pub fn default_retention(&self) -> &'static str {
        match self {
            Self::Session => "cleared at session end",
            Self::Companion(_) | Self::UserProfile => "until user deletes",
            Self::Plugin(_) => "plugin uninstall deletes",
        }
    }
}

impl core::fmt::Display for MemoryScope {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(&self.as_wire_string())
    }
}

impl Serialize for MemoryScope {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.as_wire_string())
    }
}

impl<'de> Deserialize<'de> for MemoryScope {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Self::parse(&s).ok_or_else(|| DeError::custom(format!("not a valid memory scope: {s}")))
    }
}

// --- ContentType (MEMORY_API §1: "text/plain | application/json") ---------

/// A closed set on purpose -- unlike `ActivityState`'s `Other(String)`,
/// MEMORY_API §1 lists exactly these two and doesn't say "extensible."
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentType {
    TextPlain,
    ApplicationJson,
}

impl ContentType {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::TextPlain => "text/plain",
            Self::ApplicationJson => "application/json",
        }
    }
}

impl Serialize for ContentType {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for ContentType {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        match s.as_str() {
            "text/plain" => Ok(Self::TextPlain),
            "application/json" => Ok(Self::ApplicationJson),
            other => Err(DeError::custom(format!(
                "unsupported memory contentType: {other}"
            ))),
        }
    }
}

// --- MemoryRecord (MEMORY_API §1) -------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRecord {
    pub id: Uuid,
    pub scope: MemoryScope,
    pub content: String,
    pub content_type: ContentType,
    /// Reference to the derived embedding row (sqlite-vec class, ADR-0010),
    /// or `None` if not yet embedded. Deriving the actual embedding is an
    /// AI Router concern (I6's real-backend slice), not this crate's --
    /// `MemoryStore::write` never blocks on it (MEMORY_API §2.1: "schedules
    /// embedding via the AI Router").
    pub embedding_ref: Option<String>,
    /// All `UserProfile`-scope records are sensitive by default (MEMORY_API
    /// §1); `MemoryStore::write` enforces this rather than trusting the
    /// caller to set it correctly (SEC-020's "enforcement lives inside the
    /// Memory Layer" spirit applied to this field too).
    pub sensitive: bool,
    pub created_at: DateTime<Utc>,
    /// Writing component, for provenance/audit (SEC-024) -- e.g.
    /// `"behavior-engine"`, `"companion"`, `"plugin:<id>"`, `"summarizer"`.
    pub source: String,
}

// --- Caller / authorization seam (SEC-020) ----------------------------------

/// Who is calling `MemoryStore`. Authorization is decided from this, inside
/// the store, on every call (MEMORY_API §2: "Scope authorization is checked
/// inside the Memory Layer on every call, not at load time and not by
/// callers") -- never by trusting a caller-supplied scope claim.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Caller {
    /// A core OCP component acting on the user's own behalf --
    /// Behavior Engine, Companion, the summarizer pipeline, the
    /// user-facing inspection UI, and so on. `component` names the
    /// requesting context for audit (MEMORY_API's `requesterId`) --
    /// deliberately a free string like `Envelope::source`, not a closed
    /// enum, since this crate shouldn't need to know every core component
    /// that will ever call it.
    Core { component: String },
    /// A plugin. `id` is bound by the Plugin Host from the verified
    /// package signature (SEC-020) -- this type trusts whoever constructs
    /// it to have already done that verification; it does not re-verify a
    /// signature itself. `extra_grants` are additional scopes the
    /// plugin's manifest declared **and the user approved** (MEMORY_PRIVACY
    /// rule, ADR-0007) -- empty by default, meaning "only my own scope."
    Plugin {
        id: String,
        extra_grants: Vec<MemoryScope>,
    },
}

impl Caller {
    #[must_use]
    pub fn requester_id(&self) -> String {
        match self {
            Self::Core { component } => component.clone(),
            Self::Plugin { id, .. } => format!("plugin:{id}"),
        }
    }

    fn owns(&self, scope: &MemoryScope) -> bool {
        matches!((self, scope), (Self::Plugin { id, .. }, MemoryScope::Plugin(scope_id)) if id == scope_id)
    }

    fn has_extra_grant(&self, scope: &MemoryScope) -> bool {
        match self {
            Self::Plugin { extra_grants, .. } => extra_grants.contains(scope),
            Self::Core { .. } => false,
        }
    }

    /// Write authorization. **Interpretive addition, flagged for review**
    /// (same practice as `CompanionState`'s and `ActivityState`'s own
    /// flagged additions): MEMORY_API §2.1 states the plugin-side rule
    /// explicitly ("plugins may write only to their own `plugin:<id>`
    /// scope unless... another scope"); it does not explicitly say whether
    /// a Core component may write into a *plugin's* scope. Symmetry with
    /// the plugin-isolation principle (MEMORY_PRIVACY: plugin data is
    /// plugin-owned) argues Core should not inject into a plugin's private
    /// scope either, so this denies it. Core is authorized for the three
    /// non-plugin scopes.
    #[must_use]
    pub fn can_write(&self, scope: &MemoryScope) -> bool {
        match self {
            Self::Core { .. } => !matches!(scope, MemoryScope::Plugin(_)),
            Self::Plugin { .. } => self.owns(scope) || self.has_extra_grant(scope),
        }
    }

    /// Read authorization (recall/list/export). **Interpretive addition**:
    /// MEMORY_API §2.3 names the inspection UI (a Core caller) as list's
    /// "primary caller" specifically so a user can "inspect everything the
    /// companion remembers, per scope" (MEMORY_PRIVACY principle 4) --
    /// including what plugins have stored, which the user is entitled to
    /// see even though the plugin itself couldn't read another plugin's
    /// scope. Core is therefore authorized to read every scope; plugins
    /// stay restricted to their own + granted scopes, same as write.
    #[must_use]
    pub fn can_read(&self, scope: &MemoryScope) -> bool {
        match self {
            Self::Core { .. } => true,
            Self::Plugin { .. } => self.owns(scope) || self.has_extra_grant(scope),
        }
    }

    /// Delete/purge authorization. **Interpretive addition**: MEMORY_API
    /// §2.6 lists "explicit user request on any scope" as a purge trigger,
    /// which only a Core caller (acting for the user) can issue across
    /// arbitrary scopes; a plugin deleting its own data (e.g. clearing its
    /// own cache) is reasonable and stays within the same scope-ownership
    /// rule as read/write, but a plugin is never authorized to delete
    /// another scope's records or another plugin's scope.
    #[must_use]
    pub fn can_delete(&self, scope: &MemoryScope) -> bool {
        match self {
            Self::Core { .. } => true,
            Self::Plugin { .. } => self.owns(scope) || self.has_extra_grant(scope),
        }
    }
}

// --- Errors (SEC-004-style containment: typed, never a panic) --------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemoryError {
    /// SEC-020: the caller is not authorized for this scope on this
    /// operation. `op` is a short static tag (`"write"`, `"recall"`, ...)
    /// for audit/logging, not part of any wire schema.
    Unauthorized {
        requester: String,
        scope: MemoryScope,
        op: &'static str,
    },
    /// MEMORY_API doesn't allow scope-less or content-less writes.
    EmptyContent,
    /// A `delete` call named an id that doesn't exist (already deleted, or
    /// never existed) -- distinct from `write`'s `EmptyContent`-style input
    /// error: this is a per-id containment result inside a batch
    /// (`MemoryStore::delete` returns one `Result` per requested id), never
    /// something that aborts the rest of the batch.
    NotFound { record_id: Uuid },
    /// A real backend's own storage/I/O failure (e.g. SQLite). `InMemoryStore`
    /// never produces this variant -- it has no I/O to fail. Carries the
    /// backend's own error text rather than a typed sub-enum: this crate
    /// doesn't want `MemoryStore`'s public error type to leak a specific
    /// backend's error type (ADR-0010: the Memory Provider is replaceable).
    Backend(String),
}

impl core::fmt::Display for MemoryError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Unauthorized {
                requester,
                scope,
                op,
            } => {
                write!(f, "{requester} is not authorized to {op} scope {scope}")
            }
            Self::EmptyContent => write!(f, "content must not be empty"),
            Self::NotFound { record_id } => write!(f, "no record with id {record_id}"),
            Self::Backend(msg) => write!(f, "backend error: {msg}"),
        }
    }
}

impl std::error::Error for MemoryError {}

// --- Operation request/response/outcome shapes (MEMORY_API §2) -------------

#[derive(Debug, Clone)]
pub struct WriteRequest {
    pub scope: MemoryScope,
    pub content: String,
    pub content_type: ContentType,
    /// The layer forces this to `true` for `UserProfile` scope regardless
    /// of what's passed (MEMORY_API §1's default), so a caller passing
    /// `false` there does not silently under-protect the record.
    pub sensitive: bool,
    pub source: String,
}

/// §4: `ocp.memory.record-written` — `{recordId, scope, sensitive, writtenBy}`.
#[derive(Debug, Clone)]
pub struct WriteOutcome {
    pub record_id: Uuid,
    pub scope: MemoryScope,
    pub sensitive: bool,
    pub written_by: String,
}

impl WriteOutcome {
    #[must_use]
    pub fn to_event(&self) -> Envelope {
        build_event(
            "ocp.memory.record-written",
            serde_json::json!({
                "recordId": self.record_id,
                "scope": self.scope,
                "sensitive": self.sensitive,
                "writtenBy": self.written_by,
            }),
        )
    }
}

#[derive(Debug, Clone)]
pub struct RecallBudget {
    pub max_excerpts: usize,
    pub max_chars: usize,
}

#[derive(Debug, Clone)]
pub struct RecallRequest {
    pub query: String,
    pub scopes: Vec<MemoryScope>,
    pub budget: RecallBudget,
}

#[derive(Debug, Clone)]
pub struct Excerpt {
    pub record_id: Uuid,
    pub scope: MemoryScope,
    pub excerpt: String,
    pub sensitive: bool,
    pub score: f64,
}

/// MEMORY_API §2.2's response shape exactly: `{excerpts[], truncated}`.
#[derive(Debug, Clone)]
pub struct RecallResponse {
    pub excerpts: Vec<Excerpt>,
    pub truncated: bool,
}

impl RecallResponse {
    /// §4: `ocp.memory.recalled` — `{recordIds, scope, requesterId,
    /// excerptCount}`. The frozen schema's `scope` field is **singular**
    /// even though one `recall` call can span several `scopes` at once
    /// (§2.2's request) -- read literally rather than loosely: one event
    /// **per scope actually represented in the results**, each carrying
    /// only that scope's `recordIds`, not a single aggregate event with a
    /// scope list bolted on. A scope requested but returning zero excerpts
    /// emits nothing (there is nothing to audit).
    #[must_use]
    pub fn to_events(&self, requester_id: &str) -> Vec<Envelope> {
        let mut by_scope: std::collections::BTreeMap<String, (MemoryScope, Vec<Uuid>)> =
            std::collections::BTreeMap::new();
        for excerpt in &self.excerpts {
            by_scope
                .entry(excerpt.scope.as_wire_string())
                .or_insert_with(|| (excerpt.scope.clone(), Vec::new()))
                .1
                .push(excerpt.record_id);
        }
        by_scope
            .into_values()
            .map(|(scope, record_ids)| {
                let excerpt_count = record_ids.len();
                build_event(
                    "ocp.memory.recalled",
                    serde_json::json!({
                        "recordIds": record_ids,
                        "scope": scope,
                        "requesterId": requester_id,
                        "excerptCount": excerpt_count,
                    }),
                )
            })
            .collect()
    }
}

#[derive(Debug, Clone)]
pub struct ListRequest {
    pub scope: MemoryScope,
    pub after: Option<Uuid>,
    pub limit: usize,
}

#[derive(Debug, Clone)]
pub struct ListResponse {
    pub records: Vec<MemoryRecord>,
    pub next_after: Option<Uuid>,
}

#[derive(Debug, Clone, Default)]
pub struct CascadeCounts {
    pub embeddings: usize,
    pub summaries: usize,
}

/// §4: `ocp.memory.record-deleted` — `{recordId, scope, cascaded}`. Like
/// `recalled`, the frozen schema's `recordId` is singular though §2.4's
/// `delete` operation accepts a list -- one outcome, and one event, per
/// record actually deleted (see `MemoryStore::delete`'s own doc).
#[derive(Debug, Clone)]
pub struct DeleteOutcome {
    pub record_id: Uuid,
    pub scope: MemoryScope,
    pub cascaded: CascadeCounts,
}

impl DeleteOutcome {
    #[must_use]
    pub fn to_event(&self) -> Envelope {
        build_event(
            "ocp.memory.record-deleted",
            serde_json::json!({
                "recordId": self.record_id,
                "scope": self.scope,
                "cascaded": { "embeddings": self.cascaded.embeddings, "summaries": self.cascaded.summaries },
            }),
        )
    }
}

#[derive(Debug, Clone)]
pub struct ExportRequest {
    pub scopes: Vec<MemoryScope>,
    /// e.g. `"ocp-memory-export/1.0"` (MEMORY_API §2.5).
    pub format: String,
}

/// The first line of an export file (MEMORY_API §2.5's "manifest": schema
/// version, scopes, record count, export time). `Serialize`/`Deserialize` so
/// it is itself one portable JSON object, distinguishable from a record line
/// by its `format`/`exportedAt` fields (records carry `id`/`content` instead).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportManifest {
    pub format: String,
    pub scopes: Vec<MemoryScope>,
    pub record_count: usize,
    pub exported_at: DateTime<Utc>,
}

/// §2.5: JSON Lines of `MemoryRecord` plus the manifest. [`to_jsonl`](
/// Self::to_jsonl) renders the actual portable file content; writing those
/// bytes to a real path (and SEC-023's deletion-level user confirmation
/// before doing so) is a caller/CLI concern, the same split as
/// `ocp-shared-types::Envelope` not knowing about the IPC wire framing that
/// eventually carries it.
#[derive(Debug, Clone)]
pub struct ExportResponse {
    pub manifest: ExportManifest,
    pub records: Vec<MemoryRecord>,
}

impl ExportResponse {
    /// Renders MEMORY_API §2.5's portable `ocp-memory-export/1.0` format: the
    /// manifest as the first JSON-Lines line, then one `MemoryRecord` JSON
    /// object per line, each newline-terminated (so the file ends in `\n` and
    /// concatenation/append stays well-formed). Every line is an independent,
    /// complete JSON object — a reader parses line by line without buffering
    /// the whole file.
    ///
    /// **Plaintext by design (ADR-0012 / SEC-023)**: the records here are
    /// already decrypted (the store decrypts on read), and this format does
    /// not re-encrypt them — an export is the documented recovery path and
    /// must be portable. That is exactly why SEC-023 requires deletion-level
    /// confirmation before a caller writes this to disk; enforcing that
    /// confirmation is the caller/UI's job, not this pure serializer's.
    ///
    /// Serialization of these plain data structs cannot fail in practice (no
    /// non-string map keys, no unrepresentable values); a failure would be a
    /// bug in this crate's own types, surfaced immediately in tests, so this
    /// returns `String` directly rather than a `Result`, matching
    /// [`to_event`](Self::to_event)'s infallible style.
    #[must_use]
    pub fn to_jsonl(&self) -> String {
        let mut out = String::new();
        out.push_str(
            &serde_json::to_string(&self.manifest).expect("ExportManifest is plainly serializable"),
        );
        out.push('\n');
        for record in &self.records {
            out.push_str(
                &serde_json::to_string(record).expect("MemoryRecord is plainly serializable"),
            );
            out.push('\n');
        }
        out
    }

    /// §4: `ocp.memory.store-exported` — `{scopes, recordCount, format}`.
    /// "counts and scopes only, never content" -- `self.records` itself is
    /// never touched by this method, only `self.manifest`.
    #[must_use]
    pub fn to_event(&self) -> Envelope {
        build_event(
            "ocp.memory.store-exported",
            serde_json::json!({
                "scopes": self.manifest.scopes,
                "recordCount": self.manifest.record_count,
                "format": self.manifest.format,
            }),
        )
    }
}

/// §4: `ocp.memory.scope-purged`'s `trigger` enum exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PurgeTrigger {
    SessionEnd,
    PluginUninstall,
    UserRequest,
}

impl PurgeTrigger {
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::SessionEnd => "session-end",
            Self::PluginUninstall => "plugin-uninstall",
            Self::UserRequest => "user-request",
        }
    }
}

/// §4: `ocp.memory.scope-purged` — `{scope, trigger, recordCount, cascaded}`.
#[derive(Debug, Clone)]
pub struct PurgeOutcome {
    pub scope: MemoryScope,
    pub trigger: PurgeTrigger,
    pub record_count: usize,
    pub cascaded: CascadeCounts,
}

impl PurgeOutcome {
    #[must_use]
    pub fn to_event(&self) -> Envelope {
        build_event(
            "ocp.memory.scope-purged",
            serde_json::json!({
                "scope": self.scope,
                "trigger": self.trigger.as_str(),
                "recordCount": self.record_count,
                "cascaded": { "embeddings": self.cascaded.embeddings, "summaries": self.cascaded.summaries },
            }),
        )
    }
}

fn build_event(event_type: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, "memory-layer", data)
        .expect("crate-constructed envelope is always valid")
}
