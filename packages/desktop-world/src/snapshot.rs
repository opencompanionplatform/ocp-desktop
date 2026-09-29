use chrono::{DateTime, Utc};
use ocp_shared_types::{
    Bounds, CoordinateSpace, Cursor, Monitor, SurfaceDescriptor, Window, WindowId, Workspace,
    WorldEntityId, WorldId, WorldRevision,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesktopWorldCapabilities {
    pub windows: bool,
    pub monitors: bool,
    pub cursor: bool,
    pub taskbar_or_dock: bool,
    pub workspaces: bool,
    pub occlusion: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActiveApplication {
    pub application_id: String,
    pub application_kind: Option<String>,
    pub window_id: Option<WindowId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskbarDescriptor {
    pub entity_id: WorldEntityId,
    pub bounds: Bounds,
    pub auto_hidden: bool,
    pub platform_kind: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ObstacleDescriptor {
    pub entity_id: WorldEntityId,
    pub bounds: Bounds,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DesktopWorldSnapshot {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub observed_at: DateTime<Utc>,
    pub coordinate_space: CoordinateSpace,
    pub capabilities: DesktopWorldCapabilities,
    pub virtual_desktop_bounds: Bounds,
    pub monitors: Vec<Monitor>,
    pub workspaces: Vec<Workspace>,
    pub windows: Vec<Window>,
    pub cursor: Option<Cursor>,
    pub taskbar_or_dock: Option<TaskbarDescriptor>,
    pub surfaces: Vec<SurfaceDescriptor>,
    pub obstacles: Vec<ObstacleDescriptor>,
    pub active_window_id: Option<WindowId>,
    pub active_application: Option<ActiveApplication>,
}

impl DesktopWorldSnapshot {
    #[must_use]
    pub fn active_window(&self) -> Option<&Window> {
        let id = self.active_window_id?;
        self.windows.iter().find(|window| window.id == id)
    }

    #[must_use]
    pub fn window(&self, id: WindowId) -> Option<&Window> {
        self.windows.iter().find(|window| window.id == id)
    }

    #[must_use]
    pub fn surface(&self, id: ocp_shared_types::SurfaceId) -> Option<&SurfaceDescriptor> {
        self.surfaces.iter().find(|surface| surface.id == id)
    }
}
