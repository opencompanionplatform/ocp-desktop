//! OCP Behavior Engine contract types — BEHAVIOR_ENGINE.md, STATE_MACHINE.md
//! §2 (Companion). The Behavior Engine decides what the companion does next:
//! **deterministic rules + FSM only, never an LLM call** (RFC-0001) —
//! enforced structurally by this crate (and `behavior-engine`) having no AI
//! Router / network dependency at all, not merely by convention or a runtime
//! check.
//!
//! Model (BEHAVIOR_ENGINE.md): Trigger → Rule evaluation → Arbitration →
//! Behavior execution → Actions → `ocp.behavior.completed`. Behaviors are
//! **data** (declarative `Rule`/`Behavior`/`Action` values), not hardcoded
//! branches in the engine (Constitution Article 10) — this is what lets
//! character packages ship their own behaviors later (I8) without touching
//! engine code.
//!
//! Unlike RUNTIME_API, the Behavior Engine has no stated swap-test
//! requirement (NFR-001 was specific to the Runtime per ADR-0003) — there is
//! exactly one reference implementation (`ocp-behavior-engine`), so this
//! crate holds the data model + a light trait for testability, and its
//! conformance suite (CS-BEH) lives as concrete integration tests against
//! that one implementation, the same shape as CS-PLG against `PluginHost`.

#![forbid(unsafe_code)] // SEC-042

use std::collections::BTreeMap;

use ocp_shared_types::Envelope;
use serde::{Deserialize, Serialize};

// --- Companion state machine (STATE_MACHINE.md §2 Companion) ----------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub enum CompanionState {
    Idle,
    Listening,
    Thinking,
    Acting,
    Speaking,
    Interrupted,
    Degraded,
}

impl CompanionState {
    /// STATE_MACHINE.md §2 gives the base cycle (Idle → Listening → Thinking
    /// → Acting → Speaking → Idle), "any state → Interrupted → Idle", and
    /// "Thinking → Degraded → Speaking (fallback)". The doc doesn't enumerate
    /// every edge explicitly; this validator makes two interpretive
    /// additions beyond the literal diagram, called out here for review
    /// rather than silently assumed:
    ///   - `Idle → Thinking` directly: a proactive trigger (e.g. an OS
    ///     telemetry plugin event) has nothing to "listen" to first.
    ///   - `Listening → Idle` and `Thinking → Idle`: a rule may legitimately
    ///     decide no behavior fires (e.g. a matched trigger with no
    ///     applicable rule, or a timeout) — this isn't a hidden state, it's
    ///     the existing Idle state, just reached by a shorter path.
    #[must_use]
    pub fn can_transition_to(self, next: CompanionState) -> bool {
        use CompanionState::{Acting, Degraded, Idle, Interrupted, Listening, Speaking, Thinking};
        if next == Interrupted {
            return true; // any state -> Interrupted (user override)
        }
        match self {
            Interrupted => next == Idle,
            Idle => matches!(next, Listening | Thinking),
            Listening => matches!(next, Thinking | Idle),
            Thinking => matches!(next, Acting | Speaking | Degraded | Idle),
            Degraded => matches!(next, Speaking),
            Acting => matches!(next, Speaking | Idle),
            Speaking => matches!(next, Idle),
        }
    }
}

impl core::fmt::Display for CompanionState {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let s = match self {
            Self::Idle => "Idle",
            Self::Listening => "Listening",
            Self::Thinking => "Thinking",
            Self::Acting => "Acting",
            Self::Speaking => "Speaking",
            Self::Interrupted => "Interrupted",
            Self::Degraded => "Degraded",
        };
        f.write_str(s)
    }
}

// --- Behaviors as data (BEHAVIOR_ENGINE.md "Behaviors are data") ------------

