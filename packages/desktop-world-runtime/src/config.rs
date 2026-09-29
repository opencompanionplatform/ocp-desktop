use std::time::Duration;

/// Runtime loop policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorldRuntimeConfig {
    /// Delay between completed observation attempts.
    pub poll_interval: Duration,
    /// Publish `ocp.world.updated` even when the diff is empty.
    pub publish_unchanged_updates: bool,
    /// Stop the background loop after this many consecutive failures.
    /// A value of zero means failures never stop the loop.
    pub max_consecutive_failures: u32,
    /// EVENT_API source field.
    pub event_source: String,
}

impl Default for WorldRuntimeConfig {
    fn default() -> Self {
        Self {
            poll_interval: Duration::from_millis(250),
            publish_unchanged_updates: false,
            max_consecutive_failures: 0,
            event_source: "desktop-world-runtime".to_owned(),
        }
    }
}
