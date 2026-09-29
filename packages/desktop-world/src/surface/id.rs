use serde::{Deserialize, Serialize};
use std::fmt;

/// Stable, deterministic identifier for a derived Surface.
///
/// The identifier is a semantic key (`window:<id>:top`, `monitor:<id>:floor`)
/// rather than a random UUID, so unchanged owners preserve identity across polls.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SurfaceRegistryId(String);

impl SurfaceRegistryId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn monitor_floor(monitor_id: &str) -> Self {
        Self(format!("monitor:{monitor_id}:floor"))
    }

    #[must_use]
    pub fn window_top(window_id: &str) -> Self {
        Self(format!("window:{window_id}:top"))
    }

    #[must_use]
    pub fn taskbar_top(owner_id: &str) -> Self {
        Self(format!("taskbar:{owner_id}:top"))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for SurfaceRegistryId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}
