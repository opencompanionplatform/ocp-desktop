//! CS-ACT — Activity Context Engine conformance (RFC-0005). Tests the one
//! reference implementation (`ActivityContextEngine`) concretely, the same
//! shape CS-BEH tests `DeterministicEngine` — RFC-0005 states no swap-test
//! requirement (NFR-001 is Runtime-specific, ADR-0003), so there's no
//! generic certify()-style harness here either.

use chrono::{Duration, TimeZone, Utc};
use ocp_activity_context::{ActivityContextEngine, ActivityState, Interpreter, SignalCondition};
use ocp_shared_types::Envelope;
use serde_json::json;

fn ev(event_type: &str, source: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, source, data).expect("valid conformance envelope")
}

fn t(offset_secs: i64) -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 7, 21, 12, 0, 0).unwrap() + Duration::seconds(offset_secs)
}

#[allow(clippy::too_many_arguments)]
fn interp(
    id: &str,
    signal_trigger: &str,
    candidate_state: ActivityState,
    confidence: f64,
    condition: SignalCondition,
    evidence_tag: &str,
    dwell_ms: u64,
) -> Interpreter {
    Interpreter {
        id: id.to_owned(),
        signal_trigger: signal_trigger.to_owned(),
        candidate_state,
        confidence,
        condition,
        evidence_tag: evidence_tag.to_owned(),
        dwell_ms,
    }
}

fn foreground(process_name: &str) -> Envelope {
    ev(
        "ocp.plugin.os-telemetry-foreground-changed",
        "com.ocp.os-sensors",
        json!({ "pluginId": "com.ocp.os-sensors", "windowTitle": "", "processName": process_name }),
    )
}

// --- Debounce (RFC-0005 "Debounce") -----------------------------------------

#[test]
fn candidate_below_dwell_does_not_commit() {
    let mut engine = ActivityContextEngine::new(vec![interp(
        "coding",
        "ocp.plugin.os-telemetry-foreground-changed",
        ActivityState::Coding,
        0.9,
        SignalCondition::FieldContainsAny {
            field: "processName".to_owned(),
            any_of: vec!["devenv".to_owned()],
        },
        "foreground:devenv.exe",
        5000,
    )]);
    assert_eq!(engine.current_state(), &ActivityState::Unknown);

    let out = engine.handle_signal(&foreground("devenv.exe"), t(0));
    assert!(out.is_none(), "must not commit before dwell elapses");
    assert_eq!(engine.current_state(), &ActivityState::Unknown);

    let out = engine.handle_signal(&foreground("devenv.exe"), t(2));
    assert!(out.is_none(), "2s < 5000ms dwell, still pending");
    assert_eq!(engine.current_state(), &ActivityState::Unknown);
}

#[test]
fn candidate_holding_past_dwell_commits_and_emits_state_changed() {
    let mut engine = ActivityContextEngine::new(vec![interp(
        "coding",
        "ocp.plugin.os-telemetry-foreground-changed",
        ActivityState::Coding,
        0.9,
        SignalCondition::FieldContainsAny {
            field: "processName".to_owned(),
            any_of: vec!["devenv".to_owned()],
        },
        "foreground:devenv.exe",
        5000,
    )]);
    let cause1 = foreground("devenv.exe");
    assert!(engine.handle_signal(&cause1, t(0)).is_none());

    let cause2 = foreground("devenv.exe");
    let out = engine
        .handle_signal(&cause2, t(6))
        .expect("6s >= 5000ms dwell must commit");

    assert_eq!(out.event_type, "ocp.activity.state-changed");
    assert_eq!(out.source, "activity-context");
    assert_eq!(out.data["previousState"], "Unknown");
    assert_eq!(out.data["newState"], "Coding");
    assert_eq!(out.data["confidence"], 0.9);
    assert_eq!(out.data["evidence"], json!(["foreground:devenv.exe"]));
    assert_eq!(out.correlation_id, Some(cause2.id));
    out.validate().expect("must be a valid envelope (CS-EVT)");
    assert_eq!(engine.current_state(), &ActivityState::Coding);
}

#[test]
fn a_new_candidate_replacing_a_pending_one_resets_the_dwell_clock() {
    let mut engine = ActivityContextEngine::new(vec![
        interp(
            "coding",
            "ocp.plugin.os-telemetry-foreground-changed",
            ActivityState::Coding,
            0.9,
            SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec!["devenv".to_owned()],
            },
            "foreground:devenv.exe",
            5000,
        ),
        interp(
            "meeting",
            "ocp.plugin.os-telemetry-foreground-changed",
            ActivityState::Meeting,
            0.9,
            SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec!["teams".to_owned()],
            },
            "foreground:teams.exe",
            5000,
        ),
    ]);
    assert!(engine
        .handle_signal(&foreground("devenv.exe"), t(0))
        .is_none());
    // Switches candidate before Coding's dwell elapsed -- must restart, not
    // inherit devenv's 0s start time.
    assert!(engine
        .handle_signal(&foreground("teams.exe"), t(2))
        .is_none());
    let out = engine.handle_signal(&foreground("teams.exe"), t(4));
    assert!(
        out.is_none(),
        "only 2s dwelling on Meeting so far, must not commit yet"
    );

    let out = engine
        .handle_signal(&foreground("teams.exe"), t(8))
        .expect("6s dwelling on Meeting must commit");
    assert_eq!(out.data["newState"], "Meeting");
    assert_eq!(engine.current_state(), &ActivityState::Meeting);
}

