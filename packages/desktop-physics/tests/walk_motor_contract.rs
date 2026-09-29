use ocp_desktop_physics::{
    AabbCollider, AttachmentState, DesktopPhysicsSolver, PhysicsBody, PhysicsStepState,
    PhysicsSurface, PhysicsWorldQuery, SurfaceAttachment, WalkConfig, WalkDirection,
    WalkEdgeBehavior, WalkError, WalkMotor, WalkStepState,
};
use ocp_shared_types::{Orientation, Point2, SurfaceCapabilities, SurfaceId, SurfaceKind, Vector2};
use std::collections::BTreeMap;
use std::time::Duration;

#[derive(Default)]
struct TestWorld {
    surfaces: BTreeMap<SurfaceId, PhysicsSurface>,
}

impl TestWorld {
    fn insert(&mut self, surface: PhysicsSurface) {
        self.surfaces.insert(surface.id, surface);
    }

    fn remove(&mut self, surface_id: SurfaceId) {
        self.surfaces.remove(&surface_id);
    }
}

impl PhysicsWorldQuery for TestWorld {
    fn surface(&self, id: SurfaceId) -> Option<PhysicsSurface> {
        self.surfaces.get(&id).copied()
    }

    fn candidate_surfaces(&self, _from: Point2, _to: Point2) -> Vec<PhysicsSurface> {
        self.surfaces.values().copied().collect()
    }
}

fn horizontal_surface(
    start_x: f32,
    end_x: f32,
    capabilities: SurfaceCapabilities,
) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(start_x, 200.0),
        end: Point2::new(end_x, 200.0),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities,
    }
}

fn grounded_body(surface: PhysicsSurface, x: f32) -> PhysicsBody {
    let mut body = PhysicsBody::new(Point2::new(x, 180.0), AabbCollider::new(10.0, 20.0));

    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id: surface.id,
            anchor: Point2::new(x, 200.0),
            normal: surface.normal,
        },
    };

    body
}

