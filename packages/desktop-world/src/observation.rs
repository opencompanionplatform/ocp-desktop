use chrono::{DateTime, Utc};
use ocp_shared_types::{
    Bounds, CoordinateSpace, Cursor, Monitor, Window, WindowId, Workspace, WorldRevision,
};
use serde::{Deserialize, Serialize};

use crate::{ActiveApplication, DesktopWorldCapabilities, ObstacleDescriptor, TaskbarDescriptor};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ObservationSource {
    pub provider_id: String,
    pub platform: String,
    pub provider_version: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MonitorObservation {
    pub monitors: Vec<Monitor>,
    pub virtual_desktop_bounds: Bounds,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowObservation {
    pub windows: Vec<Window>,
    pub active_window_id: Option<WindowId>,
    pub active_application: Option<ActiveApplication>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskbarObservation {
    pub taskbar_or_dock: Option<TaskbarDescriptor>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DesktopObservationBatch {
    pub source: ObservationSource,
    pub sequence: WorldRevision,
    pub observed_at: DateTime<Utc>,
    pub coordinate_space: CoordinateSpace,
    pub capabilities: DesktopWorldCapabilities,
    pub monitors: MonitorObservation,
    pub workspaces: Vec<Workspace>,
    pub windows: WindowObservation,
    pub cursor: Option<Cursor>,
    pub taskbar: TaskbarObservation,
    pub obstacles: Vec<ObstacleDescriptor>,
}