#[test]
fn repeated_signals_for_the_same_pending_candidate_accumulate_deduped_evidence() {
    let mut engine = ActivityContextEngine::new(vec![
        interp(
            "coding-fg",
            "ocp.plugin.os-telemetry-foreground-changed",
            ActivityState::Coding,
            0.9,
            SignalCondition::FieldContainsAny {
                field: "processName".to_owned(),
                any_of: vec!["devenv".to_owned()],
            },
            "foreground:devenv.exe",
            5000,
        ),
        interp(
            "coding-cpu",
            "ocp.plugin.os-telemetry-cpu-changed",
            ActivityState::Coding,
            0.6,
            SignalCondition::FieldEqualsAny {
                field: "level".to_owned(),
                any_of: vec!["high".to_owned()],
            },
            "os-telemetry-cpu:high",
            5000,
        ),
    ]);
    assert!(engine
        .handle_signal(&foreground("devenv.exe"), t(0))
        .is_none());
    assert!(engine
        .handle_signal(
            &ev(
                "ocp.plugin.os-telemetry-cpu-changed",
                "com.ocp.os-sensors",
                json!({ "pluginId": "com.ocp.os-sensors", "percent": 91.0, "level": "high" }),
            ),
            t(1),
        )
        .is_none());
    // Repeat the same foreground signal -- must not duplicate the tag.
    assert!(engine
        .handle_signal(&foreground("devenv.exe"), t(2))
        .is_none());

    let out = engine
        .handle_signal(&foreground("devenv.exe"), t(6))
        .expect("dwell elapsed");
    let evidence = out.data["evidence"].as_array().unwrap();
    assert_eq!(
        evidence.len(),
        2,
        "expected two distinct evidence tags, got {evidence:?}"
    );
    assert!(evidence.contains(&json!("foreground:devenv.exe")));
    assert!(evidence.contains(&json!("os-telemetry-cpu:high")));
}

// --- Arbitration (mirrors BEHAVIOR_ENGINE.md "losers logged, not dropped") -

#[test]
fn higher_confidence_interpreter_wins_and_loser_is_audited() {
    let mut engine = ActivityContextEngine::new(vec![
        interp(
            "low",
            "ocp.plugin.os-telemetry-foreground-changed",
            ActivityState::Reading,
            0.3,
            SignalCondition::Always,
            "foreground:generic",
            0,
        ),
        interp(
            "high",
            "ocp.plugin.os-telemetry-foreground-changed",
            ActivityState::Coding,
            0.9,
            SignalCondition::Always,
            "foreground:generic",
            0,
        ),
    ]);
    let out = engine
        .handle_signal(&foreground("devenv.exe"), t(0))
        .expect("0ms dwell commits immediately");
    assert_eq!(out.data["newState"], "Coding", "higher confidence must win");
    assert!(
        engine
            .audit_log()
            .iter()
            .any(|line| line.contains("high") && line.contains("low")),
        "losing interpreter must be logged, not silently dropped: {:?}",
        engine.audit_log()
    );
}

#[test]
fn tie_break_is_deterministic_by_interpreter_id() {
    let make = || {
        ActivityContextEngine::new(vec![
            interp(
                "bbb",
                "ocp.plugin.os-telemetry-foreground-changed",
                ActivityState::Reading,
                0.5,
                SignalCondition::Always,
                "e",
                0,
            ),
            interp(
                "aaa",
                "ocp.plugin.os-telemetry-foreground-changed",
                ActivityState::Coding,
                0.5,
                SignalCondition::Always,
                "e",
                0,
            ),
        ])
    };
    for _ in 0..3 {
        let mut engine = make();
        let out = engine.handle_signal(&foreground("x.exe"), t(0)).unwrap();
        assert_eq!(
            out.data["newState"], "Coding",
            "lexicographically smaller id (aaa) must win"
        );
    }
}

// --- No-op / unmatched paths (SEC-004-style containment) --------------------

#[test]
fn unmatched_signal_is_ignored_not_errored() {
    let mut engine = ActivityContextEngine::new(vec![interp(
        "coding",
        "ocp.plugin.os-telemetry-foreground-changed",
        ActivityState::Coding,
        0.9,
        SignalCondition::FieldContainsAny {
            field: "processName".to_owned(),
            any_of: vec!["devenv".to_owned()],
        },
        "foreground:devenv.exe",
        0,
    )]);
    let out = engine.handle_signal(
        &ev("ocp.memory.record-written", "memory-layer", json!({})),
        t(0),
    );
    assert!(out.is_none());
    assert_eq!(engine.current_state(), &ActivityState::Unknown);
}

