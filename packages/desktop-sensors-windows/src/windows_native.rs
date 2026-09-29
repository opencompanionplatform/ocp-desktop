use ocp_desktop_sensors::{
    CursorSample, DesktopSensorError, ForegroundWindowSample, MonitorSample, NativeEntityRegistry,
    TaskbarSample, WindowListSample,
};
use ocp_shared_types::{Bounds, Cursor, Monitor, Point2, Rect, Window, WindowId};
use std::ffi::c_void;
use std::mem::size_of;
use windows::core::BOOL;
use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetCursorPos, GetForegroundWindow, GetSystemMetrics, GetWindowRect,
    GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible, SM_CXVIRTUALSCREEN,
    SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

const MONITORINFOF_PRIMARY_FLAG: u32 = 1;
const WINDOW_TEXT_CAPACITY: usize = 1024;
const WINDOW_CLASS_CAPACITY: usize = 256;
const TASKBAR_CLASS: &str = "Shell_TrayWnd";

struct MonitorCollector {
    registry: *mut NativeEntityRegistry,
    monitors: Vec<Monitor>,
    failure: Option<String>,
}

struct WindowCollector {
    registry: *mut NativeEntityRegistry,
    foreground: HWND,
    foreground_is_ocp_internal: bool,
    windows: Vec<Window>,
    active_window_id: Option<WindowId>,
    active_application_kind: Option<String>,
    taskbar: Option<TaskbarSample>,
    z_order: i32,
    failure: Option<String>,
}

pub(crate) fn sample_cursor() -> Result<Option<CursorSample>, DesktopSensorError> {
    let mut point = POINT::default();

    // SAFETY: writes synchronously to a valid POINT and retains no pointer.
    unsafe { GetCursorPos(&mut point) }
        .map_err(|error| platform_failure("windows.cursor", error.to_string()))?;

    Ok(Some(CursorSample {
        cursor: Cursor {
            position: Point2::new(point.x as f32, point.y as f32),
            visible: true,
        },
    }))
}

pub(crate) fn sample_monitors(
    registry: &mut NativeEntityRegistry,
) -> Result<Option<MonitorSample>, DesktopSensorError> {
    let mut collector = MonitorCollector {
        registry: std::ptr::from_mut(registry),
        monitors: Vec::new(),
        failure: None,
    };
    let collector_ptr: *mut MonitorCollector = std::ptr::from_mut(&mut collector);

    // SAFETY: callback is synchronous and collector remains alive.
    let result = unsafe {
        EnumDisplayMonitors(
            None,
            None,
            Some(enum_monitor_callback),
            LPARAM(collector_ptr as isize),
        )
    };

    if let Some(message) = collector.failure {
        return Err(platform_failure("windows.monitors", message));
    }

    if !result.as_bool() {
        return Err(platform_failure(
            "windows.monitors",
            "EnumDisplayMonitors returned FALSE",
        ));
    }

    if collector.monitors.is_empty() {
        return Ok(None);
    }

    Ok(Some(MonitorSample {
        monitors: collector.monitors,
        virtual_desktop_bounds: virtual_desktop_bounds(),
    }))
}

pub(crate) fn sample_windows(
    registry: &mut NativeEntityRegistry,
    last_external_active_window: &mut Option<WindowId>,
) -> Result<Option<WindowListSample>, DesktopSensorError> {
    let mut collector = enumerate_windows(registry)?;

    preserve_external_active_window(&mut collector, last_external_active_window);

    if collector.windows.is_empty() {
        return Ok(None);
    }

    Ok(Some(WindowListSample {
        windows: collector.windows,
        active_window_id: collector.active_window_id,
        active_application_kind: collector.active_application_kind,
    }))
}

pub(crate) fn sample_taskbar(
    registry: &mut NativeEntityRegistry,
) -> Result<Option<TaskbarSample>, DesktopSensorError> {
    Ok(enumerate_windows(registry)?.taskbar)
}

pub(crate) fn sample_foreground_window(
) -> Result<Option<ForegroundWindowSample>, DesktopSensorError> {
    // SAFETY: GetForegroundWindow returns a borrowed HWND value.
    let foreground = unsafe { GetForegroundWindow() };

    if foreground == HWND::default() {
        return Ok(None);
    }

    let title = window_text(foreground);
    let class_name = window_class(foreground);

    if is_ocp_internal_window_class(&class_name) {
        return Ok(None);
    }

    if title.is_empty() && class_name.is_empty() {
        return Ok(None);
    }

    Ok(Some(ForegroundWindowSample {
        raw_title: title,
        process_name: class_name,
    }))
}

