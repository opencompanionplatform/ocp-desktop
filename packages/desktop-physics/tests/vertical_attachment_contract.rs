use ocp_desktop_physics::{
    AabbCollider, AttachmentError, AttachmentState, ClimbConfig, ClimbDirection,
    DesktopPhysicsSolver, PhysicsBody, PhysicsStepState, PhysicsSurface, PhysicsWorldQuery,
    SurfaceAttachmentSolver,
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

fn vertical_surface(capabilities: SurfaceCapabilities) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(300.0, 100.0),
        end: Point2::new(300.0, 500.0),
        orientation: Orientation::Vertical,
        normal: Vector2::new(-1.0, 0.0),
        capabilities,
    }
}

fn floor_at(y: f32) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(0.0, y),
        end: Point2::new(800.0, y),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
    }
}

#[test]
fn body_attaches_to_climbable_vertical_surface() {
    let surface = vertical_surface(SurfaceCapabilities::CLIMBABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = SurfaceAttachmentSolver::default();
    let mut body = PhysicsBody::new(Point2::new(200.0, 250.0), AabbCollider::new(20.0, 30.0));

    solver
        .attach_to_vertical_surface(&mut body, surface.id, 250.0, &world)
        .expect("attach");

    assert!(matches!(body.attachment, AttachmentState::Attached { .. }));
    assert_eq!(body.position, Point2::new(280.0, 250.0));
    assert_eq!(body.velocity, Vector2::ZERO);
}

#[test]
fn non_climbable_surface_is_rejected() {
    let surface = vertical_surface(SurfaceCapabilities::HANGABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = SurfaceAttachmentSolver::default();
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    let error = solver
        .attach_to_vertical_surface(&mut body, surface.id, 200.0, &world)
        .expect_err("surface must be rejected");

    assert_eq!(
        error,
        AttachmentError::SurfaceNotClimbable {
            surface_id: surface.id,
        }
    );
}

#[test]
fn climb_is_deterministic() {
    let surface = vertical_surface(SurfaceCapabilities::CLIMBABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = SurfaceAttachmentSolver::new(ClimbConfig {
        speed: 100.0,
        ..ClimbConfig::default()
    });
    let mut first = PhysicsBody::new(Point2::ZERO, AabbCollider::default());
    let mut second = first.clone();

    solver
        .attach_to_vertical_surface(&mut first, surface.id, 400.0, &world)
        .expect("first attach");
    solver
        .attach_to_vertical_surface(&mut second, surface.id, 400.0, &world)
        .expect("second attach");

    for _ in 0..60 {
        solver
            .climb(
                &mut first,
                ClimbDirection::Up,
                Duration::from_millis(16),
                &world,
            )
            .expect("first climb");
        solver
            .climb(
                &mut second,
                ClimbDirection::Up,
                Duration::from_millis(16),
                &world,
            )
            .expect("second climb");
    }

    assert_eq!(first.position, second.position);
    assert_eq!(first.attachment, second.attachment);
}

#[test]
fn reaching_hangable_top_enters_hanging_state() {
    let surface =
        vertical_surface(SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE));
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = SurfaceAttachmentSolver::new(ClimbConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..ClimbConfig::default()
    });
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    solver
        .attach_to_vertical_surface(&mut body, surface.id, 110.0, &world)
        .expect("attach");

    let result = solver
        .climb(
            &mut body,
            ClimbDirection::Up,
            Duration::from_millis(100),
            &world,
        )
        .expect("climb");

    assert!(result.reached_endpoint);
    assert!(matches!(body.attachment, AttachmentState::Hanging { .. }));
    assert_eq!(body.position.y, 100.0);
    assert_eq!(body.velocity, Vector2::ZERO);
}

#[test]
fn reaching_bottom_with_supported_floor_becomes_grounded() {
    let surface = vertical_surface(SurfaceCapabilities::CLIMBABLE);
    // Character-independent wall and floor surfaces meet at y=500. The
    // transfer solver applies the collider offset only after grounding.
    let floor = floor_at(500.0);
    let mut world = TestWorld::default();
    world.insert(surface);
    world.insert(floor);

    let solver = SurfaceAttachmentSolver::new(ClimbConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..ClimbConfig::default()
    });
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::new(20.0, 30.0));
    solver
        .attach_to_vertical_surface(&mut body, surface.id, 490.0, &world)
        .expect("attach");

    let result = solver
        .climb(
            &mut body,
            ClimbDirection::Down,
            Duration::from_millis(100),
            &world,
        )
        .expect("climb down to floor");

    assert!(result.reached_endpoint);
    assert_eq!(
        result.transition,
        ocp_desktop_physics::AttachmentTransition::Grounded {
            surface_id: floor.id,
        }
    );
    assert!(matches!(body.attachment, AttachmentState::Grounded { .. }));
    assert_eq!(body.position, Point2::new(280.0, 470.0));
    assert_eq!(body.velocity, Vector2::ZERO);
}

#[test]
fn reaching_bottom_without_supported_floor_remains_attached() {
    let surface = vertical_surface(SurfaceCapabilities::CLIMBABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let solver = SurfaceAttachmentSolver::new(ClimbConfig {
        speed: 200.0,
        max_step_seconds: 0.1,
        ..ClimbConfig::default()
    });
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::new(20.0, 30.0));
    solver
        .attach_to_vertical_surface(&mut body, surface.id, 490.0, &world)
        .expect("attach");

    let result = solver
        .climb(
            &mut body,
            ClimbDirection::Down,
            Duration::from_millis(100),
            &world,
        )
        .expect("climb down to unsupported endpoint");

    assert!(result.reached_endpoint);
    assert_eq!(
        result.transition,
        ocp_desktop_physics::AttachmentTransition::None
    );
    assert!(matches!(body.attachment, AttachmentState::Attached { .. }));
    assert_eq!(body.velocity, Vector2::ZERO);
}

#[test]
fn explicit_detach_allows_gravity_to_resume() {
    let surface = vertical_surface(SurfaceCapabilities::CLIMBABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let attachment_solver = SurfaceAttachmentSolver::default();
    let physics_solver = DesktopPhysicsSolver::default();
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    attachment_solver
        .attach_to_vertical_surface(&mut body, surface.id, 250.0, &world)
        .expect("attach");
    attachment_solver.detach(&mut body);

    let result = physics_solver.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(result.state, PhysicsStepState::Falling);
    assert!(body.velocity.y > 0.0);
}

#[test]
fn disappearing_vertical_surface_detaches_on_next_tick() {
    let surface = vertical_surface(SurfaceCapabilities::CLIMBABLE);
    let mut world = TestWorld::default();
    world.insert(surface);

    let attachment_solver = SurfaceAttachmentSolver::default();
    let physics_solver = DesktopPhysicsSolver::default();
    let mut body = PhysicsBody::new(Point2::ZERO, AabbCollider::default());

    attachment_solver
        .attach_to_vertical_surface(&mut body, surface.id, 250.0, &world)
        .expect("attach");

    world.remove(surface.id);

    let result = physics_solver.step(&mut body, Duration::from_millis(16), &world);

    assert_eq!(body.attachment, AttachmentState::Detached);
    assert_eq!(result.state, PhysicsStepState::Falling);
}
