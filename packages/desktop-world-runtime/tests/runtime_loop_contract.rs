use chrono::Utc;
use ocp_desktop_world::{
    DesktopObservationBatch, DesktopWorldCapabilities, DesktopWorldError, DesktopWorldProvider,
    MonitorObservation, ObservationSource, TaskbarObservation, WindowObservation,
};
use ocp_desktop_world_runtime::{WorldRuntime, WorldRuntimeConfig};
use ocp_event_bus::InProcessBus;
use ocp_shared_types::{
    Bounds, CoordinateSpace, Cursor, Monitor, MonitorId, Point2, Rect, Size2, Window, WindowId,
    WorldEntityId, WorldId, WorldRevision,
};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

struct QueueProvider {
    observations: VecDeque<Result<DesktopObservationBatch, DesktopWorldError>>,
}

impl QueueProvider {
    fn new(observations: Vec<Result<DesktopObservationBatch, DesktopWorldError>>) -> Self {
        Self {
            observations: observations.into(),
        }
    }
}

impl DesktopWorldProvider for QueueProvider {
    fn provider_id(&self) -> &'static str {
        "test.queue-provider"
    }

    fn observe(&mut self) -> Result<DesktopObservationBatch, DesktopWorldError> {
        self.observations.pop_front().unwrap_or_else(|| {
            Err(DesktopWorldError::ProviderFailure {
                provider_id: self.provider_id().to_owned(),
                message: "fixture exhausted".to_owned(),
            })
        })
    }
}

fn observation(sequence: u64, window_id: WindowId, x: f32) -> DesktopObservationBatch {
    let monitor = Monitor {
        id: MonitorId::new(),
        entity_id: WorldEntityId::new(),
        name: "Primary".to_owned(),
        bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
        work_area: Bounds(Rect::new(0.0, 0.0, 1920.0, 1040.0)),
        scale_factor: 1.0,
        primary: true,
    };

    let window = Window {
        id: window_id,
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
            windows: vec![window],
            active_window_id: Some(window_id),
            active_application: None,
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

#[test]
fn first_tick_stores_snapshot_and_publishes_world_created() {
    let window_id = WindowId::new();
    let bus = InProcessBus::new();
    let created = bus.subscribe("ocp.world.created");
    let family = bus.subscribe("ocp.world.");
    let provider = QueueProvider::new(vec![Ok(observation(1, window_id, 100.0))]);
    let mut runtime =
        WorldRuntime::new(WorldId::new(), provider, bus, WorldRuntimeConfig::default());

    let tick = runtime.tick().expect("first world tick");

    assert_eq!(tick.snapshot.revision, WorldRevision::new(1));
    assert_eq!(tick.diff.previous_revision, WorldRevision::new(0));
    assert_eq!(
        created
            .recv_timeout(Duration::from_millis(50))
            .unwrap()
            .event_type,
        "ocp.world.created"
    );
    assert!(family.recv_timeout(Duration::from_millis(50)).is_ok());
}

#[test]
fn moved_window_publishes_aggregate_and_specific_events() {
    let window_id = WindowId::new();
    let bus = InProcessBus::new();
    let changed = bus.subscribe("ocp.world.changed");
    let moved = bus.subscribe("ocp.world.window-moved");
    let provider = QueueProvider::new(vec![
        Ok(observation(1, window_id, 100.0)),
        Ok(observation(2, window_id, 400.0)),
    ]);
    let mut runtime =
        WorldRuntime::new(WorldId::new(), provider, bus, WorldRuntimeConfig::default());

    runtime.tick().expect("initial tick");
    changed
        .recv_timeout(Duration::from_millis(50))
        .expect("initial aggregate change");
    runtime.tick().expect("moved tick");

    assert_eq!(
        changed
            .recv_timeout(Duration::from_millis(50))
            .unwrap()
            .event_type,
        "ocp.world.changed"
    );
    assert_eq!(
        moved
            .recv_timeout(Duration::from_millis(50))
            .unwrap()
            .event_type,
        "ocp.world.window-moved"
    );
}

#[test]
fn background_loop_stops_gracefully_and_keeps_latest_snapshot() {
    let window_id = WindowId::new();
    let provider = QueueProvider::new(vec![
        Ok(observation(1, window_id, 100.0)),
        Ok(observation(2, window_id, 200.0)),
    ]);
    let config = WorldRuntimeConfig {
        poll_interval: Duration::from_millis(5),
        max_consecutive_failures: 0,
        ..WorldRuntimeConfig::default()
    };
    let handle = WorldRuntime::new(WorldId::new(), provider, InProcessBus::new(), config).spawn();

    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        if handle.snapshot().expect("snapshot read").is_some() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "runtime did not publish a snapshot"
        );
        std::thread::sleep(Duration::from_millis(5));
    }

    let summary = handle.stop_and_wait().expect("graceful stop");
    assert!(summary.successful_ticks >= 1);
    assert!(summary.stopped_by_request);
}

#[test]
fn failure_limit_stops_background_loop() {
    let provider = QueueProvider::new(vec![
        Err(DesktopWorldError::ProviderFailure {
            provider_id: "fixture".to_owned(),
            message: "offline".to_owned(),
        }),
        Err(DesktopWorldError::ProviderFailure {
            provider_id: "fixture".to_owned(),
            message: "still offline".to_owned(),
        }),
    ]);
    let config = WorldRuntimeConfig {
        poll_interval: Duration::from_millis(1),
        max_consecutive_failures: 2,
        ..WorldRuntimeConfig::default()
    };
    let handle = WorldRuntime::new(WorldId::new(), provider, InProcessBus::new(), config).spawn();

    let error = handle.wait().expect_err("failure limit must stop the loop");
    assert!(error.to_string().contains("2 consecutive failures"));
}