fn enumerate_windows(
    registry: &mut NativeEntityRegistry,
) -> Result<WindowCollector, DesktopSensorError> {
    // SAFETY: GetForegroundWindow returns a borrowed HWND value.
    let foreground = unsafe { GetForegroundWindow() };

    let foreground_is_ocp_internal = is_ocp_internal_window_class(&window_class(foreground));
    let mut collector = WindowCollector {
        registry: std::ptr::from_mut(registry),
        foreground,
        foreground_is_ocp_internal,
        windows: Vec::new(),
        active_window_id: None,
        active_application_kind: None,
        taskbar: None,
        z_order: 0,
        failure: None,
    };
    let collector_ptr: *mut WindowCollector = std::ptr::from_mut(&mut collector);

    // SAFETY: EnumWindows calls the callback synchronously; the pointer points
    // to a live local collector and is not retained.
    unsafe { EnumWindows(Some(enum_window_callback), LPARAM(collector_ptr as isize)) }
        .map_err(|error| platform_failure("windows.windows", error.to_string()))?;

    if let Some(message) = collector.failure.as_ref() {
        return Err(platform_failure("windows.windows", message.clone()));
    }

    Ok(collector)
}

fn preserve_external_active_window(
    collector: &mut WindowCollector,
    last_external_active_window: &mut Option<WindowId>,
) {
    if let Some(active_window_id) = collector.active_window_id {
        *last_external_active_window = Some(active_window_id);
        return;
    }

    // An OCP controller/input/menu HWND is never an application surface. If
    // Windows reports one as foreground during a drag or auxiliary UI click,
    // preserve the exact external application that was active immediately
    // before OCP. Choosing the first enumerated window is incorrect because
    // z-order can change independently of foreground ownership.
    if !collector.foreground_is_ocp_internal {
        return;
    }

    let Some(last_active_window_id) = *last_external_active_window else {
        return;
    };
    let Some(window) = collector
        .windows
        .iter_mut()
        .find(|window| window.id == last_active_window_id)
    else {
        *last_external_active_window = None;
        return;
    };

    window.active = true;
    collector.active_window_id = Some(window.id);
    collector.active_application_kind = window.title_classification.clone();
}

unsafe extern "system" fn enum_monitor_callback(
    monitor_handle: HMONITOR,
    _device_context: HDC,
    _monitor_rect: *mut RECT,
    user_data: LPARAM,
) -> BOOL {
    let collector_ptr = user_data.0 as *mut MonitorCollector;

    if collector_ptr.is_null() {
        return BOOL(0);
    }

    // SAFETY: pointer is valid for this synchronous callback.
    let collector = unsafe { &mut *collector_ptr };

    if collector.registry.is_null() {
        collector.failure = Some("native ID registry pointer was null".to_owned());
        return BOOL(0);
    }

    // SAFETY: registry remains exclusively borrowed during enumeration.
    let registry = unsafe { &mut *collector.registry };

    match monitor_from_handle(monitor_handle, registry, collector.monitors.len()) {
        Ok(monitor) => {
            collector.monitors.push(monitor);
            BOOL(1)
        }
        Err(message) => {
            collector.failure = Some(message);
            BOOL(0)
        }
    }
}

unsafe extern "system" fn enum_window_callback(window_handle: HWND, user_data: LPARAM) -> BOOL {
    let collector_ptr = user_data.0 as *mut WindowCollector;

    if collector_ptr.is_null() {
        return BOOL(0);
    }

    // SAFETY: pointer is valid for this synchronous callback.
    let collector = unsafe { &mut *collector_ptr };

    if collector.registry.is_null() {
        collector.failure = Some("native ID registry pointer was null".to_owned());
        return BOOL(0);
    }

    // SAFETY: registry remains exclusively borrowed during enumeration.
    let registry = unsafe { &mut *collector.registry };

    let class_name = window_class(window_handle);
    let visible = unsafe { IsWindowVisible(window_handle) }.as_bool();
    let minimized = unsafe { IsIconic(window_handle) }.as_bool();

    if class_name == TASKBAR_CLASS {
        if let Some(bounds) = basic_window_rect(window_handle) {
            let native_key = native_window_key(window_handle);
            collector.taskbar = Some(TaskbarSample {
                entity_id: registry.entity_id(native_key),
                bounds: Bounds(bounds),
                auto_hidden: !visible,
                platform_kind: "windows_taskbar".to_owned(),
            });
        }
        return BOOL(1);
    }

    // The controller, render/input proxy, hover menu, submenu, bubble and
    // picker all share this private class. None of them may become a floor,
    // ledge, climb edge or active application in canonical Desktop World.
    if is_ocp_internal_window_class(&class_name) {
        return BOOL(1);
    }

    if !visible {
        return BOOL(1);
    }

    let Some(bounds) = basic_window_rect(window_handle) else {
        return BOOL(1);
    };

    if bounds.size.width <= 0.0 || bounds.size.height <= 0.0 {
        return BOOL(1);
    }

    let native_key = native_window_key(window_handle);
    let id = registry.window_id(native_key.clone());
    let entity_id = registry.entity_id(native_key);
    let active = window_handle == collector.foreground;
    let process_id = window_process_id(window_handle);
    let application_id = application_id(&class_name, process_id);

    if active {
        collector.active_window_id = Some(id);
        collector.active_application_kind = nonempty(class_name.clone());
    }

    let frame_bounds = extended_frame_bounds(window_handle)
        .filter(|frame| frame_matches_window_coordinate_scale(bounds, *frame));

    collector.windows.push(Window {
        id,
        entity_id,
        application_id,
        title_classification: nonempty(class_name),
        bounds,
        client_bounds: None,
        frame_bounds,
        z_order: collector.z_order,
        active,
        minimized,
        visible,
        occluded: false,
        workspace_id: None,
    });

    collector.z_order = collector.z_order.saturating_add(1);

    BOOL(1)
}

