use ocp_desktop_sensors::{
    DesktopSensorError, DesktopSensorSuite, ForegroundWindowSample, ForegroundWindowSensor,
    LegacyOsSensorsAdapter, MouseIdleSample, MouseIdleSensor, SensorAvailability, SensorKind,
};
use ocp_shared_types::WorldRevision;

struct FixtureSensors;

impl ForegroundWindowSensor for FixtureSensors {
    fn sample_foreground_window(
        &self,
    ) -> Result<Option<ForegroundWindowSample>, DesktopSensorError> {
        Ok(Some(ForegroundWindowSample {
            raw_title: "Private document title".to_owned(),
            process_name: "browser.exe".to_owned(),
        }))
    }
}

impl MouseIdleSensor for FixtureSensors {
    fn sample_mouse_idle(&self) -> Result<Option<MouseIdleSample>, DesktopSensorError> {
        Ok(Some(MouseIdleSample { idle_ms: 250 }))
    }
}

#[test]
fn traits_are_mockable_without_platform_apis() {
    let fixture = FixtureSensors;

    let foreground = fixture
        .sample_foreground_window()
        .expect("foreground sample")
        .expect("foreground present");

    let mouse = fixture
        .sample_mouse_idle()
        .expect("mouse sample")
        .expect("mouse present");

    assert_eq!(foreground.process_name, "browser.exe");
    assert_eq!(mouse.idle_ms, 250);
}

#[test]
fn legacy_adapter_never_panics_without_desktop_session() {
    let adapter = LegacyOsSensorsAdapter::new();

    let sample = adapter
        .sample(WorldRevision::new(1), 1000)
        .expect("legacy sampling is non-panicking");

    assert_eq!(sample.sequence, WorldRevision::new(1));
    assert_eq!(
        sample.availability(SensorKind::Cursor),
        Some(SensorAvailability::Unsupported)
    );
    assert_eq!(
        sample.availability(SensorKind::Monitors),
        Some(SensorAvailability::Unsupported)
    );
    assert_eq!(
        sample.availability(SensorKind::Windows),
        Some(SensorAvailability::Unsupported)
    );
}

#[test]
fn legacy_foreground_sample_is_well_formed_when_available() {
    let adapter = LegacyOsSensorsAdapter::new();

    if let Some(sample) = adapter
        .sample_foreground_window()
        .expect("foreground sensor")
    {
        assert!(!sample.raw_title.is_empty() || !sample.process_name.is_empty());
    }
}

#[test]
fn legacy_mouse_idle_is_valid_when_available() {
    let adapter = LegacyOsSensorsAdapter::new();

    if let Some(sample) = adapter.sample_mouse_idle().expect("mouse idle sensor") {
        let _ = sample.idle_ms;
    }
}
