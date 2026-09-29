use ocp_desktop_sensors::{
    CursorSample, DesktopSensorError, DesktopSensorSuite, DesktopSurfaceProvider, MonitorSample,
    NativeEntityRegistry, SensorAvailability, SensorKind, SensorSource, SensorSuiteSample,
    SensorWorldProvider, TaskbarSample, TaskbarSurfaceProvider, WindowListSample,
    WindowSurfaceProvider,
};
use ocp_desktop_world::{
    DesktopWorldChange, DesktopWorldProvider, DesktopWorldService, WindowChangeKind,
};
use ocp_shared_types::{
    Bounds, CoordinateSpace, Cursor, Monitor, Point2, Rect, Size2, SurfaceCapabilities,
    SurfaceKind, Window, WindowId, WorldEntityId, WorldId, WorldRevision,
};
use std::sync::Mutex;

struct FixtureSuite {
    registry: Mutex<NativeEntityRegistry>,
    window_x: Mutex<f32>,
    mixed_height_monitors: bool,
    taskbar: bool,
}

impl FixtureSuite {
    fn new() -> Self {
        Self {
            registry: Mutex::new(NativeEntityRegistry::new()),
            window_x: Mutex::new(100.0),
            mixed_height_monitors: false,
            taskbar: false,
        }
    }

    fn with_mixed_height_monitors() -> Self {
        Self {
            registry: Mutex::new(NativeEntityRegistry::new()),
            window_x: Mutex::new(100.0),
            mixed_height_monitors: true,
            taskbar: false,
        }
    }

    fn with_taskbar() -> Self {
        Self {
            registry: Mutex::new(NativeEntityRegistry::new()),
            window_x: Mutex::new(100.0),
            mixed_height_monitors: false,
            taskbar: true,
        }
    }

    fn move_window_to(&self, x: f32) {
        *self.window_x.lock().expect("window x lock") = x;
    }
}

impl DesktopSensorSuite for FixtureSuite {
    fn source(&self) -> SensorSource {
        SensorSource {
            provider_id: "fixture.windows".to_owned(),
            platform: "windows".to_owned(),
            provider_version: "1.0".to_owned(),
        }
    }

