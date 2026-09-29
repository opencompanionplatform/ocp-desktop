use ocp_desktop_world::{DesktopWorldProvider, DesktopWorldSnapshot, SurfaceProvider};
use ocp_desktop_world_runtime::{
    RuntimeHealthSnapshot, WorldRuntime, WorldRuntimeConfig, WorldRuntimeError, WorldRuntimeHandle,
    WorldRuntimeSummary,
};
use ocp_event_bus::{BusError, InProcessBus};
use ocp_shared_types::{Envelope, WorldId};
use serde_json::json;
use std::fmt;
use std::time::Duration;

pub const DESKTOP_WORLD_STARTED: &str = "ocp.runtime.desktop-world-started";
pub const DESKTOP_WORLD_STOPPED: &str = "ocp.runtime.desktop-world-stopped";
pub const DESKTOP_WORLD_DEGRADED: &str = "ocp.runtime.desktop-world-degraded";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KernelDesktopWorldState {
    Disabled,
    Starting,
    Running,
    Degraded,
    Stopping,
    Stopped,
}

impl KernelDesktopWorldState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Degraded => "degraded",
            Self::Stopping => "stopping",
            Self::Stopped => "stopped",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelDesktopWorldConfig {
    pub enabled: bool,
    pub poll_interval: Duration,
    pub publish_unchanged_updates: bool,
    pub max_consecutive_failures: u32,
    pub event_source: String,
}

impl Default for KernelDesktopWorldConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            poll_interval: Duration::from_millis(250),
            publish_unchanged_updates: false,
            max_consecutive_failures: 5,
            event_source: "ocp-kernel-desktop-world".to_owned(),
        }
    }
}

impl KernelDesktopWorldConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let defaults = Self::default();

        Self {
            enabled: env_bool("OCP_DESKTOP_WORLD_ENABLED", defaults.enabled),
            poll_interval: Duration::from_millis(env_u64(
                "OCP_DESKTOP_WORLD_POLL_MS",
                u64::try_from(defaults.poll_interval.as_millis()).unwrap_or(250),
            )),
            publish_unchanged_updates: env_bool(
                "OCP_DESKTOP_WORLD_PUBLISH_UNCHANGED",
                defaults.publish_unchanged_updates,
            ),
            max_consecutive_failures: env_u32(
                "OCP_DESKTOP_WORLD_MAX_FAILURES",
                defaults.max_consecutive_failures,
            ),
            event_source: std::env::var("OCP_DESKTOP_WORLD_EVENT_SOURCE")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(defaults.event_source),
        }
    }

    #[must_use]
    pub fn runtime_config(&self) -> WorldRuntimeConfig {
        WorldRuntimeConfig {
            poll_interval: self.poll_interval,
            publish_unchanged_updates: self.publish_unchanged_updates,
            max_consecutive_failures: self.max_consecutive_failures,
            event_source: self.event_source.clone(),
        }
    }
}

#[derive(Debug)]
pub enum KernelDesktopWorldError {
    Disabled,
    Runtime(WorldRuntimeError),
    Event(BusError),
    Serialization(serde_json::Error),
}

impl fmt::Display for KernelDesktopWorldError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Disabled => {
                write!(formatter, "Desktop World is disabled")
            }
            Self::Runtime(error) => {
                write!(formatter, "Desktop World runtime: {error}")
            }
            Self::Event(error) => {
                write!(formatter, "Desktop World event: {error}")
            }
            Self::Serialization(error) => {
                write!(formatter, "Desktop World event serialization: {error}")
            }
        }
    }
}

impl std::error::Error for KernelDesktopWorldError {}

impl From<WorldRuntimeError> for KernelDesktopWorldError {
    fn from(error: WorldRuntimeError) -> Self {
        Self::Runtime(error)
    }
}

impl From<BusError> for KernelDesktopWorldError {
    fn from(error: BusError) -> Self {
        Self::Event(error)
    }
}

impl From<serde_json::Error> for KernelDesktopWorldError {
    fn from(error: serde_json::Error) -> Self {
        Self::Serialization(error)
    }
}

/// Kernel-owned handle for exactly one Desktop World runtime.
pub struct KernelDesktopWorldHost {
    world_id: WorldId,
    state: KernelDesktopWorldState,
    bus: InProcessBus,
    handle: Option<WorldRuntimeHandle>,
}

impl KernelDesktopWorldHost {
    #[must_use]
    pub fn disabled(bus: InProcessBus) -> Self {
        Self {
            world_id: WorldId::new(),
            state: KernelDesktopWorldState::Disabled,
            bus,
            handle: None,
        }
    }

