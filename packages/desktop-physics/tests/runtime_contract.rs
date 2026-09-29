use ocp_desktop_physics::{
    AabbCollider, AttachmentState, ClimbDirection, DesktopPhysicsRuntime, FixedStepConfig,
    JumpDirection, PhysicsBody, PhysicsCommand, PhysicsRuntimeError, PhysicsSurface,
    PhysicsWorldQuery, RuntimeBodyState, SurfaceAttachment, WalkDirection, WalkEdgeBehavior,
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
}

impl PhysicsWorldQuery for TestWorld {
    fn surface(&self, id: SurfaceId) -> Option<PhysicsSurface> {
        self.surfaces.get(&id).copied()
    }

    fn candidate_surfaces(&self, _from: Point2, _to: Point2) -> Vec<PhysicsSurface> {
        self.surfaces.values().copied().collect()
    }
}

fn floor() -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(0.0, 500.0),
        end: Point2::new(1_000.0, 500.0),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
    }
}

fn grounded_body(surface: PhysicsSurface) -> PhysicsBody {
    let mut body = PhysicsBody::new(Point2::new(400.0, 480.0), AabbCollider::new(10.0, 20.0));
    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id: surface.id,
            anchor: Point2::new(400.0, 500.0),
            normal: surface.normal,
        },
    };
    body
}

fn climbable_wall() -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::WindowLeft,
        start: Point2::new(300.0, 100.0),
        end: Point2::new(300.0, 500.0),
        orientation: Orientation::Vertical,
        normal: Vector2::new(-1.0, 0.0),
        capabilities: SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
    }
}

fn left_climbable_wall() -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::MonitorEdge,
        start: Point2::new(0.0, 100.0),
        end: Point2::new(0.0, 500.0),
        orientation: Orientation::Vertical,
        normal: Vector2::new(1.0, 0.0),
        capabilities: SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
    }
}

fn hangable_top() -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::MonitorEdge,
        start: Point2::new(0.0, 100.0),
        end: Point2::new(300.0, 100.0),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, 1.0),
        capabilities: SurfaceCapabilities::HANGABLE,
    }
}

fn hanging_body(surface: PhysicsSurface, x: f32) -> PhysicsBody {
    let mut body = PhysicsBody::new(Point2::new(x, 100.0), AabbCollider::new(20.0, 30.0));
    body.attachment = AttachmentState::Hanging {
        attachment: SurfaceAttachment {
            surface_id: surface.id,
            anchor: Point2::new(x, 100.0),
            normal: surface.normal,
        },
    };
    body
}

#[test]
fn default_fixed_step_tracks_high_refresh_presentation() {
    let config = FixedStepConfig::default();

    assert_eq!(config.step, Duration::from_micros(8_333));
    assert_eq!(config.max_catch_up_steps, 16);
}

#[test]
fn registry_rejects_duplicate_body() {
    let surface = floor();
    let body = grounded_body(surface);
    let body_id = body.id;
    let mut runtime = DesktopPhysicsRuntime::default();

    runtime.insert_body(body.clone()).expect("insert");

    let error = runtime.insert_body(body).expect_err("duplicate");

    assert_eq!(error, PhysicsRuntimeError::DuplicateBody { body_id },);
}

#[test]
fn command_queue_executes_in_fixed_step_order() {
    let surface = floor();
    let mut world = TestWorld::default();
    world.insert(surface);

    let body = grounded_body(surface);
    let body_id = body.id;
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });

    runtime.insert_body(body).expect("insert");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::Walk {
                direction: WalkDirection::Right,
                edge_behavior: WalkEdgeBehavior::StopAtEdge,
            },
        )
        .expect("walk");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::Jump {
                direction: JumpDirection::Right,
            },
        )
        .expect("jump");

    let first = runtime.tick(Duration::from_millis(10), &world);
    assert_eq!(first.simulated_steps, 1);
    assert_eq!(first.bodies[0].state, RuntimeBodyState::Walking);

    let second = runtime.tick(Duration::from_millis(10), &world);
    assert_eq!(second.simulated_steps, 1);
    assert_eq!(second.bodies[0].state, RuntimeBodyState::Airborne);
}

