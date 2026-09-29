//! OCP Activity Context Engine (RFC-0005, Approved 2026-07-21; I11 opened
//! same day). Sits between Plugin (I4's raw `ocp.plugin.os-telemetry-*`
//! signals) and Behavior (I3): interprets raw signals into a canonical,
//! debounced `ActivityState` and emits it as an ordinary
//! `ocp.activity.state-changed` event — **zero changes to
//! BEHAVIOR_ENGINE.md's own contract**, since a `Trigger` is just "an event
//! pattern" (BEHAVIOR_ENGINE.md) and this is simply another event type a
//! Rule can match, the same way it already matches raw telemetry directly.
//!
//! **Zero LLM in v1** (RFC-0001 "intelligence is routed, never embedded",
//! same discipline `ocp-behavior-engine` holds): `Interpreter`s are
//! deterministic, declared signal-pattern rules — "behaviors are data,"
//! applied here to perception instead of decision. This crate has no AI
//! Router / network dependency at all, enforced structurally, not by
//! convention.
//!
//! One crate, not an api/engine split like `behavior-api`/`behavior-engine`:
//! unlike the Runtime (NFR-001's swap test) or Behavior Engine (a stated
//! future character-package format), nothing in RFC-0005 anticipates a
//! second interchangeable implementation — this mirrors `ocp-llm-router`'s
//! own combined-crate choice, not `behavior-api`'s split.
//!
//! **Deliberately out of scope this slice** (flagged, not silently built
//! partial): RFC-0005's "any state -> Unknown when no Interpreter holds
//! confidently for longer than a configurable staleness window" needs a
//! wall-clock timeout independent of new signals arriving — this crate, like
//! every other engine in `ocp-platform` so far, is purely signal-reactive
//! with no background tick loop anywhere in the workspace yet.
//! `ActivityContextEngine::mark_unknown` is the seam (an external scheduler
//! decides *when* to call it); wiring an actual timer is a follow-up, not
//! guessed at here. The RFC-0005 Privacy section's composite-inference
//! consent question is also explicitly unresolved (`10-decisions/
//! OPEN_DECISIONS.md`) — this engine only ever emits `evidence` tags
//! (short, non-reversible strings like `"foreground:devenv.exe"`), never the
//! raw signal payload itself, as a structural (not sufficient, but
//! deliberate) limit on what a composite inference can leak until that
//! question is answered.

#![forbid(unsafe_code)] // SEC-042

use chrono::{DateTime, Utc};
use ocp_shared_types::Envelope;
use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

/// Envelope `source` for everything this crate emits.
pub const SOURCE: &str = "activity-context";

// --- ActivityState (RFC-0005 canonical vocabulary, v1 baseline) ------------

/// The canonical activity vocabulary (RFC-0005), keyed 1:1 against
/// RUNTIME_API §7's `animationId` baseline where applicable. `Unknown` is
/// the explicit default (a fact — "we don't know" — never an error, and
/// never silently folded into `Idle`, which means "known-idle").
///
/// `Other(String)` exists because RFC-0005 states the vocabulary is
/// "extensible... matching how `animationId` already stays a free string" —
/// a character/plugin-scoped `Interpreter` set may declare a state outside
/// this baseline without this enum needing to change; this crate's own
/// baseline `Interpreter`s never produce one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ActivityState {
    Idle,
    Coding,
    Debugging,
    Building,
    Testing,
    Meeting,
    Gaming,
    Learning,
    Reading,
    Downloading,
    Uploading,
    ListeningToMusic,
    Away,
    Unknown,
    Other(String),
}

