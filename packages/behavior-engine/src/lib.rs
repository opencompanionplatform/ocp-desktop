//! `DeterministicEngine` — the OCP Behavior Engine reference implementation
//! (BEHAVIOR_ENGINE.md). Implements `ocp_behavior_api::RulesEngine`: trigger
//! match → arbitration (highest `priority` wins, losers logged, deterministic
//! tie-break by rule id) → behavior execution → actions → `completed`.
//!
//! **Zero LLM calls (RFC-0001), enforced structurally**: this crate has no
//! AI Router / HTTP / network dependency at all — there is nothing here that
//! *could* call a model, not just a rule against doing so.

#![forbid(unsafe_code)] // SEC-042

use std::collections::BTreeMap;

use ocp_behavior_api::{
    Action, AnimationPriority, Behavior, CompanionState, Rule, RuleSet, RulesEngine,
};
use ocp_shared_types::Envelope;
use uuid::Uuid;

/// A small illustrative rule set for the `ocp-kernel` walking-skeleton demo
/// — not a real character package (I8 will define that format). Reacts to
/// `ocp.runtime.input-captured` (a click in the running Godot window) with a
/// **fixed, canned** bubble + animation + emotion change.
///
/// Deliberately *not* an echo of whatever the input said: the Behavior
/// Engine never calls an LLM (RFC-0001) and has no templating mechanism —
/// behaviors are static declarative data, so there is nothing here that
/// *could* read back arbitrary captured text into a reply. A real
/// conversational response belongs to the AI Router (I5), layered beside
/// this engine, not inside it.
#[must_use]
pub fn demo_rules() -> RuleSet {
    let mut behaviors = BTreeMap::new();
    behaviors.insert(
        "acknowledge-click".to_owned(),
        Behavior {
            id: "acknowledge-click".to_owned(),
            actions: vec![
                Action::Bubble {
                    text: "I noticed that!".to_owned(),
                    tone: "happy".to_owned(),
                },
                Action::Animation {
                    animation_id: "wave".to_owned(),
                    looped: false,
                    priority: AnimationPriority::Reactive,
                    blend_ms: 150,
                },
            ],
        },
    );
    RuleSet {
        rules: vec![Rule {
            id: "click-ack".to_owned(),
            trigger: "ocp.runtime.input-captured".to_owned(),
            priority: 0,
            emotion_to: Some("happy".to_owned()),
            behavior_id: "acknowledge-click".to_owned(),
        }],
        behaviors,
    }
}

/// The deterministic reference engine. One companion per instance (a
/// multi-companion core is out of scope for this slice).
pub struct DeterministicEngine {
    companion_id: Uuid,
    state: CompanionState,
    emotion: String,
    rules: RuleSet,
    /// Animation FSM state: what's tracked as currently playing, per the
    /// priority rule on `ocp_behavior_api::AnimationPriority`. Cleared when
    /// `ocp.runtime.animation-completed` arrives from the runtime.
    current_animation: Option<(String, AnimationPriority)>,
}

impl DeterministicEngine {
    #[must_use]
    pub fn new(rules: RuleSet) -> Self {
        Self {
            companion_id: Uuid::now_v7(),
            state: CompanionState::Idle,
            emotion: "neutral".to_owned(),
            rules,
            current_animation: None,
        }
    }

    #[must_use]
    pub fn with_companion_id(mut self, id: Uuid) -> Self {
        self.companion_id = id;
        self
    }

    #[must_use]
    pub fn companion_id(&self) -> Uuid {
        self.companion_id
    }

    // --- Envelope construction ---------------------------------------------
    // Every fact this engine emits correlates back to the single inbound
    // event that caused it (NFR-004 convention used throughout the
    // project). `.expect(...)` is safe here: every event type/context is a
    // fixed literal this crate controls, never user input — a failure would
    // be a genuine programming bug, not a runtime condition to recover from.

