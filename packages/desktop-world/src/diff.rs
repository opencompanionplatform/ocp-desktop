use ocp_shared_types::{SurfaceId, WindowId, WorldRevision};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowChangeKind {
    Added,
    Removed,
    Moved,
    Resized,
    Activated,
    Deactivated,
    Minimized,
    Restored,
    VisibilityChanged,
    MetadataChanged,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "change_type")]
pub enum DesktopWorldChange {
    Window {
        window_id: WindowId,
        kind: WindowChangeKind,
    },
    SurfaceCreated {
        surface_id: SurfaceId,
    },
    SurfaceUpdated {
        surface_id: SurfaceId,
    },
    SurfaceRemoved {
        surface_id: SurfaceId,
    },
    ActiveWindowChanged {
        previous: Option<WindowId>,
        current: Option<WindowId>,
    },
    MonitorLayoutChanged,
    CursorChanged,
    TaskbarChanged,
    CapabilitiesChanged,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DesktopWorldDiff {
    pub previous_revision: WorldRevision,
    pub revision: WorldRevision,
    pub changes: Vec<DesktopWorldChange>,
}