/// `ocp.behavior.animation-requested`'s priority enum (RUNTIME_API §2.2).
/// Declaration order is deliberate: derived `Ord` gives
/// `Idle < Reactive < Interrupt`, matching "`interrupt` may cancel a running
/// animation" — a higher-priority request may replace a lower-priority one
/// already playing; a lower-priority request never preempts a higher one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AnimationPriority {
    Idle,
    Reactive,
    Interrupt,
}

/// One action a behavior performs. Deliberately a small closed set for this
/// slice — mirrors the RUNTIME_API request-facts a behavior is already
/// allowed to emit (§2). Adding a new action means adding a variant here
/// (reviewable), never a free-form script.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "kind")]
pub enum Action {
    /// Emits `ocp.behavior.bubble-requested`.
    Bubble { text: String, tone: String },
    /// Emits `ocp.behavior.speech-requested`.
    Speech { text: String },
    /// Requests the companion enter a new runtime state; validated against
    /// `CompanionState::can_transition_to` before it's applied. Emits
    /// `ocp.companion.state-changed` on success.
    EnterState { state: CompanionState },
    /// Emits `ocp.behavior.animation-requested` (RUNTIME_API §2.2), subject
    /// to the animation-FSM priority rule above — the engine tracks what's
    /// currently playing and drops (doesn't queue) a request that can't
    /// preempt it.
    Animation {
        animation_id: String,
        looped: bool,
        priority: AnimationPriority,
        blend_ms: u64,
    },
}

/// A declarative, reviewable unit: what happens when a `Rule` selects it
/// (BEHAVIOR_ENGINE.md "Behavior").
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Behavior {
    pub id: String,
    pub actions: Vec<Action>,
}

/// A condition over a trigger that selects a `Behavior`
/// (BEHAVIOR_ENGINE.md "Rule"). Condition is scoped to trigger-match +
/// priority for this slice; full condition-over-companion-state/persona
/// constraints is a follow-up once character packages (I8) give it
/// something real to condition on.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rule {
    pub id: String,
    /// Event type this rule matches. Supports the same family-prefix
    /// convention as the event bus (a trailing `.` matches any subtype),
    /// e.g. `"ocp.os-telemetry."`.
    pub trigger: String,
    /// Higher fires first when multiple rules match the same trigger
    /// (BEHAVIOR_ENGINE.md "Arbitration"); losers are logged, never silently
    /// dropped (`ocp.behavior.triggered.losingCandidates`).
    pub priority: i32,
    /// Emotion this rule transitions to, if any (RFC-0001: emotion values
    /// are character-defined strings, not a fixed enum).
    #[serde(default)]
    pub emotion_to: Option<String>,
    pub behavior_id: String,
}

/// The full declarative rule/behavior definition a companion runs —
/// eventually shipped inside a character package (I8); a fixed default set
/// for now (`ocp-behavior-engine::default_rules`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleSet {
    pub rules: Vec<Rule>,
    pub behaviors: BTreeMap<String, Behavior>,
}

// --- The engine contract ------------------------------------------------

/// A deterministic behavior engine. Implementations must not call an
/// LLM/AI Router (RFC-0001) — enforced by not depending on one, not by a
/// runtime assertion here.
pub trait RulesEngine {
    /// Handle one inbound event, returning every fact emitted as a result
    /// (`ocp.behavior.triggered`/`completed`/`emotion-changed`,
    /// `ocp.companion.state-changed`, and any RUNTIME_API request-facts the
    /// selected behavior's actions produce). Unmatched events return an
    /// empty vec — never an error (mirrors RUNTIME_API's unknown-event rule).
    fn handle(&mut self, event: &Envelope) -> Vec<Envelope>;

    fn companion_state(&self) -> CompanionState;

    /// Current emotion name (character-defined string, RFC-0001). `"neutral"`
    /// until the first transition.
    fn emotion(&self) -> &str;

    /// The animation currently tracked as playing, if any (id, priority) —
    /// cleared when `ocp.runtime.animation-completed` is handled.
    fn current_animation(&self) -> Option<(&str, AnimationPriority)>;
}
