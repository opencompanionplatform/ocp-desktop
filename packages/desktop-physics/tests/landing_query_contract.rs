use ocp_desktop_physics::{
    AabbCollider, AttachmentState, DesktopPhysicsSolver, PhysicsBody, PhysicsConfig,
    PhysicsSurface, PhysicsWorldQuery,
};
use ocp_shared_types::{Orientation, Point2, SurfaceCapabilities, SurfaceId, SurfaceKind, Vector2};
use std::time::Duration;

struct SpatiallyFilteredWorld {
    floor: PhysicsSurface,
}

impl PhysicsWorldQuery for SpatiallyFilteredWorld {
    fn surface(&self, id: SurfaceId) -> Option<PhysicsSurface> {
        (id == self.floor.id).then_some(self.floor)
    }

    fn candidate_surfaces(&self, from: Point2, to: Point2) -> Vec<PhysicsSurface> {
        let query_min_x = from.x.min(to.x);
        let query_max_x = from.x.max(to.x);
        let query_min_y = from.y.min(to.y);
        let query_max_y = from.y.max(to.y);

        let surface_min_x = self.floor.start.x.min(self.floor.end.x);
        let surface_max_x = self.floor.start.x.max(self.floor.end.x);
        let surface_y = self.floor.start.y;

        if surface_max_x >= query_min_x
            && surface_min_x <= query_max_x
            && surface_y >= query_min_y
            && surface_y <= query_max_y
        {
            vec![self.floor]
        } else {
            Vec::new()
        }
    }
}

struct StackedSurfaceWorld {
    surfaces: Vec<PhysicsSurface>,
}

impl PhysicsWorldQuery for StackedSurfaceWorld {
    fn surface(&self, id: SurfaceId) -> Option<PhysicsSurface> {
        self.surfaces
            .iter()
            .copied()
            .find(|surface| surface.id == id)
    }

    fn candidate_surfaces(&self, from: Point2, to: Point2) -> Vec<PhysicsSurface> {
        let query_min_x = from.x.min(to.x);
        let query_max_x = from.x.max(to.x);
        let query_min_y = from.y.min(to.y);
        let query_max_y = from.y.max(to.y);

        self.surfaces
            .iter()
            .copied()
            .filter(|surface| {
                let surface_min_x = surface.start.x.min(surface.end.x);
                let surface_max_x = surface.start.x.max(surface.end.x);
                let surface_y = surface.start.y;
                surface_max_x >= query_min_x
                    && surface_min_x <= query_max_x
                    && surface_y >= query_min_y
                    && surface_y <= query_max_y
            })
            .collect()
    }
}

fn floor(y: f32) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind: SurfaceKind::DesktopFloor,
        start: Point2::new(0.0, y),
        end: Point2::new(1_280.0, y),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
    }
}

fn horizontal_surface(
    kind: SurfaceKind,
    y: f32,
    capabilities: SurfaceCapabilities,
) -> PhysicsSurface {
    PhysicsSurface {
        id: SurfaceId::new(),
        kind,
        start: Point2::new(0.0, y),
        end: Point2::new(1_280.0, y),
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities,
    }
}

#[test]
fn landing_query_uses_feet_sweep_instead_of_body_center_sweep() {
    let floor = floor(700.0);
    let world = SpatiallyFilteredWorld { floor };

    let mut body = PhysicsBody::new(Point2::new(640.0, 675.0), AabbCollider::new(20.0, 20.0));
    body.attachment = AttachmentState::Detached;
    body.velocity = Vector2::new(0.0, 240.0);

    let solver = DesktopPhysicsSolver::new(PhysicsConfig {
        gravity: Vector2::ZERO,
        terminal_velocity: 1_000.0,
        max_step_seconds: 0.05,
        ..PhysicsConfig::default()
    });

    let result = solver.step(&mut body, Duration::from_millis(50), &world);

    assert!(result.landed, "feet crossed the floor and must land");
    assert!(body.attachment.is_grounded());
    assert_eq!(body.position.y, 680.0);
    assert_eq!(body.velocity.y, 0.0);
}

#[test]
fn grounded_body_can_move_again_after_landing() {
    let floor = floor(700.0);
    let world = SpatiallyFilteredWorld { floor };

    let mut body = PhysicsBody::new(Point2::new(640.0, 675.0), AabbCollider::new(20.0, 20.0));
    body.attachment = AttachmentState::Detached;
    body.velocity = Vector2::new(0.0, 240.0);

    let solver = DesktopPhysicsSolver::new(PhysicsConfig {
        gravity: Vector2::ZERO,
        terminal_velocity: 1_000.0,
        max_step_seconds: 0.05,
        ..PhysicsConfig::default()
    });

    let result = solver.step(&mut body, Duration::from_millis(50), &world);

    assert!(result.landed);
    assert!(
        body.attachment.is_grounded(),
        "post-landing movement requires a grounded canonical body"
    );
}

#[test]
fn falling_body_lands_on_visible_lower_window_before_taskbar() {
    let lower_window = horizontal_surface(
        SurfaceKind::WindowTop,
        500.0,
        SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::DYNAMIC),
    );
    let taskbar = horizontal_surface(
        SurfaceKind::TaskbarTop,
        700.0,
        SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
    );
    let world = StackedSurfaceWorld {
        surfaces: vec![lower_window, taskbar],
    };

    let mut body = PhysicsBody::new(Point2::new(640.0, 450.0), AabbCollider::new(20.0, 20.0));
    body.attachment = AttachmentState::Detached;
    body.velocity = Vector2::new(0.0, 1_200.0);

    let solver = DesktopPhysicsSolver::new(PhysicsConfig {
        gravity: Vector2::ZERO,
        terminal_velocity: 2_000.0,
        max_step_seconds: 0.05,
        ..PhysicsConfig::default()
    });

    let result = solver.step(&mut body, Duration::from_millis(50), &world);

    assert!(
        result.landed,
        "the falling body must land on the lower window"
    );
    assert_eq!(body.attachment.surface_id(), Some(lower_window.id));
    assert_eq!(body.position.y, 480.0);
}
