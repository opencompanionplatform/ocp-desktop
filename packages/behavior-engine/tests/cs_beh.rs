//! CS-BEH — Behavior Engine conformance (BEHAVIOR_ENGINE.md, STATE_MACHINE.md
//! §2). Tests the one reference implementation (`DeterministicEngine`)
//! concretely, the same shape as CS-PLG against `PluginHost` — the Behavior
//! Engine has no stated swap-test requirement (NFR-001 is Runtime-specific,
//! ADR-0003), so there's no generic certify()-style harness here.

use std::collections::BTreeMap;

use ocp_behavior_api::{
    Action, AnimationPriority, Behavior, CompanionState, Rule, RuleSet, RulesEngine,
};
use ocp_behavior_engine::DeterministicEngine;
use ocp_shared_types::Envelope;
use serde_json::json;

fn ev(event_type: &str, source: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, source, data).expect("valid conformance envelope")
}

fn engine_with(rules: Vec<Rule>, behaviors: Vec<Behavior>) -> DeterministicEngine {
    let mut map = BTreeMap::new();
    for b in behaviors {
        map.insert(b.id.clone(), b);
    }
    DeterministicEngine::new(RuleSet {
        rules,
        behaviors: map,
    })
}

fn rule(
    id: &str,
    trigger: &str,
    priority: i32,
    emotion_to: Option<&str>,
    behavior_id: &str,
) -> Rule {
    Rule {
        id: id.to_owned(),
        trigger: trigger.to_owned(),
        priority,
        emotion_to: emotion_to.map(str::to_owned),
        behavior_id: behavior_id.to_owned(),
    }
}

// --- Basic trigger -> triggered -> completed round trip ---------------------

#[test]
fn matched_rule_emits_triggered_and_completed() {
    let mut engine = engine_with(
        vec![rule("r1", "ocp.runtime.input-captured", 0, None, "noop")],
        vec![Behavior {
            id: "noop".to_owned(),
            actions: vec![],
        }],
    );
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    let out = engine.handle(&cause);

    assert_eq!(out.len(), 2, "expected triggered + completed, got {out:?}");
    assert_eq!(out[0].event_type, "ocp.behavior.triggered");
    assert_eq!(out[0].source, "behavior");
    assert_eq!(out[0].correlation_id, Some(cause.id));
    assert_eq!(out[0].data["ruleId"], "r1");
    assert_eq!(out[0].data["trigger"], "ocp.runtime.input-captured");
    assert!(out[0].data["losingCandidates"]
        .as_array()
        .unwrap()
        .is_empty());

    assert_eq!(out[1].event_type, "ocp.behavior.completed");
    assert_eq!(out[1].data["outcome"], "completed");
    assert_eq!(out[1].correlation_id, Some(cause.id));
}

// --- Arbitration (BEHAVIOR_ENGINE.md "Arbitration") -------------------------

#[test]
fn higher_priority_rule_wins_and_loser_is_logged() {
    let mut engine = engine_with(
        vec![
            rule("low", "ocp.runtime.input-captured", 1, None, "noop"),
            rule("high", "ocp.runtime.input-captured", 10, None, "noop"),
        ],
        vec![Behavior {
            id: "noop".to_owned(),
            actions: vec![],
        }],
    );
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    let out = engine.handle(&cause);

    let triggered = &out[0];
    assert_eq!(triggered.data["ruleId"], "high", "higher priority must win");
    let losers = triggered.data["losingCandidates"].as_array().unwrap();
    assert_eq!(
        losers,
        &vec![json!("low")],
        "loser must be logged, not silently dropped"
    );
}

#[test]
fn tie_break_is_deterministic_by_rule_id() {
    // Same priority: lexicographically smaller id wins, both runs agree.
    let make = || {
        engine_with(
            vec![
                rule("bbb", "ocp.runtime.input-captured", 5, None, "noop"),
                rule("aaa", "ocp.runtime.input-captured", 5, None, "noop"),
            ],
            vec![Behavior {
                id: "noop".to_owned(),
                actions: vec![],
            }],
        )
    };
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    for _ in 0..3 {
        let mut engine = make();
        let out = engine.handle(&cause);
        assert_eq!(out[0].data["ruleId"], "aaa");
    }
}

// --- Emotion transitions (RFC-0001) -----------------------------------------

