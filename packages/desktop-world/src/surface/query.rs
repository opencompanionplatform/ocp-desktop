use ocp_shared_types::Point2;

use super::{SurfaceKindV2, SurfaceRegistryId, SurfaceRegistrySnapshot, SurfaceSegment};

#[derive(Debug, Clone, Default)]
pub struct SurfaceFilter {
    pub kinds: Vec<SurfaceKindV2>,
    pub eligible_only: bool,
    pub visible_only: bool,
    pub supports_walk: bool,
    pub supports_sit: bool,
}

impl SurfaceFilter {
    fn accepts(&self, surface: &SurfaceSegment) -> bool {
        (self.kinds.is_empty() || self.kinds.contains(&surface.kind))
            && (!self.eligible_only || surface.eligible)
            && (!self.visible_only || surface.visible)
            && (!self.supports_walk || surface.support.supports_walk)
            && (!self.supports_sit || surface.support.supports_sit)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SurfaceProjection {
    pub surface_id: SurfaceRegistryId,
    pub point: Point2,
    pub distance: f32,
    pub coordinate: f32,
}

pub struct SurfaceGeometryQuery<'a> {
    snapshot: &'a SurfaceRegistrySnapshot,
}

impl<'a> SurfaceGeometryQuery<'a> {
    #[must_use]
    pub const fn new(snapshot: &'a SurfaceRegistrySnapshot) -> Self {
        Self { snapshot }
    }

    #[must_use]
    pub fn nearest_surface(
        &self,
        point: Point2,
        filter: &SurfaceFilter,
    ) -> Option<SurfaceProjection> {
        self.snapshot
            .surfaces
            .values()
            .filter(|surface| filter.accepts(surface))
            .filter_map(|surface| project(surface, point))
            .min_by(|left, right| left.distance.total_cmp(&right.distance))
    }

    #[must_use]
    pub fn surface_below(
        &self,
        point: Point2,
        max_distance: f32,
        filter: &SurfaceFilter,
    ) -> Option<SurfaceProjection> {
        self.snapshot
            .surfaces
            .values()
            .filter(|surface| filter.accepts(surface))
            .filter(|surface| {
                surface.start.y >= point.y
                    && surface.end.y >= point.y
                    && point.x >= surface.start.x.min(surface.end.x)
                    && point.x <= surface.start.x.max(surface.end.x)
            })
            .filter_map(|surface| project(surface, point))
            .filter(|projection| projection.distance <= max_distance)
            .min_by(|left, right| left.distance.total_cmp(&right.distance))
    }

    #[must_use]
    pub fn project_onto_surface(
        &self,
        point: Point2,
        surface_id: &SurfaceRegistryId,
    ) -> Option<SurfaceProjection> {
        self.snapshot
            .surface(surface_id)
            .and_then(|surface| project(surface, point))
    }

    #[must_use]
    pub fn surface_at(
        &self,
        point: Point2,
        tolerance: f32,
        filter: &SurfaceFilter,
    ) -> Vec<&'a SurfaceSegment> {
        self.snapshot
            .surfaces
            .values()
            .filter(|surface| filter.accepts(surface))
            .filter(|surface| {
                project(surface, point).is_some_and(|projection| projection.distance <= tolerance)
            })
            .collect()
    }
}

fn project(surface: &SurfaceSegment, point: Point2) -> Option<SurfaceProjection> {
    let delta = surface.end - surface.start;
    let length_squared = delta.x * delta.x + delta.y * delta.y;
    if length_squared <= f32::EPSILON {
        return None;
    }

    let relative = point - surface.start;
    let coordinate =
        ((relative.x * delta.x + relative.y * delta.y) / length_squared).clamp(0.0, 1.0);
    let projected = Point2::new(
        surface.start.x + delta.x * coordinate,
        surface.start.y + delta.y * coordinate,
    );

    Some(SurfaceProjection {
        surface_id: surface.id.clone(),
        point: projected,
        distance: (projected - point).length(),
        coordinate,
    })
}
