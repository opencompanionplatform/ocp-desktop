use crate::{
    DesktopSensorError, DesktopSensorSuite, ForegroundWindowSample, ForegroundWindowSensor,
    MouseIdleSample, MouseIdleSensor, SensorAvailability, SensorKind, SensorSource,
    SensorSuiteSample,
};
use ocp_shared_types::{CoordinateSpace, WorldRevision};

/// Compatibility adapter over the existing `ocp-os-sensors` package.
///
/// It exposes only capabilities currently implemented by the legacy package.
/// Geometry sensors are supplied by the native provider in Phase 6.5.1B.
#[derive(Debug, Clone, Copy, Default)]
pub struct LegacyOsSensorsAdapter;

impl LegacyOsSensorsAdapter {
    #[must_use]
    pub const fn new() -> Self {
        Self
    }
}

impl ForegroundWindowSensor for LegacyOsSensorsAdapter {
    fn sample_foreground_window(
        &self,
    ) -> Result<Option<ForegroundWindowSample>, DesktopSensorError> {
        Ok(
            ocp_os_sensors::foreground_window().and_then(|(raw_title, process_name)| {
                if raw_title.is_empty() && process_name.is_empty() {
                    None
                } else {
                    Some(ForegroundWindowSample {
                        raw_title,
                        process_name,
                    })
                }
            }),
        )
    }
}

impl MouseIdleSensor for LegacyOsSensorsAdapter {
    fn sample_mouse_idle(&self) -> Result<Option<MouseIdleSample>, DesktopSensorError> {
        Ok(ocp_os_sensors::mouse_idle_ms().map(|idle_ms| MouseIdleSample { idle_ms }))
    }
}

impl DesktopSensorSuite for LegacyOsSensorsAdapter {
    fn source(&self) -> SensorSource {
        SensorSource {
            provider_id: "ocp.os-sensors.legacy".to_owned(),
            platform: std::env::consts::OS.to_owned(),
            provider_version: env!("CARGO_PKG_VERSION").to_owned(),
        }
    }

    fn sample(
        &self,
        sequence: WorldRevision,
        observed_at_ms: u64,
    ) -> Result<SensorSuiteSample, DesktopSensorError> {
        let foreground_window = self.sample_foreground_window()?;
        let mouse_idle = self.sample_mouse_idle()?;

        let foreground_available = foreground_window.is_some();
        let mouse_idle_available = mouse_idle.is_some();

        Ok(SensorSuiteSample {
            source: self.source(),
            sequence,
            observed_at_ms,
            coordinate_space: CoordinateSpace::DesktopGlobalPhysical,
            foreground_window,
            mouse_idle,
            cursor: None,
            monitors: None,
            windows: None,
            taskbar_or_dock: None,
            availability: vec![
                (
                    SensorKind::ForegroundWindow,
                    optional_availability(foreground_available),
                ),
                (
                    SensorKind::MouseIdle,
                    optional_availability(mouse_idle_available),
                ),
                (SensorKind::Cursor, SensorAvailability::Unsupported),
                (SensorKind::Monitors, SensorAvailability::Unsupported),
                (SensorKind::Windows, SensorAvailability::Unsupported),
                (SensorKind::TaskbarOrDock, SensorAvailability::Unsupported),
            ],
        })
    }
}

const fn optional_availability(present: bool) -> SensorAvailability {
    if present {
        SensorAvailability::Available
    } else {
        SensorAvailability::Unavailable
    }
}