fn monitor_from_handle(
    monitor_handle: HMONITOR,
    registry: &mut NativeEntityRegistry,
    index: usize,
) -> Result<Monitor, String> {
    let mut info = MONITORINFO {
        cbSize: u32::try_from(size_of::<MONITORINFO>()).map_err(|error| error.to_string())?,
        ..Default::default()
    };

    // SAFETY: valid writable MONITORINFO with cbSize initialized.
    let result = unsafe { GetMonitorInfoW(monitor_handle, &mut info as *mut MONITORINFO) };

    if !result.as_bool() {
        return Err("GetMonitorInfoW returned FALSE".to_owned());
    }

    let native_key = format!("windows:hmonitor:{}", monitor_handle.0 as usize);
    let id = registry.monitor_id(native_key.clone());
    let entity_id = registry.entity_id(native_key);

    Ok(Monitor {
        id,
        entity_id,
        name: format!("Monitor {}", index + 1),
        bounds: Bounds(rect_from_win32(info.rcMonitor)),
        work_area: Bounds(rect_from_win32(info.rcWork)),
        scale_factor: 1.0,
        primary: (info.dwFlags & MONITORINFOF_PRIMARY_FLAG) != 0,
    })
}

fn basic_window_rect(window_handle: HWND) -> Option<Rect> {
    let mut rect = RECT::default();

    // SAFETY: rect is valid and writable for the synchronous call.
    unsafe { GetWindowRect(window_handle, &mut rect) }
        .ok()
        .map(|()| rect_from_win32(rect))
}

fn extended_frame_bounds(window_handle: HWND) -> Option<Rect> {
    let mut rect = RECT::default();
    let size = u32::try_from(size_of::<RECT>()).ok()?;

    // SAFETY: RECT storage is valid for the synchronous DWM call.
    unsafe {
        DwmGetWindowAttribute(
            window_handle,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            std::ptr::from_mut(&mut rect).cast::<c_void>(),
            size,
        )
    }
    .ok()
    .map(|()| rect_from_win32(rect))
}

fn frame_matches_window_coordinate_scale(bounds: Rect, frame: Rect) -> bool {
    const MAX_DIMENSION_RATIO_DELTA: f32 = 0.10;

    if bounds.size.width <= 0.0
        || bounds.size.height <= 0.0
        || frame.size.width <= 0.0
        || frame.size.height <= 0.0
    {
        return false;
    }

    let width_ratio = frame.size.width / bounds.size.width;
    let height_ratio = frame.size.height / bounds.size.height;
    (width_ratio - 1.0).abs() <= MAX_DIMENSION_RATIO_DELTA
        && (height_ratio - 1.0).abs() <= MAX_DIMENSION_RATIO_DELTA
}

