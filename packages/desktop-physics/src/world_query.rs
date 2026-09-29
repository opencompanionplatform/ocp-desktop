use ocp_desktop_world::DesktopWorldSnapshot;
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Orientation, Point2, SurfaceCapabilities, SurfaceDescriptor, SurfaceId, SurfaceKind, Vector2,
};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PhysicsSurface {
    pub id: SurfaceId,
    pub kind: SurfaceKind,
    pub start: Point2,
    pub end: Point2,
    pub orientation: Orientation,
    pub normal: Vector2,
    pub capabilities: SurfaceCapabilities,
}

pub trait PhysicsWorldQuery {
    fn surface(&self, id: SurfaceId) -> Option<PhysicsSurface>;

    fn candidate_surfaces(&self, from: Point2, to: Point2) -> Vec<PhysicsSurface>;
}

pub struct DesktopWorldPhysicsQuery<'a> {
    world: &'a DesktopWorldSnapshot,
}

impl<'a> DesktopWorldPhysicsQuery<'a> {
    #[must_use]
    pub const fn new(world: &'a DesktopWorldSnapshot) -> Self {
        Self { world }
    }
}

impl PhysicsWorldQuery for DesktopWorldPhysicsQuery<'_> {
    fn surface(&self, id: SurfaceId) -> Option<PhysicsSurface> {
        self.world.surface(id).and_then(surface_to_physics)
    }

    fn candidate_surfaces(&self, from: Point2, to: Point2) -> Vec<PhysicsSurface> {
        let min_x = from.x.min(to.x);
        let max_x = from.x.max(to.x);
        let min_y = from.y.min(to.y);
        let max_y = from.y.max(to.y);

        self.world
            .surfaces
            .iter()
            .filter_map(surface_to_physics)
            .filter(|surface| {
                let surface_min_x = surface.start.x.min(surface.end.x);
                let surface_max_x = surface.start.x.max(surface.end.x);
                let surface_min_y = surface.start.y.min(surface.end.y);
                let surface_max_y = surface.start.y.max(surface.end.y);

                surface_max_x >= min_x
                    && surface_min_x <= max_x
                    && surface_max_y >= min_y
                    && surface_min_y <= max_y
            })
            .collect()
    }
}

fn surface_to_physics(surface: &SurfaceDescriptor) -> Option<PhysicsSurface> {
    let (start, end) = match surface.geometry {
        SurfaceGeometry::Segment { start, end } => (start, end),
        SurfaceGeometry::Rectangle { rect } => (
            Point2::new(rect.left(), rect.top()),
            Point2::new(rect.right(), rect.top()),
        ),
        SurfaceGeometry::Point { .. } => return None,
    };

    Some(PhysicsSurface {
        id: surface.id,
        kind: surface.surface_kind,
        start,
        end,
        orientation: surface.orientation,
        normal: surface.normal,
        capabilities: surface.capabilities,
    })
}
