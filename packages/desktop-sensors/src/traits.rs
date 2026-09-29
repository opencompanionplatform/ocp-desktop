use crate::{
    CursorSample, DesktopSensorError, ForegroundWindowSample, MonitorSample, MouseIdleSample,
    SensorSource, SensorSuiteSample, TaskbarSample, WindowListSample,
};
use ocp_shared_types::WorldRevision;

pub trait ForegroundWindowSensor: Send + Sync {
    fn sample_foreground_window(
        &self,
    ) -> Result<Option<ForegroundWindowSample>, DesktopSensorError>;
}

pub trait MouseIdleSensor: Send + Sync {
    fn sample_mouse_idle(&self) -> Result<Option<MouseIdleSample>, DesktopSensorError>;
}

pub trait CursorSensor: Send + Sync {
    fn sample_cursor(&self) -> Result<Option<CursorSample>, DesktopSensorError>;
}

pub trait MonitorSensor: Send + Sync {
    fn sample_monitors(&self) -> Result<Option<MonitorSample>, DesktopSensorError>;
}

pub trait WindowSensor: Send + Sync {
    fn sample_windows(&self) -> Result<Option<WindowListSample>, DesktopSensorError>;
}

pub trait TaskbarSensor: Send + Sync {
    fn sample_taskbar_or_dock(&self) -> Result<Option<TaskbarSample>, DesktopSensorError>;
}

pub trait DesktopSensorSuite: Send + Sync {
    fn source(&self) -> SensorSource;

    fn sample(
        &self,
        sequence: WorldRevision,
        observed_at_ms: u64,
    ) -> Result<SensorSuiteSample, DesktopSensorError>;
}
