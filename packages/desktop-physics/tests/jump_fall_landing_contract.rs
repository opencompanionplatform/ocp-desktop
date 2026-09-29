use ocp_desktop_physics::{
    AabbCollider, AirborneController, AirbornePhase, AttachmentState, DesktopPhysicsSolver,
    JumpConfig, JumpDirection, JumpError, JumpMotor, PhysicsBody, PhysicsConfig, PhysicsSurface,
    PhysicsWorldQuery, SurfaceAttachment,
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

fn floor(y: f32) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(0.0, y),
        end: Point2::new(1_000.0, y),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
    }
}

fn grounded_body(surface: PhysicsSurface, x: f32) -> PhysicsBody {
    let mut body = PhysicsBody::new(
        Point2::new(x, surface.start.y - 20.0),
        AabbCollider::new(10.0, 20.0),
    );

    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id: surface.id,
            anchor: Point2::new(x, surface.start.y),
            normal: surface.normal,
        },
    };

    body
}

#[test]
fn jump_requires_grounded_body() {
    let motor = JumpMotor::default();
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    let error = motor
        .start_jump(&mut body, JumpDirection::Vertical)
        .expect_err("detached body must fail");

    assert_eq!(error, JumpError::BodyNotGrounded);
}

#[test]
fn vertical_jump_detaches_and_applies_upward_velocity() {
    let surface = floor(500.0);
    let motor = JumpMotor::new(JumpConfig {
        jump_speed: 600.0,
        horizontal_speed: 200.0,
    });
    let mut body = grounded_body(surface, 400.0);

    let result = motor
        .start_jump(&mut body, JumpDirection::Vertical)
        .expect("jump");

    assert_eq!(result.source_surface_id, surface.id);
    assert_eq!(body.attachment, AttachmentState::Detached);
    assert_eq!(body.velocity.x, 0.0);
    assert_eq!(body.velocity.y, -600.0);
}

#[test]
fn directional_jump_preserves_horizontal_motion() {
    let surface = floor(500.0);
    let motor = JumpMotor::new(JumpConfig {
        jump_speed: 600.0,
        horizontal_speed: 200.0,
    });

    let mut left = grounded_body(surface, 400.0);
    let mut right = grounded_body(surface, 400.0);

    motor
        .start_jump(&mut left, JumpDirection::Left)
        .expect("left jump");
    motor
        .start_jump(&mut right, JumpDirection::Right)
        .expect("right jump");

    assert_eq!(left.velocity, Vector2::new(-200.0, -600.0));
    assert_eq!(right.velocity, Vector2::new(200.0, -600.0));
}

#[test]
fn jump_transitions_from_rising_to_falling() {
    let surface = floor(500.0);
    let world = TestWorld::default();
    let jump = JumpMotor::new(JumpConfig {
        jump_speed: 200.0,
        horizontal_speed: 0.0,
    });
    let physics = DesktopPhysicsSolver::new(PhysicsConfig {
        gravity: Vector2::new(0.0, 1_000.0),
        terminal_velocity: 1_000.0,
        max_step_seconds: 0.05,
        ..PhysicsConfig::default()
    });
    let airborne = AirborneController::new(1.0);
    let mut body = grounded_body(surface, 400.0);

    jump.start_jump(&mut body, JumpDirection::Vertical)
        .expect("jump");

    let first = airborne.step(&mut body, Duration::from_millis(50), &world, &physics);
    assert_eq!(first.phase, AirbornePhase::Rising);

    let mut falling_seen = false;
    for _ in 0..20 {
        let step = airborne.step(&mut body, Duration::from_millis(50), &world, &physics);
        if step.phase == AirbornePhase::Falling {
            falling_seen = true;
            break;
        }
    }

    assert!(falling_seen);
}

#[test]
fn body_lands_on_lower_surface_after_jump() {
    let source = floor(200.0);
    let target = floor(500.0);

    let mut world = TestWorld::default();
    world.insert(target);

    let jump = JumpMotor::new(JumpConfig {
        jump_speed: 250.0,
        horizontal_speed: 0.0,
    });
    let physics = DesktopPhysicsSolver::new(PhysicsConfig {
        gravity: Vector2::new(0.0, 1_200.0),
        terminal_velocity: 1_000.0,
        max_step_seconds: 0.02,
        ..PhysicsConfig::default()
    });
    let airborne = AirborneController::default();
    let mut body = grounded_body(source, 400.0);

    jump.start_jump(&mut body, JumpDirection::Vertical)
        .expect("jump");

    let mut landed = false;
    for _ in 0..500 {
        let step = airborne.step(&mut body, Duration::from_millis(16), &world, &physics);
        if step.landed {
            landed = true;
            assert_eq!(step.landed_surface_id, Some(target.id));
            break;
        }
    }

    assert!(landed);
    assert!(body.attachment.is_grounded());
    assert_eq!(body.position.y, 480.0);
    assert_eq!(body.velocity.y, 0.0);
}

#[test]
fn jump_simulation_is_deterministic() {
    let source = floor(500.0);
    let world = TestWorld::default();
    let jump = JumpMotor::new(JumpConfig {
        jump_speed: 300.0,
        horizontal_speed: 120.0,
    });
    let physics = DesktopPhysicsSolver::default();
    let airborne = AirborneController::default();

    let mut first = grounded_body(source, 400.0);
    let mut second = grounded_body(source, 400.0);

    jump.start_jump(&mut first, JumpDirection::Right)
        .expect("first jump");
    jump.start_jump(&mut second, JumpDirection::Right)
        .expect("second jump");

    for _ in 0..120 {
        airborne.step(&mut first, Duration::from_millis(16), &world, &physics);
        airborne.step(&mut second, Duration::from_millis(16), &world, &physics);
    }

    assert_eq!(first.position, second.position);
    assert_eq!(first.velocity, second.velocity);
    assert_eq!(first.attachment, second.attachment);
}
