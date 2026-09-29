#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopSensorError {
    Unavailable {
        sensor: &'static str,
    },

    PermissionDenied {
        sensor: &'static str,
    },

    PlatformFailure {
        sensor: &'static str,
        message: String,
    },

    InvalidSample {
        sensor: &'static str,
        message: String,
    },
}

impl core::fmt::Display for DesktopSensorError {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Unavailable { sensor } => {
                write!(formatter, "sensor unavailable: {sensor}")
            }
            Self::PermissionDenied { sensor } => {
                write!(formatter, "sensor permission denied: {sensor}")
            }
            Self::PlatformFailure { sensor, message } => {
                write!(formatter, "sensor platform failure: {sensor}: {message}")
            }
            Self::InvalidSample { sensor, message } => {
                write!(formatter, "invalid sensor sample: {sensor}: {message}")
            }
        }
    }
}

impl std::error::Error for DesktopSensorError {}