#[test]
fn emotion_transition_emits_emotion_changed_and_updates_state() {
    let mut engine = engine_with(
        vec![rule(
            "r1",
            "ocp.behavior.emotion-trigger",
            0,
            Some("happy"),
            "noop",
        )],
        vec![Behavior {
            id: "noop".to_owned(),
            actions: vec![],
        }],
    );
    assert_eq!(engine.emotion(), "neutral");
    let cause = ev("ocp.behavior.emotion-trigger", "behavior", json!({}));
    let out = engine.handle(&cause);

    let emotion_ev = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.emotion-changed")
        .expect("emotion-changed must be emitted");
    assert_eq!(emotion_ev.data["from"], "neutral");
    assert_eq!(emotion_ev.data["to"], "happy");
    assert_eq!(emotion_ev.data["causeRuleId"], "r1");
    assert_eq!(emotion_ev.correlation_id, Some(cause.id));
    assert_eq!(engine.emotion(), "happy");
}

#[test]
fn repeating_the_same_emotion_does_not_re_emit() {
    let mut engine = engine_with(
        vec![rule(
            "r1",
            "ocp.behavior.emotion-trigger",
            0,
            Some("happy"),
            "noop",
        )],
        vec![Behavior {
            id: "noop".to_owned(),
            actions: vec![],
        }],
    );
    let cause = ev("ocp.behavior.emotion-trigger", "behavior", json!({}));
    let _ = engine.handle(&cause);
    let out2 = engine.handle(&cause);
    assert!(
        !out2
            .iter()
            .any(|e| e.event_type == "ocp.behavior.emotion-changed"),
        "no-op transition to the same emotion must not re-emit"
    );
}

// --- Companion state machine (STATE_MACHINE.md §2) --------------------------

#[test]
fn enter_state_action_applies_valid_transition_and_emits_state_changed() {
    let mut engine = engine_with(
        vec![rule("r1", "ocp.runtime.input-captured", 0, None, "listen")],
        vec![Behavior {
            id: "listen".to_owned(),
            actions: vec![Action::EnterState {
                state: CompanionState::Listening,
            }],
        }],
    );
    assert_eq!(engine.companion_state(), CompanionState::Idle);
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    let out = engine.handle(&cause);

    let state_ev = out
        .iter()
        .find(|e| e.event_type == "ocp.companion.state-changed")
        .expect("state-changed must be emitted");
    assert_eq!(state_ev.source, "companion");
    assert_eq!(state_ev.data["from"], "Idle");
    assert_eq!(state_ev.data["to"], "Listening");
    assert_eq!(engine.companion_state(), CompanionState::Listening);

    let completed = out.last().unwrap();
    assert_eq!(completed.event_type, "ocp.behavior.completed");
    assert_eq!(completed.data["outcome"], "completed");
}

#[test]
fn illegal_state_transition_fails_the_behavior_without_crashing() {
    // Idle -> Speaking directly is not a legal edge (STATE_MACHINE.md §2).
    let mut engine = engine_with(
        vec![rule("r1", "ocp.runtime.input-captured", 0, None, "bad")],
        vec![Behavior {
            id: "bad".to_owned(),
            actions: vec![Action::EnterState {
                state: CompanionState::Speaking,
            }],
        }],
    );
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    let out = engine.handle(&cause);

    assert!(
        !out.iter()
            .any(|e| e.event_type == "ocp.companion.state-changed"),
        "an illegal transition must not be applied"
    );
    assert_eq!(
        engine.companion_state(),
        CompanionState::Idle,
        "state must be unchanged"
    );
    let completed = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.completed")
        .expect("completed must still be emitted");
    assert_eq!(completed.data["outcome"], "failed");
}

#[test]
fn interrupted_from_any_state_returns_to_idle() {
    let mut engine = engine_with(
        vec![rule("r1", "ocp.runtime.input-captured", 0, None, "listen")],
        vec![Behavior {
            id: "listen".to_owned(),
            actions: vec![Action::EnterState {
                state: CompanionState::Listening,
            }],
        }],
    );
    let trigger = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    engine.handle(&trigger);
    assert_eq!(engine.companion_state(), CompanionState::Listening);

    let interrupt = ev(
        "ocp.companion.interrupted",
        "companion",
        json!({ "companionId": engine.companion_id(), "interruptedState": "Listening", "reason": "user override" }),
    );
    let out = engine.handle(&interrupt);

    assert_eq!(out.len(), 1);
    assert_eq!(out[0].event_type, "ocp.companion.state-changed");
    assert_eq!(out[0].data["from"], "Listening");
    assert_eq!(out[0].data["to"], "Idle");
    assert_eq!(engine.companion_state(), CompanionState::Idle);
}

// --- Robustness (SEC-004-style containment, never a crash) ------------------

