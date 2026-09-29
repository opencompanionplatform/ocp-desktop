use ocp_desktop_sensors::{
    CursorSample, CursorSensor, DesktopSensorError, DesktopSensorSuite, ForegroundWindowSample,
    ForegroundWindowSensor, LegacyOsSensorsAdapter, MonitorSample, MonitorSensor, MouseIdleSample,
    MouseIdleSensor, NativeEntityRegistry, SensorAvailability, SensorKind, SensorSource,
    SensorSuiteSample, TaskbarSample, TaskbarSensor, WindowListSample, WindowSensor,
};
use ocp_shared_types::{CoordinateSpace, WindowId, WorldRevision};
use std::sync::Mutex;

/// Complete Windows Desktop sensor suite.
#[derive(Debug, Default)]
pub struct WindowsDesktopSensors {
    registry: Mutex<NativeEntityRegistry>,
    last_external_active_window: Mutex<Option<WindowId>>,
    legacy: LegacyOsSensorsAdapter,
}

impl WindowsDesktopSensors {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn with_registry<T>(
        &self,
        sensor: &'static str,
        operation: impl FnOnce(&mut NativeEntityRegistry) -> Result<T, DesktopSensorError>,
    ) -> Result<T, DesktopSensorError> {
        let mut registry =
            self.registry
                .lock()
                .map_err(|_| DesktopSensorError::PlatformFailure {
                    sensor,
                    message: "native ID registry lock poisoned".to_owned(),
                })?;

        operation(&mut registry)
    }
}

/// Backward-compatible B1 name.
pub type WindowsCursorMonitorSensors = WindowsDesktopSensors;

impl CursorSensor for WindowsDesktopSensors {
    fn sample_cursor(&self) -> Result<Option<CursorSample>, DesktopSensorError> {
        sample_cursor_platform()
    }
}

impl MonitorSensor for WindowsDesktopSensors {
    fn sample_monitors(&self) -> Result<Option<MonitorSample>, DesktopSensorError> {
        self.with_registry("windows.monitors", sample_monitors_platform)
    }
}

impl WindowSensor for WindowsDesktopSensors {
    fn sample_windows(&self) -> Result<Option<WindowListSample>, DesktopSensorError> {
        let mut registry =
            self.registry
                .lock()
                .map_err(|_| DesktopSensorError::PlatformFailure {
                    sensor: "windows.windows",
                    message: "native ID registry lock poisoned".to_owned(),
                })?;
        let mut last_external_active_window =
            self.last_external_active_window.lock().map_err(|_| {
                DesktopSensorError::PlatformFailure {
                    sensor: "windows.windows",
                    message: "active external window lock poisoned".to_owned(),
                }
            })?;

        sample_windows_platform(&mut registry, &mut last_external_active_window)
    }
}

impl TaskbarSensor for WindowsDesktopSensors {
    fn sample_taskbar_or_dock(&self) -> Result<Option<TaskbarSample>, DesktopSensorError> {
        self.with_registry("windows.taskbar", sample_taskbar_platform)
    }
}

impl ForegroundWindowSensor for WindowsDesktopSensors {
    fn sample_foreground_window(
        &self,
    ) -> Result<Option<ForegroundWindowSample>, DesktopSensorError> {
        sample_foreground_platform()
    }
}

impl MouseIdleSensor for WindowsDesktopSensors {
    fn sample_mouse_idle(&self) -> Result<Option<MouseIdleSample>, DesktopSensorError> {
        self.legacy.sample_mouse_idle()
    }
}

impl DesktopSensorSuite for WindowsDesktopSensors {
    fn source(&self) -> SensorSource {
        SensorSource {
            provider_id: "ocp.desktop-sensors.windows".to_owned(),
            platform: "windows".to_owned(),
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
        let cursor = self.sample_cursor()?;
        let monitors = self.sample_monitors()?;
        let windows = self.sample_windows()?;
        let taskbar_or_dock = self.sample_taskbar_or_dock()?;

        Ok(SensorSuiteSample {
            source: self.source(),
            sequence,
            observed_at_ms,
            coordinate_space: CoordinateSpace::DesktopGlobalPhysical,
            availability: vec![
                availability(SensorKind::ForegroundWindow, foreground_window.is_some()),
                availability(SensorKind::MouseIdle, mouse_idle.is_some()),
                availability(SensorKind::Cursor, cursor.is_some()),
                availability(SensorKind::Monitors, monitors.is_some()),
                availability(SensorKind::Windows, windows.is_some()),
                availability(SensorKind::TaskbarOrDock, taskbar_or_dock.is_some()),
            ],
            foreground_window,
            mouse_idle,
            cursor,
            monitors,
            windows,
            taskbar_or_dock,
        })
    }
}

const fn availability(kind: SensorKind, available: bool) -> (SensorKind, SensorAvailability) {
    (
        kind,
        if available {
            SensorAvailability::Available
        } else {
            SensorAvailability::Unavailable
        },
    )
}

#[cfg(windows)]
fn sample_cursor_platform() -> Result<Option<CursorSample>, DesktopSensorError> {
    crate::windows_native::sample_cursor()
}

#[cfg(not(windows))]
fn sample_cursor_platform() -> Result<Option<CursorSample>, DesktopSensorError> {
    Ok(None)
}

#[cfg(windows)]
fn sample_monitors_platform(
    registry: &mut NativeEntityRegistry,
) -> Result<Option<MonitorSample>, DesktopSensorError> {
    crate::windows_native::sample_monitors(registry)
}

#[cfg(not(windows))]
fn sample_monitors_platform(
    _registry: &mut NativeEntityRegistry,
) -> Result<Option<MonitorSample>, DesktopSensorError> {
    Ok(None)
}

#[cfg(windows)]
fn sample_windows_platform(
    registry: &mut NativeEntityRegistry,
    last_external_active_window: &mut Option<WindowId>,
) -> Result<Option<WindowListSample>, DesktopSensorError> {
    crate::windows_native::sample_windows(registry, last_external_active_window)
}

#[cfg(not(windows))]
fn sample_windows_platform(
    _registry: &mut NativeEntityRegistry,
    _last_external_active_window: &mut Option<WindowId>,
) -> Result<Option<WindowListSample>, DesktopSensorError> {
    Ok(None)
}

#[cfg(windows)]
fn sample_taskbar_platform(
    registry: &mut NativeEntityRegistry,
) -> Result<Option<TaskbarSample>, DesktopSensorError> {
    crate::windows_native::sample_taskbar(registry)
}

#[cfg(not(windows))]
fn sample_taskbar_platform(
    _registry: &mut NativeEntityRegistry,
) -> Result<Option<TaskbarSample>, DesktopSensorError> {
    Ok(None)
}

#[cfg(windows)]
fn sample_foreground_platform() -> Result<Option<ForegroundWindowSample>, DesktopSensorError> {
    crate::windows_native::sample_foreground_window()
}

#[cfg(not(windows))]
fn sample_foreground_platform() -> Result<Option<ForegroundWindowSample>, DesktopSensorError> {
    Ok(None)
}
