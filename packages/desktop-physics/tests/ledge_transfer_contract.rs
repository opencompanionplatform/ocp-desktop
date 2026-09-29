use ocp_desktop_physics::{
    AabbCollider, AttachmentState, LedgeTransferConfig, LedgeTransferError, LedgeTransferSolver,
    PhysicsBody, PhysicsSurface, PhysicsWorldQuery, SurfaceAttachment,
};
use ocp_shared_types::{Orientation, Point2, SurfaceCapabilities, SurfaceId, SurfaceKind, Vector2};
use std::collections::BTreeMap;

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

fn vertical_left_wall() -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(300.0, 100.0),
        end: Point2::new(300.0, 500.0),
        orientation: Orientation::Vertical,
        normal: Vector2::new(-1.0, 0.0),
        capabilities: SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
    }
}

fn horizontal_ledge(
    start_x: f32,
    end_x: f32,
    y: f32,
    capabilities: SurfaceCapabilities,
) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(start_x, y),
        end: Point2::new(end_x, y),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities,
    }
}

fn hanging_body(source: PhysicsSurface) -> PhysicsBody {
    let mut body = PhysicsBody::new(Point2::new(280.0, 100.0), AabbCollider::new(20.0, 30.0));

    body.attachment = AttachmentState::Hanging {
        attachment: SurfaceAttachment {
            surface_id: source.id,
            anchor: Point2::new(300.0, 100.0),
            normal: source.normal,
        },
    };

    body
}

#[test]
fn hanging_body_transfers_to_landable_top_surface() {
    let source = vertical_left_wall();
    let target = horizontal_ledge(
        100.0,
        300.0,
        100.0,
        SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
    );

    let mut world = TestWorld::default();
    world.insert(source);
    world.insert(target);

    let solver = LedgeTransferSolver::default();
    let mut body = hanging_body(source);

    let result = solver
        .transfer_hanging_to_grounded(&mut body, &world)
        .expect("ledge transfer");

    assert_eq!(result.source_surface_id, source.id);
    assert_eq!(result.target_surface_id, target.id);
    assert_eq!(body.position.y, 70.0);
    assert!(body.position.x < source.start.x);
    assert_eq!(body.velocity, Vector2::ZERO);
    assert!(body.attachment.is_grounded());
    assert_eq!(body.attachment.surface_id(), Some(target.id),);
}

#[test]
fn transfer_is_deterministic() {
    let source = vertical_left_wall();
    let target = horizontal_ledge(100.0, 300.0, 100.0, SurfaceCapabilities::LANDABLE);

    let mut world = TestWorld::default();
    world.insert(source);
    world.insert(target);

    let solver = LedgeTransferSolver::default();
    let mut first = hanging_body(source);
    let mut second = hanging_body(source);

    let first_result = solver
        .transfer_hanging_to_grounded(&mut first, &world)
        .expect("first transfer");
    let second_result = solver
        .transfer_hanging_to_grounded(&mut second, &world)
        .expect("second transfer");

    assert_eq!(first_result, second_result);
    assert_eq!(first.position, second.position);
    assert_eq!(first.attachment, second.attachment);
}

#[test]
fn non_landable_top_surface_is_rejected() {
    let source = vertical_left_wall();
    let target = horizontal_ledge(100.0, 300.0, 100.0, SurfaceCapabilities::WALKABLE);

    let mut world = TestWorld::default();
    world.insert(source);
    world.insert(target);

    let solver = LedgeTransferSolver::default();
    let mut body = hanging_body(source);

    let error = solver
        .transfer_hanging_to_grounded(&mut body, &world)
        .expect_err("non-landable ledge must fail");

    assert_eq!(
        error,
        LedgeTransferError::NoLandableLedge {
            source_surface_id: source.id,
        },
    );
    assert!(matches!(body.attachment, AttachmentState::Hanging { .. }));
}

#[test]
fn distant_ledge_is_rejected() {
    let source = vertical_left_wall();
    let target = horizontal_ledge(0.0, 100.0, 100.0, SurfaceCapabilities::LANDABLE);

    let mut world = TestWorld::default();
    world.insert(source);
    world.insert(target);

    let solver = LedgeTransferSolver::new(LedgeTransferConfig {
        max_horizontal_gap: 16.0,
        ..LedgeTransferConfig::default()
    });
    let mut body = hanging_body(source);

    let error = solver
        .transfer_hanging_to_grounded(&mut body, &world)
        .expect_err("distant ledge must fail");

    assert_eq!(
        error,
        LedgeTransferError::NoLandableLedge {
            source_surface_id: source.id,
        },
    );
}

#[test]
fn body_must_be_hanging_before_transfer() {
    let source = vertical_left_wall();
    let target = horizontal_ledge(100.0, 300.0, 100.0, SurfaceCapabilities::LANDABLE);

    let mut world = TestWorld::default();
    world.insert(source);
    world.insert(target);

    let solver = LedgeTransferSolver::default();
    let mut body = PhysicsBody::new(Point2::new(280.0, 100.0), AabbCollider::default());

    let error = solver
        .transfer_hanging_to_grounded(&mut body, &world)
        .expect_err("detached body must fail");

    assert_eq!(error, LedgeTransferError::BodyNotHanging);
}

#[test]
fn nearest_valid_ledge_is_selected() {
    let source = vertical_left_wall();
    let near = horizontal_ledge(150.0, 300.0, 100.0, SurfaceCapabilities::LANDABLE);
    let far = horizontal_ledge(0.0, 260.0, 108.0, SurfaceCapabilities::LANDABLE);

    let mut world = TestWorld::default();
    world.insert(source);
    world.insert(far);
    world.insert(near);

    let solver = LedgeTransferSolver::default();
    let mut body = hanging_body(source);

    let result = solver
        .transfer_hanging_to_grounded(&mut body, &world)
        .expect("nearest ledge");

    assert_eq!(result.target_surface_id, near.id);
}
