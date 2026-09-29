//! Canonical Desktop World primitive descriptors.

use crate::{Bounds, MonitorId, Point2, Rect, WindowId, WorkspaceId, WorldEntityId};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoordinateSpace {
    DesktopGlobalPhysical,
    DesktopGlobalLogical,
    MonitorLocal,
    PresentationLocal,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Monitor {
    pub id: MonitorId,
    pub entity_id: WorldEntityId,
    pub name: String,
    pub bounds: Bounds,
    pub work_area: Bounds,
    pub scale_factor: f32,
    pub primary: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub name: String,
    pub active: bool,
    pub platform_kind: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VirtualDesktop {
    pub bounds: Bounds,
    pub active_workspace_id: Option<WorkspaceId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Desktop {
    pub coordinate_space: CoordinateSpace,
    pub virtual_desktop: VirtualDesktop,
    pub monitor_ids: Vec<MonitorId>,
    pub workspace_ids: Vec<WorkspaceId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cursor {
    pub position: Point2,
    pub visible: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Window {
    pub id: WindowId,
    pub entity_id: WorldEntityId,
    pub application_id: String,
    pub title_classification: Option<String>,
    pub bounds: Rect,
    pub client_bounds: Option<Rect>,
    pub frame_bounds: Option<Rect>,
    pub z_order: i32,
    pub active: bool,
    pub minimized: bool,
    pub visible: bool,
    pub occluded: bool,
    pub workspace_id: Option<WorkspaceId>,
}
