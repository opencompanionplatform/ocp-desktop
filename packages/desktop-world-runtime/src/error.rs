use ocp_desktop_world::DesktopWorldError;
use ocp_event_bus::BusError;

#[derive(Debug)]
pub enum WorldRuntimeError {
    World(DesktopWorldError),
    Event(BusError),
    Serialization(serde_json::Error),
    StatePoisoned(&'static str),
    ThreadPanicked,
    FailureLimitReached {
        consecutive_failures: u32,
        last_error: String,
    },
}

impl core::fmt::Display for WorldRuntimeError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::World(error) => write!(formatter, "Desktop World update failed: {error}"),
            Self::Event(error) => write!(formatter, "Desktop World event publish failed: {error}"),
            Self::Serialization(error) => {
                write!(formatter, "Desktop World event serialization failed: {error}")
            }
            Self::StatePoisoned(name) => write!(formatter, "runtime state lock poisoned: {name}"),
            Self::ThreadPanicked => write!(formatter, "Desktop World runtime thread panicked"),
            Self::FailureLimitReached {
                consecutive_failures,
                last_error,
            } => write!(
                formatter,
                "Desktop World runtime stopped after {consecutive_failures} consecutive failures: {last_error}"
            ),
        }
    }
}

impl std::error::Error for WorldRuntimeError {}

impl From<DesktopWorldError> for WorldRuntimeError {
    fn from(value: DesktopWorldError) -> Self {
        Self::World(value)
    }
}

impl From<BusError> for WorldRuntimeError {
    fn from(value: BusError) -> Self {
        Self::Event(value)
    }
}

impl From<serde_json::Error> for WorldRuntimeError {
    fn from(value: serde_json::Error) -> Self {
        Self::Serialization(value)
    }
}