impl ActivityState {
    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Idle => "Idle",
            Self::Coding => "Coding",
            Self::Debugging => "Debugging",
            Self::Building => "Building",
            Self::Testing => "Testing",
            Self::Meeting => "Meeting",
            Self::Gaming => "Gaming",
            Self::Learning => "Learning",
            Self::Reading => "Reading",
            Self::Downloading => "Downloading",
            Self::Uploading => "Uploading",
            Self::ListeningToMusic => "ListeningToMusic",
            Self::Away => "Away",
            Self::Unknown => "Unknown",
            Self::Other(s) => s.as_str(),
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s {
            "Idle" => Self::Idle,
            "Coding" => Self::Coding,
            "Debugging" => Self::Debugging,
            "Building" => Self::Building,
            "Testing" => Self::Testing,
            "Meeting" => Self::Meeting,
            "Gaming" => Self::Gaming,
            "Learning" => Self::Learning,
            "Reading" => Self::Reading,
            "Downloading" => Self::Downloading,
            "Uploading" => Self::Uploading,
            "ListeningToMusic" => Self::ListeningToMusic,
            "Away" => Self::Away,
            "Unknown" => Self::Unknown,
            other => Self::Other(other.to_owned()),
        }
    }

    /// Domain state machine (STATE_MACHINE.md addition, RFC-0005): `Unknown
    /// ⇄ Idle ⇄ {named activity states} ⇄ Away`. **Interpretive addition,
    /// flagged for review** — same practice as `CompanionState`'s own two
    /// additions (`ocp-behavior-api`) and `ProviderHealth`'s direct-to-
    /// `Failed` rule (`ocp-llm-router`): the RFC's diagram reads as a chain
    /// of adjacency, but a real `Interpreter` commonly has direct evidence
    /// for switching between two named activities (closing an IDE, opening
    /// a meeting app -> `Coding` straight to `Meeting`) without the user
    /// ever actually being `Idle` in between. Forcing a spurious `Idle`
    /// stop-over would misrepresent what was actually observed, so
    /// named-state-to-named-state is allowed directly. The one rule
    /// enforced structurally: a state may never "transition" to itself
    /// (not a real transition, no event describes it) — `Unknown` is
    /// reachable from anywhere via `ActivityContextEngine::mark_unknown`,
    /// an external, explicit decision (see module doc), not something this
    /// method needs to gate.
    #[must_use]
    pub fn can_transition_to(&self, next: &ActivityState) -> bool {
        next != self
    }
}

impl core::fmt::Display for ActivityState {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl Serialize for ActivityState {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for ActivityState {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        if s.is_empty() {
            return Err(DeError::custom("ActivityState may not be empty"));
        }
        Ok(Self::parse(&s))
    }
}

// --- Interpreter (RFC-0005 "declared, reviewable rules") -------------------

/// A declarative, reviewable rule: a condition over one raw signal type ->
/// a candidate `ActivityState` + confidence (RFC-0005 "Interpreter"). Same
/// "behaviors are data, not code paths" discipline `ocp_behavior_api::Rule`
/// holds for the Behavior Engine, applied here to perception.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Interpreter {
    pub id: String,
    /// Raw signal event type this interpreter reacts to. Same family-prefix
    /// convention as `ocp_behavior_api::Rule::trigger` (a trailing `.`
    /// matches any subtype, e.g. `"ocp.plugin.os-telemetry-".`).
    pub signal_trigger: String,
    pub candidate_state: ActivityState,
    /// 0.0–1.0. When multiple interpreters fire on the same signal, highest
    /// confidence wins; ties broken deterministically by `id` (RFC-0005
    /// "ties broken deterministically", mirrors `Rule`'s own arbitration).
    pub confidence: f64,
    pub condition: SignalCondition,
    /// Short, non-reversible tag for the emitted event's `evidence[]`
    /// (e.g. `"foreground:devenv.exe"`) — never the raw signal payload
    /// itself (see module doc's Privacy note).
    pub evidence_tag: String,
    /// Minimum dwell time (ms) this interpreter's candidate must keep
    /// winning, across however many matching signals arrive, before it
    /// becomes the active `ActivityState` (RFC-0005 "Debounce"). Default
    /// 5000ms per RFC-0005.
    #[serde(default = "default_dwell_ms")]
    pub dwell_ms: u64,
}

fn default_dwell_ms() -> u64 {
    5000
}

