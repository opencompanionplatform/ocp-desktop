use ocp_shared_types::WorldRevision;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopWorldError {
    StaleObservation {
        current: WorldRevision,
        incoming: WorldRevision,
    },

    ProviderFailure {
        provider_id: String,
        message: String,
    },

    InvalidObservation(String),

    SurfaceProviderFailure {
        provider_id: String,
        message: String,
    },
}

impl core::fmt::Display for DesktopWorldError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::StaleObservation { current, incoming } => write!(
                formatter,
                "stale observation revision: current={current:?}, incoming={incoming:?}"
            ),

            Self::ProviderFailure {
                provider_id,
                message,
            } => write!(formatter, "provider failed: {provider_id}: {message}"),

            Self::InvalidObservation(message) => {
                write!(formatter, "invalid world observation: {message}")
            }

            Self::SurfaceProviderFailure {
                provider_id,
                message,
            } => write!(
                formatter,
                "surface provider failed: {provider_id}: {message}"
            ),
        }
    }
}

impl std::error::Error for DesktopWorldError {}