    fn sample(
        &self,
        sequence: WorldRevision,
        observed_at_ms: u64,
    ) -> Result<SensorSuiteSample, DesktopSensorError> {
        let mut registry = self.registry.lock().expect("registry lock");

        let monitor_id = registry.monitor_id("monitor:primary");
        let monitor_entity = registry.entity_id("monitor:primary");
        let left_monitor_id = registry.monitor_id("monitor:left");
        let left_monitor_entity = registry.entity_id("monitor:left");
        let right_monitor_id = registry.monitor_id("monitor:right");
        let right_monitor_entity = registry.entity_id("monitor:right");
        let window_id = registry.window_id("window:browser:1");
        let taskbar_entity = registry.entity_id("taskbar:primary");
        let window_entity = registry.entity_id("window:browser:1");
        let x = *self.window_x.lock().expect("window x lock");

        let monitor = Monitor {
            id: monitor_id,
            entity_id: monitor_entity,
            name: "Primary".to_owned(),
            bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
            work_area: Bounds(Rect::new(0.0, 0.0, 1920.0, 1040.0)),
            scale_factor: 1.0,
            primary: true,
        };
        let left_monitor = Monitor {
            id: left_monitor_id,
            entity_id: left_monitor_entity,
            name: "Left".to_owned(),
            bounds: Bounds(Rect::new(-1280.0, 0.0, 1280.0, 1024.0)),
            work_area: Bounds(Rect::new(-1280.0, 0.0, 1280.0, 984.0)),
            scale_factor: 1.0,
            primary: false,
        };
        let right_monitor = Monitor {
            id: right_monitor_id,
            entity_id: right_monitor_entity,
            name: "Right".to_owned(),
            bounds: Bounds(Rect::new(1920.0, 0.0, 2560.0, 1440.0)),
            work_area: Bounds(Rect::new(1920.0, 0.0, 2560.0, 1400.0)),
            scale_factor: 1.0,
            primary: false,
        };

        let window = Window {
            id: window_id,
            entity_id: window_entity,
            application_id: "browser.exe".to_owned(),
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
        };

        Ok(SensorSuiteSample {
            source: self.source(),
            sequence,
            observed_at_ms,
            coordinate_space: CoordinateSpace::DesktopGlobalPhysical,
            foreground_window: None,
            mouse_idle: None,
            cursor: Some(CursorSample {
                cursor: Cursor {
                    position: Point2::new(500.0, 400.0),
                    visible: true,
                },
            }),
            monitors: Some(if self.mixed_height_monitors {
                MonitorSample {
                    monitors: vec![left_monitor, monitor, right_monitor],
                    virtual_desktop_bounds: Bounds(Rect::new(-1280.0, 0.0, 5760.0, 1440.0)),
                }
            } else {
                MonitorSample {
                    monitors: vec![monitor],
                    virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
                }
            }),
            windows: Some(WindowListSample {
                windows: vec![window],
                active_window_id: Some(window_id),
                active_application_kind: Some("browser".to_owned()),
            }),
            taskbar_or_dock: self.taskbar.then_some(TaskbarSample {
                entity_id: taskbar_entity,
                bounds: Bounds(Rect::new(0.0, 912.0, 1440.0, 48.0)),
                auto_hidden: false,
                platform_kind: "windows_taskbar".to_owned(),
            }),
            availability: vec![
                (SensorKind::Cursor, SensorAvailability::Available),
                (SensorKind::Monitors, SensorAvailability::Available),
                (SensorKind::Windows, SensorAvailability::Available),
                (
                    SensorKind::TaskbarOrDock,
                    if self.taskbar {
                        SensorAvailability::Available
                    } else {
                        SensorAvailability::Unsupported
                    },
                ),
            ],
        })
    }
}

#[test]
fn stable_native_keys_produce_stable_domain_ids() {
    let mut registry = NativeEntityRegistry::new();

    let first = registry.window_id("hwnd:100");
    let second = registry.window_id("hwnd:100");
    let different = registry.window_id("hwnd:200");

    assert_eq!(first, second);
    assert_ne!(first, different);
    assert_eq!(registry.window_count(), 2);
}

#[test]
fn sensor_provider_builds_world_and_surfaces() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());

    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));
    world.register_surface_provider(Box::new(DesktopSurfaceProvider::new()));

    let observation = provider.observe().expect("observation");
    let diff = world.apply_observation(observation).expect("world update");

    let snapshot = world.snapshot().expect("snapshot");

    assert_eq!(snapshot.windows.len(), 1);
    assert_eq!(snapshot.monitors.len(), 1);
    assert_eq!(snapshot.surfaces.len(), 8);
    assert_eq!(
        snapshot
            .active_application
            .as_ref()
            .and_then(|value| value.application_kind.as_deref()),
        Some("browser")
    );
    assert!(diff.changes.iter().any(|change| matches!(
        change,
        DesktopWorldChange::Window {
            kind: WindowChangeKind::Added,
            ..
        }
    )));
}

#[test]
fn moved_window_keeps_surface_identity_and_updates_geometry() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());

    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));

    let first = provider.observe().expect("first observation");
    world.apply_observation(first).expect("first world");

    let first_snapshot = world.snapshot().expect("first snapshot");
    let first_top = first_snapshot
        .surfaces
        .iter()
        .find(|surface| surface.surface_kind == SurfaceKind::WindowTop)
        .expect("first top surface")
        .clone();

    provider.sensor_suite().move_window_to(400.0);

    let second = provider.observe().expect("second observation");
    let diff = world.apply_observation(second).expect("second world");

    let second_top = world
        .snapshot()
        .expect("second snapshot")
        .surfaces
        .iter()
        .find(|surface| surface.surface_kind == SurfaceKind::WindowTop)
        .expect("second top surface");

    assert_eq!(first_top.id, second_top.id);
    assert_ne!(first_top.geometry, second_top.geometry);
    assert!(second_top
        .capabilities
        .contains(SurfaceCapabilities::WALKABLE));
    assert!(diff
        .changes
        .iter()
        .any(|change| matches!(change, DesktopWorldChange::SurfaceUpdated { .. })));
}