/// A condition over a raw signal's `data` payload. Deliberately a small
/// closed set for v1 — mirrors `ocp_behavior_api::Action`'s "adding a
/// variant means adding a variant here, reviewable, never a free-form
/// script."
///
/// **No numeric-threshold variant on purpose, for now** (e.g. nothing
/// expresses "`idleMs >= 300000`" or "`percent >= 90`" directly): every
/// registered `ocp.plugin.os-telemetry-*-changed` schema already carries a
/// host-computed `level`/`state` enum field alongside its raw number
/// (`percent`+`level`, `idleMs`+`state`), so `FieldEqualsAny` against that
/// enum covers the common cases without this crate needing its own
/// numeric-comparison logic (which would duplicate whatever threshold the
/// host sampler already applied to produce `level`, and could silently
/// drift from it). Where a real numeric threshold is genuinely needed
/// (e.g. sustained duration), `Interpreter::dwell_ms` already provides one
/// — see `default_interpreters()`'s `mouse-idle-sustained` rule. Revisit if
/// a real use case needs a threshold neither of those two covers.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum SignalCondition {
    /// The named `data` field (a string) contains any of these substrings,
    /// case-insensitively — e.g. a foreground `processName` containing
    /// `"devenv"` or `"code"`.
    FieldContainsAny { field: String, any_of: Vec<String> },
    /// The named `data` field equals (case-sensitively) any of these exact
    /// values — e.g. `level == "high"`.
    FieldEqualsAny { field: String, any_of: Vec<String> },
    /// Matches any signal of the declared `signal_trigger` type regardless
    /// of payload — for interpreters where the signal's mere presence is
    /// the evidence (e.g. any mouse-idle signal proposing `Away`).
    Always,
}

impl SignalCondition {
    #[must_use]
    pub fn matches(&self, data: &serde_json::Value) -> bool {
        match self {
            Self::Always => true,
            Self::FieldEqualsAny { field, any_of } => data
                .get(field)
                .and_then(serde_json::Value::as_str)
                .is_some_and(|actual| any_of.iter().any(|expected| expected == actual)),
            Self::FieldContainsAny { field, any_of } => data
                .get(field)
                .and_then(serde_json::Value::as_str)
                .is_some_and(|actual| {
                    let lower = actual.to_lowercase();
                    any_of
                        .iter()
                        .any(|needle| lower.contains(&needle.to_lowercase()))
                }),
        }
    }
}

// --- The engine --------------------------------------------------------

struct PendingCandidate {
    state: ActivityState,
    since: DateTime<Utc>,
    dwell_ms: u64,
    confidence: f64,
    /// Accumulated across every matching signal while this candidate is
    /// pending, deduped — RFC-0005's own example event carries evidence
    /// from more than one signal (`["foreground:devenv.exe",
    /// "os-telemetry-cpu:high"]`), not just the single winning interpreter
    /// of the instant debounce completed.
    evidence: Vec<String>,
}

/// Interprets raw signals into a debounced `ActivityState`
/// (`Signal -> Interpreter match -> Debounce -> ActivityState -> event`,
/// RFC-0005's own model diagram). One companion per instance, matching
/// `ocp_behavior_engine::DeterministicEngine`'s own scoping.
pub struct ActivityContextEngine {
    interpreters: Vec<Interpreter>,
    current_state: ActivityState,
    pending: Option<PendingCandidate>,
    /// Every interpretation/debounce decision, including losing
    /// interpreters on a tie (RFC-0005 "losers logged not silently
    /// dropped") — inspectable audit trail, not part of the emitted event
    /// (whose schema is frozen in EVENT_CATALOG.md and has no field for
    /// this), same pattern as `ocp_llm_router::Router::audit_log`.
    audit: Vec<String>,
}

impl ActivityContextEngine {
    /// Starts in `ActivityState::Unknown` (RFC-0005: "`Unknown` is the
    /// explicit default").
    #[must_use]
    pub fn new(interpreters: Vec<Interpreter>) -> Self {
        Self {
            interpreters,
            current_state: ActivityState::Unknown,
            pending: None,
            audit: Vec::new(),
        }
    }