#[test]
fn walk_accelerates_and_decelerates_without_snapping() {
    let floor = floor();
    let mut world = TestWorld::default();
    world.insert(floor);
    let body = grounded_body(floor);
    let body_id = body.id;
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    runtime.insert_body(body).expect("insert");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::Walk {
                direction: WalkDirection::Right,
                edge_behavior: WalkEdgeBehavior::StopAtEdge,
            },
        )
        .expect("walk");

    runtime.tick(Duration::from_millis(10), &world);
    let first_speed = runtime.body(body_id).expect("starting walk").velocity.x;
    assert!(first_speed > 0.0 && first_speed < 140.0);

    for _ in 0..30 {
        runtime.tick(Duration::from_millis(10), &world);
    }
    let cruise_speed = runtime.body(body_id).expect("cruising walk").velocity.x;
    assert!((cruise_speed - 140.0).abs() < 0.01);

    runtime
        .enqueue(body_id, PhysicsCommand::Stop)
        .expect("stop");
    runtime.tick(Duration::from_millis(10), &world);
    let easing_speed = runtime.body(body_id).expect("easing walk").velocity.x;
    assert!(easing_speed > 0.0 && easing_speed < cruise_speed);

    for _ in 0..20 {
        runtime.tick(Duration::from_millis(10), &world);
    }
    assert_eq!(
        runtime.body(body_id).expect("settled walk").velocity,
        Vector2::ZERO
    );
}

#[test]
fn climb_remains_active_until_stop() {
    let wall = climbable_wall();
    let mut world = TestWorld::default();
    world.insert(wall);
    let body = PhysicsBody::new(Point2::new(280.0, 400.0), AabbCollider::new(20.0, 30.0));
    let body_id = body.id;
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    runtime.insert_body(body).expect("insert");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::AttachVertical {
                surface_id: wall.id,
                anchor_y: 400.0,
            },
        )
        .expect("attach");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::Climb {
                direction: ClimbDirection::Up,
            },
        )
        .expect("climb");

    runtime.tick(Duration::from_millis(10), &world);
    runtime.tick(Duration::from_millis(10), &world);
    let first_y = runtime.body(body_id).expect("climbing body").position.y;
    for _ in 0..10 {
        runtime.tick(Duration::from_millis(10), &world);
    }
    let continued_y = runtime.body(body_id).expect("continued body").position.y;
    assert!(continued_y < first_y, "one command keeps climbing");

    let velocity_before_stop = runtime
        .body(body_id)
        .expect("climbing body")
        .velocity
        .y
        .abs();
    runtime
        .enqueue(body_id, PhysicsCommand::Stop)
        .expect("stop");
    runtime.tick(Duration::from_millis(10), &world);
    let easing = runtime.body(body_id).expect("easing body");
    assert!(
        easing.velocity.y.abs() < velocity_before_stop,
        "Stop should decelerate the active climb before settling"
    );

    for _ in 0..20 {
        runtime.tick(Duration::from_millis(10), &world);
    }
    let settled_y = runtime.body(body_id).expect("settled body").position.y;
    assert_eq!(runtime.body(body_id).expect("body").velocity, Vector2::ZERO);

    for _ in 0..10 {
        runtime.tick(Duration::from_millis(10), &world);
    }
    assert_eq!(
        runtime.body(body_id).expect("body").position.y,
        settled_y,
        "the body must remain still after the bounded deceleration ramp"
    );
}

