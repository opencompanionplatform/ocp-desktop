//! Headless Desktop World runtime loop with a frozen typed event catalog.
//!
//! Dependency direction:
//!
//! ```text
//! DesktopWorldProvider
//!     -> DesktopWorldService
//!     -> immutable snapshot + diff
//!     -> typed InProcessBus events
//! ```
//!
//! The crate contains no operating-system API and no Godot dependency.

#![forbid(unsafe_code)]

mod config;
mod error;
mod events;
mod health;
mod runtime;

pub use config::WorldRuntimeConfig;
pub use error::WorldRuntimeError;
pub use events::{
    event_catalog, event_type_for_window_change, surface_descriptor_for_event,
    validate_event_catalog, window_descriptor_for_event, ActiveWindowChangedEventPayload,
    CapabilitiesChangedEventPayload, CursorChangedEventPayload, EventStability,
    MonitorLayoutChangedEventPayload, SurfaceEventKind, SurfaceEventPayload,
    TaskbarChangedEventPayload, WindowEventKind, WindowEventPayload, WorldEventCatalogEntry,
    WorldLifecycleEventPayload, WorldObservationFailurePayload, ACTIVE_WINDOW_CHANGED,
    CAPABILITIES_CHANGED, CURSOR_CHANGED, MONITOR_LAYOUT_CHANGED, SURFACE_CREATED, SURFACE_REMOVED,
    SURFACE_UPDATED, TASKBAR_CHANGED, WINDOW_ACTIVATED, WINDOW_ADDED, WINDOW_DEACTIVATED,
    WINDOW_METADATA_CHANGED, WINDOW_MINIMIZED, WINDOW_MOVED, WINDOW_REMOVED, WINDOW_RESIZED,
    WINDOW_RESTORED, WINDOW_VISIBILITY_CHANGED, WORLD_CHANGED, WORLD_CREATED, WORLD_EVENT_CATALOG,
    WORLD_EVENT_SCHEMA_VERSION, WORLD_OBSERVATION_FAILED, WORLD_UPDATED,
};
pub use health::{RuntimeHealth, RuntimeHealthSnapshot, WorldRuntimeSummary};
pub use runtime::{WorldRuntime, WorldRuntimeHandle, WorldRuntimeTick};
