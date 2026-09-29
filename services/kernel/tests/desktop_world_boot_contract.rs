use chrono::Utc;
use ocp_desktop_world::{
    DesktopObservationBatch, DesktopWorldCapabilities, DesktopWorldError, DesktopWorldProvider,
    MonitorObservation, ObservationSource, TaskbarObservation, WindowObservation,
};
use ocp_event_bus::InProcessBus;
use ocp_kernel::desktop_world_boot::{
    KernelDesktopWorldConfig, KernelDesktopWorldHost, KernelDesktopWorldState,
    DESKTOP_WORLD_STARTED, DESKTOP_WORLD_STOPPED,
};
use ocp_shared_types::{
    Bounds, CoordinateSpace, Monitor, MonitorId, Rect, WorldEntityId, WorldId, WorldRevision,
};
use std::time::{Duration, Instant};

struct StaticProvider {
    sequence: WorldRevision,
}

impl DesktopWorldProvider for StaticProvider {
    fn provider_id(&self) -> &'static str {
        "test.kernel-world"
    }

    fn observe(&mut self) -> Result<DesktopObservationBatch, DesktopWorldError> {
        let sequence = self.sequence;
        self.sequence = self.sequence.next();

        Ok(DesktopObservationBatch {
            source: ObservationSource {
                provider_id: self.provider_id().to_owned(),
                platform: "test".to_owned(),
                provider_version: "1.0".to_owned(),
            },
            sequence,
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
                monitors: vec![Monitor {
                    id: MonitorId::new(),
                    entity_id: WorldEntityId::new(),
                    name: "Test monitor".to_owned(),
                    bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
                    work_area: Bounds(Rect::new(0.0, 0.0, 1920.0, 1040.0)),
                    scale_factor: 1.0,
                    primary: true,
                }],
                virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1920.0, 1080.0)),
            },
            workspaces: vec![],
            windows: WindowObservation {
                windows: vec![],
                active_window_id: None,
                active_application: None,
            },
            cursor: None,
            taskbar: TaskbarObservation {
                taskbar_or_dock: None,
            },
            obstacles: vec![],
        })
    }
}

fn wait_for_snapshot(host: &KernelDesktopWorldHost) {
    let deadline = Instant::now() + Duration::from_secs(1);

    loop {
        if host.snapshot().expect("snapshot access").is_some() {
            return;
        }

        assert!(
            Instant::now() < deadline,
            "Desktop World did not create a snapshot"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn kernel_owns_boot_snapshot_and_graceful_shutdown() {
    let bus = InProcessBus::new();
    let started = bus.subscribe(DESKTOP_WORLD_STARTED);
    let stopped = bus.subscribe(DESKTOP_WORLD_STOPPED);

    let mut host = KernelDesktopWorldHost::start(
        WorldId::new(),
        StaticProvider {
            sequence: WorldRevision::INITIAL,
        },
        bus,
        KernelDesktopWorldConfig {
            poll_interval: Duration::from_millis(5),
            max_consecutive_failures: 3,
            ..KernelDesktopWorldConfig::default()
        },
        vec![],
    )
    .expect("kernel world boot");

    assert_eq!(host.state(), KernelDesktopWorldState::Running);
    started
        .recv_timeout(Duration::from_millis(50))
        .expect("started event");

    wait_for_snapshot(&host);

    let summary = host.shutdown().expect("shutdown").expect("runtime summary");

    assert_eq!(host.state(), KernelDesktopWorldState::Stopped);
    assert!(summary.successful_ticks > 0);
    stopped
        .recv_timeout(Duration::from_millis(50))
        .expect("stopped event");
}

#[test]
fn disabled_config_starts_no_runtime() {
    let bus = InProcessBus::new();

    let host = KernelDesktopWorldHost::start(
        WorldId::new(),
        StaticProvider {
            sequence: WorldRevision::INITIAL,
        },
        bus,
        KernelDesktopWorldConfig {
            enabled: false,
            ..KernelDesktopWorldConfig::default()
        },
        vec![],
    )
    .expect("disabled host");

    assert_eq!(host.state(), KernelDesktopWorldState::Disabled);
    assert!(host.snapshot().expect("snapshot").is_none());
}

#[test]
fn host_exposes_runtime_health() {
    let bus = InProcessBus::new();
    let mut host = KernelDesktopWorldHost::start(
        WorldId::new(),
        StaticProvider {
            sequence: WorldRevision::INITIAL,
        },
        bus,
        KernelDesktopWorldConfig {
            poll_interval: Duration::from_millis(5),
            ..KernelDesktopWorldConfig::default()
        },
        vec![],
    )
    .expect("kernel world boot");

    wait_for_snapshot(&host);

    let health = host.health().expect("health").expect("running health");

    assert!(health.successful_ticks > 0);
    host.shutdown().expect("shutdown");
}
