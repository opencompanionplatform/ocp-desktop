//! CS-CM — Companion Manager conformance (ADR-0013 §§1-4, §8; I6.5 slice 3).
//!
//! Not a 06-api contract suite (the manager implements an ADR, not an API
//! doc) — but held to the same bar. Where possible the tests drive the real
//! `StubRuntime` as the presentation peer, so the request→outcome→mirror loop
//! is proven against the actual RUNTIME_API §8 implementation from slice 2,
//! not against hand-built outcome fixtures.

use ocp_companion_manager::{
    ActorHandler, CompanionManager, Lifecycle, ManagerError, NullHandler, RouteOutcome,
};
use ocp_runtime_api::{Position, Runtime, DEFAULT_COMPANION_ID};
use ocp_runtime_stub::StubRuntime;
use ocp_shared_types::Envelope;
use serde_json::json;

/// Records which (companion, event-type) pairs the manager delivered, in order.
struct RecordingHandler {
    seen: Vec<(String, String)>,
    /// When set, emit one uncorrelated envelope per event (for the NFR-004
    /// stamping test).
    emit_uncorrelated: bool,
}

impl RecordingHandler {
    fn new() -> Self {
        Self {
            seen: Vec::new(),
            emit_uncorrelated: false,
        }
    }
}

impl ActorHandler for RecordingHandler {
    fn on_event(&mut self, companion_id: &str, event: &Envelope) -> Vec<Envelope> {
        self.seen
            .push((companion_id.to_owned(), event.event_type.clone()));
        if self.emit_uncorrelated {
            vec![Envelope::new(
                "ocp.behavior.bubble-requested",
                "companion-manager",
                json!({
                    "bubbleId": uuid::Uuid::now_v7(),
                    "companionId": companion_id,
                    "text": "reaction",
                    "tone": "neutral",
                }),
            )
            .expect("valid")]
        } else {
            Vec::new()
        }
    }
}

fn ev(event_type: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, "test", data).expect("valid test envelope")
}

/// Spawn through the REAL stub runtime and mirror the outcome back.
fn spawn_live(mgr: &mut CompanionManager, rt: &mut StubRuntime, id: &str) {
    let req = mgr
        .spawn(
            id,
            "character.test",
            Some(Position {
                x: 1,
                y: 2,
                monitor_id: None,
            }),
        )
        .expect("spawn accepted");
    req.validate().expect("spawn request is a valid envelope");
    for outcome in rt.handle(&req) {
        assert!(
            mgr.ingest_outcome(&outcome),
            "manager understands the outcome"
        );
    }
}

#[test]
fn spawn_round_trips_through_the_real_stub_and_activates() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");

    let actor = mgr.actor("aiko").expect("tracked");
    assert_eq!(actor.lifecycle, Lifecycle::Active);
    let pos = actor.position.as_ref().expect("position mirrored");
    assert_eq!((pos.x, pos.y), (1, 2));
}

#[test]
fn actor_is_only_requested_until_the_outcome_arrives() {
    let mut mgr = CompanionManager::new();
    mgr.spawn("aiko", "character.test", None).expect("accepted");
    assert_eq!(
        mgr.actor("aiko").unwrap().lifecycle,
        Lifecycle::Requested,
        "no outcome yet — never assumed Active"
    );
}

#[test]
fn duplicate_spawn_is_rejected() {
    let mut mgr = CompanionManager::new();
    mgr.spawn("aiko", "character.test", None).expect("first ok");
    assert_eq!(
        mgr.spawn("aiko", "character.test", None).unwrap_err(),
        ManagerError::DuplicateCompanion("aiko".into())
    );
}

#[test]
fn lifecycle_requests_require_a_known_companion() {
    let mut mgr = CompanionManager::new();
    assert!(matches!(
        mgr.despawn("ghost").unwrap_err(),
        ManagerError::UnknownCompanion(_)
    ));
    assert!(mgr.request_sleep("ghost", true).is_err());
    assert!(mgr.request_visibility("ghost", false).is_err());
    assert!(mgr.request_focus("ghost").is_err());
}

#[test]
fn targeted_event_reaches_only_the_addressed_actor() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");
    spawn_live(&mut mgr, &mut rt, "bob");

    let out = mgr.route(&ev(
        "ocp.plugin.os-telemetry-cpu-changed",
        json!({ "companionId": "aiko", "level": "high" }),
    ));
    let RouteOutcome::Delivered(ids) = out else {
        panic!("expected Delivered, got {out:?}");
    };
    assert_eq!(ids, vec!["aiko"]);
    assert_eq!(mgr.actor("aiko").unwrap().mailbox_len(), 1);
    assert_eq!(
        mgr.actor("bob").unwrap().mailbox_len(),
        0,
        "never broadcast"
    );
}

