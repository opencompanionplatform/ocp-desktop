use ocp_shared_types::{
    Bounds, CoordinateSpace, Cursor, Monitor, Window, WindowId, WorldEntityId, WorldRevision,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SensorKind {
    ForegroundWindow,
    MouseIdle,
    Cursor,
    Monitors,
    Windows,
    TaskbarOrDock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SensorAvailability {
    Available,
    Unavailable,
    PermissionDenied,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SensorSource {
    pub provider_id: String,
    pub platform: String,
    pub provider_version: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForegroundWindowSample {
    /// Sensitive runtime-only data. Redact or classify before exposing it to
    /// AI, plugins or external telemetry.
    pub raw_title: String,
    pub process_name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MouseIdleSample {
    pub idle_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CursorSample {
    pub cursor: Cursor,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MonitorSample {
    pub monitors: Vec<Monitor>,
    pub virtual_desktop_bounds: Bounds,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowListSample {
    pub windows: Vec<Window>,
    pub active_window_id: Option<WindowId>,
    pub active_application_kind: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskbarSample {
    pub entity_id: WorldEntityId,
    pub bounds: Bounds,
    pub auto_hidden: bool,
    pub platform_kind: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SensorSuiteSample {
    pub source: SensorSource,
    pub sequence: WorldRevision,
    pub observed_at_ms: u64,
    pub coordinate_space: CoordinateSpace,
    pub foreground_window: Option<ForegroundWindowSample>,
    pub mouse_idle: Option<MouseIdleSample>,
    pub cursor: Option<CursorSample>,
    pub monitors: Option<MonitorSample>,
    pub windows: Option<WindowListSample>,
    pub taskbar_or_dock: Option<TaskbarSample>,
    pub availability: Vec<(SensorKind, SensorAvailability)>,
}

impl SensorSuiteSample {
    #[must_use]
    pub fn availability(&self, kind: SensorKind) -> Option<SensorAvailability> {
        self.availability
            .iter()
            .find_map(|(candidate, availability)| (*candidate == kind).then_some(*availability))
    }
}