#[cfg(test)]
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::{
        frame_matches_window_coordinate_scale, is_ocp_internal_window_class,
        preserve_external_active_window, WindowCollector,
    };
    use ocp_shared_types::{Rect, Window, WindowId, WorldEntityId};
    use windows::Win32::Foundation::HWND;

    #[test]
    fn accepts_normal_extended_frame_in_same_coordinate_space() {
        let bounds = Rect::new(742.0, 76.0, 620.0, 900.0);
        let frame = Rect::new(743.0, 77.0, 618.0, 898.0);
        assert!(frame_matches_window_coordinate_scale(bounds, frame));
    }

    #[test]
    fn rejects_125_percent_physical_frame_for_logical_window_bounds() {
        let logical = Rect::new(742.0, 76.0, 620.0, 900.0);
        let physical = Rect::new(927.5, 95.0, 775.0, 1_125.0);
        assert!(!frame_matches_window_coordinate_scale(logical, physical));
    }

    #[test]
    fn recognizes_native_companion_auxiliary_window_class() {
        assert!(is_ocp_internal_window_class("OCPNativeSpike"));
        assert!(is_ocp_internal_window_class("ocpnativespike"));
        assert!(!is_ocp_internal_window_class("Notepad"));
    }

    #[test]
    fn ocp_foreground_preserves_the_exact_last_external_window() {
        let first = test_window("first");
        let second = test_window("second");
        let expected = second.id;
        let mut collector = test_collector(vec![first, second], true);
        let mut last_external_active_window = Some(expected);

        preserve_external_active_window(&mut collector, &mut last_external_active_window);

        assert_eq!(collector.active_window_id, Some(expected));
        assert_eq!(collector.active_application_kind.as_deref(), Some("second"));
        assert!(!collector.windows[0].active);
        assert!(collector.windows[1].active);
    }

    #[test]
    fn ocp_foreground_does_not_guess_an_external_window_without_history() {
        let mut collector = test_collector(vec![test_window("first")], true);
        let mut last_external_active_window = None;

        preserve_external_active_window(&mut collector, &mut last_external_active_window);

        assert_eq!(collector.active_window_id, None);
        assert!(!collector.windows[0].active);
    }

    fn test_collector(windows: Vec<Window>, foreground_is_ocp_internal: bool) -> WindowCollector {
        WindowCollector {
            registry: std::ptr::null_mut(),
            foreground: HWND::default(),
            foreground_is_ocp_internal,
            windows,
            active_window_id: None,
            active_application_kind: None,
            taskbar: None,
            z_order: 0,
            failure: None,
        }
    }

    fn test_window(title: &str) -> Window {
        Window {
            id: WindowId::new(),
            entity_id: WorldEntityId::new(),
            application_id: format!("{title}.test"),
            title_classification: Some(title.to_owned()),
            bounds: Rect::new(100.0, 100.0, 800.0, 600.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 0,
            active: false,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }
    }
}

fn window_text(window_handle: HWND) -> String {
    let mut buffer = [0_u16; WINDOW_TEXT_CAPACITY];

    // SAFETY: buffer is valid and writable for this call.
    let length = unsafe { GetWindowTextW(window_handle, &mut buffer) };

    utf16_buffer(&buffer, length)
}

fn window_class(window_handle: HWND) -> String {
    let mut buffer = [0_u16; WINDOW_CLASS_CAPACITY];

    // SAFETY: buffer is valid and writable for this call.
    let length = unsafe { GetClassNameW(window_handle, &mut buffer) };

    utf16_buffer(&buffer, length)
}

fn utf16_buffer(buffer: &[u16], length: i32) -> String {
    let usable = usize::try_from(length)
        .unwrap_or_default()
        .min(buffer.len());

    String::from_utf16_lossy(&buffer[..usable])
}

fn window_process_id(window_handle: HWND) -> u32 {
    let mut process_id = 0_u32;

    // SAFETY: process_id is valid writable storage.
    unsafe { GetWindowThreadProcessId(window_handle, Some(std::ptr::from_mut(&mut process_id))) };

    process_id
}

fn application_id(class_name: &str, process_id: u32) -> String {
    let class = if class_name.is_empty() {
        "unknown"
    } else {
        class_name
    };

    format!("{class}:pid:{process_id}")
}

fn is_ocp_internal_window_class(class_name: &str) -> bool {
    class_name.eq_ignore_ascii_case("OCPNativeSpike")
}

fn native_window_key(window_handle: HWND) -> String {
    format!("windows:hwnd:{}", window_handle.0 as usize)
}

fn nonempty(value: String) -> Option<String> {
    (!value.is_empty()).then_some(value)
}

fn rect_from_win32(rect: RECT) -> Rect {
    Rect::new(
        rect.left as f32,
        rect.top as f32,
        (rect.right - rect.left) as f32,
        (rect.bottom - rect.top) as f32,
    )
}

fn virtual_desktop_bounds() -> Bounds {
    // SAFETY: scalar queries with no pointer ownership.
    let x = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    // SAFETY: same contract.
    let y = unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) };
    // SAFETY: same contract.
    let width = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) };
    // SAFETY: same contract.
    let height = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) };

    Bounds(Rect::new(
        x as f32,
        y as f32,
        width.max(0) as f32,
        height.max(0) as f32,
    ))
}

fn platform_failure(sensor: &'static str, message: impl Into<String>) -> DesktopSensorError {
    DesktopSensorError::PlatformFailure {
        sensor,
        message: message.into(),
    }
}
