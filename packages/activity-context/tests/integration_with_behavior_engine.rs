//! CS-ACT integration proof: `ocp-behavior-engine` consumes
//! `ocp.activity.state-changed` with **zero changes to its own contract**
//! (RFC-0005 exit criterion; BEHAVIOR_ENGINE.md's `Trigger` is already just
//! "an event pattern" -- this test is the live proof, not just a
//! contract-reading claim: it exercises the real, unmodified
//! `DeterministicEngine` against a real event this crate produces).
//!
//! Lives here (dev-dependency only, see Cargo.toml -- Activity Context has
//! no *runtime* dependency on the Behavior Engine, RFC-0005 keeps that
//! direction one-way) rather than in `ocp-behavior-engine`'s own suite,
//! since Activity Context is the new party integrating against an
//! already-frozen contract, not the other way around.

use std::collections::BTreeMap;

use chrono::{Duration, Utc};
use ocp_activity_context::{default_interpreters, ActivityContextEngine};
use ocp_behavior_api::{Action, Behavior, Rule, RuleSet, RulesEngine};
use ocp_behavior_engine::DeterministicEngine;
use ocp_shared_types::Envelope;
use serde_json::json;

fn foreground(process_name: &str) -> Envelope {
    Envelope::new(
        "ocp.plugin.os-telemetry-foreground-changed",
        "com.ocp.os-sensors",
        json!({ "pluginId": "com.ocp.os-sensors", "windowTitle": "", "processName": process_name }),
    )
    .expect("valid conformance envelope")
}

#[test]
fn behavior_engine_reacts_to_a_real_activity_state_changed_event_with_no_contract_change() {
    // --- Activity Context side: produce a real, debounced state change
    // using the shipped baseline rule set (default_interpreters), not a
    // test-only fixture. ---
    let mut activity = ActivityContextEngine::new(default_interpreters());
    let t0 = Utc::now();
    assert!(
        activity
            .handle_signal(&foreground("devenv.exe"), t0)
            .is_none(),
        "first signal only starts the dwell"
    );
    let activity_event = activity
        .handle_signal(&foreground("devenv.exe"), t0 + Duration::seconds(6))
        .expect("6s exceeds the coding-ide interpreter's 5000ms dwell");
    assert_eq!(activity_event.event_type, "ocp.activity.state-changed");
    assert_eq!(activity_event.data["newState"], "Coding");
    activity_event
        .validate()
        .expect("must be a valid envelope (CS-EVT)");

    // --- Behavior Engine side: an ORDINARY Rule matching the new event
    // type by the same family-prefix convention every other trigger already
    // uses -- no new code, no special case, in ocp-behavior-engine itself. ---
    let mut behaviors = BTreeMap::new();
    behaviors.insert(
        "focus-ack".to_owned(),
        Behavior {
            id: "focus-ack".to_owned(),
            actions: vec![Action::Bubble {
                text: "heads down, got it".to_owned(),
                tone: "neutral".to_owned(),
            }],
        },
    );
    let mut engine = DeterministicEngine::new(RuleSet {
        rules: vec![Rule {
            id: "react-to-coding".to_owned(),
            trigger: "ocp.activity.".to_owned(), // family prefix, matches any ocp.activity.* subtype
            priority: 0,
            emotion_to: None,
            behavior_id: "focus-ack".to_owned(),
        }],
        behaviors,
    });

    let out = engine.handle(&activity_event);

    let triggered = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.triggered")
        .expect("rule must match");
    assert_eq!(triggered.data["ruleId"], "react-to-coding");
    assert_eq!(
        triggered.correlation_id,
        Some(activity_event.id),
        "caused-by the activity event (NFR-004)"
    );

    let bubble = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.bubble-requested")
        .expect("the rule's behavior action must actually fire");
    assert_eq!(bubble.data["text"], "heads down, got it");

    let completed = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.completed")
        .expect("must complete");
    assert_eq!(completed.data["outcome"], "completed");
}

#[test]
fn a_specific_activity_rule_outranks_a_generic_family_rule_on_a_real_cross_crate_event() {
    // BEHAVIOR_ENGINE.md's arbitration (highest priority wins, loser logged
    // not dropped) is already covered generically in ocp-behavior-engine's
    // own CS-BEH suite against synthetic causes. The value of repeating the
    // shape here is proving it holds for a *real* event this crate
    // produced -- a Meeting state, not the Coding one used above, so this
    // isn't just re-testing the same path twice under a different name.
    let mut activity = ActivityContextEngine::new(default_interpreters());
    let t0 = Utc::now();
    activity.handle_signal(&foreground("teams.exe"), t0);
    let activity_event = activity
        .handle_signal(&foreground("teams.exe"), t0 + Duration::seconds(6))
        .expect("6s exceeds the meeting-app interpreter's 5000ms dwell");
    assert_eq!(activity_event.data["newState"], "Meeting");

    let mut behaviors = BTreeMap::new();
    behaviors.insert(
        "b-specific".to_owned(),
        Behavior {
            id: "b-specific".to_owned(),
            actions: vec![],
        },
    );
    behaviors.insert(
        "b-generic".to_owned(),
        Behavior {
            id: "b-generic".to_owned(),
            actions: vec![],
        },
    );
    let mut engine = DeterministicEngine::new(RuleSet {
        rules: vec![
            Rule {
                id: "generic-activity".to_owned(),
                trigger: "ocp.activity.".to_owned(), // family prefix, lower priority
                priority: 1,
                emotion_to: None,
                behavior_id: "b-generic".to_owned(),
            },
            Rule {
                id: "specific-meeting-reaction".to_owned(),
                trigger: "ocp.activity.state-changed".to_owned(), // exact match, higher priority
                priority: 10,
                emotion_to: None,
                behavior_id: "b-specific".to_owned(),
            },
        ],
        behaviors,
    });

    let out = engine.handle(&activity_event);
    let triggered = out
        .iter()
        .find(|e| e.event_type == "ocp.behavior.triggered")
        .expect("a rule must match");
    assert_eq!(
        triggered.data["ruleId"], "specific-meeting-reaction",
        "higher priority must win"
    );
    let losers = triggered.data["losingCandidates"].as_array().unwrap();
    assert_eq!(
        losers,
        &vec![json!("generic-activity")],
        "loser must be logged, not silently dropped"
    );
}
