use ocp_shared_types::{MonitorId, WindowId, WorldEntityId};
use std::collections::HashMap;

/// Stable domain-ID registry for opaque native entity keys.
///
/// Native handles never cross this boundary. Providers convert a native key
/// such as `windows:hwnd:1234` into canonical IDs that remain stable while the
/// registry remains alive.
#[derive(Debug, Default)]
pub struct NativeEntityRegistry {
    entities: HashMap<String, WorldEntityId>,
    windows: HashMap<String, WindowId>,
    monitors: HashMap<String, MonitorId>,
}

impl NativeEntityRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn entity_id(&mut self, native_key: impl Into<String>) -> WorldEntityId {
        *self.entities.entry(native_key.into()).or_default()
    }

    pub fn window_id(&mut self, native_key: impl Into<String>) -> WindowId {
        *self.windows.entry(native_key.into()).or_default()
    }

    pub fn monitor_id(&mut self, native_key: impl Into<String>) -> MonitorId {
        *self.monitors.entry(native_key.into()).or_default()
    }

    #[must_use]
    pub fn entity_count(&self) -> usize {
        self.entities.len()
    }

    #[must_use]
    pub fn window_count(&self) -> usize {
        self.windows.len()
    }

    #[must_use]
    pub fn monitor_count(&self) -> usize {
        self.monitors.len()
    }
}