#[test]
fn hang_traverse_moves_left_and_right_on_top_edge() {
    let top = hangable_top();
    let mut world = TestWorld::default();
    world.insert(top);

    for (direction, expected_sign) in [
        (WalkDirection::Left, -1.0_f32),
        (WalkDirection::Right, 1.0_f32),
    ] {
        let body = hanging_body(top, 150.0);
        let body_id = body.id;
        let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
            step: Duration::from_millis(10),
            max_catch_up_steps: 8,
        });
        runtime.insert_body(body).expect("insert hanging body");
        runtime
            .enqueue(body_id, PhysicsCommand::HangTraverse { direction })
            .expect("queue hang traversal");

        let frame = runtime.tick(Duration::from_millis(10), &world);
        let moved = runtime.body(body_id).expect("traversing body");

        assert_eq!(frame.bodies[0].state, RuntimeBodyState::Hanging);
        assert_eq!(moved.attachment.surface_id(), Some(top.id));
        assert_eq!(moved.position.y, top.start.y);
        assert_eq!(moved.velocity.x.signum(), expected_sign);
        assert_eq!((moved.position.x - 150.0).signum(), expected_sign);
    }
}

#[test]
fn hang_traverse_prefers_window_top_over_overlapping_monitor_top() {
    let window_side = PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::WindowRight,
        start: Point2::new(400.0, 200.0),
        end: Point2::new(400.0, 700.0),
        orientation: Orientation::Vertical,
        normal: Vector2::new(-1.0, 0.0),
        capabilities: SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
    };
    let window_top = PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::WindowTop,
        start: Point2::new(100.0, 200.0),
        end: Point2::new(400.0, 200.0),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::HANGABLE,
    };
    let monitor_top = PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::MonitorEdge,
        start: Point2::new(0.0, 200.0),
        end: Point2::new(1920.0, 200.0),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, 1.0),
        capabilities: SurfaceCapabilities::HANGABLE,
    };
    let mut world = TestWorld::default();
    world.insert(window_side);
    world.insert(monitor_top);
    world.insert(window_top);

    let mut body = hanging_body(window_side, 390.0);
    body.position.y = 200.0;
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    let body_id = body.id;
    runtime.insert_body(body).expect("insert hanging body");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::HangTraverse {
                direction: WalkDirection::Right,
            },
        )
        .expect("queue hang traversal");

    runtime.tick(Duration::from_millis(10), &world);
    let hanging = runtime.body(body_id).expect("window hanging body");
    assert_eq!(hanging.attachment.surface_id(), Some(window_top.id));
    assert_eq!(hanging.position.y, window_top.start.y);
}

#[test]
fn hang_traverse_stops_and_remains_hanging_at_top_corner() {
    let top = hangable_top();
    let mut world = TestWorld::default();
    world.insert(top);
    let right_limit = top.end.x - 20.0;
    let body = hanging_body(top, right_limit);
    let body_id = body.id;
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    runtime.insert_body(body).expect("insert hanging body");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::HangTraverse {
                direction: WalkDirection::Right,
            },
        )
        .expect("queue traversal into corner");

    runtime.tick(Duration::from_millis(10), &world);
    let corner = runtime.body(body_id).expect("corner body").clone();
    assert_eq!(corner.position, Point2::new(right_limit, top.start.y));
    assert_eq!(corner.velocity, Vector2::ZERO);
    assert!(matches!(corner.attachment, AttachmentState::Hanging { .. }));

    for _ in 0..10 {
        runtime.tick(Duration::from_millis(10), &world);
    }
    assert_eq!(runtime.body(body_id), Some(&corner));
}

