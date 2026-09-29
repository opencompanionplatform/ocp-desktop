//! CS-RT — Runtime conformance (RUNTIME_API §6, TEST_STRATEGY §3.5) against the
//! headless reference stub. Passing this + CS-EVT certifies a runtime for the
//! NFR-001 swap test. The verb round-trip is driven by the shared `certify`
//! harness; the rest pins the rendering rule (§5, X4) and window degradation.

use ocp_runtime_api::{
    certify, certify_multi_companion, sanitize_display_text, Runtime, DEFAULT_COMPANION_ID,
    MAX_DISPLAY_CHARS,
};
use ocp_runtime_stub::{StubRuntime, WindowCaps};
use ocp_shared_types::Envelope;
use serde_json::json;
use uuid::Uuid;

fn bubble(text: &str) -> Envelope {
    Envelope::new(
        "ocp.behavior.bubble-requested",
        "behavior",
        json!({ "bubbleId": Uuid::now_v7(), "text": text, "tone": "neutral", "anchor": "companion" }),
    )
    .expect("valid")
}

#[test]
fn stub_passes_minimal_conformance() {
    let mut rt = StubRuntime::new();
    certify(&mut rt).expect("stub must pass CS-RT minimal set (NFR-001)");
}

// --- Rendering rule §5: displayed strings are data, never markup (X4-I) ---

#[test]
fn markup_in_bubble_is_treated_as_literal_data() {
    let mut rt = StubRuntime::new();
    let hostile = "<b>bold</b> [url=x]click[/url] <script>alert(1)</script>";
    let out = rt.handle(&bubble(hostile));
    assert_eq!(out.len(), 1);
    // The runtime rendered the string verbatim — no tag was stripped, parsed,
    // or executed; it is opaque data.
    assert_eq!(rt.last_rendered_text(), Some(hostile));
}

#[test]
fn control_characters_are_stripped() {
    let (clean, _) = sanitize_display_text("a\u{0007}b\n\rc\td");
    assert_eq!(
        clean, "abcd",
        "control chars (incl. \\n\\r\\t, BEL) removed"
    );
}

#[test]
fn overlong_text_truncated_and_flagged() {
    let mut rt = StubRuntime::new();
    let long = "x".repeat(MAX_DISPLAY_CHARS + 50);
    let out = rt.handle(&bubble(&long));
    assert_eq!(out[0].data["truncated"], true);
    assert_eq!(
        rt.last_rendered_text().map(str::len),
        Some(MAX_DISPLAY_CHARS),
        "rendered text capped at the display limit"
    );
}

// --- Window policy degradation must be reported, never silent (§3.1) ---

#[test]
fn degraded_transparency_is_reported() {
    let mut rt = StubRuntime::with_caps(WindowCaps {
        transparent: false,
        always_on_top: true,
    });
    let policy = Envelope::new(
        "ocp.companion.window-policy-changed",
        "companion",
        json!({ "transparent": true, "alwaysOnTop": true, "clickThrough": "outside-sprite" }),
    )
    .expect("valid");
    let out = rt.handle(&policy);
    assert_eq!(out.len(), 1);
    let degraded = out[0].data["degraded"].as_array().unwrap();
    assert!(
        degraded.iter().any(|d| d == "transparent"),
        "unsupported transparency must appear in `degraded` (RUNTIME_API §3.1)"
    );
}

#[test]
fn fully_applied_policy_reports_no_degradation() {
    let mut rt = StubRuntime::new(); // full caps
    let policy = Envelope::new(
        "ocp.companion.window-policy-changed",
        "companion",
        json!({ "transparent": true, "alwaysOnTop": true, "clickThrough": "always" }),
    )
    .expect("valid");
    let out = rt.handle(&policy);
    assert!(out[0].data["degraded"].as_array().unwrap().is_empty());
}

// --- Mirror-only + input reporting (RUNTIME_API §2.7, RUNTIME.md) ---

#[test]
fn state_changed_is_mirrored_without_emitting() {
    let mut rt = StubRuntime::new();
    let ev = Envelope::new(
        "ocp.companion.state-changed",
        "companion",
        json!({ "companionId": Uuid::now_v7(), "from": "Idle", "to": "Speaking" }),
    )
    .expect("valid");
    let out = rt.handle(&ev);
    assert!(out.is_empty(), "mirroring emits no outbound fact");
    assert_eq!(rt.mirrored_state.as_deref(), Some("Speaking"));
}

#[test]
fn captured_input_is_a_fact_with_sanitized_text() {
    let rt = StubRuntime::new();
    let ev = rt.capture_input("text", Some("hi <b>there</b>\u{0007}"), "companion");
    assert_eq!(ev.event_type, "ocp.runtime.input-captured");
    assert_eq!(ev.source, "runtime");
    // Control char stripped, markup preserved as literal data.
    assert_eq!(ev.data["text"], "hi <b>there</b>");
    ev.validate().expect("input-captured is a valid envelope");
}

#[test]
fn unknown_events_are_ignored_not_errored() {
    let mut rt = StubRuntime::new();
    let ev = Envelope::new("ocp.memory.record-written", "memory-layer", json!({})).expect("valid");
    assert!(rt.handle(&ev).is_empty());
}

// --- §8 multi-companion addressing + lifecycle (ADR-0013, I6.5) ---------------

fn lifecycle(event_type: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, "behavior", data).expect("valid lifecycle envelope")
}

#[test]
fn stub_passes_multi_companion_conformance() {
    let mut rt = StubRuntime::new();
    certify_multi_companion(&mut rt).expect("stub must pass §8 lifecycle set (ADR-0013)");
}