#[test]
fn input_captured_target_forms_are_understood() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");
    spawn_live(&mut mgr, &mut rt, DEFAULT_COMPANION_ID);

    // §8.1 form: companion:<id>
    let out = mgr.route(&ev(
        "ocp.runtime.input-captured",
        json!({ "modality": "click", "target": "companion:aiko" }),
    ));
    let RouteOutcome::Delivered(ids) = out else {
        panic!("expected Delivered")
    };
    assert_eq!(ids, vec!["aiko"]);

    // Legacy bare `companion` maps to the default id (flagged interpretive).
    let out = mgr.route(&ev(
        "ocp.runtime.input-captured",
        json!({ "modality": "click", "target": "companion" }),
    ));
    let RouteOutcome::Delivered(ids) = out else {
        panic!("expected Delivered")
    };
    assert_eq!(ids, vec![DEFAULT_COMPANION_ID]);
}

#[test]
fn unaddressed_events_deliver_by_subscription_never_broadcast() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");
    spawn_live(&mut mgr, &mut rt, "bob");
    mgr.subscribe("aiko", "ocp.plugin.os-telemetry-")
        .expect("ok");

    let out = mgr.route(&ev(
        "ocp.plugin.os-telemetry-cpu-changed",
        json!({ "level": "high" }), // no companionId: subscription routing
    ));
    let RouteOutcome::Delivered(ids) = out else {
        panic!("expected Delivered")
    };
    assert_eq!(ids, vec!["aiko"], "only the subscriber");
    assert_eq!(mgr.actor("bob").unwrap().mailbox_len(), 0);
}

#[test]
fn an_event_nobody_subscribes_to_is_delivered_to_no_one() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");
    spawn_live(&mut mgr, &mut rt, "bob");

    let out = mgr.route(&ev(
        "ocp.plugin.os-telemetry-cpu-changed",
        json!({ "level": "high" }),
    ));
    let RouteOutcome::Delivered(ids) = out else {
        panic!("expected Delivered")
    };
    assert!(
        ids.is_empty(),
        "targeted-not-broadcast: no subscriber, no delivery"
    );
}

#[test]
fn unknown_addressee_is_unroutable_not_a_panic() {
    let mut mgr = CompanionManager::new();
    let out = mgr.route(&ev(
        "ocp.behavior.bubble-requested",
        json!({ "companionId": "ghost", "text": "hi" }),
    ));
    assert!(matches!(
        out,
        RouteOutcome::Unroutable { companion_id } if companion_id == "ghost"
    ));
}

#[test]
fn request_to_a_sleeping_companion_queues_and_wakes_exactly_once() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");

    // Put aiko to sleep through the real stub round trip.
    let sleep_req = mgr.request_sleep("aiko", true).expect("ok");
    for o in rt.handle(&sleep_req) {
        mgr.ingest_outcome(&o);
    }
    assert_eq!(mgr.actor("aiko").unwrap().lifecycle, Lifecycle::Sleeping);

    // First addressed event: queued + ONE wake request, correlated to cause.
    let cause = ev(
        "ocp.behavior.bubble-requested",
        json!({ "companionId": "aiko", "text": "wake up" }),
    );
    let out = mgr.route(&cause);
    let RouteOutcome::WakeRequested {
        companion_id,
        wake_request,
    } = out
    else {
        panic!("expected WakeRequested, got {out:?}");
    };
    assert_eq!(companion_id, "aiko");
    assert_eq!(
        wake_request.event_type,
        "ocp.behavior.companion-sleep-requested"
    );
    assert_eq!(wake_request.data["active"], false);
    assert_eq!(wake_request.correlation_id, Some(cause.id), "audit chain");

    // Second event while still asleep: queued, NO second wake.
    let out = mgr.route(&ev(
        "ocp.behavior.bubble-requested",
        json!({ "companionId": "aiko", "text": "still there?" }),
    ));
    assert!(
        matches!(out, RouteOutcome::Delivered(_)),
        "wake emitted once"
    );
    assert_eq!(mgr.actor("aiko").unwrap().mailbox_len(), 2, "both held");

    // Wake completes through the real stub; the held mail then processes.
    for o in rt.handle(&wake_request) {
        mgr.ingest_outcome(&o);
    }
    assert_eq!(mgr.actor("aiko").unwrap().lifecycle, Lifecycle::Active);
    let mut handler = RecordingHandler::new();
    mgr.tick(&mut handler);
    mgr.tick(&mut handler);
    assert_eq!(handler.seen.len(), 2, "held mail processed after waking");
}

