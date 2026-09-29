use ocp_desktop_world::{
    DesktopWorldCapabilities, DesktopWorldDiff, DesktopWorldSnapshot, TaskbarDescriptor,
    WindowChangeKind,
};
use ocp_shared_types::{
    Bounds, Cursor, Monitor, SurfaceDescriptor, SurfaceId, Window, WindowId, WorldId, WorldRevision,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Schema version frozen by Phase 6.5.2B.
pub const WORLD_EVENT_SCHEMA_VERSION: &str = "1.0";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventStability {
    Stable,
    Operational,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorldEventCatalogEntry {
    pub event_type: &'static str,
    pub version: &'static str,
    pub payload_schema: &'static str,
    pub stability: EventStability,
}

pub const WORLD_CREATED: &str = "ocp.world.created";
pub const WORLD_UPDATED: &str = "ocp.world.updated";
pub const WORLD_CHANGED: &str = "ocp.world.changed";
pub const WORLD_OBSERVATION_FAILED: &str = "ocp.world.observation-failed";

pub const WINDOW_ADDED: &str = "ocp.world.window-added";
pub const WINDOW_REMOVED: &str = "ocp.world.window-removed";
pub const WINDOW_MOVED: &str = "ocp.world.window-moved";
pub const WINDOW_RESIZED: &str = "ocp.world.window-resized";
pub const WINDOW_ACTIVATED: &str = "ocp.world.window-activated";
pub const WINDOW_DEACTIVATED: &str = "ocp.world.window-deactivated";
pub const WINDOW_MINIMIZED: &str = "ocp.world.window-minimized";
pub const WINDOW_RESTORED: &str = "ocp.world.window-restored";
pub const WINDOW_VISIBILITY_CHANGED: &str = "ocp.world.window-visibility-changed";
pub const WINDOW_METADATA_CHANGED: &str = "ocp.world.window-metadata-changed";
pub const ACTIVE_WINDOW_CHANGED: &str = "ocp.world.active-window-changed";

pub const SURFACE_CREATED: &str = "ocp.surface.created";
pub const SURFACE_UPDATED: &str = "ocp.surface.updated";
pub const SURFACE_REMOVED: &str = "ocp.surface.removed";

pub const MONITOR_LAYOUT_CHANGED: &str = "ocp.world.monitor-layout-changed";
pub const CURSOR_CHANGED: &str = "ocp.world.cursor-changed";
pub const TASKBAR_CHANGED: &str = "ocp.world.taskbar-changed";
pub const CAPABILITIES_CHANGED: &str = "ocp.world.capabilities-changed";

pub const WORLD_EVENT_CATALOG: &[WorldEventCatalogEntry] = &[
    stable(WORLD_CREATED, "WorldLifecycleEventPayload"),
    stable(WORLD_UPDATED, "WorldLifecycleEventPayload"),
    stable(WORLD_CHANGED, "WorldLifecycleEventPayload"),
    operational(WORLD_OBSERVATION_FAILED, "WorldObservationFailurePayload"),
    stable(WINDOW_ADDED, "WindowEventPayload"),
    stable(WINDOW_REMOVED, "WindowEventPayload"),
    stable(WINDOW_MOVED, "WindowEventPayload"),
    stable(WINDOW_RESIZED, "WindowEventPayload"),
    stable(WINDOW_ACTIVATED, "WindowEventPayload"),
    stable(WINDOW_DEACTIVATED, "WindowEventPayload"),
    stable(WINDOW_MINIMIZED, "WindowEventPayload"),
    stable(WINDOW_RESTORED, "WindowEventPayload"),
    stable(WINDOW_VISIBILITY_CHANGED, "WindowEventPayload"),
    stable(WINDOW_METADATA_CHANGED, "WindowEventPayload"),
    stable(ACTIVE_WINDOW_CHANGED, "ActiveWindowChangedEventPayload"),
    stable(SURFACE_CREATED, "SurfaceEventPayload"),
    stable(SURFACE_UPDATED, "SurfaceEventPayload"),
    stable(SURFACE_REMOVED, "SurfaceEventPayload"),
    stable(MONITOR_LAYOUT_CHANGED, "MonitorLayoutChangedEventPayload"),
    stable(CURSOR_CHANGED, "CursorChangedEventPayload"),
    stable(TASKBAR_CHANGED, "TaskbarChangedEventPayload"),
    stable(CAPABILITIES_CHANGED, "CapabilitiesChangedEventPayload"),
];

const fn stable(event_type: &'static str, payload_schema: &'static str) -> WorldEventCatalogEntry {
    WorldEventCatalogEntry {
        event_type,
        version: WORLD_EVENT_SCHEMA_VERSION,
        payload_schema,
        stability: EventStability::Stable,
    }
}

const fn operational(
    event_type: &'static str,
    payload_schema: &'static str,
) -> WorldEventCatalogEntry {
    WorldEventCatalogEntry {
        event_type,
        version: WORLD_EVENT_SCHEMA_VERSION,
        payload_schema,
        stability: EventStability::Operational,
    }
}

#[must_use]
pub fn event_catalog() -> &'static [WorldEventCatalogEntry] {
    WORLD_EVENT_CATALOG
}

pub fn validate_event_catalog() -> Result<(), String> {
    let mut names = HashSet::new();

    for entry in WORLD_EVENT_CATALOG {
        ocp_shared_types::validate_type_name(entry.event_type)
            .map_err(|error| error.to_string())?;

        if entry.version != WORLD_EVENT_SCHEMA_VERSION {
            return Err(format!(
                "{} has unsupported schema version {}",
                entry.event_type, entry.version
            ));
        }

        if entry.payload_schema.is_empty() {
            return Err(format!("{} has an empty payload schema", entry.event_type));
        }

        if !names.insert(entry.event_type) {
            return Err(format!("duplicate event type: {}", entry.event_type));
        }
    }

    Ok(())
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorldLifecycleEventPayload {
    pub world_id: WorldId,
    pub previous_revision: WorldRevision,
    pub revision: WorldRevision,
    pub change_count: usize,
}

impl WorldLifecycleEventPayload {
    #[must_use]
    pub fn from_diff(world_id: WorldId, diff: &DesktopWorldDiff) -> Self {
        Self {
            world_id,
            previous_revision: diff.previous_revision,
            revision: diff.revision,
            change_count: diff.changes.len(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WindowEventKind {
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

impl From<WindowChangeKind> for WindowEventKind {
    fn from(value: WindowChangeKind) -> Self {
        match value {
            WindowChangeKind::Added => Self::Added,
            WindowChangeKind::Removed => Self::Removed,
            WindowChangeKind::Moved => Self::Moved,
            WindowChangeKind::Resized => Self::Resized,
            WindowChangeKind::Activated => Self::Activated,
            WindowChangeKind::Deactivated => Self::Deactivated,
            WindowChangeKind::Minimized => Self::Minimized,
            WindowChangeKind::Restored => Self::Restored,
            WindowChangeKind::VisibilityChanged => Self::VisibilityChanged,
            WindowChangeKind::MetadataChanged => Self::MetadataChanged,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WindowEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub window_id: WindowId,
    pub event_kind: WindowEventKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<Window>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceEventKind {
    Created,
    Updated,
    Removed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SurfaceEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub surface_id: SurfaceId,
    pub event_kind: SurfaceEventKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<SurfaceDescriptor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActiveWindowChangedEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub previous_window_id: Option<WindowId>,
    pub current_window_id: Option<WindowId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MonitorLayoutChangedEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub virtual_desktop_bounds: Bounds,
    pub monitors: Vec<Monitor>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CursorChangedEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub cursor: Option<Cursor>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TaskbarChangedEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub taskbar_or_dock: Option<TaskbarDescriptor>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CapabilitiesChangedEventPayload {
    pub world_id: WorldId,
    pub revision: WorldRevision,
    pub capabilities: DesktopWorldCapabilities,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorldObservationFailurePayload {
    pub provider_id: String,
    pub consecutive_failures: u32,
    pub message: String,
}

#[must_use]
pub const fn event_type_for_window_change(kind: WindowChangeKind) -> &'static str {
    match kind {
        WindowChangeKind::Added => WINDOW_ADDED,
        WindowChangeKind::Removed => WINDOW_REMOVED,
        WindowChangeKind::Moved => WINDOW_MOVED,
        WindowChangeKind::Resized => WINDOW_RESIZED,
        WindowChangeKind::Activated => WINDOW_ACTIVATED,
        WindowChangeKind::Deactivated => WINDOW_DEACTIVATED,
        WindowChangeKind::Minimized => WINDOW_MINIMIZED,
        WindowChangeKind::Restored => WINDOW_RESTORED,
        WindowChangeKind::VisibilityChanged => WINDOW_VISIBILITY_CHANGED,
        WindowChangeKind::MetadataChanged => WINDOW_METADATA_CHANGED,
    }
}

#[must_use]
pub fn window_descriptor_for_event(
    current: &DesktopWorldSnapshot,
    previous: Option<&DesktopWorldSnapshot>,
    window_id: WindowId,
    kind: WindowChangeKind,
) -> Option<Window> {
    if kind == WindowChangeKind::Removed {
        return previous
            .and_then(|snapshot| snapshot.window(window_id))
            .cloned();
    }

    current.window(window_id).cloned().or_else(|| {
        previous
            .and_then(|snapshot| snapshot.window(window_id))
            .cloned()
    })
}

#[must_use]
pub fn surface_descriptor_for_event(
    current: &DesktopWorldSnapshot,
    previous: Option<&DesktopWorldSnapshot>,
    surface_id: SurfaceId,
    kind: SurfaceEventKind,
) -> Option<SurfaceDescriptor> {
    if kind == SurfaceEventKind::Removed {
        return previous
            .and_then(|snapshot| snapshot.surface(surface_id))
            .cloned();
    }

    current.surface(surface_id).cloned().or_else(|| {
        previous
            .and_then(|snapshot| snapshot.surface(surface_id))
            .cloned()
    })
}