#[test]
fn climb_down_from_either_top_corner_transfers_to_connected_wall() {
    let top = hangable_top();
    let left_wall = left_climbable_wall();
    let right_wall = climbable_wall();
    let mut world = TestWorld::default();
    world.insert(top);
    world.insert(left_wall);
    world.insert(right_wall);

    for (start_x, expected_wall) in [(20.0, left_wall), (280.0, right_wall)] {
        let body = hanging_body(top, start_x);
        let body_id = body.id;
        let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
            step: Duration::from_millis(10),
            max_catch_up_steps: 8,
        });
        runtime.insert_body(body).expect("insert corner body");
        runtime
            .enqueue(
                body_id,
                PhysicsCommand::Climb {
                    direction: ClimbDirection::Down,
                },
            )
            .expect("queue climb down");

        let frame = runtime.tick(Duration::from_millis(10), &world);
        let climbing = runtime.body(body_id).expect("climbing body");
        assert_eq!(frame.bodies[0].state, RuntimeBodyState::Climbing);
        assert_eq!(climbing.attachment.surface_id(), Some(expected_wall.id));
        assert!(matches!(
            climbing.attachment,
            AttachmentState::Attached { .. }
        ));
        assert!(climbing.position.y > top.start.y);
        assert!(climbing.velocity.y > 0.0);
        assert!(frame.transitions.iter().all(|transition| !matches!(
            transition,
            ocp_desktop_physics::RuntimeTransition::CommandRejected { .. }
        )));
    }
}

#[test]
fn climb_down_from_middle_of_top_edge_is_rejected() {
    let top = hangable_top();
    let left_wall = left_climbable_wall();
    let right_wall = climbable_wall();
    let mut world = TestWorld::default();
    world.insert(top);
    world.insert(left_wall);
    world.insert(right_wall);
    let body = hanging_body(top, 150.0);
    let body_id = body.id;
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    runtime.insert_body(body).expect("insert middle body");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::Climb {
                direction: ClimbDirection::Down,
            },
        )
        .expect("queue unsupported climb down");

    let frame = runtime.tick(Duration::from_millis(10), &world);
    let hanging = runtime.body(body_id).expect("hanging body");
    assert_eq!(frame.bodies[0].state, RuntimeBodyState::Hanging);
    assert_eq!(hanging.position, Point2::new(150.0, top.start.y));
    assert!(frame.transitions.iter().any(|transition| matches!(
        transition,
        ocp_desktop_physics::RuntimeTransition::CommandRejected { .. }
    )));
}

#[test]
fn accumulator_runs_multiple_fixed_steps() {
    let surface = floor();
    let mut world = TestWorld::default();
    world.insert(surface);

    let body = grounded_body(surface);
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    runtime.insert_body(body).expect("insert");

    let frame = runtime.tick(Duration::from_millis(35), &world);

    assert_eq!(frame.simulated_steps, 3);
}

#[test]
fn catch_up_limit_prevents_spiral_of_death() {
    let surface = floor();
    let mut world = TestWorld::default();
    world.insert(surface);

    let body = grounded_body(surface);
    let mut runtime = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 2,
    });
    runtime.insert_body(body).expect("insert");

    let frame = runtime.tick(Duration::from_secs(1), &world);

    assert_eq!(frame.simulated_steps, 2);
}

#[test]
fn runtime_is_deterministic() {
    let surface = floor();
    let mut world = TestWorld::default();
    world.insert(surface);

    let first_body = grounded_body(surface);
    let mut second_body = first_body.clone();

    let mut first = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });
    let mut second = DesktopPhysicsRuntime::new(FixedStepConfig {
        step: Duration::from_millis(10),
        max_catch_up_steps: 8,
    });

    let first_id = first_body.id;
    second_body.id = first_id;

    first.insert_body(first_body).expect("first insert");
    second.insert_body(second_body).expect("second insert");

    for runtime in [&mut first, &mut second] {
        runtime
            .enqueue(
                first_id,
                PhysicsCommand::Jump {
                    direction: JumpDirection::Right,
                },
            )
            .expect("jump");
    }

    for _ in 0..120 {
        first.tick(Duration::from_millis(10), &world);
        second.tick(Duration::from_millis(10), &world);
    }

    assert_eq!(first.body(first_id), second.body(first_id));
}
