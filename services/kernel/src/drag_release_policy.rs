use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Orientation, Point2, SurfaceCapabilities, SurfaceDescriptor, SurfaceId, SurfaceKind,
    WorldEntityId,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DragReleaseTargetKind {
    WindowTop,
    TaskbarTop,
    DesktopFloor,
    MonitorEdge,
    Airborne,
}

impl DragReleaseTargetKind {
    #[must_use]
    pub const fn attachment_state(self) -> &'static str {
        match self {
            Self::Airborne => "airborne",
            Self::WindowTop | Self::TaskbarTop | Self::DesktopFloor => "grounded",
            Self::MonitorEdge => "attached",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DragReleaseDecision {
    pub target_kind: DragReleaseTargetKind,
    pub resolved_feet: Point2,
    pub surface_id: Option<SurfaceId>,
}

/// Selects the first canonical horizontal surface below the released feet.
///
/// The body footprint must fit completely inside the surface. Selection is by
/// vertical distance, then semantic rank for deterministic equal-Y ties.
#[must_use]
pub fn decide_drag_release(
    requested_feet: Point2,
    surfaces: &[SurfaceDescriptor],
    half_width: f32,
) -> DragReleaseDecision {
    decide_drag_release_with_preferred_monitor(requested_feet, surfaces, half_width, None)
}

/// Selects a drag-release surface while preserving the originating monitor at
/// a coincident multi-monitor seam. Distance remains primary; monitor ownership
/// is only the deterministic tie-breaker when both edge segments overlap.
#[must_use]
pub fn decide_drag_release_with_preferred_monitor(
    requested_feet: Point2,
    surfaces: &[SurfaceDescriptor],
    half_width: f32,
    preferred_monitor_owner: Option<WorldEntityId>,
) -> DragReleaseDecision {
    const MONITOR_EDGE_SNAP_DISTANCE: f32 = 80.0;
    const HORIZONTAL_SURFACE_SNAP_DISTANCE: f32 = 80.0;
    // The release point is the character centre in Runtime V3. Include the
    // body half-width so the visible sprite can be within 80px of the edge.
    let monitor_edge_snap_distance = MONITOR_EDGE_SNAP_DISTANCE + half_width;

    let mut edge_candidates: Vec<&SurfaceDescriptor> = surfaces
        .iter()
        .filter(|surface| {
            surface.surface_kind == SurfaceKind::MonitorEdge
                && surface.orientation == Orientation::Vertical
                && surface
                    .capabilities
                    .contains(SurfaceCapabilities::CLIMBABLE)
                && surface.capabilities.contains(SurfaceCapabilities::HANGABLE)
        })
        .filter(|surface| {
            let SurfaceGeometry::Segment { start, end } = surface.geometry else {
                return false;
            };
            let edge_x = start.x;
            let top = start.y.min(end.y);
            let bottom = start.y.max(end.y);
            (requested_feet.x - edge_x).abs() <= monitor_edge_snap_distance
                && requested_feet.y >= top
                && requested_feet.y <= bottom
        })
        .collect();

    edge_candidates.sort_by(|left, right| {
        let left_x = match left.geometry {
            SurfaceGeometry::Segment { start, .. } => start.x,
            _ => f32::INFINITY,
        };
        let right_x = match right.geometry {
            SurfaceGeometry::Segment { start, .. } => start.x,
            _ => f32::INFINITY,
        };
        (requested_feet.x - left_x)
            .abs()
            .total_cmp(&(requested_feet.x - right_x).abs())
            .then_with(|| {
                let left_preference = u8::from(
                    preferred_monitor_owner.is_some()
                        && left.owner_entity_id != preferred_monitor_owner,
                );
                let right_preference = u8::from(
                    preferred_monitor_owner.is_some()
                        && right.owner_entity_id != preferred_monitor_owner,
                );
                left_preference.cmp(&right_preference)
            })
            .then_with(|| left.id.cmp(&right.id))
    });

    if let Some(surface) = edge_candidates.first().copied() {
        let edge_x = match surface.geometry {
            SurfaceGeometry::Segment { start, .. } => start.x,
            _ => requested_feet.x,
        };
        return DragReleaseDecision {
            target_kind: DragReleaseTargetKind::MonitorEdge,
            resolved_feet: Point2::new(edge_x, requested_feet.y),
            surface_id: Some(surface.id),
        };
    }

    let mut candidates: Vec<&SurfaceDescriptor> = surfaces
        .iter()
        .filter(|surface| {
            surface.orientation == Orientation::Horizontal
                && surface.normal.y < 0.0
                && surface.capabilities.contains(SurfaceCapabilities::LANDABLE)
                && surface.capabilities.contains(SurfaceCapabilities::WALKABLE)
        })
        .filter(|surface| {
            let Some((left, right, y)) = horizontal_bounds(surface) else {
                return false;
            };
            let usable_left = left + half_width;
            let usable_right = right - half_width;
            usable_left <= usable_right
                && requested_feet.x >= usable_left
                && requested_feet.x <= usable_right
                && y >= requested_feet.y
                && y - requested_feet.y <= HORIZONTAL_SURFACE_SNAP_DISTANCE
        })
        .collect();

    candidates.sort_by(|left, right| {
        let left_y = horizontal_bounds(left).map_or(f32::INFINITY, |(_, _, y)| y);
        let right_y = horizontal_bounds(right).map_or(f32::INFINITY, |(_, _, y)| y);
        (left_y - requested_feet.y)
            .total_cmp(&(right_y - requested_feet.y))
            .then_with(|| kind_rank(left.surface_kind).cmp(&kind_rank(right.surface_kind)))
    });

    let Some(surface) = candidates.first().copied() else {
        return DragReleaseDecision {
            target_kind: DragReleaseTargetKind::Airborne,
            resolved_feet: requested_feet,
            surface_id: None,
        };
    };
    let (_, _, y) = horizontal_bounds(surface).expect("candidate geometry already validated");

    DragReleaseDecision {
        target_kind: classify(surface.surface_kind),
        resolved_feet: Point2::new(requested_feet.x, y),
        surface_id: Some(surface.id),
    }
}

#[must_use]
pub fn surface_by_id(
    surfaces: &[SurfaceDescriptor],
    surface_id: SurfaceId,
) -> Option<&SurfaceDescriptor> {
    surfaces.iter().find(|surface| surface.id == surface_id)
}

fn horizontal_bounds(surface: &SurfaceDescriptor) -> Option<(f32, f32, f32)> {
    match surface.geometry {
        SurfaceGeometry::Segment { start, end } => {
            Some((start.x.min(end.x), start.x.max(end.x), start.y))
        }
        SurfaceGeometry::Rectangle { rect } => Some((rect.left(), rect.right(), rect.top())),
        SurfaceGeometry::Point { .. } => None,
    }
}

fn classify(kind: SurfaceKind) -> DragReleaseTargetKind {
    match kind {
        SurfaceKind::WindowTop => DragReleaseTargetKind::WindowTop,
        SurfaceKind::TaskbarTop | SurfaceKind::DockTop => DragReleaseTargetKind::TaskbarTop,
        SurfaceKind::DesktopFloor => DragReleaseTargetKind::DesktopFloor,
        SurfaceKind::MonitorEdge => DragReleaseTargetKind::MonitorEdge,
        _ => DragReleaseTargetKind::WindowTop,
    }
}

fn kind_rank(kind: SurfaceKind) -> u8 {
    match kind {
        // A monitor floor is authoritative when it shares the same Y as a
        // stale/overlapping WindowTop (common when the pointer is released
        // over another monitor). A genuinely higher WindowTop still wins by
        // the primary vertical-distance sort above.
        SurfaceKind::DesktopFloor => 0,
        SurfaceKind::TaskbarTop | SurfaceKind::DockTop => 1,
        SurfaceKind::WindowTop => 2,
        _ => 3,
    }
}
