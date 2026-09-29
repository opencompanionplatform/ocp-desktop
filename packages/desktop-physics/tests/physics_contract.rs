use ocp_desktop_physics::{
    AabbCollider, AttachmentState, DesktopPhysicsSolver, PhysicsBody, PhysicsConfig,
    PhysicsStepState, PhysicsSurface, PhysicsWorldQuery, SurfaceAttachment,
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

#[test]
fn gravity_is_deterministic() {
    let solver = DesktopPhysicsSolver::default();
    let world = TestWorld::default();
    let mut first = PhysicsBody::new(Point2::new(10.0, 10.0), AabbCollider::new(10.0, 10.0));
    let mut second = first.clone();

    for _ in 0..120 {
        solver.step(&mut first, Duration::from_millis(16), &world);
        solver.step(&mut second, Duration::from_millis(16), &world);
    }

    assert_eq!(first.position, second.position);
    assert_eq!(first.velocity, second.velocity);
}

#[test]
fn terminal_velocity_is_enforced() {
    let solver = DesktopPhysicsSolver::new(PhysicsConfig {
        terminal_velocity: 250.0,
        ..PhysicsConfig::default()
    });
    let world = TestWorld::default();
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    for _ in 0..1_000 {
        solver.step(&mut body, Duration::from_millis(16), &world);
    }

    assert!(body.velocity.y <= 250.0);
}

#[test]
fn body_lands_on_horizontal_surface() {
    let surface = floor(200.0);
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = DesktopPhysicsSolver::default();
    let mut body = PhysicsBody::new(Point2::new(100.0, 100.0), AabbCollider::new(10.0, 20.0));

    let mut landed = false;
    for _ in 0..120 {
        let result = solver.step(&mut body, Duration::from_millis(16), &world);
        landed |= result.landed;
        if result.state == PhysicsStepState::Grounded {
            break;
        }
    }

    assert!(landed);
    assert!(body.attachment.is_grounded());
    assert_eq!(body.position.y, 180.0);
    assert_eq!(body.velocity.y, 0.0);
}

#[test]
fn missing_surface_detaches_body() {
    let surface = floor(200.0);
    let surface_id = surface.id;
    let world = TestWorld::default();
    let solver = DesktopPhysicsSolver::default();

    let mut body = PhysicsBody::new(Point2::new(100.0, 180.0), AabbCollider::new(10.0, 20.0));
    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id,
            anchor: Point2::new(100.0, 200.0),
            normal: Vector2::new(0.0, -1.0),
        },
    };

    let result = solver.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(body.attachment, AttachmentState::Detached);
    assert_eq!(result.state, PhysicsStepState::Falling);
}

#[test]
fn grounded_body_remains_attached_to_dynamic_only_surface() {
    let mut surface = floor(200.0);
    surface.capabilities = SurfaceCapabilities::DYNAMIC;
    let surface_id = surface.id;
    let mut world = TestWorld::default();
    world.insert(surface);
    let solver = DesktopPhysicsSolver::default();

    let mut body = PhysicsBody::new(Point2::new(100.0, 180.0), AabbCollider::new(10.0, 20.0));
    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id,
            anchor: Point2::new(100.0, 200.0),
            normal: Vector2::new(0.0, -1.0),
        },
    };

    let result = solver.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(result.state, PhysicsStepState::Grounded);
    assert_eq!(
        result.attachment_transition,
        ocp_desktop_physics::AttachmentTransition::None
    );
    assert!(body.attachment.is_grounded());
}

#[test]
fn large_delta_is_clamped() {
    let solver = DesktopPhysicsSolver::new(PhysicsConfig {
        max_step_seconds: 0.02,
        ..PhysicsConfig::default()
    });
    let world = TestWorld::default();
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    solver.step(&mut body, Duration::from_secs(10), &world);

    assert!(body.position.y < 10.0);
}

#[test]
fn detached_body_far_below_floor_is_recovered() {
    let surface = floor(200.0);
    let surface_id = surface.id;
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = DesktopPhysicsSolver::default();
    let mut body = PhysicsBody::new(Point2::new(100.0, 2_000.0), AabbCollider::new(10.0, 20.0));
    body.velocity = Vector2::new(0.0, 1_600.0);
    body.attachment = AttachmentState::Detached;
    let body_id = body.id;

    let result = solver.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(body.id, body_id);
    assert_eq!(body.attachment.surface_id(), Some(surface_id));
    assert_eq!(body.position, Point2::new(100.0, 180.0));
    assert_eq!(body.velocity, Vector2::ZERO);
    assert_eq!(result.state, PhysicsStepState::Grounded);
    assert!(result.landed);
}

#[test]
fn fall_guard_clamps_recovery_to_supported_surface_width() {
    let surface = floor(200.0);
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = DesktopPhysicsSolver::default();
    let mut body = PhysicsBody::new(Point2::new(-5.0, 2_000.0), AabbCollider::new(10.0, 20.0));
    body.velocity = Vector2::new(0.0, 1_600.0);
    body.attachment = AttachmentState::Detached;

    let result = solver.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(result.state, PhysicsStepState::Grounded);
    assert_eq!(body.position.x, 10.0);
    assert_eq!(body.position.y, 180.0);
}