#[test]
fn spanning_overlay_window_is_not_a_character_surface() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));
    world.register_surface_provider(Box::new(DesktopSurfaceProvider::new()));

    let mut observation = provider.observe().expect("observation");
    let virtual_bounds = observation.monitors.virtual_desktop_bounds;
    observation.windows.windows.push(Window {
        id: WindowId::new(),
        entity_id: WorldEntityId::new(),
        application_id: "godot-overlay".to_owned(),
        title_classification: Some("Godot".to_owned()),
        bounds: virtual_bounds.0,
        client_bounds: None,
        frame_bounds: None,
        z_order: -1,
        active: true,
        minimized: false,
        visible: true,
        occluded: false,
        workspace_id: None,
    });
    world.apply_observation(observation).expect("world update");
    let snapshot = world.snapshot().expect("snapshot");

    assert_eq!(
        snapshot
            .surfaces
            .iter()
            .filter(|surface| surface.surface_kind == SurfaceKind::WindowTop)
            .count(),
        1
    );
}

#[test]
fn native_companion_auxiliary_window_is_not_a_character_surface() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));

    let mut observation = provider.observe().expect("observation");
    let auxiliary_entity = WorldEntityId::new();
    observation.windows.windows.push(Window {
        id: WindowId::new(),
        entity_id: auxiliary_entity,
        application_id: "OCPNativeSpike:pid:4242".to_owned(),
        title_classification: Some("OCPNativeSpike".to_owned()),
        bounds: Rect::new(400.0, 365.0, 340.0, 288.0),
        client_bounds: None,
        frame_bounds: None,
        z_order: -1,
        active: true,
        minimized: false,
        visible: true,
        occluded: false,
        workspace_id: None,
    });
    world.apply_observation(observation).expect("world update");
    let snapshot = world.snapshot().expect("snapshot");

    assert!(snapshot
        .surfaces
        .iter()
        .all(|surface| surface.owner_entity_id != Some(auxiliary_entity)));
}

#[test]
fn inactive_window_top_is_fall_landable_but_not_interactive() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));

    let mut observation = provider.observe().expect("observation");
    observation.windows.windows.push(Window {
        id: WindowId::new(),
        entity_id: WorldEntityId::new(),
        application_id: "background.exe".to_owned(),
        title_classification: Some("background".to_owned()),
        bounds: Rect::new(200.0, 300.0, 600.0, 500.0),
        client_bounds: None,
        frame_bounds: None,
        z_order: 1,
        active: false,
        minimized: false,
        visible: true,
        occluded: false,
        workspace_id: None,
    });
    world.apply_observation(observation).expect("world update");
    let snapshot = world.snapshot().expect("snapshot");

    let tops: Vec<_> = snapshot
        .surfaces
        .iter()
        .filter(|surface| surface.surface_kind == SurfaceKind::WindowTop)
        .collect();
    assert_eq!(tops.len(), 2);

    let inactive = tops
        .iter()
        .find(|surface| {
            matches!(
                surface.geometry,
                ocp_shared_types::surface::SurfaceGeometry::Segment { start, .. }
                    if start.x == 200.0
            )
        })
        .expect("inactive window top");
    assert!(inactive.capabilities.contains(SurfaceCapabilities::DYNAMIC));
    assert!(inactive
        .capabilities
        .contains(SurfaceCapabilities::LANDABLE));
    assert!(!inactive
        .capabilities
        .contains(SurfaceCapabilities::WALKABLE));
    assert!(!inactive
        .capabilities
        .contains(SurfaceCapabilities::SITTABLE));
}

