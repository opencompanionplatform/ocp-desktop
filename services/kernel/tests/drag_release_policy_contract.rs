use ocp_kernel::drag_release_policy::{
    decide_drag_release, decide_drag_release_with_preferred_monitor, DragReleaseTargetKind,
};
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Orientation, Point2, SurfaceCapabilities, SurfaceDescriptor, SurfaceId, SurfaceKind,
    SurfaceStability, Vector2, WorldEntityId,
};

fn surface(kind: SurfaceKind, left: f32, right: f32, y: f32) -> SurfaceDescriptor {
    SurfaceDescriptor {
        id: SurfaceId::new(),
        provider_id: "test.drag-release".to_owned(),
        owner_entity_id: None,
        surface_kind: kind,
        geometry: SurfaceGeometry::Segment {
            start: Point2::new(left, y),
            end: Point2::new(right, y),
        },
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::WALKABLE),
        stability: SurfaceStability::Static,
        motion_binding: None,
        attachment_points: Vec::new(),
        tags: Vec::new(),
        revision: 1,
    }
}

fn monitor_edge(x: f32, normal_x: f32) -> SurfaceDescriptor {
    SurfaceDescriptor {
        id: SurfaceId::new(),
        provider_id: "test.drag-release.monitor".to_owned(),
        owner_entity_id: None,
        surface_kind: SurfaceKind::MonitorEdge,
        geometry: SurfaceGeometry::Segment {
            start: Point2::new(x, 0.0),
            end: Point2::new(x, 1_024.0),
        },
        orientation: Orientation::Vertical,
        normal: Vector2::new(normal_x, 0.0),
        capabilities: SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
        stability: SurfaceStability::Static,
        motion_binding: None,
        attachment_points: Vec::new(),
        tags: Vec::new(),
        revision: 1,
    }
}

#[test]
fn no_surface_below_produces_airborne_release() {
    let decision = decide_drag_release(Point2::new(500.0, 300.0), &[], 64.0);
    assert_eq!(decision.target_kind, DragReleaseTargetKind::Airborne);
    assert_eq!(decision.resolved_feet, Point2::new(500.0, 300.0));
    assert!(decision.surface_id.is_none());
}

#[test]
fn release_above_window_selects_window_top_before_floor() {
    let window = surface(SurfaceKind::WindowTop, 300.0, 900.0, 500.0);
    let window_id = window.id;
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let decision = decide_drag_release(Point2::new(600.0, 460.0), &[floor, window], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::WindowTop);
    assert_eq!(decision.surface_id, Some(window_id));
    assert_eq!(decision.resolved_feet, Point2::new(600.0, 500.0));
}

#[test]
fn equal_height_window_top_does_not_capture_release_on_adjacent_monitor_floor() {
    let left_floor = surface(SurfaceKind::DesktopFloor, -1_920.0, 0.0, 1_032.0);
    let left_floor_id = left_floor.id;
    let stale_window = surface(SurfaceKind::WindowTop, -1_600.0, -200.0, 1_032.0);
    let decision = decide_drag_release(
        Point2::new(-273.5, 980.0),
        &[stale_window, left_floor],
        64.0,
    );

    assert_eq!(decision.target_kind, DragReleaseTargetKind::DesktopFloor);
    assert_eq!(decision.surface_id, Some(left_floor_id));
    assert_eq!(decision.resolved_feet, Point2::new(-273.5, 1_032.0));
}

#[test]
fn release_above_taskbar_selects_taskbar_top() {
    let taskbar = surface(SurfaceKind::TaskbarTop, 0.0, 1_536.0, 980.0);
    let taskbar_id = taskbar.id;
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let decision = decide_drag_release(Point2::new(700.0, 900.0), &[floor, taskbar], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::TaskbarTop);
    assert_eq!(decision.surface_id, Some(taskbar_id));
    assert_eq!(decision.resolved_feet.y, 980.0);
}

#[test]
fn window_outside_body_footprint_does_not_capture_release() {
    let window = surface(SurfaceKind::WindowTop, 300.0, 600.0, 500.0);
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let floor_id = floor.id;
    let decision = decide_drag_release(Point2::new(250.0, 960.0), &[window, floor], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::DesktopFloor);
    assert_eq!(decision.surface_id, Some(floor_id));
}

#[test]
fn non_walkable_surface_is_not_a_grounded_release_target() {
    let mut window = surface(SurfaceKind::WindowTop, 300.0, 900.0, 500.0);
    window.capabilities = SurfaceCapabilities::LANDABLE;
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let floor_id = floor.id;
    let decision = decide_drag_release(Point2::new(600.0, 960.0), &[window, floor], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::DesktopFloor);
    assert_eq!(decision.surface_id, Some(floor_id));
}

#[test]
fn release_near_left_monitor_edge_snaps_to_hanging_edge() {
    let edge = monitor_edge(0.0, 1.0);
    let edge_id = edge.id;
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let decision = decide_drag_release(Point2::new(72.0, 480.0), &[floor, edge], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::MonitorEdge);
    assert_eq!(decision.surface_id, Some(edge_id));
    assert_eq!(decision.resolved_feet, Point2::new(0.0, 480.0));
}

#[test]
fn release_near_right_monitor_edge_snaps_without_wrapping() {
    let edge = monitor_edge(1_536.0, -1.0);
    let edge_id = edge.id;
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let decision = decide_drag_release(Point2::new(1_470.0, 480.0), &[floor, edge], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::MonitorEdge);
    assert_eq!(decision.surface_id, Some(edge_id));
    assert_eq!(decision.resolved_feet, Point2::new(1_536.0, 480.0));
}

#[test]
fn shared_monitor_seam_prefers_the_drag_origin_monitor() {
    let origin_monitor = WorldEntityId::new();
    let adjacent_monitor = WorldEntityId::new();
    let mut origin_edge = monitor_edge(1_536.0, -1.0);
    origin_edge.owner_entity_id = Some(origin_monitor);
    let origin_edge_id = origin_edge.id;
    let mut adjacent_edge = monitor_edge(1_536.0, 1.0);
    adjacent_edge.owner_entity_id = Some(adjacent_monitor);

    let decision = decide_drag_release_with_preferred_monitor(
        Point2::new(1_536.0, 480.0),
        &[adjacent_edge, origin_edge],
        64.0,
        Some(origin_monitor),
    );

    assert_eq!(decision.target_kind, DragReleaseTargetKind::MonitorEdge);
    assert_eq!(decision.surface_id, Some(origin_edge_id));
}

#[test]
fn release_with_sprite_body_within_eighty_pixels_of_edge_snaps() {
    let edge = monitor_edge(1_536.0, -1.0);
    let decision = decide_drag_release(Point2::new(1_393.0, 480.0), &[edge], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::MonitorEdge);
    assert_eq!(decision.resolved_feet.x, 1_536.0);
}

#[test]
fn release_far_from_monitor_edge_keeps_normal_floor_policy() {
    let edge = monitor_edge(0.0, 1.0);
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let decision = decide_drag_release(Point2::new(240.0, 960.0), &[floor, edge], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::DesktopFloor);
}

#[test]
fn release_far_above_floor_remains_airborne_until_physics_lands() {
    let floor = surface(SurfaceKind::DesktopFloor, 0.0, 1_536.0, 1_024.0);
    let decision = decide_drag_release(Point2::new(700.0, 480.0), &[floor], 64.0);

    assert_eq!(decision.target_kind, DragReleaseTargetKind::Airborne);
    assert_eq!(decision.resolved_feet, Point2::new(700.0, 480.0));
    assert!(decision.surface_id.is_none());
}