#[test]
fn rule_pointing_at_missing_behavior_reports_failed_not_a_panic() {
    let mut engine = engine_with(
        vec![rule(
            "r1",
            "ocp.runtime.input-captured",
            0,
            None,
            "does-not-exist",
        )],
        vec![], // no behaviors defined at all
    );
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    let out = engine.handle(&cause);

    let completed = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.completed")
        .expect("completed must still be emitted");
    assert_eq!(completed.data["outcome"], "failed");
    assert_eq!(completed.data["behaviorId"], "does-not-exist");
}

#[test]
fn unmatched_event_is_ignored_not_errored() {
    let mut engine = engine_with(vec![], vec![]);
    let cause = ev("ocp.memory.record-written", "memory-layer", json!({}));
    let out = engine.handle(&cause);
    assert!(out.is_empty());
}

// --- Trigger matching --------------------------------------------------------

#[test]
fn family_prefix_trigger_matches_subtypes() {
    // "os-telemetry" isn't a registered EVENT_API context yet (that's I4, OS
    // Plugins, not started) -- use an already-valid context (ocp.plugin.*)
    // just to exercise the family-prefix matching logic itself.
    let mut engine = engine_with(
        vec![rule("r1", "ocp.plugin.", 0, None, "noop")],
        vec![Behavior {
            id: "noop".to_owned(),
            actions: vec![],
        }],
    );
    let cause = ev(
        "ocp.plugin.weather-updated",
        "com.example.hello",
        json!({ "tempC": 21 }),
    );
    let out = engine.handle(&cause);
    assert_eq!(out[0].event_type, "ocp.behavior.triggered");
    assert_eq!(out[0].data["ruleId"], "r1");
}

// --- Actions translate to RUNTIME_API request-facts -------------------------

#[test]
fn bubble_and_speech_actions_translate_to_runtime_request_facts() {
    let mut engine = engine_with(
        vec![rule("r1", "ocp.runtime.input-captured", 0, None, "greet")],
        vec![Behavior {
            id: "greet".to_owned(),
            actions: vec![
                Action::Bubble {
                    text: "hi".to_owned(),
                    tone: "happy".to_owned(),
                },
                Action::Speech {
                    text: "hello there".to_owned(),
                },
            ],
        }],
    );
    let cause = ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    );
    let out = engine.handle(&cause);

    let bubble = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.bubble-requested")
        .unwrap();
    assert_eq!(bubble.data["text"], "hi");
    assert_eq!(bubble.data["tone"], "happy");
    assert_eq!(bubble.correlation_id, Some(cause.id));
    bubble
        .validate()
        .expect("must be a valid envelope (CS-EVT)");

    let speech = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.speech-requested")
        .unwrap();
    assert_eq!(speech.data["text"], "hello there");
    speech
        .validate()
        .expect("must be a valid envelope (CS-EVT)");
}

// --- Animation FSM (RUNTIME_API §2.2, priority preemption) ------------------

fn animation_behavior(id: &str, animation_id: &str, priority: AnimationPriority) -> Behavior {
    Behavior {
        id: id.to_owned(),
        actions: vec![Action::Animation {
            animation_id: animation_id.to_owned(),
            looped: false,
            priority,
            blend_ms: 100,
        }],
    }
}

fn input_captured() -> Envelope {
    ev(
        "ocp.runtime.input-captured",
        "runtime",
        json!({ "inputId": uuid::Uuid::now_v7(), "modality": "click", "target": "companion" }),
    )
}

#[test]
fn animation_action_starts_and_is_tracked() {
    let mut engine = engine_with(
        vec![rule("r1", "ocp.runtime.input-captured", 0, None, "wave")],
        vec![animation_behavior(
            "wave",
            "wave",
            AnimationPriority::Reactive,
        )],
    );
    assert!(engine.current_animation().is_none());
    let out = engine.handle(&input_captured());

    let anim = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.animation-requested")
        .unwrap();
    assert_eq!(anim.data["animationId"], "wave");
    assert_eq!(anim.data["priority"], "reactive");
    assert_eq!(anim.data["blendMs"], 100);
    assert_eq!(
        engine.current_animation(),
        Some(("wave", AnimationPriority::Reactive))
    );
}