    pub fn start<P>(
        world_id: WorldId,
        provider: P,
        bus: InProcessBus,
        config: KernelDesktopWorldConfig,
        surface_providers: Vec<Box<dyn SurfaceProvider>>,
    ) -> Result<Self, KernelDesktopWorldError>
    where
        P: DesktopWorldProvider + 'static,
    {
        if !config.enabled {
            return Ok(Self::disabled(bus));
        }

        let runtime_config = config.runtime_config();
        let mut runtime = WorldRuntime::new(world_id, provider, bus.clone(), runtime_config);

        for surface_provider in surface_providers {
            runtime.register_surface_provider(surface_provider);
        }

        let handle = runtime.spawn();
        let host = Self {
            world_id,
            state: KernelDesktopWorldState::Running,
            bus,
            handle: Some(handle),
        };

        host.publish_lifecycle(
            DESKTOP_WORLD_STARTED,
            json!({
                "worldId": host.world_id,
                "state": host.state.as_str(),
                "pollIntervalMs":
                    config.poll_interval.as_millis(),
                "maxConsecutiveFailures":
                    config.max_consecutive_failures,
            }),
        )?;

        Ok(host)
    }

    #[must_use]
    pub const fn world_id(&self) -> WorldId {
        self.world_id
    }

    #[must_use]
    pub const fn state(&self) -> KernelDesktopWorldState {
        self.state
    }

    #[must_use]
    pub fn bus(&self) -> InProcessBus {
        self.bus.clone()
    }

    #[must_use]
    pub fn snapshot_store(
        &self,
    ) -> std::sync::Arc<std::sync::RwLock<Option<DesktopWorldSnapshot>>> {
        self.handle
            .as_ref()
            .map(WorldRuntimeHandle::snapshot_store)
            .unwrap_or_else(|| std::sync::Arc::new(std::sync::RwLock::new(None)))
    }

    pub fn health(&mut self) -> Result<Option<RuntimeHealthSnapshot>, KernelDesktopWorldError> {
        let Some(handle) = self.handle.as_ref() else {
            return Ok(None);
        };

        let health = handle.health()?;
        if health.failed_ticks > 0 {
            self.state = KernelDesktopWorldState::Degraded;
        }

        Ok(Some(health))
    }

    pub fn snapshot(&self) -> Result<Option<DesktopWorldSnapshot>, KernelDesktopWorldError> {
        match self.handle.as_ref() {
            Some(handle) => Ok(handle.snapshot()?),
            None => Ok(None),
        }
    }

    pub fn shutdown(&mut self) -> Result<Option<WorldRuntimeSummary>, KernelDesktopWorldError> {
        let Some(handle) = self.handle.take() else {
            if self.state != KernelDesktopWorldState::Disabled {
                self.state = KernelDesktopWorldState::Stopped;
            }
            return Ok(None);
        };

        self.state = KernelDesktopWorldState::Stopping;
        let summary = handle.stop_and_wait()?;
        self.state = KernelDesktopWorldState::Stopped;

        self.publish_lifecycle(
            DESKTOP_WORLD_STOPPED,
            json!({
                "worldId": self.world_id,
                "state": self.state.as_str(),
                "completedTicks": summary.completed_ticks,
                "successfulTicks": summary.successful_ticks,
                "failedTicks": summary.failed_ticks,
                "finalRevision": summary.final_revision,
                "stoppedByRequest": summary.stopped_by_request,
            }),
        )?;

        Ok(Some(summary))
    }

    pub fn publish_degraded(
        &mut self,
        message: impl Into<String>,
    ) -> Result<(), KernelDesktopWorldError> {
        self.state = KernelDesktopWorldState::Degraded;
        self.publish_lifecycle(
            DESKTOP_WORLD_DEGRADED,
            json!({
                "worldId": self.world_id,
                "state": self.state.as_str(),
                "message": message.into(),
            }),
        )
    }

    fn publish_lifecycle(
        &self,
        event_type: &'static str,
        data: serde_json::Value,
    ) -> Result<(), KernelDesktopWorldError> {
        let envelope = Envelope::new(event_type, "ocp-kernel", data)
            .map_err(|error| KernelDesktopWorldError::Event(BusError::Invalid(error)))?;

        self.bus.publish(envelope)?;
        Ok(())
    }
}

impl Drop for KernelDesktopWorldHost {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            handle.request_stop();
            let _ = handle.wait();
        }
    }
}

#[cfg(windows)]
pub fn boot_platform(
    bus: InProcessBus,
    config: KernelDesktopWorldConfig,
) -> Result<KernelDesktopWorldHost, KernelDesktopWorldError> {
    use ocp_desktop_sensors::{
        DesktopSurfaceProvider, SensorWorldProvider, TaskbarSurfaceProvider, WindowSurfaceProvider,
    };
    use ocp_desktop_sensors_windows::WindowsDesktopSensors;

    let sensors = WindowsDesktopSensors::new();
    let provider = SensorWorldProvider::new("ocp.kernel.desktop-world.windows", sensors);

    KernelDesktopWorldHost::start(
        WorldId::new(),
        provider,
        bus,
        config,
        vec![
            Box::new(WindowSurfaceProvider::new()),
            Box::new(DesktopSurfaceProvider::new()),
            Box::new(TaskbarSurfaceProvider::new()),
        ],
    )
}

