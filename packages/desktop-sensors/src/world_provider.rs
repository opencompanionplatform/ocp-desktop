use crate::{DesktopSensorSuite, SensorAvailability, SensorKind};
use chrono::{DateTime, Utc};
use ocp_desktop_world::{
    ActiveApplication, DesktopObservationBatch, DesktopWorldCapabilities, DesktopWorldError,
    DesktopWorldProvider, MonitorObservation, ObservationSource, TaskbarDescriptor,
    TaskbarObservation, WindowObservation,
};
use ocp_shared_types::WorldRevision;

/// Converts a complete normalized Sensor Suite sample into a Desktop World
/// observation. It owns only sequence progression, not World state.
pub struct SensorWorldProvider<S> {
    provider_id: &'static str,
    sensor_suite: S,
    next_sequence: WorldRevision,
}

impl<S> SensorWorldProvider<S> {
    #[must_use]
    pub fn new(provider_id: &'static str, sensor_suite: S) -> Self {
        Self {
            provider_id,
            sensor_suite,
            next_sequence: WorldRevision::INITIAL,
        }
    }

    #[must_use]
    pub fn sequence(&self) -> WorldRevision {
        self.next_sequence
    }

    #[must_use]
    pub const fn sensor_suite(&self) -> &S {
        &self.sensor_suite
    }
}

impl<S> DesktopWorldProvider for SensorWorldProvider<S>
where
    S: DesktopSensorSuite,
{
    fn provider_id(&self) -> &'static str {
        self.provider_id
    }

    fn observe(&mut self) -> Result<DesktopObservationBatch, DesktopWorldError> {
        let observed_at = Utc::now();
        let observed_at_ms = u64::try_from(observed_at.timestamp_millis()).unwrap_or_default();

        let sample = self
            .sensor_suite
            .sample(self.next_sequence, observed_at_ms)
            .map_err(|error| DesktopWorldError::ProviderFailure {
                provider_id: self.provider_id.to_owned(),
                message: error.to_string(),
            })?;

        let capabilities = DesktopWorldCapabilities {
            windows: is_available(&sample, SensorKind::Windows),
            monitors: is_available(&sample, SensorKind::Monitors),
            cursor: is_available(&sample, SensorKind::Cursor),
            taskbar_or_dock: is_available(&sample, SensorKind::TaskbarOrDock),
            workspaces: false,
            occlusion: false,
        };

        let monitors = sample.monitors.ok_or_else(|| {
            DesktopWorldError::InvalidObservation(
                "monitor geometry is required to build Desktop World".to_owned(),
            )
        })?;

        let windows = sample.windows.ok_or_else(|| {
            DesktopWorldError::InvalidObservation(
                "window enumeration is required to build Desktop World".to_owned(),
            )
        })?;

        let active_application = windows.active_window_id.and_then(|active_window_id| {
            windows
                .windows
                .iter()
                .find(|window| window.id == active_window_id)
                .map(|window| ActiveApplication {
                    application_id: window.application_id.clone(),
                    application_kind: windows.active_application_kind.clone(),
                    window_id: Some(active_window_id),
                })
        });

        let taskbar_or_dock = sample.taskbar_or_dock.map(|taskbar| TaskbarDescriptor {
            entity_id: taskbar.entity_id,
            bounds: taskbar.bounds,
            auto_hidden: taskbar.auto_hidden,
            platform_kind: taskbar.platform_kind,
        });

        let batch = DesktopObservationBatch {
            source: ObservationSource {
                provider_id: sample.source.provider_id,
                platform: sample.source.platform,
                provider_version: sample.source.provider_version,
            },
            sequence: sample.sequence,
            observed_at: as_datetime(sample.observed_at_ms, observed_at),
            coordinate_space: sample.coordinate_space,
            capabilities,
            monitors: MonitorObservation {
                monitors: monitors.monitors,
                virtual_desktop_bounds: monitors.virtual_desktop_bounds,
            },
            workspaces: Vec::new(),
            windows: WindowObservation {
                windows: windows.windows,
                active_window_id: windows.active_window_id,
                active_application,
            },
            cursor: sample.cursor.map(|value| value.cursor),
            taskbar: TaskbarObservation { taskbar_or_dock },
            obstacles: Vec::new(),
        };

        self.next_sequence = self.next_sequence.next();

        Ok(batch)
    }
}

fn is_available(sample: &crate::SensorSuiteSample, kind: SensorKind) -> bool {
    sample.availability(kind) == Some(SensorAvailability::Available)
}

fn as_datetime(milliseconds: u64, fallback: DateTime<Utc>) -> DateTime<Utc> {
    i64::try_from(milliseconds)
        .ok()
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .unwrap_or(fallback)
}