#[test]
fn higher_priority_animation_preempts_lower() {
    let mut engine = engine_with(
        vec![
            rule("idle-r", "ocp.runtime.input-captured", 0, None, "idle-anim"),
            rule(
                "interrupt-r",
                "ocp.runtime.bubble-shown",
                0,
                None,
                "interrupt-anim",
            ),
        ],
        vec![
            animation_behavior("idle-anim", "breathe", AnimationPriority::Idle),
            animation_behavior("interrupt-anim", "startle", AnimationPriority::Interrupt),
        ],
    );
    engine.handle(&input_captured());
    assert_eq!(
        engine.current_animation(),
        Some(("breathe", AnimationPriority::Idle))
    );

    let out = engine.handle(&ev("ocp.runtime.bubble-shown", "runtime", json!({ "bubbleId": uuid::Uuid::now_v7(), "shownAt": "2026-07-20T00:00:00Z", "truncated": false })));
    assert!(
        out.iter()
            .any(|e| e.event_type == "ocp.behavior.animation-requested"
                && e.data["animationId"] == "startle"),
        "a higher-priority request must preempt the lower-priority one playing"
    );
    assert_eq!(
        engine.current_animation(),
        Some(("startle", AnimationPriority::Interrupt))
    );
}

#[test]
fn lower_priority_animation_does_not_preempt_higher() {
    let mut engine = engine_with(
        vec![
            rule(
                "interrupt-r",
                "ocp.runtime.input-captured",
                0,
                None,
                "interrupt-anim",
            ),
            rule("idle-r", "ocp.runtime.bubble-shown", 0, None, "idle-anim"),
        ],
        vec![
            animation_behavior("interrupt-anim", "startle", AnimationPriority::Interrupt),
            animation_behavior("idle-anim", "breathe", AnimationPriority::Idle),
        ],
    );
    engine.handle(&input_captured());
    assert_eq!(
        engine.current_animation(),
        Some(("startle", AnimationPriority::Interrupt))
    );

    let out = engine.handle(&ev("ocp.runtime.bubble-shown", "runtime", json!({ "bubbleId": uuid::Uuid::now_v7(), "shownAt": "2026-07-20T00:00:00Z", "truncated": false })));
    assert!(
        !out.iter()
            .any(|e| e.event_type == "ocp.behavior.animation-requested"),
        "a lower-priority request must not preempt what's already playing"
    );
    assert_eq!(
        engine.current_animation(),
        Some(("startle", AnimationPriority::Interrupt)),
        "the higher-priority animation must keep playing"
    );
}

#[test]
fn animation_completed_clears_tracked_animation_and_allows_a_new_one() {
    let mut engine = engine_with(
        vec![
            rule("r1", "ocp.runtime.input-captured", 0, None, "idle-anim-1"),
            rule("r2", "ocp.runtime.bubble-shown", 0, None, "idle-anim-2"),
        ],
        vec![
            animation_behavior("idle-anim-1", "breathe", AnimationPriority::Idle),
            animation_behavior("idle-anim-2", "look-around", AnimationPriority::Idle),
        ],
    );
    engine.handle(&input_captured());
    assert_eq!(
        engine.current_animation(),
        Some(("breathe", AnimationPriority::Idle))
    );

    engine.handle(&ev(
        "ocp.runtime.animation-completed",
        "runtime",
        json!({ "animationId": "breathe", "outcome": "finished" }),
    ));
    assert!(
        engine.current_animation().is_none(),
        "completion must clear the tracked animation"
    );

    // Same priority as before -- would have been blocked had the slot still
    // been considered occupied.
    let out = engine.handle(&ev("ocp.runtime.bubble-shown", "runtime", json!({ "bubbleId": uuid::Uuid::now_v7(), "shownAt": "2026-07-20T00:00:00Z", "truncated": false })));
    assert!(out
        .iter()
        .any(|e| e.data.get("animationId") == Some(&json!("look-around"))));
    assert_eq!(
        engine.current_animation(),
        Some(("look-around", AnimationPriority::Idle))
    );
}

// --- Behaviors loadable as data (prep for character packages, I8) ----------

#[test]
fn ruleset_loads_from_external_json_data() {
    let json_str = include_str!("fixtures/default_rules.json");
    let rules: RuleSet =
        serde_json::from_str(json_str).expect("fixture must deserialize into RuleSet");
    assert_eq!(rules.rules.len(), 1);
    assert_eq!(rules.rules[0].id, "greet-on-input");
    assert!(rules.behaviors.contains_key("greet"));

    // Drive the engine with it end-to-end -- this is real external JSON
    // data selecting real behavior, not just a type-level round trip.
    let mut engine = DeterministicEngine::new(rules);
    let out = engine.handle(&input_captured());

    let bubble = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.bubble-requested")
        .unwrap();
    assert_eq!(bubble.data["text"], "hi!");
    let anim = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.animation-requested")
        .unwrap();
    assert_eq!(anim.data["animationId"], "wave");
    assert_eq!(engine.emotion(), "happy");
}
