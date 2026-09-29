use ocp_shared_types::{Point2, SurfaceCapabilities, SurfaceDescriptor, SurfaceKind, Window};

use crate::DesktopWorldSnapshot;

#[derive(Debug, Clone, Default)]
pub struct WindowQuery {
    pub active_only: bool,
    pub visible_only: bool,
    pub include_minimized: bool,
    pub application_id: Option<String>,
}

impl WindowQuery {
    #[must_use]
    pub fn execute<'a>(&self, world: &'a DesktopWorldSnapshot) -> Vec<&'a Window> {
        world
            .windows
            .iter()
            .filter(|window| {
                (!self.active_only || window.active)
                    && (!self.visible_only || window.visible)
                    && (self.include_minimized || !window.minimized)
                    && self
                        .application_id
                        .as_ref()
                        .is_none_or(|application_id| &window.application_id == application_id)
            })
            .collect()
    }
}

#[derive(Debug, Clone, Default)]
pub struct SurfaceQuery {
    pub required_capabilities: SurfaceCapabilities,
    pub kinds: Vec<SurfaceKind>,
    pub near: Option<(Point2, f32)>,
}

impl SurfaceQuery {
    #[must_use]
    pub fn execute<'a>(&self, world: &'a DesktopWorldSnapshot) -> Vec<&'a SurfaceDescriptor> {
        world
            .surfaces
            .iter()
            .filter(|surface| {
                self.required_capabilities == SurfaceCapabilities::NONE
                    || surface.capabilities.contains(self.required_capabilities)
            })
            .filter(|surface| self.kinds.is_empty() || self.kinds.contains(&surface.surface_kind))
            .filter(|surface| {
                self.near
                    .is_none_or(|(point, radius)| surface_distance(surface, point) <= radius)
            })
            .collect()
    }
}

fn surface_distance(surface: &SurfaceDescriptor, point: Point2) -> f32 {
    use ocp_shared_types::surface::SurfaceGeometry;

    let representative = match &surface.geometry {
        SurfaceGeometry::Segment { start, end } => {
            Point2::new((start.x + end.x) * 0.5, (start.y + end.y) * 0.5)
        }
        SurfaceGeometry::Rectangle { rect } => rect.center(),
        SurfaceGeometry::Point { position } => *position,
    };

    (representative - point).length()
}
