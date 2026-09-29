use chrono::Utc;
use ocp_desktop_world::{
    DesktopObservationBatch, DesktopWorldCapabilities, DesktopWorldChange, DesktopWorldError,
    DesktopWorldService, MonitorObservation, ObservationSource, SurfaceProvider, SurfaceQuery,
    TaskbarObservation, WindowObservation, WindowQuery,
};
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Bounds, CoordinateSpace, Cursor, Monitor, MonitorId, Point2, Rect, Size2, SurfaceCapabilities,
    SurfaceDescriptor, SurfaceId, SurfaceKind, SurfaceStability, Vector2, Window, WindowId,
    WorldEntityId, WorldId, WorldRevision,
};

struct WindowTopSurfaceProvider;

impl SurfaceProvider for WindowTopSurfaceProvider {
    fn provider_id(&self) -> &'static str {
        "test.window-top"
    }

    fn collect_surfaces(
        &self,
        world: &ocp_desktop_world::DesktopWorldSnapshot,
    ) -> Result<Vec<SurfaceDescriptor>, ocp_desktop_world::DesktopWorldError> {
        Ok(world
            .windows
            .iter()
            .map(|window| SurfaceDescriptor {
                id: SurfaceId::from_uuid(*window.id.as_uuid()),
                provider_id: self.provider_id().to_owned(),
                owner_entity_id: Some(window.entity_id),
                surface_kind: SurfaceKind::WindowTop,
                geometry: SurfaceGeometry::Segment {
                    start: Point2::new(window.bounds.left(), window.bounds.top()),
                    end: Point2::new(window.bounds.right(), window.bounds.top()),
                },
                orientation: ocp_shared_types::Orientation::Horizontal,
                normal: Vector2::new(0.0, -1.0),
                capabilities: SurfaceCapabilities::WALKABLE
                    .union(SurfaceCapabilities::LANDABLE)
                    .union(SurfaceCapabilities::SITTABLE),
                stability: SurfaceStability::Dynamic,
                motion_binding: None,
                attachment_points: vec![],
                tags: vec!["window".to_owned()],
                revision: world.revision.value(),
            })
            .collect())
    }
}

fn observation(sequence: u64, window: Window) -> DesktopObservationBatch {
    let monitor = Monitor {
        id: MonitorId::new(),
        entity_id: WorldEntityId::new(),
        name: "Primary".to_owned(),
        bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
        work_area: Bounds(Rect::new(0.0, 0.0, 1920.0, 1040.0)),
        scale_factor: 1.0,
        primary: true,
    };

    DesktopObservationBatch {
        source: ObservationSource {
            provider_id: "fixture.windows".to_owned(),
            platform: "windows".to_owned(),
            provider_version: "1.0".to_owned(),
        },
        sequence: WorldRevision::new(sequence),
        observed_at: Utc::now(),
        coordinate_space: CoordinateSpace::DesktopGlobalPhysical,
        capabilities: DesktopWorldCapabilities {
            windows: true,
            monitors: true,
            cursor: true,
            taskbar_or_dock: false,
            workspaces: false,
            occlusion: false,
        },
        monitors: MonitorObservation {
            monitors: vec![monitor],
            virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
        },
        workspaces: vec![],
        windows: WindowObservation {
            active_window_id: Some(window.id),
            active_application: None,
            windows: vec![window],
        },
        cursor: Some(Cursor {
            position: Point2::new(500.0, 400.0),
            visible: true,
        }),
        taskbar: TaskbarObservation {
            taskbar_or_dock: None,
        },
        obstacles: vec![],
    }
}

fn test_window(id: WindowId, x: f32) -> Window {
    Window {
        id,
        entity_id: WorldEntityId::new(),
        application_id: "browser".to_owned(),
        title_classification: Some("browser".to_owned()),
        bounds: Rect {
            origin: Point2::new(x, 100.0),
            size: Size2::new(800.0, 600.0),
        },
        client_bounds: None,
        frame_bounds: None,
        z_order: 0,
        active: true,
        minimized: false,
        visible: true,
        occluded: false,
        workspace_id: None,
    }
}

#[test]
fn service_builds_one_immutable_world_snapshot() {
    let window_id = WindowId::new();
    let mut service = DesktopWorldService::new(WorldId::new());

    service.register_surface_provider(Box::new(WindowTopSurfaceProvider));

    let diff = service
        .apply_observation(observation(1, test_window(window_id, 100.0)))
        .expect("apply initial observation");

    let snapshot = service.snapshot().expect("snapshot");

    assert_eq!(snapshot.revision, WorldRevision::new(1));
    assert_eq!(snapshot.windows.len(), 1);
    assert_eq!(snapshot.surfaces.len(), 1);
    assert_eq!(snapshot.active_window().unwrap().id, window_id);
    assert_eq!(diff.previous_revision, WorldRevision::new(0));
}

#[test]
fn stale_observation_is_rejected() {
    let window_id = WindowId::new();
    let mut service = DesktopWorldService::new(WorldId::new());

    service
        .apply_observation(observation(2, test_window(window_id, 100.0)))
        .expect("first observation");

    let error = service
        .apply_observation(observation(1, test_window(window_id, 100.0)))
        .expect_err("stale observation must fail");

    assert!(matches!(error, DesktopWorldError::StaleObservation { .. }));
}

#[test]
fn moved_window_generates_diff_and_surface_update() {
    let window_id = WindowId::new();
    let mut service = DesktopWorldService::new(WorldId::new());

    service.register_surface_provider(Box::new(WindowTopSurfaceProvider));

    service
        .apply_observation(observation(1, test_window(window_id, 100.0)))
        .expect("initial observation");

    let diff = service
        .apply_observation(observation(2, test_window(window_id, 400.0)))
        .expect("moved observation");

    assert!(diff.changes.iter().any(|change| matches!(
        change,
        DesktopWorldChange::Window {
            kind: ocp_desktop_world::WindowChangeKind::Moved,
            ..
        }
    )));

    assert!(diff
        .changes
        .iter()
        .any(|change| matches!(change, DesktopWorldChange::SurfaceUpdated { .. })));
}

#[test]
fn queries_use_world_model_not_provider() {
    let window_id = WindowId::new();
    let mut service = DesktopWorldService::new(WorldId::new());

    service.register_surface_provider(Box::new(WindowTopSurfaceProvider));

    service
        .apply_observation(observation(1, test_window(window_id, 100.0)))
        .expect("observation");

    let world = service.snapshot().expect("snapshot");

    let windows = WindowQuery {
        active_only: true,
        visible_only: true,
        include_minimized: false,
        application_id: Some("browser".to_owned()),
    }
    .execute(world);

    assert_eq!(windows.len(), 1);

    let surfaces = SurfaceQuery {
        required_capabilities: SurfaceCapabilities::SITTABLE,
        kinds: vec![SurfaceKind::WindowTop],
        near: Some((Point2::new(500.0, 100.0), 500.0)),
    }
    .execute(world);

    assert_eq!(surfaces.len(), 1);
}
