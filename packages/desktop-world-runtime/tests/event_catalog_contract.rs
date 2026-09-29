use chrono::Utc;
use ocp_desktop_world::{
    DesktopObservationBatch, DesktopWorldCapabilities, DesktopWorldError, DesktopWorldProvider,
    MonitorObservation, ObservationSource, TaskbarObservation, WindowObservation,
};
use ocp_desktop_world_runtime::{
    event_catalog, validate_event_catalog, WindowEventPayload, WorldRuntime, WorldRuntimeConfig,
    WINDOW_MOVED, WORLD_EVENT_SCHEMA_VERSION,
};
use ocp_event_bus::InProcessBus;
use ocp_shared_types::{
    Bounds, CoordinateSpace, Monitor, MonitorId, Point2, Rect, Size2, Window, WindowId,
    WorldEntityId, WorldId, WorldRevision,
};
use std::collections::{HashSet, VecDeque};
use std::time::Duration;

struct QueueProvider {
    observations: VecDeque<Result<DesktopObservationBatch, DesktopWorldError>>,
}

impl DesktopWorldProvider for QueueProvider {
    fn provider_id(&self) -> &'static str {
        "test.event-catalog"
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
            cursor: false,
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
        cursor: None,
        taskbar: TaskbarObservation {
            taskbar_or_dock: None,
        },
        obstacles: vec![],
    }
}

#[test]
fn catalog_is_unique_valid_and_frozen_at_version_1_0() {
    validate_event_catalog().expect("valid catalog");

    let mut names = HashSet::new();
    for entry in event_catalog() {
        assert!(names.insert(entry.event_type));
        assert_eq!(entry.version, WORLD_EVENT_SCHEMA_VERSION);
        assert!(!entry.payload_schema.is_empty());
    }

    assert_eq!(event_catalog().len(), 22);
}

#[test]
fn moved_window_uses_typed_payload_without_generic_change_blob() {
    let window_id = WindowId::new();
    let bus = InProcessBus::new();
    let moved = bus.subscribe(WINDOW_MOVED);
    let provider = QueueProvider {
        observations: vec![
            Ok(observation(1, window_id, 100.0)),
            Ok(observation(2, window_id, 500.0)),
        ]
        .into(),
    };
    let mut runtime =
        WorldRuntime::new(WorldId::new(), provider, bus, WorldRuntimeConfig::default());

    runtime.tick().expect("initial tick");
    runtime.tick().expect("moved tick");

    let envelope = moved
        .recv_timeout(Duration::from_millis(50))
        .expect("window moved event");

    assert_eq!(envelope.version, WORLD_EVENT_SCHEMA_VERSION);
    assert!(envelope.data.get("change").is_none());

    let payload: WindowEventPayload =
        serde_json::from_value(envelope.data).expect("typed window payload");

    assert_eq!(payload.window_id, window_id);
    assert!(payload.window.is_some());
}

#[test]
fn typed_payloads_reject_unknown_fields() {
    let value = serde_json::json!({
        "worldId": WorldId::new(),
        "revision": WorldRevision::new(1),
        "windowId": WindowId::new(),
        "eventKind": "moved",
        "unexpected": true
    });

    assert!(serde_json::from_value::<WindowEventPayload>(value).is_err());
}