    fn triggered(
        &self,
        rule_id: &str,
        behavior_id: &str,
        trigger: &str,
        losers: &[String],
        cause: &Envelope,
    ) -> Envelope {
        let data = serde_json::json!({
            "behaviorId": behavior_id,
            "companionId": self.companion_id,
            "ruleId": rule_id,
            "trigger": trigger,
            "losingCandidates": losers,
        });
        Envelope::new("ocp.behavior.triggered", "behavior", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }

    fn completed(&self, behavior_id: &str, outcome: &str, cause: &Envelope) -> Envelope {
        let data = serde_json::json!({
            "behaviorId": behavior_id,
            "companionId": self.companion_id,
            "outcome": outcome,
            "durationMs": 0,
        });
        Envelope::new("ocp.behavior.completed", "behavior", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }

    fn emotion_changed(
        &self,
        from: &str,
        to: &str,
        cause_rule_id: &str,
        cause: &Envelope,
    ) -> Envelope {
        let data = serde_json::json!({
            "companionId": self.companion_id,
            "from": from,
            "to": to,
            "causeRuleId": cause_rule_id,
        });
        Envelope::new("ocp.behavior.emotion-changed", "behavior", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }

    fn bubble(&self, text: &str, tone: &str, cause: &Envelope) -> Envelope {
        let data = serde_json::json!({
            "bubbleId": Uuid::now_v7(),
            "text": text,
            "tone": tone,
            "anchor": "companion",
        });
        Envelope::new("ocp.behavior.bubble-requested", "behavior", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }

    fn speech(&self, text: &str, cause: &Envelope) -> Envelope {
        let data = serde_json::json!({
            "speechId": Uuid::now_v7(),
            "text": text,
        });
        Envelope::new("ocp.behavior.speech-requested", "behavior", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }

    fn animation(
        &self,
        animation_id: &str,
        looped: bool,
        priority: AnimationPriority,
        blend_ms: u64,
        cause: &Envelope,
    ) -> Envelope {
        let priority_str = match priority {
            AnimationPriority::Idle => "idle",
            AnimationPriority::Reactive => "reactive",
            AnimationPriority::Interrupt => "interrupt",
        };
        let data = serde_json::json!({
            "animationId": animation_id,
            "loop": looped,
            "priority": priority_str,
            "blendMs": blend_ms,
        });
        Envelope::new("ocp.behavior.animation-requested", "behavior", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }

    fn state_changed(
        &self,
        from: CompanionState,
        to: CompanionState,
        cause: &Envelope,
    ) -> Envelope {
        let data = serde_json::json!({
            "companionId": self.companion_id,
            "from": from,
            "to": to,
        });
        Envelope::new("ocp.companion.state-changed", "companion", data)
            .expect("engine-constructed envelope is always valid")
            .with_correlation(cause.id)
    }
}

/// Family-prefix trigger match, same convention as the event bus: a trigger
/// ending in `.` matches any subtype (e.g. `"ocp.os-telemetry."` matches
/// `"ocp.os-telemetry.cpu-high"`); otherwise it's an exact match.
fn trigger_matches(trigger: &str, event_type: &str) -> bool {
    if let Some(prefix) = trigger.strip_suffix('.') {
        event_type.starts_with(prefix) && event_type[prefix.len()..].starts_with('.')
    } else {
        trigger == event_type
    }
}

impl RulesEngine for DeterministicEngine {
    fn handle(&mut self, event: &Envelope) -> Vec<Envelope> {
        let mut out = Vec::new();

        // Animation FSM feedback: whatever was tracked as playing is done
        // now (finished, cancelled, or missing-asset all free the slot).
        // This is a side effect, not an early return -- a Rule may still
        // match this same event too (e.g. to chain a follow-up behavior).
        if event.event_type == "ocp.runtime.animation-completed" {
            self.current_animation = None;
        }

        // Interrupt is handled outside normal arbitration: "any state ->
        // Interrupted -> Idle" (STATE_MACHINE.md) is a user override, not
        // something a Rule competes to win.
        if event.event_type == "ocp.companion.interrupted" {
            let old = self.state;
            if old.can_transition_to(CompanionState::Interrupted) {
                self.state = CompanionState::Idle;
                out.push(self.state_changed(old, CompanionState::Idle, event));
            }
            return out;
        }

        // Scope the borrow of `self.rules.rules` to this block so the later
        // `&mut self` mutations below aren't blocked by it.
        let (winner_id, winner_emotion_to, winner_behavior_id, losers) = {
            let mut matched: Vec<&Rule> = self
                .rules
                .rules
                .iter()
                .filter(|r| trigger_matches(&r.trigger, &event.event_type))
                .collect();
            if matched.is_empty() {
                return out; // no rule matches: ignored, never an error
            }
            // Deterministic arbitration: highest priority first; tie-break
            // by rule id so results don't depend on iteration/insertion order.
            matched.sort_by(|a, b| b.priority.cmp(&a.priority).then_with(|| a.id.cmp(&b.id)));
            let winner = matched[0];
            let losers: Vec<String> = matched[1..].iter().map(|r| r.id.clone()).collect();
            (
                winner.id.clone(),
                winner.emotion_to.clone(),
                winner.behavior_id.clone(),
                losers,
            )
        };

        out.push(self.triggered(
            &winner_id,
            &winner_behavior_id,
            &event.event_type,
            &losers,
            event,
        ));

        if let Some(new_emotion) = &winner_emotion_to {
            if *new_emotion != self.emotion {
                out.push(self.emotion_changed(
                    &self.emotion.clone(),
                    new_emotion,
                    &winner_id,
                    event,
                ));
                self.emotion = new_emotion.clone();
            }
        }

        let Some(behavior): Option<Behavior> =
            self.rules.behaviors.get(&winner_behavior_id).cloned()
        else {
            // Data bug (a rule points at a behavior id that doesn't exist in
            // the rule set) -- contained, never a crash (SEC-004 posture),
            // reported as a failed completion rather than silently dropped.
            out.push(self.completed(&winner_behavior_id, "failed", event));
            return out;
        };

        let mut failed = false;
        for action in &behavior.actions {
            match action {
                Action::Bubble { text, tone } => out.push(self.bubble(text, tone, event)),
                Action::Speech { text } => out.push(self.speech(text, event)),
                Action::EnterState { state } => {
                    if self.state.can_transition_to(*state) {
                        let old = self.state;
                        self.state = *state;
                        out.push(self.state_changed(old, *state, event));
                    } else {
                        // An illegal transition halts the behavior rather
                        // than leaving the FSM in a partially-applied,
                        // undefined place.
                        failed = true;
                        break;
                    }
                }
                Action::Animation {
                    animation_id,
                    looped,
                    priority,
                    blend_ms,
                } => {
                    let can_start = match &self.current_animation {
                        None => true,
                        Some((_, current)) => *priority >= *current,
                    };
                    if can_start {
                        self.current_animation = Some((animation_id.clone(), *priority));
                        out.push(self.animation(
                            animation_id,
                            *looped,
                            *priority,
                            *blend_ms,
                            event,
                        ));
                    }
                    // Lower priority than what's already playing: dropped,
                    // not queued -- BEHAVIOR_ENGINE.md only requires that
                    // `interrupt` *may* preempt, not that every request
                    // eventually plays. Not a failure: the behavior
                    // continues with its remaining actions.
                }
            }
        }

        out.push(self.completed(
            &behavior.id,
            if failed { "failed" } else { "completed" },
            event,
        ));
        out
    }

    fn companion_state(&self) -> CompanionState {
        self.state
    }

    fn emotion(&self) -> &str {
        &self.emotion
    }

    fn current_animation(&self) -> Option<(&str, AnimationPriority)> {
        self.current_animation
            .as_ref()
            .map(|(id, p)| (id.as_str(), *p))
    }
}
