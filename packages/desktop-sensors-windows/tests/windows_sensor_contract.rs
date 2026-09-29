use ocp_desktop_sensors::{
    CursorSensor, DesktopSensorSuite, MonitorSensor, SensorAvailability, SensorKind, TaskbarSensor,
    WindowSensor,
};
use ocp_desktop_sensors_windows::{WindowsCursorMonitorSensors, WindowsDesktopSensors};
use ocp_shared_types::WorldRevision;

#[test]
fn provider_is_constructible() {
    let _provider = WindowsDesktopSensors::new();
    let _legacy_name = WindowsCursorMonitorSensors::new();
}

#[cfg(windows)]
#[test]
fn cursor_and_monitor_geometry_are_available() {
    let provider = WindowsDesktopSensors::new();

    let cursor = provider
        .sample_cursor()
        .expect("cursor query")
        .expect("cursor sample");

    let monitors = provider
        .sample_monitors()
        .expect("monitor query")
        .expect("monitor sample");

    assert!(cursor.cursor.position.x.is_finite());
    assert!(cursor.cursor.position.y.is_finite());
    assert!(!monitors.monitors.is_empty());
    assert!(monitors.virtual_desktop_bounds.0.size.width > 0.0);
    assert!(monitors.virtual_desktop_bounds.0.size.height > 0.0);
}

#[cfg(windows)]
#[test]
fn window_enumeration_has_stable_valid_descriptors() {
    let provider = WindowsDesktopSensors::new();

    let first = provider
        .sample_windows()
        .expect("first window query")
        .expect("first window sample");

    let second = provider
        .sample_windows()
        .expect("second window query")
        .expect("second window sample");

    assert!(!first.windows.is_empty());

    for window in &first.windows {
        assert!(window.bounds.size.width > 0.0);
        assert!(window.bounds.size.height > 0.0);
        assert!(!window.application_id.is_empty());
    }

    let first_ids: Vec<_> = first.windows.iter().map(|window| window.id).collect();
    let second_ids: Vec<_> = second.windows.iter().map(|window| window.id).collect();

    assert!(
        first_ids.iter().any(|id| second_ids.contains(id)),
        "at least one live HWND should preserve its WindowId"
    );
}

#[cfg(windows)]
#[test]
fn complete_windows_suite_reports_world_capabilities() {
    let provider = WindowsDesktopSensors::new();

    let sample = provider
        .sample(WorldRevision::new(1), 1_000)
        .expect("complete Windows sensor suite");

    assert_eq!(
        sample.availability(SensorKind::Cursor),
        Some(SensorAvailability::Available)
    );
    assert_eq!(
        sample.availability(SensorKind::Monitors),
        Some(SensorAvailability::Available)
    );
    assert_eq!(
        sample.availability(SensorKind::Windows),
        Some(SensorAvailability::Available)
    );
    assert!(sample.cursor.is_some());
    assert!(sample.monitors.is_some());
    assert!(sample.windows.is_some());
}

#[cfg(windows)]
#[test]
fn taskbar_query_is_safe_and_optional() {
    let provider = WindowsDesktopSensors::new();

    if let Some(taskbar) = provider.sample_taskbar_or_dock().expect("taskbar query") {
        assert!(taskbar.bounds.0.size.width > 0.0);
        assert!(taskbar.bounds.0.size.height > 0.0);
        assert_eq!(taskbar.platform_kind, "windows_taskbar");
    }
}

#[cfg(not(windows))]
#[test]
fn non_windows_fallback_returns_none() {
    let provider = WindowsDesktopSensors::new();

    assert!(provider.sample_cursor().unwrap().is_none());
    assert!(provider.sample_monitors().unwrap().is_none());
    assert!(provider.sample_windows().unwrap().is_none());
    assert!(provider.sample_taskbar_or_dock().unwrap().is_none());
}