    #[must_use]
    pub fn current_state(&self) -> &ActivityState {
        &self.current_state
    }

    #[must_use]
    pub fn audit_log(&self) -> &[String] {
        &self.audit
    }

    /// Handle one raw signal event. `now` is taken explicitly rather than
    /// read from the wall clock internally, so debounce timing is
    /// deterministic and testable without real sleeps — this crate has no
    /// implicit timer anywhere, matching every other engine in
    /// `ocp-platform` so far.
    ///
    /// Returns `Some(envelope)` only when a debounced state change actually
    /// commits; every other call (no interpreter matched, a matching
    /// interpreter's candidate is already the active state, or dwell hasn't
    /// elapsed yet) returns `None` — never an error, mirroring
    /// `RulesEngine::handle`'s "unmatched events return an empty vec" rule.
    pub fn handle_signal(&mut self, event: &Envelope, now: DateTime<Utc>) -> Option<Envelope> {
        let mut matched: Vec<&Interpreter> = self
            .interpreters
            .iter()
            .filter(|i| trigger_matches(&i.signal_trigger, &event.event_type))
            .filter(|i| i.condition.matches(&event.data))
            .collect();
        if matched.is_empty() {
            return None;
        }
        matched.sort_by(|a, b| {
            b.confidence
                .partial_cmp(&a.confidence)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.id.cmp(&b.id))
        });
        // Own everything needed from `matched` up front: it borrows
        // `self.interpreters`, and the rest of this method needs to mutate
        // other fields of `self` (disjoint fields, but only clean once this
        // borrow has visibly ended).
        let winner_id = matched[0].id.clone();
        let winner_state = matched[0].candidate_state.clone();
        let winner_confidence = matched[0].confidence;
        let winner_dwell_ms = matched[0].dwell_ms;
        let winner_evidence_tag = matched[0].evidence_tag.clone();
        let losers: Vec<&str> = matched[1..].iter().map(|i| i.id.as_str()).collect();
        if !losers.is_empty() {
            self.audit.push(format!(
                "INTERPRETER {winner_id} beat {losers:?} for signal {}",
                event.event_type
            ));
        }

        if winner_state == self.current_state {
            return None; // already active; nothing to debounce toward
        }
        if !self.current_state.can_transition_to(&winner_state) {
            return None; // structurally unreachable (see can_transition_to's doc)
        }

        // Update (or start) the pending candidate for this state. This is
        // deliberately a single unified step, not two -- a *newly created*
        // pending candidate must still be checked against its own dwell
        // threshold immediately afterward (an interpreter declaring
        // `dwell_ms: 0` must commit on its very first matching signal, not
        // only from its second consecutive one).
        let is_continuation = matches!(&self.pending, Some(p) if p.state == winner_state);
        if is_continuation {
            let p = self.pending.as_mut().expect("checked Some above");
            if !p.evidence.contains(&winner_evidence_tag) {
                p.evidence.push(winner_evidence_tag);
            }
        } else {
            self.audit.push(format!(
                "PENDING {winner_id}: candidate {winner_state} started dwelling (needs {winner_dwell_ms}ms)"
            ));
            self.pending = Some(PendingCandidate {
                state: winner_state,
                since: now,
                dwell_ms: winner_dwell_ms,
                confidence: winner_confidence,
                evidence: vec![winner_evidence_tag],
            });
        }

        let pending = self.pending.as_ref().expect("just set above");
        let elapsed_ms = u64::try_from(
            now.signed_duration_since(pending.since)
                .num_milliseconds()
                .max(0),
        )
        .unwrap_or(u64::MAX);
        if elapsed_ms < pending.dwell_ms {
            return None; // still dwelling
        }