#[cfg(not(windows))]
pub fn boot_platform(
    bus: InProcessBus,
    config: KernelDesktopWorldConfig,
) -> Result<KernelDesktopWorldHost, KernelDesktopWorldError> {
    let _ = config;
    Ok(KernelDesktopWorldHost::disabled(bus))
}

fn env_bool(name: &str, fallback: bool) -> bool {
    std::env::var(name)
        .ok()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(fallback)
}

fn env_u64(name: &str, fallback: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(fallback)
}

fn env_u32(name: &str, fallback: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(fallback)
}

/// Replay the current Kernel-owned lifecycle state to a newly subscribed
/// Runtime. Lifecycle events may have been published before the presentation
/// channel existed, so reconnect must receive an explicit current-state fact.
pub fn publish_lifecycle_replay(
    world_id: WorldId,
    state: KernelDesktopWorldState,
    bus: &InProcessBus,
) -> Result<(), KernelDesktopWorldError> {
    let event_type = match state {
        KernelDesktopWorldState::Running => DESKTOP_WORLD_STARTED,
        KernelDesktopWorldState::Degraded => DESKTOP_WORLD_DEGRADED,
        KernelDesktopWorldState::Stopping | KernelDesktopWorldState::Stopped => {
            DESKTOP_WORLD_STOPPED
        }
        KernelDesktopWorldState::Disabled | KernelDesktopWorldState::Starting => return Ok(()),
    };

    let envelope = Envelope::new(
        event_type,
        "ocp-kernel",
        json!({
            "worldId": world_id,
            "state": state.as_str(),
            "replay": true,
        }),
    )
    .map_err(|error| KernelDesktopWorldError::Event(BusError::Invalid(error)))?;

    bus.publish(envelope)?;
    Ok(())
}

pub fn publish_snapshot_replay_from_store(
    snapshot_store: &std::sync::Arc<std::sync::RwLock<Option<DesktopWorldSnapshot>>>,
    bus: &InProcessBus,
) -> Result<(), KernelDesktopWorldError> {
    use ocp_desktop_world_runtime::{
        CursorChangedEventPayload, MonitorLayoutChangedEventPayload, SurfaceEventKind,
        SurfaceEventPayload, TaskbarChangedEventPayload, WindowEventKind, WindowEventPayload,
        CURSOR_CHANGED, MONITOR_LAYOUT_CHANGED, SURFACE_CREATED, TASKBAR_CHANGED, WINDOW_ADDED,
    };
    let snapshot = snapshot_store
        .read()
        .map_err(|_| {
            KernelDesktopWorldError::Runtime(WorldRuntimeError::StatePoisoned(
                "kernel snapshot replay",
            ))
        })?
        .clone();
    let Some(snapshot) = snapshot else {
        return Ok(());
    };
    let publish = |event_type: &'static str,
                   data: serde_json::Value|
     -> Result<(), KernelDesktopWorldError> {
        let envelope = Envelope::new(event_type, "ocp-kernel", data)
            .map_err(|error| KernelDesktopWorldError::Event(BusError::Invalid(error)))?;
        bus.publish(envelope)?;
        Ok(())
    };
    publish(
        MONITOR_LAYOUT_CHANGED,
        serde_json::to_value(MonitorLayoutChangedEventPayload {
            world_id: snapshot.world_id,
            revision: snapshot.revision,
            virtual_desktop_bounds: snapshot.virtual_desktop_bounds,
            monitors: snapshot.monitors.clone(),
        })?,
    )?;
    for window in &snapshot.windows {
        publish(
            WINDOW_ADDED,
            serde_json::to_value(WindowEventPayload {
                world_id: snapshot.world_id,
                revision: snapshot.revision,
                window_id: window.id,
                event_kind: WindowEventKind::Added,
                window: Some(window.clone()),
            })?,
        )?;
    }
    for surface in &snapshot.surfaces {
        publish(
            SURFACE_CREATED,
            serde_json::to_value(SurfaceEventPayload {
                world_id: snapshot.world_id,
                revision: snapshot.revision,
                surface_id: surface.id,
                event_kind: SurfaceEventKind::Created,
                surface: Some(surface.clone()),
            })?,
        )?;
    }
    publish(
        CURSOR_CHANGED,
        serde_json::to_value(CursorChangedEventPayload {
            world_id: snapshot.world_id,
            revision: snapshot.revision,
            cursor: snapshot.cursor.clone(),
        })?,
    )?;
    publish(
        TASKBAR_CHANGED,
        serde_json::to_value(TaskbarChangedEventPayload {
            world_id: snapshot.world_id,
            revision: snapshot.revision,
            taskbar_or_dock: snapshot.taskbar_or_dock.clone(),
        })?,
    )?;
    Ok(())
}