#[test]
fn tick_staggers_one_event_per_call_in_spawn_order_rotation() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "a");
    spawn_live(&mut mgr, &mut rt, "b");
    for id in ["a", "b"] {
        for i in 0..2 {
            mgr.route(&ev(
                "ocp.activity.state-changed",
                json!({ "companionId": id, "newState": format!("s{i}") }),
            ));
        }
    }

    let mut handler = RecordingHandler::new();
    for _ in 0..4 {
        mgr.tick(&mut handler);
    }
    let order: Vec<&str> = handler.seen.iter().map(|(id, _)| id.as_str()).collect();
    assert_eq!(
        order,
        vec!["a", "b", "a", "b"],
        "frame-rotation stagger (§4)"
    );
}

#[test]
fn tick_skips_sleeping_actors_but_hidden_actors_still_process() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "sleepy");
    spawn_live(&mut mgr, &mut rt, "hidden");

    // sleepy → Sleeping; hidden → hidden (visibility only), both via real stub.
    let sleep_req = mgr.request_sleep("sleepy", true).expect("ok");
    for o in rt.handle(&sleep_req) {
        mgr.ingest_outcome(&o);
    }
    let hide_req = mgr.request_visibility("hidden", false).expect("ok");
    for o in rt.handle(&hide_req) {
        mgr.ingest_outcome(&o);
    }

    // Note: routing to sleepy now triggers wake-on-request by design, so
    // deliver to its mailbox via an unaddressed subscription instead — this
    // test is about tick's skip rule, not wake.
    mgr.subscribe("sleepy", "ocp.activity.").expect("ok");
    mgr.subscribe("hidden", "ocp.activity.").expect("ok");
    mgr.route(&ev(
        "ocp.activity.state-changed",
        json!({ "newState": "Coding" }),
    ));

    let mut handler = RecordingHandler::new();
    mgr.tick(&mut handler);
    mgr.tick(&mut handler);
    let ids: Vec<&str> = handler.seen.iter().map(|(id, _)| id.as_str()).collect();
    assert_eq!(
        ids,
        vec!["hidden"],
        "hidden processes (§8.2); sleeping holds"
    );
    assert_eq!(mgr.actor("sleepy").unwrap().mailbox_len(), 1, "mail held");
}

#[test]
fn handler_outputs_without_correlation_are_stamped_with_the_cause() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");
    let cause = ev(
        "ocp.activity.state-changed",
        json!({ "companionId": "aiko", "newState": "Coding" }),
    );
    mgr.route(&cause);

    let mut handler = RecordingHandler::new();
    handler.emit_uncorrelated = true;
    let out = mgr.tick(&mut handler);
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].correlation_id, Some(cause.id), "NFR-004 stamped");
}

#[test]
fn despawn_round_trip_removes_the_actor() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");

    let req = mgr.despawn("aiko").expect("ok");
    assert!(mgr.actor("aiko").is_some(), "not removed optimistically");
    for o in rt.handle(&req) {
        mgr.ingest_outcome(&o);
    }
    assert!(mgr.actor("aiko").is_none(), "removed on confirmed outcome");
    assert!(matches!(
        mgr.route(&ev(
            "ocp.behavior.bubble-requested",
            json!({ "companionId": "aiko" })
        )),
        RouteOutcome::Unroutable { .. }
    ));
}

#[test]
fn focus_outcome_is_exclusive_across_actors() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "a");
    spawn_live(&mut mgr, &mut rt, "b");

    for id in ["a", "b"] {
        let req = mgr.request_focus(id).expect("ok");
        for o in rt.handle(&req) {
            mgr.ingest_outcome(&o);
        }
    }
    assert!(!mgr.actor("a").unwrap().focused, "focus moved away");
    assert!(mgr.actor("b").unwrap().focused);
}

#[test]
fn null_handler_keeps_the_manager_usable_for_pure_routing() {
    let mut mgr = CompanionManager::new();
    let mut rt = StubRuntime::new();
    spawn_live(&mut mgr, &mut rt, "aiko");
    mgr.route(&ev(
        "ocp.behavior.bubble-requested",
        json!({ "companionId": "aiko", "text": "hi" }),
    ));
    assert!(mgr.tick(&mut NullHandler).is_empty());
    assert_eq!(mgr.actor("aiko").unwrap().processed, 1);
}
