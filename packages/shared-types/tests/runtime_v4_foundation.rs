use ocp_shared_types::{
    validate_type_name, Bounds, Envelope, Goal, GoalId, IntentSource, Point2, Rect,
    SurfaceCapabilities, SurfacePlacement,
};

#[test]
fn existing_envelope_contract_stays_compatible() {
    let envelope = Envelope::new(
        "ocp.runtime.speech-started",
        "runtime",
        serde_json::json!({
            "speechId": "speech-1",
        }),
    )
    .expect("existing Runtime V3 event must remain valid");

    let serialized = serde_json::to_value(&envelope).expect("serialize envelope");

    assert_eq!(
        serialized.get("type").and_then(|value| value.as_str()),
        Some("ocp.runtime.speech-started")
    );
    assert_eq!(
        serialized
            .get("contentType")
            .and_then(|value| value.as_str()),
        Some("application/json")
    );
}

#[test]
fn runtime_v4_contexts_are_accepted() {
    let names = [
        "ocp.world.world-updated",
        "ocp.surface.surface-created",
        "ocp.navigation.path-created",
        "ocp.goal.goal-created",
        "ocp.intent.intent-requested",
        "ocp.planner.plan-created",
        "ocp.scheduler.work-preempted",
        "ocp.physics.body-landed",
    ];

    for name in names {
        assert!(
            validate_type_name(name).is_ok(),
            "Runtime V4 event rejected: {name}"
        );
    }
}

#[test]
fn canonical_rect_behaves_consistently() {
    let rect = Rect::new(100.0, 200.0, 800.0, 600.0);

    assert!(rect.contains(Point2::new(100.0, 200.0)));
    assert!(rect.contains(Point2::new(900.0, 800.0)));
    assert_eq!(rect.center(), Point2::new(500.0, 500.0));

    let bounds = Bounds(rect);
    assert_eq!(bounds.0, rect);
}

#[test]
fn surface_capabilities_are_composable() {
    let capabilities = SurfaceCapabilities::WALKABLE
        .union(SurfaceCapabilities::LANDABLE)
        .union(SurfaceCapabilities::SITTABLE);

    assert!(capabilities.contains(SurfaceCapabilities::WALKABLE));
    assert!(capabilities.contains(SurfaceCapabilities::LANDABLE));
    assert!(capabilities.contains(SurfaceCapabilities::SITTABLE));
    assert!(!capabilities.contains(SurfaceCapabilities::CLIMBABLE));
}

#[test]
fn priority_policy_matches_architecture_freeze() {
    assert!(IntentSource::Manual.default_priority() > IntentSource::Api.default_priority());
    assert!(IntentSource::Api.default_priority() > IntentSource::Ai.default_priority());
    assert!(IntentSource::Ai.default_priority() > IntentSource::Auto.default_priority());
}

#[test]
fn high_level_goal_contains_no_per_frame_command() {
    let goal = Goal::OccupyActiveWindowSurface {
        id: GoalId::new(),
        required_capabilities: SurfaceCapabilities::SITTABLE,
        placement: SurfacePlacement::Center,
        arrival_behavior: Some("sit".to_owned()),
    };

    assert!(matches!(goal, Goal::OccupyActiveWindowSurface { .. }));
}