#[test]
fn active_window_top_keeps_identity_when_focus_changes() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));

    let first = provider.observe().expect("active observation");
    world.apply_observation(first).expect("active world");
    let active_top = world
        .snapshot()
        .expect("active snapshot")
        .surfaces
        .iter()
        .find(|surface| surface.surface_kind == SurfaceKind::WindowTop)
        .expect("active window top")
        .clone();
    assert!(active_top
        .capabilities
        .contains(SurfaceCapabilities::SITTABLE));

    let mut inactive = provider.observe().expect("inactive observation");
    inactive.windows.windows[0].active = false;
    inactive.windows.active_window_id = None;
    inactive.windows.active_application = None;
    world
        .apply_observation(inactive)
        .expect("inactive world update");

    let inactive_top = world
        .snapshot()
        .expect("inactive snapshot")
        .surfaces
        .iter()
        .find(|surface| surface.surface_kind == SurfaceKind::WindowTop)
        .expect("inactive window top")
        .clone();
    assert_eq!(inactive_top.id, active_top.id);
    assert!(inactive_top
        .capabilities
        .contains(SurfaceCapabilities::DYNAMIC));
    assert!(inactive_top
        .capabilities
        .contains(SurfaceCapabilities::LANDABLE));
    assert!(!inactive_top
        .capabilities
        .contains(SurfaceCapabilities::SITTABLE));
}

#[test]
fn active_window_top_above_work_area_is_not_a_surface() {
    let suite = FixtureSuite::new();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(WindowSurfaceProvider::new()));

    let mut observation = provider.observe().expect("observation");
    observation.windows.windows[0].bounds = Rect::new(200.0, -134.0, 600.0, 500.0);
    world.apply_observation(observation).expect("world update");
    let snapshot = world.snapshot().expect("snapshot");

    assert!(snapshot
        .surfaces
        .iter()
        .all(|surface| surface.surface_kind != SurfaceKind::WindowTop));
}

#[test]
fn desktop_provider_creates_independent_floors_for_mixed_height_monitors() {
    let suite = FixtureSuite::with_mixed_height_monitors();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());

    world.register_surface_provider(Box::new(DesktopSurfaceProvider::new()));

    let observation = provider.observe().expect("observation");
    world.apply_observation(observation).expect("world update");

    let snapshot = world.snapshot().expect("snapshot");
    let mut floors: Vec<_> = snapshot
        .surfaces
        .iter()
        .filter(|surface| surface.surface_kind == SurfaceKind::DesktopFloor)
        .collect();

    floors.sort_by(|left, right| {
        let left_x = match left.geometry {
            ocp_shared_types::surface::SurfaceGeometry::Segment { start, .. } => start.x,
            _ => f32::MAX,
        };
        let right_x = match right.geometry {
            ocp_shared_types::surface::SurfaceGeometry::Segment { start, .. } => start.x,
            _ => f32::MAX,
        };
        left_x.total_cmp(&right_x)
    });

    assert_eq!(floors.len(), 3);

    let segments: Vec<_> = floors
        .iter()
        .map(|surface| match surface.geometry {
            ocp_shared_types::surface::SurfaceGeometry::Segment { start, end } => {
                (start.x, end.x, start.y)
            }
            _ => panic!("desktop floor must be a segment"),
        })
        .collect();

    assert_eq!(
        segments,
        vec![
            (-1280.0, 0.0, 984.0),
            (0.0, 1920.0, 1040.0),
            (1920.0, 4480.0, 1400.0),
        ]
    );
}