#[test]
fn candidate_matching_the_already_active_state_is_a_no_op() {
    let mut engine = ActivityContextEngine::new(vec![interp(
        "coding",
        "ocp.plugin.os-telemetry-foreground-changed",
        ActivityState::Coding,
        0.9,
        SignalCondition::Always,
        "foreground:devenv.exe",
        0,
    )]);
    engine.handle_signal(&foreground("devenv.exe"), t(0));
    assert_eq!(engine.current_state(), &ActivityState::Coding);

    let out = engine.handle_signal(&foreground("devenv.exe"), t(1));
    assert!(out.is_none(), "already-active state must not re-emit");
}

// --- Staleness -> Unknown (RFC-0005; external decision, see module doc) ----

#[test]
fn mark_unknown_from_an_active_state_emits_state_changed_to_unknown() {
    let mut engine = ActivityContextEngine::new(vec![interp(
        "coding",
        "ocp.plugin.os-telemetry-foreground-changed",
        ActivityState::Coding,
        0.9,
        SignalCondition::Always,
        "foreground:devenv.exe",
        0,
    )]);
    let cause = foreground("devenv.exe");
    engine.handle_signal(&cause, t(0));
    assert_eq!(engine.current_state(), &ActivityState::Coding);

    let out = engine
        .mark_unknown(t(30), Some(cause.id))
        .expect("must emit on real transition");
    assert_eq!(out.data["previousState"], "Coding");
    assert_eq!(out.data["newState"], "Unknown");
    assert_eq!(out.correlation_id, Some(cause.id));
    assert_eq!(engine.current_state(), &ActivityState::Unknown);
}

#[test]
fn mark_unknown_when_already_unknown_is_a_no_op() {
    let mut engine = ActivityContextEngine::new(vec![]);
    assert_eq!(engine.current_state(), &ActivityState::Unknown);
    assert!(engine.mark_unknown(t(0), None).is_none());
}

// --- SignalCondition semantics ----------------------------------------------

#[test]
fn field_equals_any_is_case_sensitive_exact_match() {
    let cond = SignalCondition::FieldEqualsAny {
        field: "level".to_owned(),
        any_of: vec!["high".to_owned()],
    };
    assert!(cond.matches(&json!({ "level": "high" })));
    assert!(
        !cond.matches(&json!({ "level": "High" })),
        "must be case-sensitive"
    );
    assert!(!cond.matches(&json!({ "level": "normal" })));
    assert!(!cond.matches(&json!({})), "missing field must not match");
}

#[test]
fn field_contains_any_is_case_insensitive_substring_match() {
    let cond = SignalCondition::FieldContainsAny {
        field: "processName".to_owned(),
        any_of: vec!["DevEnv".to_owned()],
    };
    assert!(cond.matches(&json!({ "processName": "devenv.exe" })));
    assert!(!cond.matches(&json!({ "processName": "chrome.exe" })));
}

// --- ActivityState round trip / extensibility -------------------------------

#[test]
fn baseline_state_serializes_as_its_bare_name() {
    let s = serde_json::to_value(ActivityState::ListeningToMusic).unwrap();
    assert_eq!(s, json!("ListeningToMusic"));
    let back: ActivityState = serde_json::from_value(json!("ListeningToMusic")).unwrap();
    assert_eq!(back, ActivityState::ListeningToMusic);
}

#[test]
fn unrecognized_state_string_round_trips_via_other() {
    // RFC-0005: "extensible... matching how animationId already stays a free
    // string" -- a plugin/character-scoped state outside the baseline must
    // still deserialize losslessly rather than being rejected.
    let back: ActivityState = serde_json::from_value(json!("Cooking")).unwrap();
    assert_eq!(back, ActivityState::Other("Cooking".to_owned()));
    assert_eq!(serde_json::to_value(&back).unwrap(), json!("Cooking"));
}

// --- Trigger matching (mirrors DeterministicEngine's family-prefix rule) ---

#[test]
fn family_prefix_signal_trigger_matches_subtypes() {
    let mut engine = ActivityContextEngine::new(vec![interp(
        "any-telemetry",
        "ocp.plugin.",
        ActivityState::Coding,
        0.5,
        SignalCondition::Always,
        "telemetry",
        0,
    )]);
    let out = engine
        .handle_signal(
            &ev(
                "ocp.plugin.os-telemetry-battery-changed",
                "com.ocp.os-sensors",
                json!({ "pluginId": "x", "percent": 50.0, "level": "normal", "charging": false }),
            ),
            t(0),
        )
        .expect("family-prefix trigger must match a registered subtype");
    assert_eq!(out.data["newState"], "Coding");
}