#[test]
fn walk_is_deterministic() {
    let surface = horizontal_surface(
        0.0,
        500.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::new(WalkConfig {
        speed: 100.0,
        ..WalkConfig::default()
    });
    let mut first = grounded_body(surface, 250.0);
    let mut second = grounded_body(surface, 250.0);

    for _ in 0..60 {
        motor
            .step(
                &mut first,
                WalkDirection::Right,
                WalkEdgeBehavior::StopAtEdge,
                Duration::from_millis(16),
                &world,
            )
            .expect("first walk");
        motor
            .step(
                &mut second,
                WalkDirection::Right,
                WalkEdgeBehavior::StopAtEdge,
                Duration::from_millis(16),
                &world,
            )
            .expect("second walk");
    }

    assert_eq!(first.position, second.position);
    assert_eq!(first.velocity, second.velocity);
    assert_eq!(first.attachment, second.attachment);
}

#[test]
fn stop_at_edge_keeps_body_grounded() {
    let surface = horizontal_surface(0.0, 100.0, SurfaceCapabilities::WALKABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::new(WalkConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(surface, 85.0);

    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("stop at edge");

    assert_eq!(result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(body.position, Point2::new(90.0, 180.0));
    assert_eq!(body.velocity, Vector2::ZERO);
    assert!(body.attachment.is_grounded());
}

#[test]
fn walk_off_detaches_body_at_edge() {
    let surface = horizontal_surface(0.0, 100.0, SurfaceCapabilities::WALKABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::new(WalkConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(surface, 85.0);

    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::WalkOff,
            Duration::from_millis(100),
            &world,
        )
        .expect("walk off");

    assert_eq!(result.state, WalkStepState::WalkedOff);
    assert_eq!(body.attachment, AttachmentState::Detached);
    assert!(body.position.x > 90.0);
    assert!(body.velocity.x > 0.0);
}

#[test]
fn gravity_resumes_after_walking_off() {
    let surface = horizontal_surface(0.0, 100.0, SurfaceCapabilities::WALKABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::new(WalkConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let physics = DesktopPhysicsSolver::default();
    let mut body = grounded_body(surface, 85.0);

    motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::WalkOff,
            Duration::from_millis(100),
            &world,
        )
        .expect("walk off");

    let result = physics.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(result.state, PhysicsStepState::Falling);
    assert!(body.velocity.y > 0.0);
}

#[test]
fn lost_surface_detaches_without_panicking() {
    let surface = horizontal_surface(0.0, 500.0, SurfaceCapabilities::WALKABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::default();
    let mut body = grounded_body(surface, 250.0);
    world.remove(surface.id);

    let result = motor
        .step(
            &mut body,
            WalkDirection::Left,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(16),
            &world,
        )
        .expect("lost surface");

    assert_eq!(result.state, WalkStepState::SurfaceLost);
    assert_eq!(body.attachment, AttachmentState::Detached);
}

#[test]
fn non_walkable_surface_is_rejected() {
    let surface = horizontal_surface(0.0, 500.0, SurfaceCapabilities::LANDABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::default();
    let mut body = grounded_body(surface, 250.0);

    let error = motor
        .step(
            &mut body,
            WalkDirection::Left,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(16),
            &world,
        )
        .expect_err("non-walkable");

    assert_eq!(
        error,
        WalkError::SurfaceNotWalkable {
            surface_id: surface.id,
        },
    );
}

#[test]
fn surface_narrower_than_body_is_rejected() {
    let surface = horizontal_surface(0.0, 10.0, SurfaceCapabilities::WALKABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let motor = WalkMotor::default();
    let mut body = grounded_body(surface, 5.0);

    let error = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(16),
            &world,
        )
        .expect_err("narrow surface");

    assert_eq!(
        error,
        WalkError::SurfaceTooNarrow {
            surface_id: surface.id,
        },
    );
}

#[test]
fn stop_at_edge_stays_on_current_monitor_when_adjacent_floor_touches_seam() {
    let left = horizontal_surface(
        0.0,
        100.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let mut right = horizontal_surface(
        100.0,
        220.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    right.start.y = 240.0;
    right.end.y = 240.0;

    let mut world = TestWorld::default();
    world.insert(left);
    world.insert(right);

    let motor = WalkMotor::new(WalkConfig {
        speed: 20.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(left, 90.0);
    let body_id = body.id;
    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("current-monitor edge stop");

    assert_eq!(body.id, body_id);
    assert_eq!(result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(body.position, Point2::new(90.0, 180.0));
    assert_eq!(body.velocity, Vector2::ZERO);
    assert_eq!(body.attachment.surface_id(), Some(left.id));
    assert_ne!(body.attachment.surface_id(), Some(right.id));
}

#[test]
fn real_gap_between_surfaces_still_stops_at_edge() {
    let left = horizontal_surface(
        0.0,
        100.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let right = horizontal_surface(
        120.0,
        220.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );

    let mut world = TestWorld::default();
    world.insert(left);
    world.insert(right);

    let motor = WalkMotor::new(WalkConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(left, 85.0);

    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("gap remains a hard edge");

    assert_eq!(result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(body.position, Point2::new(90.0, 180.0));
    assert_eq!(body.attachment.surface_id(), Some(left.id));
}

#[test]
fn stop_at_edge_zeroes_velocity_before_crossing_touching_monitor_floor() {
    let left = horizontal_surface(
        0.0,
        100.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let right = horizontal_surface(
        100.0,
        220.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );

    let mut world = TestWorld::default();
    world.insert(left);
    world.insert(right);

    let motor = WalkMotor::new(WalkConfig {
        speed: 20.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(left, 89.0);

    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("touching monitor remains a hard walking edge");

    assert_eq!(result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(body.velocity, Vector2::ZERO);
    assert_eq!(body.position.x, 90.0);
    assert_eq!(body.attachment.surface_id(), Some(left.id));
}

#[test]
fn window_and_taskbar_at_seam_do_not_override_current_monitor_confinement() {
    let left = horizontal_surface(
        0.0,
        100.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let right = horizontal_surface(
        100.0,
        220.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let mut window_top = horizontal_surface(
        100.0,
        180.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    window_top.kind = SurfaceKind::WindowTop;
    window_top.start.y = 50.0;
    window_top.end.y = 50.0;
    let mut taskbar_top = window_top;
    taskbar_top.id = SurfaceId::new();
    taskbar_top.kind = SurfaceKind::TaskbarTop;

    let mut world = TestWorld::default();
    world.insert(left);
    world.insert(window_top);
    world.insert(taskbar_top);
    world.insert(right);

    let motor = WalkMotor::new(WalkConfig {
        speed: 20.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(left, 89.0);

    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("current monitor edge stop");

    assert_eq!(result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(body.attachment.surface_id(), Some(left.id));
    assert_ne!(body.attachment.surface_id(), Some(right.id));
    assert_ne!(body.attachment.surface_id(), Some(window_top.id));
    assert_ne!(body.attachment.surface_id(), Some(taskbar_top.id));
}

#[test]
fn actual_three_monitor_topology_stops_at_primary_right_gap() {
    let left = horizontal_surface(
        -1920.0,
        0.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let primary = horizontal_surface(
        0.0,
        1440.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let right = horizontal_surface(
        2880.0,
        3960.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let primary_id = primary.id;
    let right_id = right.id;
    let mut world = TestWorld::default();
    world.insert(left);
    world.insert(primary);
    world.insert(right);

    let motor = WalkMotor::new(WalkConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut body = grounded_body(primary, 1425.0);
    let body_id = body.id;

    let result = motor
        .step(
            &mut body,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("primary gap remains a hard edge");

    assert_eq!(result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(body.position.x, 1430.0);
    assert_eq!(body.attachment.surface_id(), Some(primary_id));
    assert_ne!(body.attachment.surface_id(), Some(right_id));
    assert_eq!(body.id, body_id);
}

#[test]
fn three_touching_monitors_confine_walk_to_the_attached_current_floor() {
    let left = horizontal_surface(
        -1920.0,
        0.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let primary = horizontal_surface(
        0.0,
        1440.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let right = horizontal_surface(
        1440.0,
        2520.0,
        SurfaceCapabilities::WALKABLE.union(SurfaceCapabilities::LANDABLE),
    );
    let mut world = TestWorld::default();
    world.insert(left);
    world.insert(primary);
    world.insert(right);

    let motor = WalkMotor::new(WalkConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..WalkConfig::default()
    });
    let mut walking_left = grounded_body(primary, 20.0);
    let left_body_id = walking_left.id;
    let left_result = motor
        .step(
            &mut walking_left,
            WalkDirection::Left,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("left edge stops on primary");

    let mut walking_right = grounded_body(primary, 1420.0);
    let right_body_id = walking_right.id;
    let right_result = motor
        .step(
            &mut walking_right,
            WalkDirection::Right,
            WalkEdgeBehavior::StopAtEdge,
            Duration::from_millis(100),
            &world,
        )
        .expect("right edge stops on primary");

    assert_eq!(left_result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(walking_left.position.x, 10.0);
    assert_eq!(walking_left.attachment.surface_id(), Some(primary.id));
    assert_eq!(walking_left.id, left_body_id);

    assert_eq!(right_result.state, WalkStepState::StoppedAtEdge);
    assert_eq!(walking_right.position.x, 1430.0);
    assert_eq!(walking_right.attachment.surface_id(), Some(primary.id));
    assert_eq!(walking_right.id, right_body_id);
}