#[test]
fn desktop_provider_creates_stable_shimeji_edges_for_three_monitors() {
    let suite = FixtureSuite::with_mixed_height_monitors();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(DesktopSurfaceProvider::new()));

    let first = provider.observe().expect("first observation");
    world.apply_observation(first).expect("first world");
    let first_snapshot = world.snapshot().expect("first snapshot");
    let edges: Vec<_> = first_snapshot
        .surfaces
        .iter()
        .filter(|surface| surface.surface_kind == SurfaceKind::MonitorEdge)
        .collect();

    assert_eq!(edges.len(), 9);
    for edge in &edges {
        assert!(edge.tags.iter().any(|tag| tag == "monitor-edge"));
        if edge.orientation == ocp_shared_types::Orientation::Vertical {
            assert!(edge.capabilities.contains(SurfaceCapabilities::CLIMBABLE));
            assert!(edge.capabilities.contains(SurfaceCapabilities::HANGABLE));
        } else {
            assert!(edge.tags.iter().any(|tag| tag == "monitor-top"));
            assert!(edge.capabilities.contains(SurfaceCapabilities::HANGABLE));
            assert!(!edge.capabilities.contains(SurfaceCapabilities::WALKABLE));
        }
    }

    let first_ids: Vec<_> = edges.iter().map(|surface| surface.id).collect();
    let second = provider.observe().expect("second observation");
    world.apply_observation(second).expect("second world");
    let second_ids: Vec<_> = world
        .snapshot()
        .expect("second snapshot")
        .surfaces
        .iter()
        .filter(|surface| surface.surface_kind == SurfaceKind::MonitorEdge)
        .map(|surface| surface.id)
        .collect();
    assert_eq!(first_ids, second_ids);
}

#[test]
fn monitor_floor_identity_is_stable_across_observations() {
    let suite = FixtureSuite::with_mixed_height_monitors();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());

    world.register_surface_provider(Box::new(DesktopSurfaceProvider::new()));

    let first = provider.observe().expect("first observation");
    world.apply_observation(first).expect("first world");
    let first_ids: Vec<_> = world
        .snapshot()
        .expect("first snapshot")
        .surfaces
        .iter()
        .filter(|surface| surface.surface_kind == SurfaceKind::DesktopFloor)
        .map(|surface| surface.id)
        .collect();

    let second = provider.observe().expect("second observation");
    world.apply_observation(second).expect("second world");
    let second_ids: Vec<_> = world
        .snapshot()
        .expect("second snapshot")
        .surfaces
        .iter()
        .filter(|surface| surface.surface_kind == SurfaceKind::DesktopFloor)
        .map(|surface| surface.id)
        .collect();

    assert_eq!(first_ids, second_ids);
}

#[test]
fn monitor_floor_uses_visible_taskbar_top_when_work_area_disagrees() {
    let suite = FixtureSuite::with_taskbar();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());
    world.register_surface_provider(Box::new(DesktopSurfaceProvider::new()));

    let observation = provider.observe().expect("observation");
    world.apply_observation(observation).expect("world update");
    let snapshot = world.snapshot().expect("snapshot");
    let floor = snapshot
        .surfaces
        .iter()
        .find(|surface| surface.surface_kind == SurfaceKind::DesktopFloor)
        .expect("desktop floor");

    assert_eq!(
        floor.geometry,
        ocp_shared_types::surface::SurfaceGeometry::Segment {
            start: Point2::new(0.0, 912.0),
            end: Point2::new(1920.0, 912.0),
        }
    );
}

#[test]
fn taskbar_provider_creates_stable_walkable_surface() {
    let suite = FixtureSuite::with_taskbar();
    let mut provider = SensorWorldProvider::new("windows.fixture", suite);
    let mut world = DesktopWorldService::new(WorldId::new());

    world.register_surface_provider(Box::new(TaskbarSurfaceProvider::new()));

    let observation = provider.observe().expect("observation");
    world.apply_observation(observation).expect("world update");
    let snapshot = world.snapshot().expect("snapshot");
    let taskbar = snapshot
        .surfaces
        .iter()
        .find(|surface| surface.surface_kind == SurfaceKind::TaskbarTop)
        .expect("taskbar top surface");

    assert_eq!(
        taskbar.geometry,
        ocp_shared_types::surface::SurfaceGeometry::Segment {
            start: Point2::new(0.0, 912.0),
            end: Point2::new(1440.0, 912.0),
        }
    );
    assert!(taskbar.capabilities.contains(SurfaceCapabilities::WALKABLE));
    assert!(taskbar.capabilities.contains(SurfaceCapabilities::LANDABLE));
}