#[test]
fn legacy_bubble_without_companion_id_defaults_and_still_emits_one() {
    // §8.1 backward compatibility: a single-companion sender omitting
    // companionId is tolerated; the outcome still carries the default id.
    let mut rt = StubRuntime::new();
    let out = rt.handle(&bubble("hi"));
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].data["companionId"], DEFAULT_COMPANION_ID);
}

#[test]
fn addressed_bubble_outcome_carries_the_requested_companion_id() {
    let mut rt = StubRuntime::new();
    let ev = Envelope::new(
        "ocp.behavior.bubble-requested",
        "behavior",
        json!({
            "bubbleId": Uuid::now_v7(), "companionId": "aiko",
            "text": "hi", "tone": "neutral", "anchor": "companion"
        }),
    )
    .expect("valid");
    let out = rt.handle(&ev);
    assert_eq!(out[0].data["companionId"], "aiko");
}

#[test]
fn spawn_tracks_state_and_despawn_removes_it() {
    let mut rt = StubRuntime::new();
    rt.handle(&lifecycle(
        "ocp.behavior.companion-spawn-requested",
        json!({
            "companionId": "aiko", "characterPackageId": "character.aiko",
            "initialPosition": { "x": 5, "y": 7, "monitorId": "m1" }
        }),
    ));
    let c = rt
        .companions
        .get("aiko")
        .expect("spawned companion tracked");
    assert_eq!((c.position.x, c.position.y), (5, 7));
    assert!(!c.sleeping && !c.hidden);

    rt.handle(&lifecycle(
        "ocp.behavior.companion-despawn-requested",
        json!({ "companionId": "aiko" }),
    ));
    assert!(!rt.companions.contains_key("aiko"), "despawn removes state");
}

#[test]
fn sleep_wake_and_hide_show_are_distinct_flags() {
    let mut rt = StubRuntime::new();
    rt.handle(&lifecycle(
        "ocp.behavior.companion-spawn-requested",
        json!({ "companionId": "aiko", "characterPackageId": "character.aiko", "initialPosition": null }),
    ));

    rt.handle(&lifecycle(
        "ocp.behavior.companion-sleep-requested",
        json!({ "companionId": "aiko", "active": true }),
    ));
    assert!(rt.companions["aiko"].sleeping);
    assert!(
        !rt.companions["aiko"].hidden,
        "sleep is resource state, not visibility (§8.2)"
    );

    rt.handle(&lifecycle(
        "ocp.behavior.companion-hide-requested",
        json!({ "companionId": "aiko" }),
    ));
    assert!(rt.companions["aiko"].hidden);

    rt.handle(&lifecycle(
        "ocp.behavior.companion-sleep-requested",
        json!({ "companionId": "aiko", "active": false }),
    ));
    rt.handle(&lifecycle(
        "ocp.behavior.companion-show-requested",
        json!({ "companionId": "aiko" }),
    ));
    let c = &rt.companions["aiko"];
    assert!(!c.sleeping && !c.hidden);
}

#[test]
fn focus_is_exclusive_across_companions() {
    let mut rt = StubRuntime::new();
    for id in ["a", "b"] {
        rt.handle(&lifecycle(
            "ocp.behavior.companion-spawn-requested",
            json!({ "companionId": id, "characterPackageId": "character.test", "initialPosition": null }),
        ));
    }
    rt.handle(&lifecycle(
        "ocp.behavior.companion-focus-requested",
        json!({ "companionId": "a" }),
    ));
    rt.handle(&lifecycle(
        "ocp.behavior.companion-focus-requested",
        json!({ "companionId": "b" }),
    ));
    assert!(!rt.companions["a"].focused, "focus moved away from a");
    assert!(rt.companions["b"].focused);
}

#[test]
fn follow_tracks_leader_and_stop_clears_it() {
    let mut rt = StubRuntime::new();
    for id in ["a", "b"] {
        rt.handle(&lifecycle(
            "ocp.behavior.companion-spawn-requested",
            json!({ "companionId": id, "characterPackageId": "character.test", "initialPosition": null }),
        ));
    }
    let started = rt.handle(&lifecycle(
        "ocp.behavior.companion-follow-requested",
        json!({ "companionId": "b", "leaderCompanionId": "a", "active": true, "distancePx": 64 }),
    ));
    assert_eq!(
        started[0].event_type,
        "ocp.runtime.companion-follow-started"
    );
    assert_eq!(started[0].data["leaderCompanionId"], "a");
    assert_eq!(rt.companions["b"].following.as_deref(), Some("a"));

    rt.handle(&lifecycle(
        "ocp.behavior.companion-follow-requested",
        json!({ "companionId": "b", "leaderCompanionId": "a", "active": false }),
    ));
    assert!(rt.companions["b"].following.is_none());
}

#[test]
fn window_policy_dock_and_toolbar_fields_round_trip_in_applied() {
    // §8.4: the two new optional window-level fields follow the same
    // declarative-policy/applied-fact pattern as every other WindowPolicy field.
    let mut rt = StubRuntime::new();
    let policy = Envelope::new(
        "ocp.companion.window-policy-changed",
        "companion",
        json!({
            "transparent": true, "alwaysOnTop": true, "clickThrough": "always",
            "dockVisible": true, "toolbarVisible": false
        }),
    )
    .expect("valid");
    let out = rt.handle(&policy);
    assert_eq!(out[0].data["applied"]["dockVisible"], true);
    assert_eq!(out[0].data["applied"]["toolbarVisible"], false);
}