        let previous = self.current_state.clone();
        let committed = self.pending.take().expect("just checked Some above");
        self.current_state = committed.state;
        self.audit.push(format!(
            "STATE {previous} -> {} (dwell satisfied after {elapsed_ms}ms)",
            self.current_state
        ));
        Some(self.state_changed_event(
            &previous,
            committed.confidence,
            committed.evidence,
            now,
            Some(event.id),
        ))
    }

    /// External staleness/no-signal timeout -> `Unknown` (RFC-0005: "any
    /// state -> Unknown when no Interpreter holds confidently... signals
    /// stopped arriving"). Deliberately **not** computed from an internal
    /// clock (see module doc) — an external scheduler decides when to call
    /// this. No-op (returns `None`) if already `Unknown`.
    pub fn mark_unknown(
        &mut self,
        now: DateTime<Utc>,
        correlation: Option<Uuid>,
    ) -> Option<Envelope> {
        if self.current_state == ActivityState::Unknown {
            return None;
        }
        let previous = self.current_state.clone();
        self.current_state = ActivityState::Unknown;
        self.pending = None;
        self.audit.push(format!(
            "STATE {previous} -> Unknown (staleness, external decision)"
        ));
        Some(self.state_changed_event(&previous, 1.0, Vec::new(), now, correlation))
    }

    fn state_changed_event(
        &self,
        previous: &ActivityState,
        confidence: f64,
        evidence: Vec<String>,
        since: DateTime<Utc>,
        correlation: Option<Uuid>,
    ) -> Envelope {
        let data = serde_json::json!({
            "previousState": previous.as_str(),
            "newState": self.current_state.as_str(),
            "confidence": confidence,
            "evidence": evidence,
            "since": since,
        });
        let env = Envelope::new("ocp.activity.state-changed", SOURCE, data)
            .expect("engine-constructed envelope is always valid");
        match correlation {
            Some(c) => env.with_correlation(c),
            None => env,
        }
    }
}

/// A small, reviewable baseline `Interpreter` set for I4's five real
/// `ocp.plugin.os-telemetry-*-changed` signals — the activity-context
/// analog of `ocp_behavior_engine::demo_rules()` (same "not exhaustive, a
/// real starting point" role; `services/kernel` can wire this in directly).
///
/// **Deliberately covers only `foreground-changed` and `mouse-changed`,
/// not `cpu`/`memory`/`battery-changed`.** This is not an oversight — it is
/// the direct consequence of RFC-0005's still-open Privacy question
/// (`10-decisions/OPEN_DECISIONS.md`): a single `Interpreter` here only
/// ever inspects **one** raw signal's payload (`SignalCondition::matches`
/// takes one `data` value), so anything genuinely informative about
/// `cpu`/`memory`/`battery` on their own would either be a weak, likely-
/// wrong guess (high CPU alone means anything from compiling to a browser
/// tab) or would need combining with a *second* signal (e.g. high CPU +
/// `devenv.exe` foregrounded -> `Building`) — and that combination is
/// exactly the "composite activity inference" the Privacy section flags as
/// still needing its own consent-gate decision. Shipping such a rule in the
/// *default* baseline before that question is answered would preempt it.
/// `foreground`/`mouse` alone, by contrast, are single-signal and map
/// directly to `ActivityState` the same way one `os-telemetry-*-changed`
/// event already maps to one `Interpreter` elsewhere in this set.
///
/// **Also deliberately excludes `Gaming` and `Learning`.** Both would need
/// matching against an effectively unbounded, fast-changing list of
/// third-party executable names (`Gaming`) or free-text window titles
/// (`Learning`) — a maintained allowlist like that belongs in a
/// plugin/character package that can be updated independently, not
/// hardcoded into this core crate's shipped default. `windowTitle` is also
/// avoidably higher-sensitivity payload than `processName` (RUNTIME_API §5
/// already treats window titles as needing sanitization before display);
/// the baseline stays on `processName` substring matches only.
///
/// Five resulting baseline states — `Coding`, `Meeting`, `ListeningToMusic`,
/// `Reading`, `Away` — each backed by a short, named list of common
/// application executables/state, reviewable and extensible in place (add
/// an entry to `any_of`, or a new `Interpreter`, rather than branching code).
#[must_use]
pub fn default_interpreters() -> Vec<Interpreter> {
    vec![
        Interpreter {
            id: "coding-ide".to_owned(),
            signal_trigger: "ocp.plugin.os-telemetry-foreground-changed".to_owned(),
            candidate_state: ActivityState::Coding,
            confidence: 0.85,
            condition: SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec![
                    "devenv".to_owned(),
                    "code".to_owned(),
                    "rustrover".to_owned(),
                    "idea64".to_owned(),
                    "pycharm64".to_owned(),
                    "clion64".to_owned(),
                    "sublime_text".to_owned(),
                    "notepad++".to_owned(),
                    "vim".to_owned(),
                    "nvim".to_owned(),
                ],
            },
            evidence_tag: "foreground:coding-tool".to_owned(),
            dwell_ms: 5000,
        },
        Interpreter {
            id: "meeting-app".to_owned(),
            signal_trigger: "ocp.plugin.os-telemetry-foreground-changed".to_owned(),
            candidate_state: ActivityState::Meeting,
            confidence: 0.85,
            condition: SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec![
                    "teams".to_owned(),
                    "zoom".to_owned(),
                    "webex".to_owned(),
                    "skype".to_owned(),
                ],
            },
            evidence_tag: "foreground:meeting-app".to_owned(),
            dwell_ms: 5000,
        },
        Interpreter {
            id: "music-player".to_owned(),
            signal_trigger: "ocp.plugin.os-telemetry-foreground-changed".to_owned(),
            candidate_state: ActivityState::ListeningToMusic,
            // Lower than coding/meeting: a music player being foregrounded
            // is weaker evidence of ongoing attention (people alt-tab back
            // to a browser/editor while music keeps playing in the
            // background) than an IDE or a call actually being focused.
            confidence: 0.7,
            condition: SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec![
                    "spotify".to_owned(),
                    "itunes".to_owned(),
                    "musicbee".to_owned(),
                    "foobar2000".to_owned(),
                ],
            },
            evidence_tag: "foreground:music-player".to_owned(),
            dwell_ms: 5000,
        },
        Interpreter {
            id: "reader-app".to_owned(),
            signal_trigger: "ocp.plugin.os-telemetry-foreground-changed".to_owned(),
            candidate_state: ActivityState::Reading,
            confidence: 0.65,
            condition: SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec![
                    "acrobat".to_owned(),
                    "sumatrapdf".to_owned(),
                    "foxitreader".to_owned(),
                ],
            },
            evidence_tag: "foreground:reader-app".to_owned(),
            dwell_ms: 5000,
        },
        Interpreter {
            id: "mouse-idle-sustained".to_owned(),
            signal_trigger: "ocp.plugin.os-telemetry-mouse-changed".to_owned(),
            candidate_state: ActivityState::Away,
            confidence: 0.7,
            condition: SignalCondition::FieldEqualsAny {
                field: "state".to_owned(),
                any_of: vec!["idle".to_owned()],
            },
            evidence_tag: "mouse:idle-sustained".to_owned(),
            // Deliberately much longer than the 5000ms default: the raw
            // `mouse-changed` signal already carries its own `idleMs` the
            // moment it fires (SignalCondition has no numeric-threshold
            // variant to gate on that directly -- see SignalCondition's own
            // doc), so this Interpreter leans on ActivityContextEngine's
            // own debounce clock instead: only *five real minutes* of
            // continued idle mouse signals commits to `Away`, not one blip.
            dwell_ms: 300_000,
        },
    ]
}

/// Family-prefix trigger match — identical convention to
/// `ocp_behavior_engine`'s own private `trigger_matches` (a trailing `.`
/// matches any subtype); duplicated rather than shared across crates, same
/// choice every provider adapter in `ocp-llm-router` makes for its own small
/// mapping functions rather than factoring out a shared-but-barely-used
/// helper crate.
fn trigger_matches(trigger: &str, event_type: &str) -> bool {
    if let Some(prefix) = trigger.strip_suffix('.') {
        event_type.starts_with(prefix) && event_type[prefix.len()..].starts_with('.')
    } else {
        trigger == event_type
    }
}
