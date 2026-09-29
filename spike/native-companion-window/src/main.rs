#![cfg_attr(not(windows), allow(dead_code))]

#[cfg(not(windows))]
fn main() {
    eprintln!("This Gate G2 spike runs on Windows only.");
}

#[cfg(windows)]
mod windows_spike {
    use std::collections::HashMap;
    use std::ffi::c_void;
    use std::fs;
    use std::mem::size_of;
    use std::ptr::{null, null_mut};
    use std::sync::atomic::{AtomicBool, AtomicI32, AtomicIsize, AtomicU32, AtomicUsize, Ordering};
    use std::sync::{Mutex, OnceLock};

    use resvg::{tiny_skia, usvg};
    use windows::core::{Interface, GUID};
    use windows::Win32::Foundation::{HWND as WinHwnd, PROPERTYKEY, RECT};
    use windows::Win32::Graphics::Direct2D::Common::{
        D2D1_ALPHA_MODE_IGNORE, D2D1_COLOR_F, D2D1_PIXEL_FORMAT, D2D_RECT_F,
    };
    use windows::Win32::Graphics::Direct2D::{
        D2D1CreateFactory, ID2D1Factory, ID2D1RenderTarget, ID2D1StrokeStyle, D2D1_ELLIPSE,
        D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_FEATURE_LEVEL_DEFAULT,
        D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1_RENDER_TARGET_USAGE_NONE, D2D1_ROUNDED_RECT,
    };
    use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_UNKNOWN;
    use windows::Win32::Graphics::Gdi::HDC;
    use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
    use windows::Win32::System::Variant::VARIANT;
    use windows::Win32::UI::Shell::PropertiesSystem::{
        IPropertyStore, SHGetPropertyStoreForWindow,
    };
    use windows_numerics::Vector2;

    use ocp_native_companion_window_spike::{
        align_grounded_placement_to_work_area, auxiliary_prepaint_color,
        canonical_anchor_to_native_placement, canonical_feet_to_native_placement, colorref_rgb,
        companion_scale_preset_index, derive_logical_monitor, expand_physical_rect_within,
        hover_accent_color, hover_menu_primary_action, hover_menu_submenu_action,
        hover_menu_submenu_mode, input_proxy_should_be_visible, localized_hover_label,
        logical_extent_to_physical, monitor_for_logical_point, native_bounds_to_canonical_anchor,
        normalize_hover_language, place_auxiliary_group, place_drag_safe_auxiliary_menu,
        place_side_submenu, popup_row_bounds, popup_row_from_client_y, popup_segment_from_client_x,
        render_surface_needs_sync, should_align_grounded_to_work_area, DesktopLogicalPoint,
        MonitorDescriptor, PhysicalRect,
    };

    type Bool = i32;
    type Dword = u32;
    type Hbrush = isize;
    type Hcursor = isize;
    type Hfont = isize;
    type Hinstance = isize;
    type Hmonitor = isize;
    type Hwnd = isize;
    type Lparam = isize;
    type Lresult = isize;
    type Uint = u32;
    type Wparam = usize;
    type NormalizedHitbox = (f32, f32, f32, f32);

    const DEFAULT_WINDOW_SIZE: i32 = 256;
    const NULL_PEN: i32 = 8;
    const NULL_BRUSH: i32 = 5;
    const PS_SOLID: i32 = 0;
    const DIB_RGB_COLORS: Uint = 0;
    const AC_SRC_OVER: u8 = 0;
    const AC_SRC_ALPHA: u8 = 1;
    const CLASS_NAME: &[u16] = &[
        79, 67, 80, 78, 97, 116, 105, 118, 101, 83, 112, 105, 107, 101, 0,
    ];
    const TITLE: &[u16] = &[
        79, 67, 80, 32, 78, 97, 116, 105, 118, 101, 32, 71, 50, 32, 83, 112, 105, 107, 101, 0,
    ];
    const OCP_TASKBAR_APP_ID: &str = "OpenCompanion.OCP.Runtime";
    const OCP_TASKBAR_DISPLAY_NAME: &str = "OCP";
    const APPUSERMODEL_FMTID: GUID = GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3);
    const PKEY_APPUSERMODEL_RELAUNCH_COMMAND: PROPERTYKEY = PROPERTYKEY {
        fmtid: APPUSERMODEL_FMTID,
        pid: 2,
    };
    const PKEY_APPUSERMODEL_RELAUNCH_ICON_RESOURCE: PROPERTYKEY = PROPERTYKEY {
        fmtid: APPUSERMODEL_FMTID,
        pid: 3,
    };
    const PKEY_APPUSERMODEL_RELAUNCH_DISPLAY_NAME_RESOURCE: PROPERTYKEY = PROPERTYKEY {
        fmtid: APPUSERMODEL_FMTID,
        pid: 4,
    };
    const PKEY_APPUSERMODEL_ID: PROPERTYKEY = PROPERTYKEY {
        fmtid: APPUSERMODEL_FMTID,
        pid: 5,
    };

    const CS_HREDRAW: Uint = 0x0002;
    const CS_VREDRAW: Uint = 0x0001;
    const CW_USEDEFAULT: i32 = i32::MIN;
    const GWL_STYLE: i32 = -16;
    const GWLP_EXSTYLE: i32 = -20;
    const HTCLIENT: Lresult = 1;
    const HTTRANSPARENT: Lresult = -1;
    const IDC_ARROW: *const u16 = 32512usize as *const u16;
    const LWA_COLORKEY: Dword = 0x0000_0001;
    const LWA_ALPHA: Dword = 0x0000_0002;
    const MOD_ALT: Uint = 0x0001;
    const MOD_CONTROL: Uint = 0x0002;
    const MONITOR_DEFAULTTONEAREST: Dword = 2;
    const PM_REMOVE: Uint = 0x0001;
    const SWP_NOACTIVATE: Uint = 0x0010;
    const SWP_FRAMECHANGED: Uint = 0x0020;
    const SWP_NOMOVE: Uint = 0x0002;
    const SWP_NOSIZE: Uint = 0x0001;
    const VK_C: Uint = 0x43;
    const VK_B: Uint = 0x42;
    const VK_A: Uint = 0x41;
    const VK_M: Uint = 0x4D;
    const VK_P: Uint = 0x50;
    const VK_Q: Uint = 0x51;
    const WM_DESTROY: Uint = 0x0002;
    const WM_SHOWWINDOW: Uint = 0x0018;
    const WM_DPICHANGED: Uint = 0x02E0;
    const WM_HOTKEY: Uint = 0x0312;
    const WM_MOVE: Uint = 0x0003;
    const WM_MOUSEMOVE: Uint = 0x0200;
    const WM_LBUTTONDOWN: Uint = 0x0201;
    const WM_LBUTTONUP: Uint = 0x0202;
    const WM_CAPTURECHANGED: Uint = 0x0215;
    const WM_MOUSELEAVE: Uint = 0x02A3;
    const WM_NCMOUSEMOVE: Uint = 0x00A0;
    const WM_NCMOUSELEAVE: Uint = 0x02A2;
    const WM_TIMER: Uint = 0x0113;
    const WM_ENTERSIZEMOVE: Uint = 0x0231;
    const WM_EXITSIZEMOVE: Uint = 0x0232;
    const WM_NCHITTEST: Uint = 0x0084;
    const WM_PAINT: Uint = 0x000F;
    const WM_ERASEBKGND: Uint = 0x0014;
    const WM_MOUSEACTIVATE: Uint = 0x0021;
    const MA_NOACTIVATE: Lresult = 3;
    const TRANSPARENT: i32 = 1;
    const DT_CENTER: Uint = 0x0001;
    const DT_LEFT: Uint = 0x0000;
    const DT_RIGHT: Uint = 0x0002;
    const DT_SINGLELINE: Uint = 0x0020;
    const DT_VCENTER: Uint = 0x0004;
    const DT_WORDBREAK: Uint = 0x0010;
    const FW_NORMAL: i32 = 400;
    const FW_SEMIBOLD: i32 = 600;
    const DEFAULT_CHARSET: u32 = 1;
    const OUT_DEFAULT_PRECIS: u32 = 0;
    const CLIP_DEFAULT_PRECIS: u32 = 0;
    const DEFAULT_QUALITY: u32 = 0;
    const DEFAULT_PITCH: u32 = 0;
    const FF_DONTCARE: u32 = 0;
    const WS_EX_LAYERED: Dword = 0x0008_0000;
    const WS_EX_APPWINDOW: Dword = 0x0004_0000;
    const WS_EX_NOACTIVATE: Dword = 0x0800_0000;
    const WS_EX_TOOLWINDOW: Dword = 0x0000_0080;
    const WS_EX_TOPMOST: Dword = 0x0000_0008;
    const WS_DISABLED: Dword = 0x0800_0000;
    const WS_EX_TRANSPARENT: Dword = 0x0000_0020;
    const WS_POPUP: Dword = 0x8000_0000;
    const WS_CHILD: Dword = 0x4000_0000;
    const WS_VISIBLE: Dword = 0x1000_0000;
    const HOTKEY_CLICK_THROUGH: i32 = 1;
    const HOTKEY_QUIT: i32 = 2;
    const HOTKEY_CANONICAL_NEXT: i32 = 3;
    const HOTKEY_BUBBLE: i32 = 4;
    const HOTKEY_MENU: i32 = 5;
    const HOTKEY_ACTIVE_ATTACH: i32 = 6;
    const HWND_TOPMOST: Hwnd = -1;
    const SW_HIDE: i32 = 0;
    const SW_SHOWNOACTIVATE: i32 = 4;
    const TME_LEAVE: Dword = 0x0000_0002;
    const TME_NONCLIENT: Dword = 0x0000_0010;
    const HOVER_CLOSE_TIMER: usize = 10;
    const ACTIVE_ATTACH_TIMER: usize = 11;
    const AURA_FRAME_TIMER: usize = 12;
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
    const DWMWA_NCRENDERING_POLICY: Dword = 2;
    const DWMNCRP_DISABLED: Dword = 1;
    const FR_PRIVATE: Dword = 0x10;

    static CLICK_THROUGH: AtomicBool = AtomicBool::new(false);
    static CANONICAL_APPLYING: AtomicBool = AtomicBool::new(false);
    // Per-monitor DPI notifications are delivered to every top-level HWND.
    // The controller is the only placement authority; all other surfaces
    // derive their geometry from it after the controller has moved.
    static OWNED_SURFACE_DPI_SYNC: AtomicBool = AtomicBool::new(false);
    static DRAG_ACTIVE: AtomicBool = AtomicBool::new(false);
    // Do not reopen hover UI under the pointer that just completed a drag.
    // It must leave the visual hitbox once before hover can be armed again.
    static HOVER_REARM_REQUIRED: AtomicBool = AtomicBool::new(false);
    static DRAG_OFFSET_X: AtomicI32 = AtomicI32::new(0);
    static DRAG_OFFSET_Y: AtomicI32 = AtomicI32::new(0);
    static ACTIVE_ATTACH: AtomicBool = AtomicBool::new(false);
    static THEME_INDEX: AtomicUsize = AtomicUsize::new(0);
    // 0 = English fallback, 1 = Thai. Atomic reads keep paint/layout hot paths
    // allocation-free and avoid locking on every hover repaint.
    static UI_LANGUAGE_INDEX: AtomicUsize = AtomicUsize::new(0);
    static LAST_THEME_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static LAST_PRESENTATION_SCALE_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static MENU_HOVER_ROW: AtomicI32 = AtomicI32::new(-1);
    static SUBMENU_HOVER_ROW: AtomicI32 = AtomicI32::new(-1);
    // 0 = animation actions, 1 = presentation-only size presets,
    // 2 = Runtime-owned Sound controls.
    static SUBMENU_MODE: AtomicI32 = AtomicI32::new(0);
    // Runtime-approved active size segment. Native UI is a request surface,
    // so clicks do not mutate this value until Runtime confirms application.
    static ACTIVE_PRESENTATION_SCALE_INDEX: AtomicI32 = AtomicI32::new(3);
    // Native hover UI never flips these optimistically. Runtime acknowledges
    // the requested state through the authenticated UI command channel.
    static MASTER_SOUND_MUTED: AtomicBool = AtomicBool::new(false);
    static CHARACTER_SFX_ENABLED: AtomicBool = AtomicBool::new(true);
    static LAST_SOUND_STATE_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static REDUCED_MOTION: AtomicBool = AtomicBool::new(false);
    static AURA_FRAME: AtomicUsize = AtomicUsize::new(0);
    static PICKER_HOVER_ROW: AtomicI32 = AtomicI32::new(-1);
    static CANONICAL_SEQUENCE: AtomicUsize = AtomicUsize::new(0);
    static MAIN_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static RENDER_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static INPUT_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static BUBBLE_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static MENU_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static SUBMENU_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static CHARACTER_PICKER_WINDOW: AtomicIsize = AtomicIsize::new(0);
    static MENU_ACTIVE: AtomicBool = AtomicBool::new(false);
    // Recomputed after every native move. A popup with no non-overlapping
    // work-area placement stays hidden instead of covering the drag target.
    static MENU_DRAG_SAFE: AtomicBool = AtomicBool::new(true);
    static SUBMENU_DRAG_SAFE: AtomicBool = AtomicBool::new(true);
    static RENDER_HOST_LOGGED: AtomicBool = AtomicBool::new(false);
    static HANDOFF_EVENT_SEQUENCE: AtomicUsize = AtomicUsize::new(0);
    static LAST_MOVE_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static LAST_BUBBLE_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static LAST_AUX_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static LAST_VISIBILITY_GENERATION: AtomicIsize = AtomicIsize::new(-1);
    static RUNTIME_VISIBILITY_DESIRED: AtomicBool = AtomicBool::new(true);
    static CANONICAL_SURFACE_REVEALED: AtomicBool = AtomicBool::new(false);
    static LAST_ANCHOR_SEQUENCE: AtomicIsize = AtomicIsize::new(-1);
    static PRESENTATION_ANCHOR_X: AtomicU32 = AtomicU32::new(0x3f00_0000);
    static PRESENTATION_ANCHOR_Y: AtomicU32 = AtomicU32::new(0x3f80_0000);
    static INITIAL_FALLBACK_PLACED: AtomicBool = AtomicBool::new(false);
    static INITIAL_CANONICAL_REVEAL_PENDING: AtomicBool = AtomicBool::new(true);
    static BUBBLE_TEXT: OnceLock<Mutex<String>> = OnceLock::new();
    static BUBBLE_STYLE: OnceLock<Mutex<String>> = OnceLock::new();
    static BUBBLE_FONT: OnceLock<Mutex<String>> = OnceLock::new();
    static TEXT_SCALE: OnceLock<Mutex<f64>> = OnceLock::new();
    type SvgIconCache = HashMap<(String, i32, Dword), CachedSvgIcon>;
    static SVG_ICON_CACHE: OnceLock<Mutex<SvgIconCache>> = OnceLock::new();
    static BUBBLE_UNTIL: OnceLock<Mutex<Option<std::time::Instant>>> = OnceLock::new();
    static HOVER_LEAVE_AT: OnceLock<Mutex<Option<std::time::Instant>>> = OnceLock::new();
    static RUNTIME_HITBOX: OnceLock<Mutex<Option<NormalizedHitbox>>> = OnceLock::new();

    fn theme_name(index: usize) -> &'static str {
        match index % 3 {
            0 => "Solid",
            1 => "Glass",
            _ => "Liquid",
        }
    }

    unsafe fn register_bundled_ocp_font() {
        let Ok(path) = std::env::var("OCP_BUNDLED_FONT_PATH") else {
            return;
        };
        if path.trim().is_empty() {
            return;
        }
        let mut wide: Vec<u16> = path.encode_utf16().collect();
        wide.push(0);
        let loaded = AddFontResourceExW(wide.as_ptr(), FR_PRIVATE, null_mut());
        if loaded > 0 {
            println!(
                "[native-spike] phase=font-register family=Noto Sans Thai loaded={} path={}",
                loaded, path
            );
        } else {
            eprintln!(
                "[native-spike] phase=font-register-degraded family=Noto Sans Thai path={}",
                path
            );
        }
    }

    fn current_text_scale() -> f64 {
        TEXT_SCALE
            .get()
            .and_then(|lock| lock.lock().ok().map(|value| *value))
            .unwrap_or(1.15)
            .clamp(1.0, 1.80)
    }

    fn theme_palette(index: usize) -> (u32, u32, u32, u32, u32) {
        // COLORREF is BGR: menu, submenu, text, accent, hover.
        // Keep native hover UI in the same dark-navy/cyan family as the
        // Godot Control Center instead of the old diagnostic brown/purple set.
        match index % 3 {
            1 => (0x00361F10, 0x00261409, 0x00FFFFFF, 0x00FF9D4B, 0x00543318),
            2 => (0x00381A07, 0x00281404, 0x00FFF8F4, 0x00EEB928, 0x005A3A0D),
            _ => (0x00271811, 0x001E120B, 0x00FFFFFF, 0x00E17D2F, 0x00452C17),
        }
    }

    fn theme_alpha(index: usize) -> u8 {
        match index % 3 {
            1 => 224,
            2 => 236,
            _ => 255,
        }
    }

    unsafe fn apply_native_theme_transparency() {
        let alpha = theme_alpha(THEME_INDEX.load(Ordering::Relaxed));
        for hwnd in [
            MENU_WINDOW.load(Ordering::Relaxed),
            SUBMENU_WINDOW.load(Ordering::Relaxed),
            CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed),
        ] {
            if hwnd == 0 {
                continue;
            }
            // These auxiliary surfaces paint their whole client area. Keep one
            // alpha-only layered-window contract for Solid/Glass/Liquid instead
            // of switching Solid through a magenta color key. The old mode
            // transition could briefly expose #FF00FF during hover reveal.
            SetLayeredWindowAttributes(hwnd, 0, alpha, LWA_ALPHA);
        }
    }

    #[repr(C)]
    struct Point {
        x: i32,
        y: i32,
    }
    #[derive(Clone, Copy)]
    #[repr(C)]
    struct Rect {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    }
    #[repr(C)]
    struct Msg {
        hwnd: Hwnd,
        message: Uint,
        w_param: Wparam,
        l_param: Lparam,
        time: Dword,
        pt: Point,
        private: Dword,
    }
    #[repr(C)]
    struct PaintStruct {
        hdc: isize,
        erase: Bool,
        paint: Rect,
        restore: Bool,
        inc_update: Bool,
        reserved: [u8; 32],
    }
    #[repr(C)]
    struct MonitorInfo {
        size: Dword,
        monitor: Rect,
        work: Rect,
        flags: Dword,
    }
    #[repr(C)]
    struct TrackMouseEventData {
        size: Dword,
        flags: Dword,
        hwnd_track: Hwnd,
        hover_time: Dword,
    }
    #[repr(C)]
    struct BitmapInfoHeader {
        size: Dword,
        width: i32,
        height: i32,
        planes: u16,
        bit_count: u16,
        compression: Dword,
        size_image: Dword,
        x_pels_per_meter: i32,
        y_pels_per_meter: i32,
        clr_used: Dword,
        clr_important: Dword,
    }
    #[repr(C)]
    struct BitmapInfo {
        header: BitmapInfoHeader,
        colors: [Dword; 1],
    }
    #[repr(C)]
    struct BlendFunction {
        blend_op: u8,
        blend_flags: u8,
        source_constant_alpha: u8,
        alpha_format: u8,
    }
    #[derive(Clone, Copy)]
    struct CachedSvgIcon {
        bitmap: isize,
        size: i32,
    }
    #[repr(C)]
    struct WndClassW {
        style: Uint,
        wnd_proc: Option<unsafe extern "system" fn(Hwnd, Uint, Wparam, Lparam) -> Lresult>,
        class_extra: i32,
        window_extra: i32,
        instance: Hinstance,
        icon: isize,
        cursor: Hcursor,
        background: Hbrush,
        menu_name: *const u16,
        class_name: *const u16,
    }

    #[link(name = "user32")]
    extern "system" {
        fn BeginPaint(hwnd: Hwnd, paint: *mut PaintStruct) -> isize;
        fn CreateWindowExW(
            ex_style: Dword,
            class_name: *const u16,
            title: *const u16,
            style: Dword,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            parent: Hwnd,
            menu: isize,
            instance: Hinstance,
            param: *const c_void,
        ) -> Hwnd;
        fn CreateRoundRectRgn(
            left: i32,
            top: i32,
            right: i32,
            bottom: i32,
            ellipse_width: i32,
            ellipse_height: i32,
        ) -> isize;
        fn DefWindowProcW(hwnd: Hwnd, message: Uint, w_param: Wparam, l_param: Lparam) -> Lresult;
        fn DestroyWindow(hwnd: Hwnd) -> Bool;
        fn DispatchMessageW(message: *const Msg) -> Lresult;
        fn EnumDisplayMonitors(
            hdc: isize,
            clip: *const Rect,
            callback: Option<unsafe extern "system" fn(Hmonitor, isize, *mut Rect, Lparam) -> Bool>,
            data: Lparam,
        ) -> Bool;
        fn EndPaint(hwnd: Hwnd, paint: *const PaintStruct) -> Bool;
        fn FillRect(hdc: isize, rect: *const Rect, brush: Hbrush) -> i32;
        fn GetClientRect(hwnd: Hwnd, rect: *mut Rect) -> Bool;
        fn GetCursorPos(point: *mut Point) -> Bool;
        fn GetForegroundWindow() -> Hwnd;
        fn GetDpiForWindow(hwnd: Hwnd) -> Uint;
        fn GetAwarenessFromDpiAwarenessContext(value: isize) -> i32;
        fn GetThreadDpiAwarenessContext() -> isize;
        fn GetWindowDpiAwarenessContext(hwnd: Hwnd) -> isize;
        fn GetMonitorInfoW(monitor: Hmonitor, info: *mut MonitorInfo) -> Bool;
        fn GetWindowLongPtrW(hwnd: Hwnd, index: i32) -> isize;
        fn GetWindowRect(hwnd: Hwnd, rect: *mut Rect) -> Bool;
        fn IsWindowVisible(hwnd: Hwnd) -> Bool;
        fn KillTimer(hwnd: Hwnd, id: usize) -> Bool;
        fn LoadCursorW(instance: Hinstance, cursor_name: *const u16) -> Hcursor;
        fn MonitorFromWindow(hwnd: Hwnd, flags: Dword) -> Hmonitor;
        fn PeekMessageW(message: *mut Msg, hwnd: Hwnd, min: Uint, max: Uint, remove: Uint) -> Bool;
        fn PostQuitMessage(exit_code: i32);
        fn RegisterClassW(class: *const WndClassW) -> u16;
        fn RegisterHotKey(hwnd: Hwnd, id: i32, modifiers: Uint, key: Uint) -> Bool;
        fn ReleaseCapture() -> Bool;
        fn SetCapture(hwnd: Hwnd) -> Hwnd;
        fn SetLayeredWindowAttributes(
            hwnd: Hwnd,
            color_key: Dword,
            alpha: u8,
            flags: Dword,
        ) -> Bool;
        fn SetProcessDpiAwarenessContext(value: isize) -> Bool;
        fn SetParent(child: Hwnd, parent: Hwnd) -> Hwnd;
        fn SetWindowLongPtrW(hwnd: Hwnd, index: i32, value: isize) -> isize;
        fn SetWindowTextW(hwnd: Hwnd, text: *const u16) -> Bool;
        fn EnableWindow(hwnd: Hwnd, enable: Bool) -> Bool;
        fn InvalidateRect(hwnd: Hwnd, rect: *const Rect, erase: Bool) -> Bool;
        fn UpdateWindow(hwnd: Hwnd) -> Bool;
        fn DrawTextW(
            hdc: isize,
            text: *const u16,
            count: i32,
            rect: *mut Rect,
            format: Uint,
        ) -> i32;
        fn SetBkMode(hdc: isize, mode: i32) -> i32;
        fn SetTextColor(hdc: isize, color: Dword) -> Dword;
        fn SelectObject(hdc: isize, object: isize) -> isize;
        fn CreateFontW(
            height: i32,
            width: i32,
            escapement: i32,
            orientation: i32,
            weight: i32,
            italic: u32,
            underline: u32,
            strikeout: u32,
            charset: u32,
            output_precision: u32,
            clip_precision: u32,
            quality: u32,
            pitch_and_family: u32,
            face: *const u16,
        ) -> Hfont;
        fn SetWindowPos(
            hwnd: Hwnd,
            insert_after: Hwnd,
            x: i32,
            y: i32,
            width: i32,
            height: i32,
            flags: Uint,
        ) -> Bool;
        fn SetWindowRgn(hwnd: Hwnd, region: isize, redraw: Bool) -> i32;
        fn SetTimer(hwnd: Hwnd, id: usize, milliseconds: Uint, callback: isize) -> usize;
        fn ShowWindow(hwnd: Hwnd, command: i32) -> Bool;
        fn TrackMouseEvent(event: *mut TrackMouseEventData) -> Bool;
        fn TranslateMessage(message: *const Msg) -> Bool;
        fn UnregisterHotKey(hwnd: Hwnd, id: i32) -> Bool;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetModuleHandleW(name: *const u16) -> Hinstance;
    }
    #[link(name = "gdi32")]
    extern "system" {
        fn AddFontResourceExW(name: *const u16, flags: Dword, reserved: *mut c_void) -> i32;
        fn CreateCompatibleDC(hdc: isize) -> isize;
        fn CreateDIBSection(
            hdc: isize,
            info: *const BitmapInfo,
            usage: Uint,
            bits: *mut *mut c_void,
            section: isize,
            offset: Dword,
        ) -> isize;
        fn CreatePen(style: i32, width: i32, color: Dword) -> isize;
        fn CreateSolidBrush(color: Dword) -> Hbrush;
        fn DeleteDC(hdc: isize) -> Bool;
        fn DeleteObject(object: isize) -> Bool;
        fn Ellipse(hdc: isize, left: i32, top: i32, right: i32, bottom: i32) -> Bool;
        fn GetStockObject(object: i32) -> isize;
        fn LineTo(hdc: isize, x: i32, y: i32) -> Bool;
        fn MoveToEx(hdc: isize, x: i32, y: i32, previous: *mut Point) -> Bool;
        fn Polygon(hdc: isize, points: *const Point, count: i32) -> Bool;
        fn RoundRect(
            hdc: isize,
            left: i32,
            top: i32,
            right: i32,
            bottom: i32,
            width: i32,
            height: i32,
        ) -> Bool;
    }
    #[link(name = "msimg32")]
    extern "system" {
        fn AlphaBlend(
            destination: isize,
            destination_x: i32,
            destination_y: i32,
            destination_width: i32,
            destination_height: i32,
            source: isize,
            source_x: i32,
            source_y: i32,
            source_width: i32,
            source_height: i32,
            blend: BlendFunction,
        ) -> Bool;
    }
    #[link(name = "shcore")]
    extern "system" {
        fn GetDpiForMonitor(monitor: Hmonitor, dpi_type: i32, x: *mut Uint, y: *mut Uint) -> i32;
    }
    #[link(name = "dwmapi")]
    extern "system" {
        fn DwmSetWindowAttribute(
            hwnd: Hwnd,
            attribute: Dword,
            value: *const c_void,
            value_size: Dword,
        ) -> i32;
    }

    unsafe extern "system" fn window_proc(
        hwnd: Hwnd,
        message: Uint,
        w_param: Wparam,
        l_param: Lparam,
    ) -> Lresult {
        match message {
            WM_ERASEBKGND
                if hwnd == MENU_WINDOW.load(Ordering::Relaxed)
                    || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
                    || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed) =>
            {
                // Auxiliary windows repaint the entire invalid region themselves.
                // Suppress the default background erase so a hover transition
                // cannot expose a blank layered-window frame before WM_PAINT.
                1
            }
            WM_PAINT => {
                paint(hwnd);
                0
            }
            WM_SHOWWINDOW if hwnd == MAIN_WINDOW.load(Ordering::Relaxed) => {
                // Win+D and Windows' own minimize/restore path can hide and
                // show the controller without a Runtime event. Only re-arm a
                // surface that Runtime still wants visible and that has
                // already received a canonical placement; Hide-to-Tray keeps
                // the desired flag false and is never resurrected here.
                if w_param != 0
                    && RUNTIME_VISIBILITY_DESIRED.load(Ordering::Relaxed)
                    && CANONICAL_SURFACE_REVEALED.load(Ordering::Relaxed)
                    && !CANONICAL_APPLYING.load(Ordering::Relaxed)
                {
                    sync_render_window_to_controller(hwnd);
                    let render = RENDER_WINDOW.load(Ordering::Relaxed);
                    if render != 0 && IsWindowVisible(render) == 0 {
                        ShowWindow(render, SW_SHOWNOACTIVATE);
                    }
                    sync_input_proxy_visibility();
                    println!("[native-spike] phase=os-visibility-rearmed source=wm-showwindow");
                }
                0
            }
            WM_MOVE => {
                if hwnd == MAIN_WINDOW.load(Ordering::Relaxed)
                    && !DRAG_ACTIVE.load(Ordering::Relaxed)
                {
                    log_placement(hwnd, "move");
                    reposition_auxiliary_windows(hwnd);
                }
                0
            }
            WM_ENTERSIZEMOVE => {
                DRAG_ACTIVE.store(true, Ordering::Relaxed);
                suppress_hover_for_drag(hwnd);
                log_drag_event(hwnd, "drag-begin");
                0
            }
            WM_EXITSIZEMOVE => {
                log_drag_event(hwnd, "drag-end");
                DRAG_ACTIVE.store(false, Ordering::Relaxed);
                reposition_auxiliary_windows(hwnd);
                0
            }
            WM_LBUTTONDOWN if is_drag_input_window(hwnd) => {
                let owner = MAIN_WINDOW.load(Ordering::Relaxed);
                let mut cursor = Point { x: 0, y: 0 };
                let mut rect: Rect = std::mem::zeroed();
                if GetCursorPos(&mut cursor) != 0
                    && cursor_in_visual_hitbox(owner, &cursor)
                    && GetWindowRect(owner, &mut rect) != 0
                {
                    DRAG_OFFSET_X.store(cursor.x - rect.left, Ordering::Relaxed);
                    DRAG_OFFSET_Y.store(cursor.y - rect.top, Ordering::Relaxed);
                    DRAG_ACTIVE.store(true, Ordering::Relaxed);
                    SetCapture(hwnd);
                    suppress_hover_for_drag(owner);
                    log_drag_event(owner, "drag-begin");
                }
                0
            }
            WM_MOUSEMOVE if is_drag_input_window(hwnd) && DRAG_ACTIVE.load(Ordering::Relaxed) => {
                let owner = MAIN_WINDOW.load(Ordering::Relaxed);
                let mut cursor = Point { x: 0, y: 0 };
                let mut rect: Rect = std::mem::zeroed();
                if GetCursorPos(&mut cursor) != 0 && GetWindowRect(owner, &mut rect) != 0 {
                    SetWindowPos(
                        owner,
                        HWND_TOPMOST,
                        cursor.x - DRAG_OFFSET_X.load(Ordering::Relaxed),
                        cursor.y - DRAG_OFFSET_Y.load(Ordering::Relaxed),
                        rect.right - rect.left,
                        rect.bottom - rect.top,
                        SWP_NOACTIVATE,
                    );
                    reposition_auxiliary_windows(owner);
                }
                0
            }
            WM_LBUTTONUP if is_drag_input_window(hwnd) => {
                finish_explicit_drag(MAIN_WINDOW.load(Ordering::Relaxed), "input-release");
                0
            }
            WM_CAPTURECHANGED
                if is_drag_input_window(hwnd) && DRAG_ACTIVE.load(Ordering::Relaxed) =>
            {
                finish_explicit_drag(MAIN_WINDOW.load(Ordering::Relaxed), "capture-changed");
                0
            }
            WM_MOUSEMOVE | WM_NCMOUSEMOVE
                if hwnd == MAIN_WINDOW.load(Ordering::Relaxed)
                    || hwnd == MENU_WINDOW.load(Ordering::Relaxed)
                    || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
                    || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed) =>
            {
                track_mouse_leave(hwnd, message == WM_NCMOUSEMOVE);
                KillTimer(MAIN_WINDOW.load(Ordering::Relaxed), HOVER_CLOSE_TIMER);
                if message == WM_MOUSEMOVE {
                    update_hover_item(
                        hwnd,
                        (l_param as i16) as i32,
                        ((l_param >> 16) as i16) as i32,
                    );
                }
                if hwnd == MAIN_WINDOW.load(Ordering::Relaxed) {
                    if DRAG_ACTIVE.load(Ordering::Relaxed)
                        || HOVER_REARM_REQUIRED.load(Ordering::Relaxed)
                    {
                        return 0;
                    }
                    set_auxiliary_visibility(
                        MAIN_WINDOW.load(Ordering::Relaxed),
                        MENU_WINDOW.load(Ordering::Relaxed),
                        "menu",
                        true,
                        "hover-enter",
                    );
                }
                0
            }
            WM_LBUTTONUP if hwnd == MENU_WINDOW.load(Ordering::Relaxed) => {
                let x = (l_param as i16) as i32;
                let y = ((l_param >> 16) as i16) as i32;
                let Some(row) = auxiliary_item_at(hwnd, x, y) else {
                    return 0;
                };
                if let Some(submenu_mode) = hover_menu_submenu_mode(row) {
                    SUBMENU_MODE.store(submenu_mode, Ordering::Relaxed);
                    // The two submenu modes have different geometry. Reflow
                    // even when the submenu is already visible and the user
                    // moves directly between Actions and Size.
                    reposition_auxiliary_windows(MAIN_WINDOW.load(Ordering::Relaxed));
                    InvalidateRect(SUBMENU_WINDOW.load(Ordering::Relaxed), null(), 0);
                    InvalidateRect(MENU_WINDOW.load(Ordering::Relaxed), null(), 0);
                    set_auxiliary_visibility(
                        MAIN_WINDOW.load(Ordering::Relaxed),
                        SUBMENU_WINDOW.load(Ordering::Relaxed),
                        "submenu",
                        true,
                        "menu-click",
                    );
                    MENU_ACTIVE.store(true, Ordering::Relaxed);
                    write_native_event(hwnd, "menu-submenu", None);
                } else {
                    // A menu action owns the next UI transition. Close the
                    // current menu before opening a picker or bubble so the
                    // two auxiliary surfaces cannot stack over one another.
                    ShowWindow(MENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
                    ShowWindow(SUBMENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
                    sync_input_proxy_visibility();
                    sync_aura_timer();
                    if let Some(item) = hover_menu_primary_action(row) {
                        write_native_event_with_item(hwnd, "menu-click", item);
                    }
                }
                0
            }
            WM_LBUTTONUP if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) => {
                let x = (l_param as i16) as i32;
                let y = ((l_param >> 16) as i16) as i32;
                let Some(row) = auxiliary_item_at(hwnd, x, y) else {
                    return 0;
                };
                if let Some(item) =
                    hover_menu_submenu_action(SUBMENU_MODE.load(Ordering::Relaxed), row)
                {
                    write_native_event_with_item(hwnd, "submenu-click", item);
                }
                0
            }
            WM_LBUTTONUP if hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed) => {
                let x = (l_param as i16) as i32;
                let y = ((l_param >> 16) as i16) as i32;
                let Some(row) = auxiliary_item_at(hwnd, x, y) else {
                    return 0;
                };
                let item = match row {
                    0 => "character.meowsom",
                    1 => "character.scifi_woman",
                    2 => "character.bible",
                    _ => "close",
                };
                ShowWindow(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed), SW_HIDE);
                sync_input_proxy_visibility();
                sync_aura_timer();
                write_native_event_with_item(hwnd, "character-select", item);
                0
            }
            WM_MOUSELEAVE | WM_NCMOUSELEAVE
                if hwnd == MAIN_WINDOW.load(Ordering::Relaxed)
                    || hwnd == MENU_WINDOW.load(Ordering::Relaxed)
                    || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
                    || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed) =>
            {
                update_hover_item(hwnd, -1, -1);
                SetTimer(
                    MAIN_WINDOW.load(Ordering::Relaxed),
                    HOVER_CLOSE_TIMER,
                    900,
                    0,
                );
                0
            }
            WM_TIMER if w_param == HOVER_CLOSE_TIMER => {
                let mut cursor = Point { x: 0, y: 0 };
                let in_visual = GetCursorPos(&mut cursor) != 0
                    && cursor_in_visual_hitbox(MAIN_WINDOW.load(Ordering::Relaxed), &cursor);
                if !in_visual
                    && !cursor_inside_window(MENU_WINDOW.load(Ordering::Relaxed))
                    && !cursor_inside_window(SUBMENU_WINDOW.load(Ordering::Relaxed))
                    && !cursor_inside_window(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed))
                {
                    KillTimer(hwnd, HOVER_CLOSE_TIMER);
                    set_auxiliary_visibility(
                        hwnd,
                        MENU_WINDOW.load(Ordering::Relaxed),
                        "menu",
                        false,
                        "hover-leave",
                    );
                }
                0
            }
            WM_TIMER if w_param == ACTIVE_ATTACH_TIMER => {
                if ACTIVE_ATTACH.load(Ordering::Relaxed) {
                    follow_active_window(hwnd);
                }
                0
            }
            WM_TIMER if w_param == AURA_FRAME_TIMER => {
                let any_auxiliary_visible = [
                    MENU_WINDOW.load(Ordering::Relaxed),
                    SUBMENU_WINDOW.load(Ordering::Relaxed),
                    CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed),
                ]
                .into_iter()
                .any(|surface| surface != 0 && IsWindowVisible(surface) != 0);
                if any_auxiliary_visible && !REDUCED_MOTION.load(Ordering::Relaxed) {
                    AURA_FRAME.fetch_add(1, Ordering::Relaxed);
                    InvalidateRect(MENU_WINDOW.load(Ordering::Relaxed), null(), 0);
                    InvalidateRect(SUBMENU_WINDOW.load(Ordering::Relaxed), null(), 0);
                    InvalidateRect(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed), null(), 0);
                } else {
                    KillTimer(hwnd, AURA_FRAME_TIMER);
                }
                0
            }
            WM_DPICHANGED => {
                let controller = MAIN_WINDOW.load(Ordering::Relaxed);
                if controller != 0 && hwnd != controller {
                    // Do not accept Windows' per-surface suggested rectangle.
                    // It makes the transparent render and input-proxy HWNDs
                    // drift away from the controller on mixed-DPI monitors.
                    if !OWNED_SURFACE_DPI_SYNC.swap(true, Ordering::Relaxed) {
                        reposition_auxiliary_windows(controller);
                        OWNED_SURFACE_DPI_SYNC.store(false, Ordering::Relaxed);
                    }
                    log_placement(hwnd, "dpi-changed-owner-derived");
                    return 0;
                }
                if CANONICAL_APPLYING.load(Ordering::Relaxed) {
                    log_placement(hwnd, "dpi-changed-canonical-owned");
                    return 0;
                }
                let suggested = &*(l_param as *const Rect);
                // The authored canvas is 384 logical pixels. Accept Windows'
                // PMv2 suggested rectangle so it becomes 768 physical pixels
                // on a 192-DPI monitor and remains 384 on a 96-DPI monitor.
                // Godot content scaling maps the same authored canvas into the
                // resulting client rect, keeping visual size and hit testing
                // stable across monitors.
                SetWindowPos(
                    hwnd,
                    0,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    SWP_NOACTIVATE,
                );
                if controller != 0 {
                    reposition_auxiliary_windows(controller);
                }
                log_placement(hwnd, "dpi-changed");
                0
            }
            // The Godot render surface is a separate top-level transparent
            // window.  It must never win hit-testing: the alpha-sized input
            // proxy above it is the only surface allowed to start a drag.
            // Without this branch DefWindowProc returns HTCLIENT for the
            // render HWND, so clicks land on Godot and never reach the proxy.
            WM_NCHITTEST if hwnd == RENDER_WINDOW.load(Ordering::Relaxed) => HTTRANSPARENT,
            WM_NCHITTEST
                if is_drag_input_window(hwnd) && !CLICK_THROUGH.load(Ordering::Relaxed) =>
            {
                if hwnd == INPUT_WINDOW.load(Ordering::Relaxed) {
                    return HTCLIENT;
                }
                let mut cursor = Point { x: 0, y: 0 };
                if GetCursorPos(&mut cursor) != 0 && cursor_in_visual_hitbox(hwnd, &cursor) {
                    HTCLIENT
                } else {
                    // Only the visible character is interactive. The rest of
                    // the native host must let desktop icons and applications
                    // receive the pointer normally.
                    HTTRANSPARENT
                }
            }
            WM_MOUSEACTIVATE if is_drag_input_window(hwnd) => MA_NOACTIVATE,
            WM_HOTKEY if w_param as i32 == HOTKEY_CLICK_THROUGH => {
                toggle_click_through(hwnd);
                0
            }
            WM_HOTKEY if w_param as i32 == HOTKEY_QUIT => {
                // In production handoff mode, Ctrl+Alt+Q must use the same
                // shutdown handshake as the hover-menu Exit action. Destroying
                // the native controller directly leaves Godot alive because it
                // never receives system.shutting_down / detach-request.
                if handoff_event_path().is_some() {
                    write_native_event_with_item(hwnd, "menu-click", "exit");
                } else {
                    // Standalone spike/dev mode has no Godot lifecycle peer.
                    DestroyWindow(hwnd);
                }
                0
            }
            WM_HOTKEY if w_param as i32 == HOTKEY_CANONICAL_NEXT => {
                apply_next_canonical_position(hwnd);
                0
            }
            WM_HOTKEY if w_param as i32 == HOTKEY_BUBBLE => {
                toggle_auxiliary(hwnd, BUBBLE_WINDOW.load(Ordering::Relaxed), "bubble");
                0
            }
            WM_HOTKEY if w_param as i32 == HOTKEY_MENU => {
                toggle_auxiliary(hwnd, MENU_WINDOW.load(Ordering::Relaxed), "menu");
                0
            }
            WM_HOTKEY if w_param as i32 == HOTKEY_ACTIVE_ATTACH => {
                toggle_active_attachment(hwnd);
                0
            }
            WM_DESTROY => {
                if hwnd == MAIN_WINDOW.load(Ordering::Relaxed) {
                    PostQuitMessage(0);
                }
                0
            }
            _ => DefWindowProcW(hwnd, message, w_param, l_param),
        }
    }

    unsafe fn fill_colored_rect(hdc: isize, rect: &Rect, color: Dword) {
        let brush = CreateSolidBrush(color);
        FillRect(hdc, rect, brush);
        DeleteObject(brush);
    }

    /// Minimal Aura treatment: movement is carried by one small indicator,
    /// never by a box around every menu row. This keeps the popup readable
    /// while retaining a live cue for the item under the pointer.
    unsafe fn draw_aurora_accent_bar(
        hdc: isize,
        rect: Rect,
        cyan: Dword,
        violet: Dword,
        thickness: i32,
    ) {
        // Pointer hover is an interaction-state cue, not an ambient aura.
        // Keep it on the stable primary accent so Liquid/Glass themes never
        // flash through the violet/pink secondary accent while the pointer moves.
        let color = hover_accent_color(cyan, violet);
        let thickness = thickness.max(2);
        let indicator = Rect {
            left: rect.left,
            top: rect.top + thickness,
            right: (rect.left + thickness).min(rect.right),
            bottom: (rect.bottom - thickness).max(rect.top),
        };
        fill_colored_rect(hdc, &indicator, color);
    }

    fn lucide_svg_asset(label: &str) -> Option<&'static [u8]> {
        let asset: &'static [u8] = match label {
            "Actions" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/actions.svg"
            )),
            "Size" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/size.svg"
            )),
            "Sound" | "Unmute all" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/sound.svg"
            )),
            "Mute all" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/mute.svg"
            )),
            "Character SFX" | "Character SFX off" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/character-sfx.svg"
            )),
            "Chat" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/chat.svg"
            )),
            "Bubble Test" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/bubble.svg"
            )),
            "Open OCP" | "Settings" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/open-ocp.svg"
            )),
            "Change Character" | "Meowsom" | "SciFi Woman" | "Bible" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/character.svg"
            )),
            "Hide to Tray" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/hide-to-tray.svg"
            )),
            "Exit" | "Close" => include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apps/desktop-runtime/godot/assets/icons/exit.svg"
            )),
            _ => return None,
        };
        Some(asset)
    }

    fn svg_color_hex(color: Dword) -> String {
        format!(
            "#{:02X}{:02X}{:02X}",
            color & 0xff,
            (color >> 8) & 0xff,
            (color >> 16) & 0xff
        )
    }

    unsafe fn rasterize_lucide_svg(
        hdc: isize,
        label: &str,
        physical_size: i32,
        color: Dword,
    ) -> Option<CachedSvgIcon> {
        let source = lucide_svg_asset(label)?;
        let source = std::str::from_utf8(source).ok()?;
        let tinted = source.replace("currentColor", &svg_color_hex(color));
        let tree = usvg::Tree::from_data(tinted.as_bytes(), &usvg::Options::default()).ok()?;
        let size = physical_size.max(12) as u32;
        let mut pixmap = tiny_skia::Pixmap::new(size, size)?;
        let source_size = tree.size();
        let scale = (size as f32 / source_size.width()).min(size as f32 / source_size.height());
        resvg::render(
            &tree,
            tiny_skia::Transform::from_scale(scale, scale),
            &mut pixmap.as_mut(),
        );

        // tiny-skia produces premultiplied RGBA; GDI AlphaBlend requires the
        // same premultiplied bytes in BGRA order on little-endian Windows.
        let mut pixels = pixmap.data().to_vec();
        for pixel in pixels.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
        let info = BitmapInfo {
            header: BitmapInfoHeader {
                size: size_of::<BitmapInfoHeader>() as Dword,
                width: size as i32,
                height: -(size as i32),
                planes: 1,
                bit_count: 32,
                compression: 0,
                size_image: (size * size * 4) as Dword,
                x_pels_per_meter: 0,
                y_pels_per_meter: 0,
                clr_used: 0,
                clr_important: 0,
            },
            colors: [0],
        };
        let mut destination: *mut c_void = null_mut();
        let bitmap = CreateDIBSection(hdc, &info, DIB_RGB_COLORS, &mut destination, 0, 0);
        if bitmap == 0 || destination.is_null() {
            return None;
        }
        std::ptr::copy_nonoverlapping(pixels.as_ptr(), destination.cast::<u8>(), pixels.len());
        Some(CachedSvgIcon {
            bitmap,
            size: size as i32,
        })
    }

    unsafe fn draw_lucide_svg_icon(hdc: isize, label: &str, rect: Rect, color: Dword) -> bool {
        let size = (rect.right - rect.left).min(rect.bottom - rect.top).max(12);
        let key = (label.to_owned(), size, color);
        let bitmap = {
            let cache = SVG_ICON_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
            let Ok(mut cache) = cache.lock() else {
                return false;
            };
            if let Some(icon) = cache.get(&key) {
                *icon
            } else {
                let Some(icon) = rasterize_lucide_svg(hdc, label, size, color) else {
                    return false;
                };
                cache.insert(key, icon);
                icon
            }
        };
        let source = CreateCompatibleDC(hdc);
        if source == 0 {
            return false;
        }
        let previous = SelectObject(source, bitmap.bitmap);
        let x = rect.left + ((rect.right - rect.left - bitmap.size) / 2).max(0);
        let y = rect.top + ((rect.bottom - rect.top - bitmap.size) / 2).max(0);
        let drawn = AlphaBlend(
            hdc,
            x,
            y,
            bitmap.size,
            bitmap.size,
            source,
            0,
            0,
            bitmap.size,
            bitmap.size,
            BlendFunction {
                blend_op: AC_SRC_OVER,
                blend_flags: 0,
                source_constant_alpha: 255,
                alpha_format: AC_SRC_ALPHA,
            },
        ) != 0;
        SelectObject(source, previous);
        DeleteDC(source);
        drawn
    }

    unsafe fn draw_gdi_line(hdc: isize, from: Point, to: Point, color: Dword, width: i32) {
        let pen = CreatePen(PS_SOLID, width.max(1), color);
        if pen == 0 {
            return;
        }
        let previous = SelectObject(hdc, pen);
        MoveToEx(hdc, from.x, from.y, null_mut());
        LineTo(hdc, to.x, to.y);
        if previous != 0 {
            SelectObject(hdc, previous);
        }
        DeleteObject(pen);
    }

    unsafe fn draw_gdi_vector_icon(
        hdc: isize,
        label: &str,
        rect: Rect,
        color: Dword,
        active: bool,
    ) {
        // Keep a generous visual footprint at every DPI. The previous
        // five-pixel inset made the GDI symbols look needle-thin on the
        // compact ARM64 popup.
        let left = rect.left + 2;
        let top = rect.top + 3;
        let right = rect.right - 2;
        let bottom = rect.bottom - 3;
        let center_x = (left + right) / 2;
        let center_y = (top + bottom) / 2;
        let width = if active { 3 } else { 2 };
        let line = |from: Point, to: Point| draw_gdi_line(hdc, from, to, color, width);
        match label {
            "Actions" => {
                line(
                    Point {
                        x: center_x,
                        y: top,
                    },
                    Point {
                        x: center_x,
                        y: bottom,
                    },
                );
                line(
                    Point {
                        x: center_x - 5,
                        y: center_y - 5,
                    },
                    Point {
                        x: center_x + 5,
                        y: center_y + 5,
                    },
                );
                line(
                    Point {
                        x: center_x + 5,
                        y: center_y - 5,
                    },
                    Point {
                        x: center_x - 5,
                        y: center_y + 5,
                    },
                );
                line(
                    Point {
                        x: center_x - 7,
                        y: center_y,
                    },
                    Point {
                        x: center_x + 7,
                        y: center_y,
                    },
                );
            }
            "Size" => {
                line(
                    Point {
                        x: left,
                        y: top + 6,
                    },
                    Point { x: left, y: top },
                );
                line(
                    Point { x: left, y: top },
                    Point {
                        x: left + 6,
                        y: top,
                    },
                );
                line(
                    Point {
                        x: right,
                        y: top + 6,
                    },
                    Point { x: right, y: top },
                );
                line(
                    Point {
                        x: right - 6,
                        y: top,
                    },
                    Point { x: right, y: top },
                );
                line(
                    Point {
                        x: left,
                        y: bottom - 6,
                    },
                    Point { x: left, y: bottom },
                );
                line(
                    Point { x: left, y: bottom },
                    Point {
                        x: left + 6,
                        y: bottom,
                    },
                );
                line(
                    Point {
                        x: right,
                        y: bottom - 6,
                    },
                    Point {
                        x: right,
                        y: bottom,
                    },
                );
                line(
                    Point {
                        x: right - 6,
                        y: bottom,
                    },
                    Point {
                        x: right,
                        y: bottom,
                    },
                );
            }
            "Sound" | "Mute all" | "Unmute all" => {
                line(
                    Point {
                        x: left,
                        y: center_y - 4,
                    },
                    Point {
                        x: left,
                        y: center_y + 4,
                    },
                );
                line(
                    Point {
                        x: left,
                        y: center_y - 4,
                    },
                    Point {
                        x: left + 6,
                        y: top + 2,
                    },
                );
                line(
                    Point {
                        x: left,
                        y: center_y + 4,
                    },
                    Point {
                        x: left + 6,
                        y: bottom - 2,
                    },
                );
                line(
                    Point {
                        x: left + 6,
                        y: top + 2,
                    },
                    Point {
                        x: left + 6,
                        y: bottom - 2,
                    },
                );
                if label == "Mute all" {
                    line(
                        Point {
                            x: left + 10,
                            y: top + 2,
                        },
                        Point {
                            x: right,
                            y: bottom - 2,
                        },
                    );
                } else {
                    line(
                        Point {
                            x: left + 10,
                            y: center_y - 4,
                        },
                        Point {
                            x: right,
                            y: center_y - 7,
                        },
                    );
                    line(
                        Point {
                            x: left + 10,
                            y: center_y + 4,
                        },
                        Point {
                            x: right,
                            y: center_y + 7,
                        },
                    );
                }
            }
            "Chat" | "Bubble Test" => {
                let pen = CreatePen(PS_SOLID, width, color);
                let null_brush = GetStockObject(NULL_BRUSH);
                if pen != 0 && null_brush != 0 {
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, null_brush);
                    RoundRect(hdc, left, top + 2, right, bottom - 3, 5, 5);
                    SelectObject(hdc, old_brush);
                    SelectObject(hdc, old_pen);
                }
                if pen != 0 {
                    DeleteObject(pen);
                }
                line(
                    Point {
                        x: left + 7,
                        y: bottom - 3,
                    },
                    Point {
                        x: left + 4,
                        y: bottom,
                    },
                );
                line(
                    Point {
                        x: left + 9,
                        y: center_y,
                    },
                    Point {
                        x: right - 5,
                        y: center_y,
                    },
                );
            }
            "Open OCP" | "Settings" => {
                let pen = CreatePen(PS_SOLID, width, color);
                let null_brush = GetStockObject(NULL_BRUSH);
                if pen != 0 && null_brush != 0 {
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, null_brush);
                    RoundRect(hdc, left, top + 4, right - 4, bottom, 3, 3);
                    SelectObject(hdc, old_brush);
                    SelectObject(hdc, old_pen);
                }
                if pen != 0 {
                    DeleteObject(pen);
                }
                line(
                    Point {
                        x: center_x,
                        y: center_y + 2,
                    },
                    Point {
                        x: right + 1,
                        y: top - 1,
                    },
                );
                line(
                    Point {
                        x: right - 5,
                        y: top - 1,
                    },
                    Point {
                        x: right + 1,
                        y: top - 1,
                    },
                );
                line(
                    Point {
                        x: right + 1,
                        y: top - 1,
                    },
                    Point {
                        x: right + 1,
                        y: top + 5,
                    },
                );
            }
            "Change Character" => {
                let pen = CreatePen(PS_SOLID, width, color);
                let null_brush = GetStockObject(NULL_BRUSH);
                if pen != 0 && null_brush != 0 {
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, null_brush);
                    Ellipse(hdc, center_x - 4, top, center_x + 4, top + 8);
                    SelectObject(hdc, old_brush);
                    SelectObject(hdc, old_pen);
                }
                if pen != 0 {
                    DeleteObject(pen);
                }
                line(
                    Point {
                        x: center_x - 8,
                        y: bottom - 2,
                    },
                    Point {
                        x: center_x + 8,
                        y: bottom - 2,
                    },
                );
                line(
                    Point {
                        x: center_x - 8,
                        y: bottom - 2,
                    },
                    Point {
                        x: center_x - 8,
                        y: bottom - 6,
                    },
                );
                line(
                    Point {
                        x: center_x + 8,
                        y: bottom - 2,
                    },
                    Point {
                        x: center_x + 8,
                        y: bottom - 6,
                    },
                );
            }
            "Hide to Tray" => {
                line(
                    Point {
                        x: left + 2,
                        y: center_y,
                    },
                    Point {
                        x: right - 2,
                        y: center_y,
                    },
                );
                line(
                    Point {
                        x: center_x,
                        y: top + 2,
                    },
                    Point {
                        x: center_x,
                        y: bottom - 2,
                    },
                );
                line(
                    Point {
                        x: center_x,
                        y: bottom - 2,
                    },
                    Point {
                        x: center_x - 3,
                        y: bottom - 5,
                    },
                );
                line(
                    Point {
                        x: center_x,
                        y: bottom - 2,
                    },
                    Point {
                        x: center_x + 3,
                        y: bottom - 5,
                    },
                );
            }
            "Exit" | "Close" => {
                let pen = CreatePen(PS_SOLID, width, color);
                let null_brush = GetStockObject(NULL_BRUSH);
                if pen != 0 && null_brush != 0 {
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, null_brush);
                    Ellipse(hdc, center_x - 8, center_y - 8, center_x + 8, center_y + 8);
                    SelectObject(hdc, old_brush);
                    SelectObject(hdc, old_pen);
                }
                if pen != 0 {
                    DeleteObject(pen);
                }
                line(
                    Point {
                        x: center_x,
                        y: top,
                    },
                    Point {
                        x: center_x,
                        y: center_y,
                    },
                );
            }
            "Character SFX" | "Character SFX off" => {
                let pen = CreatePen(PS_SOLID, width, color);
                let null_brush = GetStockObject(NULL_BRUSH);
                if pen != 0 && null_brush != 0 {
                    let old_pen = SelectObject(hdc, pen);
                    let old_brush = SelectObject(hdc, null_brush);
                    Ellipse(hdc, center_x - 7, center_y - 7, center_x + 7, center_y + 7);
                    SelectObject(hdc, old_brush);
                    SelectObject(hdc, old_pen);
                }
                if pen != 0 {
                    DeleteObject(pen);
                }
                line(
                    Point {
                        x: center_x,
                        y: top + 2,
                    },
                    Point {
                        x: center_x,
                        y: bottom - 2,
                    },
                );
                line(
                    Point {
                        x: left + 2,
                        y: center_y,
                    },
                    Point {
                        x: right - 2,
                        y: center_y,
                    },
                );
            }
            _ => {}
        }
    }

    unsafe fn draw_gdi_toggle(hdc: isize, rect: Rect, enabled: bool, active_color: Dword) {
        let track_color = if enabled {
            active_color
        } else {
            colorref_rgb(71, 93, 127)
        };
        let brush = CreateSolidBrush(track_color);
        let null_pen = GetStockObject(NULL_PEN);
        let old_brush = SelectObject(hdc, brush);
        let old_pen = SelectObject(hdc, null_pen);
        let radius = (rect.bottom - rect.top).max(1);
        RoundRect(
            hdc,
            rect.left,
            rect.top,
            rect.right,
            rect.bottom,
            radius,
            radius,
        );
        SelectObject(hdc, old_pen);
        SelectObject(hdc, old_brush);
        DeleteObject(brush);

        let knob_size = (rect.bottom - rect.top - 6).max(4);
        let knob_left = if enabled {
            rect.right - knob_size - 3
        } else {
            rect.left + 3
        };
        let knob_brush = CreateSolidBrush(colorref_rgb(245, 249, 255));
        let old_knob_brush = SelectObject(hdc, knob_brush);
        let old_knob_pen = SelectObject(hdc, null_pen);
        Ellipse(
            hdc,
            knob_left,
            rect.top + 3,
            knob_left + knob_size,
            rect.bottom - 3,
        );
        SelectObject(hdc, old_knob_pen);
        SelectObject(hdc, old_knob_brush);
        DeleteObject(knob_brush);
    }

    fn d2d_color(color: Dword, alpha: f32) -> D2D1_COLOR_F {
        // COLORREF uses 0x00BBGGRR while Direct2D takes normalized RGB.
        D2D1_COLOR_F {
            r: f32::from((color & 0xff) as u8) / 255.0,
            g: f32::from(((color >> 8) & 0xff) as u8) / 255.0,
            b: f32::from(((color >> 16) & 0xff) as u8) / 255.0,
            a: alpha.clamp(0.0, 1.0),
        }
    }

    /// The Direct2D DC render target faults inside USER32 on the current
    /// Windows/ARM64 layered-window path (0xC000041D). Keep the production
    /// menu alive with the GDI Aura renderer there; Direct2D stays enabled by
    /// default on x86_64 and can be explicitly trialled on ARM64.
    fn direct2d_aura_enabled() -> bool {
        match std::env::var("OCP_NATIVE_DIRECT2D_AURA").ok().as_deref() {
            Some("0") | Some("false") | Some("False") => false,
            Some("1") | Some("true") | Some("True") => true,
            _ => !cfg!(target_arch = "aarch64"),
        }
    }

    fn d2d_rect(rect: Rect) -> D2D_RECT_F {
        D2D_RECT_F {
            left: rect.left as f32,
            top: rect.top as f32,
            right: rect.right as f32,
            bottom: rect.bottom as f32,
        }
    }

    fn d2d_rounded(rect: Rect, radius: f32) -> D2D1_ROUNDED_RECT {
        D2D1_ROUNDED_RECT {
            rect: d2d_rect(rect),
            radiusX: radius,
            radiusY: radius,
        }
    }

    unsafe fn draw_vector_icon(
        target: &ID2D1RenderTarget,
        label: &str,
        rect: Rect,
        color: Dword,
        active: bool,
    ) {
        let Ok(brush) =
            target.CreateSolidColorBrush(&d2d_color(color, if active { 1.0 } else { 0.82 }), None)
        else {
            return;
        };
        let no_stroke = None::<&ID2D1StrokeStyle>;
        let line = |from: Vector2, to: Vector2| {
            target.DrawLine(from, to, &brush, if active { 2.0 } else { 1.55 }, no_stroke);
        };
        let left = rect.left as f32 + 5.0;
        let top = rect.top as f32 + 4.0;
        let right = rect.right as f32 - 5.0;
        let bottom = rect.bottom as f32 - 4.0;
        let center_x = (left + right) * 0.5;
        let center_y = (top + bottom) * 0.5;
        match label {
            "Actions" => {
                line(
                    Vector2 {
                        X: center_x,
                        Y: top,
                    },
                    Vector2 {
                        X: center_x,
                        Y: bottom,
                    },
                );
                line(
                    Vector2 {
                        X: left,
                        Y: center_y,
                    },
                    Vector2 {
                        X: right,
                        Y: center_y,
                    },
                );
                line(
                    Vector2 {
                        X: left + 3.0,
                        Y: top + 3.0,
                    },
                    Vector2 {
                        X: right - 3.0,
                        Y: bottom - 3.0,
                    },
                );
                line(
                    Vector2 {
                        X: right - 3.0,
                        Y: top + 3.0,
                    },
                    Vector2 {
                        X: left + 3.0,
                        Y: bottom - 3.0,
                    },
                );
            }
            "Size" => {
                let inset = 2.0;
                line(
                    Vector2 {
                        X: left,
                        Y: top + 6.0,
                    },
                    Vector2 {
                        X: left,
                        Y: top + inset,
                    },
                );
                line(
                    Vector2 {
                        X: left,
                        Y: top + inset,
                    },
                    Vector2 {
                        X: left + 6.0,
                        Y: top + inset,
                    },
                );
                line(
                    Vector2 {
                        X: right,
                        Y: top + 6.0,
                    },
                    Vector2 {
                        X: right,
                        Y: top + inset,
                    },
                );
                line(
                    Vector2 {
                        X: right - 6.0,
                        Y: top + inset,
                    },
                    Vector2 {
                        X: right,
                        Y: top + inset,
                    },
                );
                line(
                    Vector2 {
                        X: left,
                        Y: bottom - 6.0,
                    },
                    Vector2 {
                        X: left,
                        Y: bottom - inset,
                    },
                );
                line(
                    Vector2 {
                        X: left,
                        Y: bottom - inset,
                    },
                    Vector2 {
                        X: left + 6.0,
                        Y: bottom - inset,
                    },
                );
                line(
                    Vector2 {
                        X: right,
                        Y: bottom - 6.0,
                    },
                    Vector2 {
                        X: right,
                        Y: bottom - inset,
                    },
                );
                line(
                    Vector2 {
                        X: right - 6.0,
                        Y: bottom - inset,
                    },
                    Vector2 {
                        X: right,
                        Y: bottom - inset,
                    },
                );
            }
            "Sound" | "Mute all" | "Unmute all" => {
                let body = D2D_RECT_F {
                    left,
                    top: center_y - 4.0,
                    right: left + 6.0,
                    bottom: center_y + 4.0,
                };
                target.DrawRectangle(&body, &brush, 1.6, no_stroke);
                line(
                    Vector2 {
                        X: left + 6.0,
                        Y: center_y - 4.0,
                    },
                    Vector2 {
                        X: left + 12.0,
                        Y: top + 2.0,
                    },
                );
                line(
                    Vector2 {
                        X: left + 6.0,
                        Y: center_y + 4.0,
                    },
                    Vector2 {
                        X: left + 12.0,
                        Y: bottom - 2.0,
                    },
                );
                if label == "Mute all" {
                    line(
                        Vector2 {
                            X: left + 15.0,
                            Y: top + 3.0,
                        },
                        Vector2 {
                            X: right - 1.0,
                            Y: bottom - 3.0,
                        },
                    );
                } else if label == "Unmute all" || label == "Sound" {
                    line(
                        Vector2 {
                            X: left + 15.0,
                            Y: center_y - 5.0,
                        },
                        Vector2 {
                            X: right - 1.0,
                            Y: center_y - 8.0,
                        },
                    );
                    line(
                        Vector2 {
                            X: left + 15.0,
                            Y: center_y + 5.0,
                        },
                        Vector2 {
                            X: right - 1.0,
                            Y: center_y + 8.0,
                        },
                    );
                }
            }
            "Chat" | "Bubble Test" => {
                let bubble = d2d_rounded(
                    Rect {
                        left: left as i32,
                        top: top as i32 + 1,
                        right: right as i32,
                        bottom: (bottom - 4.0) as i32,
                    },
                    4.0,
                );
                target.DrawRoundedRectangle(&bubble, &brush, 1.6, no_stroke);
                line(
                    Vector2 {
                        X: left + 8.0,
                        Y: bottom - 4.0,
                    },
                    Vector2 {
                        X: left + 5.0,
                        Y: bottom,
                    },
                );
                line(
                    Vector2 {
                        X: left + 9.0,
                        Y: center_y,
                    },
                    Vector2 {
                        X: right - 5.0,
                        Y: center_y,
                    },
                );
            }
            "Open OCP" | "Settings" => {
                let box_rect = D2D_RECT_F {
                    left,
                    top: top + 4.0,
                    right: right - 4.0,
                    bottom,
                };
                target.DrawRectangle(&box_rect, &brush, 1.5, no_stroke);
                line(
                    Vector2 {
                        X: center_x,
                        Y: center_y + 2.0,
                    },
                    Vector2 {
                        X: right + 1.0,
                        Y: top - 1.0,
                    },
                );
                line(
                    Vector2 {
                        X: right - 5.0,
                        Y: top - 1.0,
                    },
                    Vector2 {
                        X: right + 1.0,
                        Y: top - 1.0,
                    },
                );
                line(
                    Vector2 {
                        X: right + 1.0,
                        Y: top - 1.0,
                    },
                    Vector2 {
                        X: right + 1.0,
                        Y: top + 5.0,
                    },
                );
            }
            "Change Character" => {
                let head = D2D1_ELLIPSE {
                    point: Vector2 {
                        X: center_x - 3.0,
                        Y: top + 6.0,
                    },
                    radiusX: 3.5,
                    radiusY: 3.5,
                };
                target.DrawEllipse(&head, &brush, 1.5, no_stroke);
                line(
                    Vector2 {
                        X: left + 3.0,
                        Y: bottom - 2.0,
                    },
                    Vector2 {
                        X: center_x + 4.0,
                        Y: bottom - 2.0,
                    },
                );
                line(
                    Vector2 {
                        X: right - 5.0,
                        Y: top + 4.0,
                    },
                    Vector2 {
                        X: right,
                        Y: top + 4.0,
                    },
                );
                line(
                    Vector2 {
                        X: right,
                        Y: top + 4.0,
                    },
                    Vector2 {
                        X: right - 3.0,
                        Y: top + 1.0,
                    },
                );
            }
            "Hide to Tray" => {
                line(
                    Vector2 {
                        X: left + 2.0,
                        Y: center_y,
                    },
                    Vector2 {
                        X: right - 2.0,
                        Y: center_y,
                    },
                );
                line(
                    Vector2 {
                        X: center_x,
                        Y: top + 2.0,
                    },
                    Vector2 {
                        X: center_x,
                        Y: bottom - 2.0,
                    },
                );
                line(
                    Vector2 {
                        X: center_x,
                        Y: bottom - 2.0,
                    },
                    Vector2 {
                        X: center_x - 3.0,
                        Y: bottom - 5.0,
                    },
                );
                line(
                    Vector2 {
                        X: center_x,
                        Y: bottom - 2.0,
                    },
                    Vector2 {
                        X: center_x + 3.0,
                        Y: bottom - 5.0,
                    },
                );
            }
            "Exit" => {
                let ring = D2D1_ELLIPSE {
                    point: Vector2 {
                        X: center_x,
                        Y: center_y,
                    },
                    radiusX: 8.0,
                    radiusY: 8.0,
                };
                target.DrawEllipse(&ring, &brush, 1.7, no_stroke);
                line(
                    Vector2 {
                        X: center_x,
                        Y: top,
                    },
                    Vector2 {
                        X: center_x,
                        Y: center_y,
                    },
                );
            }
            "Character SFX" | "Character SFX off" => {
                let ring = D2D1_ELLIPSE {
                    point: Vector2 {
                        X: center_x,
                        Y: center_y,
                    },
                    radiusX: 7.0,
                    radiusY: 7.0,
                };
                target.DrawEllipse(&ring, &brush, 1.5, no_stroke);
                line(
                    Vector2 {
                        X: center_x,
                        Y: top + 2.0,
                    },
                    Vector2 {
                        X: center_x,
                        Y: bottom - 2.0,
                    },
                );
                line(
                    Vector2 {
                        X: left + 2.0,
                        Y: center_y,
                    },
                    Vector2 {
                        X: right - 2.0,
                        Y: center_y,
                    },
                );
            }
            _ => {}
        }
    }

    unsafe fn paint_direct2d_overlay(hwnd: Hwnd, hdc: isize, client: Rect) {
        if !direct2d_aura_enabled() {
            return;
        }
        let is_auxiliary_surface = hwnd == MENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed);
        if !is_auxiliary_surface || client.right <= client.left || client.bottom <= client.top {
            return;
        }
        let Ok(factory) =
            D2D1CreateFactory::<ID2D1Factory>(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)
        else {
            return;
        };
        let properties = D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_UNKNOWN,
                alphaMode: D2D1_ALPHA_MODE_IGNORE,
            },
            dpiX: 0.0,
            dpiY: 0.0,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        let Ok(dc_target) = factory.CreateDCRenderTarget(&properties) else {
            return;
        };
        let bounds = RECT {
            left: client.left,
            top: client.top,
            right: client.right,
            bottom: client.bottom,
        };
        if dc_target.BindDC(HDC(hdc as *mut c_void), &bounds).is_err() {
            return;
        }
        let Ok(target) = dc_target.cast::<ID2D1RenderTarget>() else {
            return;
        };
        target.BeginDraw();
        let dpi = GetDpiForWindow(hwnd).max(96);
        let (menu_color, submenu_color, text_color, accent_color, hover_color) =
            theme_palette(THEME_INDEX.load(Ordering::Relaxed));
        let secondary_accent = theme_secondary_accent(THEME_INDEX.load(Ordering::Relaxed));
        let phase = if REDUCED_MOTION.load(Ordering::Relaxed) {
            0.0
        } else {
            (AURA_FRAME.load(Ordering::Relaxed) % 120) as f32 / 120.0
        };
        let pulse = 0.45 + (phase * std::f32::consts::TAU).sin().abs() * 0.35;
        let outer = d2d_rounded(
            Rect {
                left: 2,
                top: 2,
                right: client.right - 2,
                bottom: client.bottom - 2,
            },
            logical_extent_to_physical(11, dpi) as f32,
        );
        if let Ok(glow) = target.CreateSolidColorBrush(&d2d_color(accent_color, pulse * 0.26), None)
        {
            target.DrawRoundedRectangle(
                &outer,
                &glow,
                logical_extent_to_physical(5, dpi) as f32,
                None::<&ID2D1StrokeStyle>,
            );
        }
        // The D2D layer is painted before the GDI row layer. Using the theme's
        // violet secondary accent here caused a one-frame pink/violet flash while
        // the hover menu was being revealed. Keep the transient surface border on
        // the same stable primary accent used by hovered rows.
        let stable_border_color = hover_accent_color(accent_color, secondary_accent);
        if let Ok(border) =
            target.CreateSolidColorBrush(&d2d_color(stable_border_color, 0.82), None)
        {
            target.DrawRoundedRectangle(
                &outer,
                &border,
                logical_extent_to_physical(1, dpi) as f32,
                None::<&ID2D1StrokeStyle>,
            );
        }

        let header_height = auxiliary_layout(hwnd).map(|layout| layout.0).unwrap_or(42);
        let labels = auxiliary_labels(hwnd);
        let hovered = if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
            MENU_HOVER_ROW.load(Ordering::Relaxed)
        } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
            SUBMENU_HOVER_ROW.load(Ordering::Relaxed)
        } else {
            PICKER_HOVER_ROW.load(Ordering::Relaxed)
        };
        let (_, row_height, _) =
            auxiliary_layout(hwnd).unwrap_or((header_height, 36, labels.len() as i32));
        for (index, (_, label)) in labels.iter().enumerate() {
            let row = Rect {
                left: logical_extent_to_physical(18, dpi),
                top: header_height + index as i32 * row_height,
                right: client.right - logical_extent_to_physical(8, dpi),
                bottom: header_height + (index as i32 + 1) * row_height,
            };
            let active_row = hovered == index as i32
                || (hwnd == MENU_WINDOW.load(Ordering::Relaxed)
                    && index <= 2
                    && MENU_ACTIVE.load(Ordering::Relaxed)
                    && IsWindowVisible(SUBMENU_WINDOW.load(Ordering::Relaxed)) != 0
                    && SUBMENU_MODE.load(Ordering::Relaxed) == index as i32);
            if active_row {
                let focus = d2d_rounded(
                    Rect {
                        left: row.left - 8,
                        top: row.top + 2,
                        right: row.right + 4,
                        bottom: row.bottom - 2,
                    },
                    logical_extent_to_physical(8, dpi) as f32,
                );
                if let Ok(focus_brush) =
                    target.CreateSolidColorBrush(&d2d_color(accent_color, 0.92), None)
                {
                    target.DrawRoundedRectangle(
                        &focus,
                        &focus_brush,
                        logical_extent_to_physical(1, dpi) as f32,
                        None::<&ID2D1StrokeStyle>,
                    );
                }
            }
            let icon_rect = Rect {
                left: row.left,
                top: row.top + logical_extent_to_physical(6, dpi),
                right: logical_extent_to_physical(38, dpi) - logical_extent_to_physical(4, dpi),
                bottom: row.bottom - logical_extent_to_physical(6, dpi),
            };
            // Production icons are rasterized from the embedded Lucide SVGs
            // in the GDI base pass. Retain the old Direct2D strokes only as a
            // diagnostic fallback for renderer investigations.
            if std::env::var("OCP_NATIVE_DEBUG_GDI_ICONS").is_ok() {
                draw_vector_icon(
                    &target,
                    sound_row_label(hwnd, index, label).as_str(),
                    icon_rect,
                    if label == &"Exit" {
                        colorref_rgb(255, 101, 113)
                    } else {
                        text_color
                    },
                    active_row,
                );
            }
        }

        if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            && SUBMENU_MODE.load(Ordering::Relaxed) == 2
        {
            let control_left = client.right - logical_extent_to_physical(58, dpi);
            for index in 0..2 {
                let top = header_height + index * row_height + logical_extent_to_physical(10, dpi);
                let toggle_rect = d2d_rounded(
                    Rect {
                        left: control_left,
                        top,
                        right: client.right - logical_extent_to_physical(14, dpi),
                        bottom: top + logical_extent_to_physical(24, dpi),
                    },
                    logical_extent_to_physical(12, dpi) as f32,
                );
                let is_on = if index == 0 {
                    !MASTER_SOUND_MUTED.load(Ordering::Relaxed)
                } else {
                    CHARACTER_SFX_ENABLED.load(Ordering::Relaxed)
                };
                if let Ok(track) = target.CreateSolidColorBrush(
                    &d2d_color(
                        if is_on {
                            accent_color
                        } else {
                            colorref_rgb(75, 97, 132)
                        },
                        0.92,
                    ),
                    None,
                ) {
                    target.FillRoundedRectangle(&toggle_rect, &track);
                }
                if let Ok(knob_brush) =
                    target.CreateSolidColorBrush(&d2d_color(colorref_rgb(244, 249, 255), 1.0), None)
                {
                    let center = Vector2 {
                        X: if is_on {
                            toggle_rect.rect.right - 12.0
                        } else {
                            toggle_rect.rect.left + 12.0
                        },
                        Y: (toggle_rect.rect.top + toggle_rect.rect.bottom) * 0.5,
                    };
                    let knob = D2D1_ELLIPSE {
                        point: center,
                        radiusX: 8.0,
                        radiusY: 8.0,
                    };
                    target.FillEllipse(&knob, &knob_brush);
                }
            }
        }
        let _ = target.EndDraw(None, None);
        let _ = (menu_color, submenu_color, hover_color);
    }

    unsafe fn fill_hex_badge(hdc: isize, rect: Rect, color: Dword) {
        let notch = ((rect.right - rect.left).min(rect.bottom - rect.top) / 4).max(2);
        let points = [
            Point {
                x: rect.left + notch,
                y: rect.top,
            },
            Point {
                x: rect.right - notch,
                y: rect.top,
            },
            Point {
                x: rect.right,
                y: rect.top + notch,
            },
            Point {
                x: rect.right,
                y: rect.bottom - notch,
            },
            Point {
                x: rect.right - notch,
                y: rect.bottom,
            },
            Point {
                x: rect.left + notch,
                y: rect.bottom,
            },
            Point {
                x: rect.left,
                y: rect.bottom - notch,
            },
            Point {
                x: rect.left,
                y: rect.top + notch,
            },
        ];
        let brush = CreateSolidBrush(color);
        let previous_brush = SelectObject(hdc, brush);
        let null_pen = GetStockObject(NULL_PEN);
        let previous_pen = if null_pen != 0 {
            SelectObject(hdc, null_pen)
        } else {
            0
        };
        Polygon(hdc, points.as_ptr(), points.len() as i32);
        if previous_pen != 0 {
            SelectObject(hdc, previous_pen);
        }
        SelectObject(hdc, previous_brush);
        DeleteObject(brush);
    }

    fn theme_secondary_accent(index: usize) -> Dword {
        // COLORREF is BGR. Glass/Liquid use the restrained violet edge from
        // the approved aurora mock; Solid keeps one quiet blue edge.
        match index % 3 {
            1 => 0x00F45AB1,
            2 => 0x00E96FC2,
            _ => 0x009D6BEA,
        }
    }

    fn current_ui_language() -> &'static str {
        if UI_LANGUAGE_INDEX.load(Ordering::Relaxed) == 1 {
            "th"
        } else {
            "en"
        }
    }

    fn localized_auxiliary_label(label: &str) -> &str {
        localized_hover_label(current_ui_language(), label)
    }

    fn auxiliary_visual_copy(hwnd: Hwnd) -> (&'static str, &'static str) {
        let (title, subtitle) = if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
            ("OCP Companion", "Quick actions")
        } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
            match SUBMENU_MODE.load(Ordering::Relaxed) {
                1 => ("Size", "Visual scale"),
                2 => ("Sound", "Runtime audio"),
                _ => ("Actions", "Choose a pose"),
            }
        } else {
            ("Characters", "Choose companion")
        };
        (
            localized_auxiliary_label(title),
            localized_auxiliary_label(subtitle),
        )
    }

    fn auxiliary_labels(hwnd: Hwnd) -> &'static [(&'static str, &'static str)] {
        if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
            &[
                ("", "Actions"),
                ("", "Size"),
                ("", "Sound"),
                ("", "Chat"),
                ("", "Settings"),
                ("", "Change Character"),
                ("", "Hide to Tray"),
                ("", "Exit"),
            ]
        } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
            match SUBMENU_MODE.load(Ordering::Relaxed) {
                1 => &[
                    ("", "25%"),
                    ("", "50%"),
                    ("", "75%"),
                    ("", "100%"),
                    ("", "125%"),
                ],
                2 => &[("", "Mute all"), ("", "Character SFX")],
                _ => &[("•", "Idle"), ("⌁", "Wave"), ("✦", "Think"), ("⌂", "Sit")],
            }
        } else {
            &[
                ("◉", "Meowsom"),
                ("◉", "SciFi Woman"),
                ("◉", "Bible"),
                ("×", "Close"),
            ]
        }
    }

    fn sound_row_label(hwnd: Hwnd, index: usize, fallback: &str) -> String {
        if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            && SUBMENU_MODE.load(Ordering::Relaxed) == 2
        {
            return match index {
                0 if MASTER_SOUND_MUTED.load(Ordering::Relaxed) => "Unmute all".to_owned(),
                0 => "Mute all".to_owned(),
                1 if CHARACTER_SFX_ENABLED.load(Ordering::Relaxed) => "Character SFX".to_owned(),
                1 => "Character SFX off".to_owned(),
                _ => fallback.to_owned(),
            };
        }
        fallback.to_owned()
    }

    unsafe fn paint(hwnd: Hwnd) {
        let mut paint: PaintStruct = std::mem::zeroed();
        let hdc = BeginPaint(hwnd, &mut paint);
        let mut client: Rect = std::mem::zeroed();
        GetClientRect(hwnd, &mut client);
        if hwnd == MAIN_WINDOW.load(Ordering::Relaxed)
            && !RENDER_HOST_LOGGED.swap(true, Ordering::Relaxed)
        {
            println!(
                "[native-spike] phase=render-host-ready owner=main client_size=({}, {}) virtual_overlay=false physics_committed=false",
                client.right - client.left,
                client.bottom - client.top
            );
        }
        // In the real Runtime handoff, Godot owns the entire client area. The
        // colored body is only a diagnostic placeholder for isolated spike
        // runs; painting it here creates a visible rectangle behind the sprite.
        if hwnd == MAIN_WINDOW.load(Ordering::Relaxed)
            && std::env::var_os("OCP_NATIVE_HOST_EMBED").is_some()
        {
            // Production embed mode keeps the controller HWND fully invisible.
            // Reassert alpha=0 on paint so an unexpected WM_SHOWWINDOW/style
            // transition can never expose the old magenta diagnostic surface.
            let neutral_brush = CreateSolidBrush(0x00000000);
            FillRect(hdc, &client, neutral_brush);
            DeleteObject(neutral_brush);
            SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA);
            EndPaint(hwnd, &paint);
            return;
        }
        if hwnd == INPUT_WINDOW.load(Ordering::Relaxed) {
            // The input proxy must remain non-zero alpha so Windows keeps it
            // hit-testable. Painting it magenta and then applying alpha=1 leaves
            // a faint purple rectangle on some compositors. Use neutral black
            // instead: at 1/255 global alpha it is effectively invisible while
            // preserving the proxy's drag/click contract.
            let neutral_brush = CreateSolidBrush(0x00000000);
            FillRect(hdc, &client, neutral_brush);
            DeleteObject(neutral_brush);
            EndPaint(hwnd, &paint);
            return;
        }
        // Auxiliary menus fill the complete client rect and do not need the
        // magenta color-key prepaint used by shaped bubble/controller surfaces.
        // Painting magenta first can become visible for one compositor frame
        // while a hover menu is being shown, which looks like a pink flash.
        let prepaint_is_auxiliary = hwnd == MENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed);
        let auxiliary_surface_color = if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
            theme_palette(THEME_INDEX.load(Ordering::Relaxed)).0
        } else {
            theme_palette(THEME_INDEX.load(Ordering::Relaxed)).1
        };
        let prepaint_color =
            auxiliary_prepaint_color(prepaint_is_auxiliary, auxiliary_surface_color, 0x00FF00FF);
        let key_brush = CreateSolidBrush(prepaint_color);
        FillRect(hdc, &client, key_brush);
        DeleteObject(key_brush);
        let bubble_style = BUBBLE_STYLE
            .get()
            .and_then(|lock| lock.lock().ok().map(|value| value.clone()))
            .unwrap_or_else(|| String::from("Rounded"));
        let bubble_margin = match bubble_style.to_ascii_lowercase().as_str() {
            "compact" => 2,
            "soft" => 6,
            _ => 4,
        };
        let body = if hwnd == MENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed)
        {
            Rect {
                left: 0,
                top: 0,
                right: client.right,
                bottom: client.bottom,
            }
        } else if hwnd == BUBBLE_WINDOW.load(Ordering::Relaxed) {
            Rect {
                left: bubble_margin,
                top: bubble_margin,
                right: client.right - bubble_margin,
                bottom: client.bottom - bubble_margin,
            }
        } else {
            Rect {
                left: 28,
                top: 28,
                right: client.right - 28,
                bottom: client.bottom - 28,
            }
        };
        let (menu_color, submenu_color, text_color, accent_color, _hover_color) =
            theme_palette(THEME_INDEX.load(Ordering::Relaxed));
        let secondary_accent = theme_secondary_accent(THEME_INDEX.load(Ordering::Relaxed));
        let color = if hwnd == BUBBLE_WINDOW.load(Ordering::Relaxed) {
            // COLORREF is BGR. Bubble style changes the actual native surface,
            // not only the Settings dropdown state.
            match bubble_style.to_ascii_lowercase().as_str() {
                "compact" => 0x0024150A,
                "soft" => 0x00412616,
                _ => 0x00301C10,
            }
        } else if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
            menu_color
        } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
            submenu_color
        } else {
            accent_color
        };
        let body_brush = CreateSolidBrush(color);
        FillRect(hdc, &body, body_brush);
        DeleteObject(body_brush);
        let is_auxiliary_surface = hwnd == MENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed);
        if is_auxiliary_surface {
            let header_height = auxiliary_layout(hwnd)
                .map(|layout| layout.0)
                .unwrap_or_else(|| logical_extent_to_physical(42, GetDpiForWindow(hwnd).max(96)));
            let header = Rect {
                left: body.left,
                top: body.top,
                right: body.right,
                bottom: (body.top + header_height).min(body.bottom),
            };
            let header_color = if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
                submenu_color
            } else {
                menu_color
            };
            fill_colored_rect(hdc, &header, header_color);
            let accent_rule = Rect {
                left: header.left,
                top: header
                    .bottom
                    .saturating_sub(logical_extent_to_physical(1, GetDpiForWindow(hwnd).max(96))),
                right: header.right,
                bottom: header.bottom,
            };
            fill_colored_rect(hdc, &accent_rule, colorref_rgb(39, 69, 105));
        }
        if hwnd == BUBBLE_WINDOW.load(Ordering::Relaxed) {
            if let Some(lock) = BUBBLE_TEXT.get() {
                if let Ok(text) = lock.lock() {
                    let wide: Vec<u16> = text.encode_utf16().collect();
                    let compact = bubble_style.eq_ignore_ascii_case("compact");
                    let soft = bubble_style.eq_ignore_ascii_case("soft");
                    let horizontal_padding = if compact {
                        10
                    } else if soft {
                        18
                    } else {
                        16
                    };
                    let vertical_padding = if compact {
                        6
                    } else if soft {
                        10
                    } else {
                        8
                    };
                    let mut text_rect = Rect {
                        left: horizontal_padding,
                        top: vertical_padding,
                        right: client.right - horizontal_padding,
                        bottom: client.bottom - vertical_padding,
                    };
                    let dpi = GetDpiForWindow(hwnd).max(96);
                    let base_point_size = if compact {
                        13
                    } else if soft {
                        16
                    } else {
                        15
                    };
                    let point_size =
                        ((base_point_size as f64) * current_text_scale()).round() as i32;
                    let font_height = -((point_size * dpi as i32 + 95) / 96);
                    let selected_family = BUBBLE_FONT
                        .get()
                        .and_then(|font_lock| font_lock.lock().ok().map(|value| value.clone()))
                        .unwrap_or_else(|| String::from("Noto Sans Thai"));
                    let face_name = match selected_family.to_ascii_lowercase().as_str() {
                        "noto sans thai" => "Noto Sans Thai",
                        "system" | "segoe ui" => "Segoe UI Variable",
                        "tahoma" => "Tahoma",
                        "leelawadee ui" => "Leelawadee UI",
                        "arial" => "Arial",
                        "inter" => "Inter",
                        _ => "Noto Sans Thai",
                    };
                    let face: Vec<u16> = format!("{}\0", face_name).encode_utf16().collect();
                    let font = CreateFontW(
                        font_height,
                        0,
                        0,
                        0,
                        FW_NORMAL,
                        0,
                        0,
                        0,
                        DEFAULT_CHARSET,
                        OUT_DEFAULT_PRECIS,
                        CLIP_DEFAULT_PRECIS,
                        DEFAULT_QUALITY,
                        DEFAULT_PITCH | FF_DONTCARE,
                        face.as_ptr(),
                    );
                    let previous_font = if font != 0 {
                        SelectObject(hdc, font)
                    } else {
                        0
                    };
                    SetBkMode(hdc, TRANSPARENT);
                    SetTextColor(hdc, 0x00FFFFFF);
                    DrawTextW(
                        hdc,
                        wide.as_ptr(),
                        wide.len() as i32,
                        &mut text_rect,
                        DT_CENTER | DT_VCENTER | DT_WORDBREAK,
                    );
                    if font != 0 {
                        SelectObject(hdc, previous_font);
                        DeleteObject(font);
                    }
                }
            }
        }
        if hwnd == MENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            || hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed)
        {
            let dpi = GetDpiForWindow(hwnd).max(96);
            let menu_point_size = (13.0 * current_text_scale()).round() as i32;
            let font_height = -((menu_point_size * dpi as i32 + 95) / 96);
            let selected_family = BUBBLE_FONT
                .get()
                .and_then(|lock| lock.lock().ok().map(|value| value.clone()))
                .unwrap_or_else(|| String::from("Noto Sans Thai"));
            let face_name = match selected_family.to_ascii_lowercase().as_str() {
                "noto sans thai" => "Noto Sans Thai",
                "system" | "segoe ui" => "Segoe UI Variable",
                "tahoma" => "Tahoma",
                "leelawadee ui" => "Leelawadee UI",
                "arial" => "Arial",
                "inter" => "Inter",
                _ => "Noto Sans Thai",
            };
            let face: Vec<u16> = format!("{}\0", face_name).encode_utf16().collect();
            let font = CreateFontW(
                font_height,
                0,
                0,
                0,
                FW_NORMAL,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                DEFAULT_QUALITY,
                DEFAULT_PITCH | FF_DONTCARE,
                face.as_ptr(),
            );
            let icon_face: Vec<u16> = "Segoe UI Symbol\0".encode_utf16().collect();
            let icon_point_size = (16.0 * current_text_scale()).round() as i32;
            let icon_font_height = -((icon_point_size * dpi as i32 + 95) / 96);
            let icon_font = CreateFontW(
                icon_font_height,
                0,
                0,
                0,
                FW_NORMAL,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                DEFAULT_QUALITY,
                DEFAULT_PITCH | FF_DONTCARE,
                icon_face.as_ptr(),
            );
            let header_point_size = (11.0 * current_text_scale()).round() as i32;
            let header_font_height = -((header_point_size * dpi as i32 + 95) / 96);
            let header_font = CreateFontW(
                header_font_height,
                0,
                0,
                0,
                FW_SEMIBOLD,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                DEFAULT_QUALITY,
                DEFAULT_PITCH | FF_DONTCARE,
                face.as_ptr(),
            );
            let subtitle_point_size = (9.0 * current_text_scale()).round() as i32;
            let subtitle_font_height = -((subtitle_point_size * dpi as i32 + 95) / 96);
            let subtitle_font = CreateFontW(
                subtitle_font_height,
                0,
                0,
                0,
                FW_NORMAL,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                DEFAULT_QUALITY,
                DEFAULT_PITCH | FF_DONTCARE,
                face.as_ptr(),
            );
            let previous_font = if font != 0 {
                SelectObject(hdc, font)
            } else {
                0
            };
            let (header_height, row_height, _) = auxiliary_layout(hwnd).unwrap_or_else(|| {
                (
                    logical_extent_to_physical(42, dpi),
                    logical_extent_to_physical(36, dpi),
                    0,
                )
            });
            let labels = auxiliary_labels(hwnd);
            SetBkMode(hdc, TRANSPARENT);
            let (header_title, header_subtitle) = auxiliary_visual_copy(hwnd);
            let is_primary_menu = hwnd == MENU_WINDOW.load(Ordering::Relaxed);
            let header_left =
                logical_extent_to_physical(if is_primary_menu { 56 } else { 16 }, dpi);
            if is_primary_menu {
                let badge = Rect {
                    left: logical_extent_to_physical(12, dpi),
                    top: logical_extent_to_physical(8, dpi),
                    right: logical_extent_to_physical(48, dpi),
                    bottom: (header_height - logical_extent_to_physical(8, dpi))
                        .max(logical_extent_to_physical(34, dpi)),
                };
                // Keep the primary hover menu entirely on the stable cyan/blue
                // interaction accent. The violet secondary is reserved for
                // non-transient decorative surfaces, never menu reveal/hover.
                fill_hex_badge(hdc, badge, accent_color);
                let inner_badge = Rect {
                    left: badge.left + logical_extent_to_physical(1, dpi),
                    top: badge.top + logical_extent_to_physical(1, dpi),
                    right: badge.right - logical_extent_to_physical(1, dpi),
                    bottom: badge.bottom - logical_extent_to_physical(1, dpi),
                };
                fill_hex_badge(hdc, inner_badge, menu_color);
                let mut badge_text = badge;
                let badge_wide: Vec<u16> = "OCP".encode_utf16().collect();
                if subtitle_font != 0 {
                    SelectObject(hdc, subtitle_font);
                }
                SetTextColor(hdc, 0x00F5FBFF);
                DrawTextW(
                    hdc,
                    badge_wide.as_ptr(),
                    badge_wide.len() as i32,
                    &mut badge_text,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                );
            }
            let mut header_title_rect = Rect {
                left: header_left,
                top: logical_extent_to_physical(4, dpi),
                right: client.right - header_left,
                bottom: (header_height / 2).max(logical_extent_to_physical(14, dpi)),
            };
            if header_font != 0 {
                SelectObject(hdc, header_font);
            }
            SetTextColor(hdc, 0x00F5FBFF);
            let header_title_wide: Vec<u16> = header_title.encode_utf16().collect();
            DrawTextW(
                hdc,
                header_title_wide.as_ptr(),
                header_title_wide.len() as i32,
                &mut header_title_rect,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE,
            );
            if subtitle_font != 0 {
                SelectObject(hdc, subtitle_font);
            }
            SetTextColor(hdc, 0x00B9CADB);
            let mut header_subtitle_rect = Rect {
                left: header_left,
                top: header_title_rect
                    .bottom
                    .saturating_sub(logical_extent_to_physical(1, dpi)),
                right: client.right - header_left,
                bottom: header_height,
            };
            let header_subtitle_wide: Vec<u16> = header_subtitle.encode_utf16().collect();
            DrawTextW(
                hdc,
                header_subtitle_wide.as_ptr(),
                header_subtitle_wide.len() as i32,
                &mut header_subtitle_rect,
                DT_LEFT | DT_VCENTER | DT_SINGLELINE,
            );
            if font != 0 {
                SelectObject(hdc, font);
            }
            SetTextColor(hdc, text_color);
            let row_left = logical_extent_to_physical(18, dpi);
            let row_right = logical_extent_to_physical(8, dpi);
            let hover_inset = logical_extent_to_physical(4, dpi);
            let hover_vertical_inset = logical_extent_to_physical(2, dpi);
            let icon_right = logical_extent_to_physical(38, dpi);
            let text_right = logical_extent_to_physical(10, dpi);
            let minimal_hover_color = colorref_rgb(25, 46, 75);
            let hovered = if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
                MENU_HOVER_ROW.load(Ordering::Relaxed)
            } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
                SUBMENU_HOVER_ROW.load(Ordering::Relaxed)
            } else {
                PICKER_HOVER_ROW.load(Ordering::Relaxed)
            };
            let is_size_submenu = hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
                && SUBMENU_MODE.load(Ordering::Relaxed) == 1;
            if is_size_submenu {
                let content_left = logical_extent_to_physical(12, dpi);
                let content_right = client.right - content_left;
                let card_gap = logical_extent_to_physical(4, dpi);
                let card_top = header_height + logical_extent_to_physical(6, dpi);
                let card_bottom = client.bottom - logical_extent_to_physical(8, dpi);
                let active_index = ACTIVE_PRESENTATION_SCALE_INDEX.load(Ordering::Relaxed);
                for (index, (_, label)) in labels.iter().enumerate() {
                    let segment_left = content_left
                        + ((content_right - content_left) * index as i32) / labels.len() as i32;
                    let segment_right = content_left
                        + ((content_right - content_left) * (index as i32 + 1))
                            / labels.len() as i32;
                    let card = Rect {
                        left: segment_left + card_gap / 2,
                        top: card_top,
                        right: segment_right - card_gap / 2,
                        bottom: card_bottom,
                    };
                    let selected = active_index == index as i32;
                    let under_pointer = hovered == index as i32;
                    fill_colored_rect(
                        hdc,
                        &card,
                        if selected || under_pointer {
                            minimal_hover_color
                        } else {
                            submenu_color
                        },
                    );
                    if selected || under_pointer {
                        let indicator = Rect {
                            left: card.left,
                            top: (card.bottom - logical_extent_to_physical(2, dpi)).max(card.top),
                            right: card.right,
                            bottom: card.bottom,
                        };
                        fill_colored_rect(hdc, &indicator, accent_color);
                    }
                    let mut label_rect = card;
                    let label_wide: Vec<u16> = label.encode_utf16().collect();
                    DrawTextW(
                        hdc,
                        label_wide.as_ptr(),
                        label_wide.len() as i32,
                        &mut label_rect,
                        DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                    );
                }
            } else {
                for (index, (_icon, label)) in labels.iter().enumerate() {
                    let visual_index = index;
                    let row = Rect {
                        left: row_left,
                        top: header_height + (visual_index as i32) * row_height,
                        right: client.right - row_right,
                        bottom: header_height + ((visual_index as i32) + 1) * row_height,
                    };
                    let highlight = Rect {
                        left: hover_inset,
                        top: row.top + hover_vertical_inset,
                        right: client.right - hover_inset,
                        bottom: row.bottom - hover_vertical_inset,
                    };
                    let submenu_selected = hwnd == MENU_WINDOW.load(Ordering::Relaxed)
                        && index <= 2
                        && MENU_ACTIVE.load(Ordering::Relaxed)
                        && IsWindowVisible(SUBMENU_WINDOW.load(Ordering::Relaxed)) != 0
                        && SUBMENU_MODE.load(Ordering::Relaxed) == index as i32;
                    fill_colored_rect(
                        hdc,
                        &highlight,
                        if hovered == visual_index as i32 || submenu_selected {
                            minimal_hover_color
                        } else {
                            submenu_color
                        },
                    );
                    if hovered == visual_index as i32 || submenu_selected {
                        draw_aurora_accent_bar(
                            hdc,
                            highlight,
                            accent_color,
                            secondary_accent,
                            logical_extent_to_physical(2, dpi),
                        );
                    }
                    let icon_badge = Rect {
                        left: row_left,
                        top: row.top + logical_extent_to_physical(6, dpi),
                        right: icon_right - logical_extent_to_physical(4, dpi),
                        bottom: row.bottom - logical_extent_to_physical(6, dpi),
                    };
                    let semantic_label = sound_row_label(hwnd, index, label);
                    let visible_label = localized_auxiliary_label(&semantic_label);
                    let icon_color = if label == &"Exit" || label == &"Close" {
                        colorref_rgb(255, 116, 135)
                    } else if hovered == visual_index as i32 || submenu_selected {
                        accent_color
                    } else {
                        text_color
                    };
                    if !draw_lucide_svg_icon(hdc, &semantic_label, icon_badge, icon_color) {
                        draw_gdi_vector_icon(
                            hdc,
                            &semantic_label,
                            icon_badge,
                            icon_color,
                            hovered == visual_index as i32 || submenu_selected,
                        );
                    }
                    let mut text_row = row;
                    text_row.left = icon_right;
                    text_row.right = if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
                        && SUBMENU_MODE.load(Ordering::Relaxed) == 2
                    {
                        client.right - logical_extent_to_physical(68, dpi)
                    } else {
                        client.right - logical_extent_to_physical(30, dpi)
                    };
                    let label_wide: Vec<u16> = visible_label.encode_utf16().collect();
                    DrawTextW(
                        hdc,
                        label_wide.as_ptr(),
                        label_wide.len() as i32,
                        &mut text_row,
                        DT_LEFT | DT_VCENTER | DT_SINGLELINE,
                    );
                    let has_chevron =
                        hwnd == MENU_WINDOW.load(Ordering::Relaxed) && matches!(index, 0..=2);
                    if has_chevron {
                        let mut chevron_row = row;
                        chevron_row.left = client.right - logical_extent_to_physical(34, dpi);
                        chevron_row.right = client.right - text_right;
                        let chevron_wide: Vec<u16> = "›".encode_utf16().collect();
                        DrawTextW(
                            hdc,
                            chevron_wide.as_ptr(),
                            chevron_wide.len() as i32,
                            &mut chevron_row,
                            DT_RIGHT | DT_VCENTER | DT_SINGLELINE,
                        );
                    }
                }
                if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
                    && SUBMENU_MODE.load(Ordering::Relaxed) == 2
                    && !direct2d_aura_enabled()
                {
                    let toggle_width = logical_extent_to_physical(38, dpi);
                    let toggle_height = logical_extent_to_physical(20, dpi);
                    let toggle_right = client.right - logical_extent_to_physical(14, dpi);
                    for index in 0..2 {
                        let row_top = header_height + index * row_height;
                        let toggle = Rect {
                            left: toggle_right - toggle_width,
                            top: row_top + (row_height - toggle_height) / 2,
                            right: toggle_right,
                            bottom: row_top + (row_height + toggle_height) / 2,
                        };
                        let enabled = match index {
                            0 => !MASTER_SOUND_MUTED.load(Ordering::Relaxed),
                            _ => CHARACTER_SFX_ENABLED.load(Ordering::Relaxed),
                        };
                        draw_gdi_toggle(hdc, toggle, enabled, accent_color);
                    }
                }
            }
            if font != 0 {
                SelectObject(hdc, previous_font);
                DeleteObject(font);
            }
            if icon_font != 0 {
                DeleteObject(icon_font);
            }
            if header_font != 0 {
                DeleteObject(header_font);
            }
            if subtitle_font != 0 {
                DeleteObject(subtitle_font);
            }
        }
        // Keep the GDI text path for compatibility while Direct2D owns the
        // rounded focus rings, animated Aura and vector icon layer.
        paint_direct2d_overlay(hwnd, hdc, client);
        EndPaint(hwnd, &paint);
    }

    fn handoff_path() -> Option<std::path::PathBuf> {
        std::env::var_os("OCP_NATIVE_HOST_HANDOFF_PATH").map(std::path::PathBuf::from)
    }

    fn handoff_event_path() -> Option<std::path::PathBuf> {
        std::env::var_os("OCP_NATIVE_HOST_EVENT_PATH").map(std::path::PathBuf::from)
    }

    fn handoff_command_path() -> Option<std::path::PathBuf> {
        std::env::var_os("OCP_NATIVE_HOST_COMMAND_PATH").map(std::path::PathBuf::from)
    }

    fn handoff_ui_command_path() -> Option<std::path::PathBuf> {
        std::env::var_os("OCP_NATIVE_HOST_UI_COMMAND_PATH").map(std::path::PathBuf::from)
    }

    fn handoff_bubble_path() -> Option<std::path::PathBuf> {
        std::env::var_os("OCP_NATIVE_HOST_BUBBLE_PATH").map(std::path::PathBuf::from)
    }

    // The Godot character canvas is authored in desktop logical pixels. PMv2
    // converts this extent once for the destination monitor.
    fn native_logical_window_size() -> i32 {
        std::env::var("OCP_NATIVE_HOST_SIZE")
            .ok()
            .and_then(|value| value.parse::<i32>().ok())
            .filter(|value| (128..=768).contains(value))
            .unwrap_or(DEFAULT_WINDOW_SIZE)
    }

    unsafe fn dpi_scaled(hwnd: Hwnd, logical: i32) -> i32 {
        logical_extent_to_physical(logical, GetDpiForWindow(hwnd).max(96))
    }

    unsafe fn auxiliary_layout(hwnd: Hwnd) -> Option<(i32, i32, i32)> {
        let (base_header_height, base_row_height, row_count) =
            if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
                // Keep hit-testing and drawing in lock-step with the real menu
                // model. The previous hard-coded count of 9 left one phantom
                // row of empty space after the 8 visible actions.
                (48, 32, auxiliary_labels(hwnd).len() as i32)
            } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
                match SUBMENU_MODE.load(Ordering::Relaxed) {
                    1 => (44, 48, 1),
                    2 => (48, 48, 2),
                    _ => (44, 32, 4),
                }
            } else if hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed) {
                (42, 40, 4)
            } else {
                return None;
            };
        let header_height = ((dpi_scaled(hwnd, base_header_height) as f64) * current_text_scale())
            .round()
            .max(1.0) as i32;
        let row_height = ((dpi_scaled(hwnd, base_row_height) as f64) * current_text_scale())
            .round()
            .max(1.0) as i32;
        Some((header_height, row_height, row_count))
    }

    unsafe fn auxiliary_row_at(hwnd: Hwnd, y: i32) -> Option<i32> {
        let (header_height, row_height, row_count) = auxiliary_layout(hwnd)?;
        popup_row_from_client_y(y, header_height, row_height, row_count)
    }

    unsafe fn auxiliary_item_at(hwnd: Hwnd, x: i32, y: i32) -> Option<i32> {
        if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            && SUBMENU_MODE.load(Ordering::Relaxed) == 1
        {
            let (header_height, row_height, _) = auxiliary_layout(hwnd)?;
            if y < header_height || y >= header_height + row_height {
                return None;
            }
            let dpi = GetDpiForWindow(hwnd).max(96);
            let content_left = logical_extent_to_physical(12, dpi);
            let mut client: Rect = std::mem::zeroed();
            GetClientRect(hwnd, &mut client);
            return popup_segment_from_client_x(x, content_left, client.right - content_left, 5);
        }
        auxiliary_row_at(hwnd, y)
    }

    fn visual_hitbox() -> (f32, f32, f32, f32) {
        if let Ok(hitbox) = RUNTIME_HITBOX.get_or_init(|| Mutex::new(None)).lock() {
            if let Some(value) = *hitbox {
                return value;
            }
        }
        std::env::var("OCP_NATIVE_HOST_HITBOX")
            .ok()
            .and_then(|value| {
                let values: Vec<f32> = value
                    .split(',')
                    .filter_map(|part| part.trim().parse::<f32>().ok())
                    .collect();
                if values.len() == 4 {
                    Some((
                        values[0].clamp(0.0, 1.0),
                        values[1].clamp(0.0, 1.0),
                        values[2].clamp(0.0, 1.0),
                        values[3].clamp(0.0, 1.0),
                    ))
                } else {
                    None
                }
            })
            .unwrap_or((0.08, 0.02, 0.84, 0.96))
    }

    fn json_string(payload: &str, key: &str) -> Option<String> {
        let marker = format!("\"{key}\":\"");
        let tail = payload.split(&marker).nth(1)?;
        let mut out = String::new();
        let mut escaped = false;
        for ch in tail.chars() {
            if escaped {
                out.push(match ch {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    other => other,
                });
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                return Some(out);
            } else {
                out.push(ch);
            }
        }
        None
    }

    unsafe fn apply_runtime_bubble_request() {
        let Some(path) = handoff_bubble_path() else {
            return;
        };
        let Ok(payload) = fs::read_to_string(path) else {
            return;
        };
        if !payload.contains("\"status\":\"bubble-request\"") || !payload.contains("\"token\":\"") {
            return;
        }
        let Ok(expected_token) = std::env::var("OCP_NATIVE_HOST_TOKEN") else {
            return;
        };
        let Some(token) = json_string(&payload, "token") else {
            return;
        };
        if token != expected_token {
            return;
        }
        let Some(sequence) = json_number(&payload, "sequence") else {
            return;
        };
        if LAST_BUBBLE_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
            return;
        }
        let Some(text) = json_string(&payload, "text") else {
            return;
        };
        LAST_BUBBLE_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
        let lock = BUBBLE_TEXT.get_or_init(|| Mutex::new(String::new()));
        if let Ok(mut value) = lock.lock() {
            *value = text;
        }
        if let Some(style) = json_string(&payload, "bubble_style") {
            let lock = BUBBLE_STYLE.get_or_init(|| Mutex::new(String::from("Rounded")));
            if let Ok(mut value) = lock.lock() {
                *value = style;
            }
        }
        if let Some(font_family) = json_string(&payload, "font_family") {
            let lock = BUBBLE_FONT.get_or_init(|| Mutex::new(String::from("Noto Sans Thai")));
            if let Ok(mut value) = lock.lock() {
                *value = font_family;
            }
        }
        if let Some(text_scale) = json_number(&payload, "text_scale") {
            let lock = TEXT_SCALE.get_or_init(|| Mutex::new(1.15));
            if let Ok(mut value) = lock.lock() {
                *value = text_scale.clamp(1.0, 1.80);
            }
        }
        let duration = json_number(&payload, "duration_ms")
            .unwrap_or(4000.0)
            .max(250.0) as u64;
        let until = BUBBLE_UNTIL.get_or_init(|| Mutex::new(None));
        if let Ok(mut value) = until.lock() {
            *value = Some(std::time::Instant::now() + std::time::Duration::from_millis(duration));
        }
        let bubble = BUBBLE_WINDOW.load(Ordering::Relaxed);
        // A runtime bubble is a mutually exclusive auxiliary surface. Close
        // menu/submenu/picker first so a click or an AI response cannot leave
        // multiple panels stacked over the companion.
        ShowWindow(MENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
        ShowWindow(SUBMENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
        ShowWindow(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed), SW_HIDE);
        sync_input_proxy_visibility();
        sync_aura_timer();
        reposition_auxiliary_windows(MAIN_WINDOW.load(Ordering::Relaxed));
        ShowWindow(bubble, SW_SHOWNOACTIVATE);
        InvalidateRect(bubble, null(), 1);
        println!(
            "[native-spike] phase=bubble-request text_received=true sequence={} visible=true",
            sequence as isize
        );
    }

    unsafe fn expire_runtime_bubble() {
        let Some(lock) = BUBBLE_UNTIL.get() else {
            return;
        };
        let expired = lock
            .lock()
            .ok()
            .and_then(|value| *value)
            .is_some_and(|until| std::time::Instant::now() >= until);
        if expired {
            ShowWindow(BUBBLE_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            if let Ok(mut value) = lock.lock() {
                *value = None;
            }
            println!("[native-spike] phase=bubble-request visible=false source=timeout");
        }
    }

    unsafe fn write_host_handoff(hwnd: Hwnd) -> Result<(), String> {
        let Some(path) = handoff_path() else {
            return Ok(());
        };
        let token = std::env::var("OCP_NATIVE_HOST_TOKEN")
            .map_err(|_| "OCP_NATIVE_HOST_TOKEN is not set".to_owned())?;
        // The launcher may deliberately start Godot first so its D3D12 render
        // surface exists before this native host begins changing Win32 window
        // state. In that safe order Godot has already published its HWND.
        // Do not overwrite that valid, token-bound acknowledgement with
        // `ready`, or both sides will wait for a status that no longer exists.
        let expected_token = format!("\"token\":\"{token}\"");
        if fs::read_to_string(&path).is_ok_and(|payload| {
            payload.contains("\"status\":\"godot-ready\"")
                && payload.contains(&expected_token)
                && payload.contains("\"godot_hwnd\":")
        }) {
            println!(
                "[native-spike] phase=host-handoff-ready token_present=true hwnd={hwnd:#x} preserve_godot_ready=true physics_committed=false"
            );
            return Ok(());
        }
        let mut rect: Rect = std::mem::zeroed();
        if GetWindowRect(hwnd, &mut rect) == 0 {
            return Err("GetWindowRect failed during native host handoff".to_owned());
        }
        let payload = format!(
            "{{\"status\":\"ready\",\"token\":\"{}\",\"hwnd\":{},\"dpi\":{},\"rect\":[{},{},{},{}]}}",
            token,
            hwnd,
            GetDpiForWindow(hwnd),
            rect.left,
            rect.top,
            rect.right,
            rect.bottom
        );
        write_handoff_atomically(path, &payload, "native")?;
        println!("[native-spike] phase=host-handoff-ready token_present=true hwnd={hwnd:#x} physics_committed=false");
        Ok(())
    }

    fn handoff_consumed() -> bool {
        handoff_path()
            .and_then(|path| fs::read_to_string(path).ok())
            .is_some_and(|payload| payload.contains("\"status\":\"consumed\""))
    }

    fn handoff_contains(status: &str) -> bool {
        handoff_path()
            .and_then(|path| fs::read_to_string(path).ok())
            .is_some_and(|payload| payload.contains(&format!("\"status\":\"{status}\"")))
    }

    fn write_handoff_status(status: &str, extra: &str) -> Result<(), String> {
        let Some(path) = handoff_path() else {
            return Err("handoff path is not set".to_owned());
        };
        let token = std::env::var("OCP_NATIVE_HOST_TOKEN")
            .map_err(|_| "OCP_NATIVE_HOST_TOKEN is not set".to_owned())?;
        let payload = format!("{{\"status\":\"{status}\",\"token\":\"{token}\"{extra}}}");
        write_handoff_atomically(path, &payload, "native")
    }

    fn write_handoff_atomically(
        path: std::path::PathBuf,
        payload: &str,
        writer: &str,
    ) -> Result<(), String> {
        let mut temporary = path.clone();
        temporary.set_extension(format!("{writer}.tmp"));
        fs::write(&temporary, payload)
            .map_err(|error| format!("write handoff temporary file failed: {error}"))?;
        let _ = fs::remove_file(&path);
        fs::rename(&temporary, &path)
            .map_err(|error| format!("publish handoff file failed: {error}"))
    }

    unsafe fn write_native_event(hwnd: Hwnd, phase: &str, feet: Option<DesktopLogicalPoint>) {
        let Some(path) = handoff_event_path() else {
            return;
        };
        let Ok(token) = std::env::var("OCP_NATIVE_HOST_TOKEN") else {
            return;
        };
        let sequence = HANDOFF_EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed) + 1;
        let extra = feet.map_or_else(String::new, |point| {
            format!(
                ",\"desktop_feet_x\":{},\"desktop_feet_y\":{}",
                point.x, point.y
            )
        });
        let payload = format!(
            "{{\"status\":\"{phase}\",\"token\":\"{token}\",\"sequence\":{sequence}{extra},\"physics_committed\":false}}"
        );
        let _ = write_handoff_atomically(path, &payload, "native-event");
        let _ = hwnd;
    }

    unsafe fn write_native_event_with_item(hwnd: Hwnd, phase: &str, item: &str) {
        let Some(path) = handoff_event_path() else {
            return;
        };
        let Ok(token) = std::env::var("OCP_NATIVE_HOST_TOKEN") else {
            return;
        };
        let sequence = HANDOFF_EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed) + 1;
        let payload = format!(
            "{{\"status\":\"{phase}\",\"token\":\"{token}\",\"sequence\":{sequence},\"item\":\"{item}\",\"physics_committed\":false}}"
        );
        let _ = write_handoff_atomically(path, &payload, "native-event");
        let _ = hwnd;
    }

    fn propvariant_string(value: &str) -> Result<PROPVARIANT, String> {
        let variant = VARIANT::from(value);
        PROPVARIANT::try_from(&variant)
            .map_err(|error| format!("PROPVARIANT conversion failed: {error}"))
    }

    unsafe fn set_window_string_property(
        store: &IPropertyStore,
        key: &PROPERTYKEY,
        value: &str,
    ) -> Result<(), String> {
        let prop = propvariant_string(value)?;
        store
            .SetValue(key, &prop)
            .map_err(|error| format!("IPropertyStore::SetValue failed: {error}"))
    }

    unsafe fn apply_ocp_taskbar_identity(render: Hwnd) -> Result<(), String> {
        if render == 0 {
            return Err("render HWND is null".to_owned());
        }

        let store: IPropertyStore = SHGetPropertyStoreForWindow(WinHwnd(render as *mut c_void))
            .map_err(|error| format!("SHGetPropertyStoreForWindow failed: {error}"))?;

        let relaunch_command = std::env::var("OCP_TASKBAR_RELAUNCH_COMMAND")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let display_name = std::env::var("OCP_TASKBAR_DISPLAY_NAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| OCP_TASKBAR_DISPLAY_NAME.to_owned());

        // Windows requires RelaunchCommand + RelaunchDisplayNameResource as a
        // pair. Set them before the explicit AppUserModelID so Explorer refreshes
        // the existing taskbar item using OCP rather than Godot's host identity.
        if let Some(command) = relaunch_command {
            set_window_string_property(
                &store,
                &PKEY_APPUSERMODEL_RELAUNCH_COMMAND,
                command.trim(),
            )?;
            set_window_string_property(
                &store,
                &PKEY_APPUSERMODEL_RELAUNCH_DISPLAY_NAME_RESOURCE,
                display_name.trim(),
            )?;

            if let Ok(icon_resource) = std::env::var("OCP_TASKBAR_ICON_RESOURCE") {
                if !icon_resource.trim().is_empty() {
                    set_window_string_property(
                        &store,
                        &PKEY_APPUSERMODEL_RELAUNCH_ICON_RESOURCE,
                        icon_resource.trim(),
                    )?;
                }
            }
        }

        set_window_string_property(&store, &PKEY_APPUSERMODEL_ID, OCP_TASKBAR_APP_ID)?;
        store
            .Commit()
            .map_err(|error| format!("IPropertyStore::Commit failed: {error}"))?;

        let mut title: Vec<u16> = "OCP Desktop Runtime".encode_utf16().collect();
        title.push(0);
        let _ = SetWindowTextW(render, title.as_ptr());

        Ok(())
    }

    unsafe fn adopt_render_window(controller: Hwnd, render: Hwnd) -> Result<(), String> {
        if render == 0 {
            return Err("Godot HWND is null".to_owned());
        }
        let mut controller_rect: Rect = std::mem::zeroed();
        if GetWindowRect(controller, &mut controller_rect) == 0 {
            return Err("GetWindowRect failed while adopting Godot HWND".to_owned());
        }
        // Keep Godot top-level so Windows preserves the transparent swap-chain
        // composition. Godot runs in a separate process, so its WNDPROC must
        // not be subclassed by this host. The sibling input proxy owns pointer
        // input only inside the runtime visual hitbox.
        SetParent(render, 0);
        match apply_ocp_taskbar_identity(render) {
            Ok(()) => println!(
                "[native-spike] phase=taskbar-identity app_id={} display_name={} physics_committed=false",
                OCP_TASKBAR_APP_ID,
                OCP_TASKBAR_DISPLAY_NAME,
            ),
            Err(error) => eprintln!(
                "[native-spike] phase=taskbar-identity-degraded error={} physics_committed=false",
                error
            ),
        }
        let mut style = GetWindowLongPtrW(render, GWL_STYLE);
        style &= !(WS_CHILD as isize | WS_DISABLED as isize);
        style |= WS_POPUP as isize;
        SetWindowLongPtrW(render, GWL_STYLE, style);
        let mut ex_style = GetWindowLongPtrW(render, GWLP_EXSTYLE);
        // Godot creates its top-level render surface with WS_EX_APPWINDOW,
        // which forces a taskbar/Alt+Tab entry even after TOOLWINDOW is added.
        // The companion is tray-first and controlled by the native host/tray,
        // so explicitly clear APPWINDOW before applying the non-activating
        // tool-window policy. Desktop Shell windows remain ordinary taskbar apps.
        ex_style &= !(WS_EX_APPWINDOW as isize);
        ex_style |= WS_EX_LAYERED as isize
            | WS_EX_TOOLWINDOW as isize
            | WS_EX_NOACTIVATE as isize
            | WS_EX_TRANSPARENT as isize;
        SetWindowLongPtrW(render, GWLP_EXSTYLE, ex_style);
        // Godot supplies the per-pixel alpha for this borderless surface.
        // Disable DWM non-client rendering so Windows does not add a tinted
        // shadow/glow around the transparent top-level render HWND.
        let nc_policy = DWMNCRP_DISABLED;
        DwmSetWindowAttribute(
            render,
            DWMWA_NCRENDERING_POLICY,
            &nc_policy as *const Dword as *const c_void,
            size_of::<Dword>() as Dword,
        );
        EnableWindow(render, 1);
        RENDER_WINDOW.store(render, Ordering::Relaxed);
        let controller_context = GetWindowDpiAwarenessContext(controller);
        let render_context = GetWindowDpiAwarenessContext(render);
        let thread_context = GetThreadDpiAwarenessContext();
        println!(
            "[native-spike] phase=dpi-awareness controller={} render={} thread={} controller_dpi={} render_dpi={} physics_committed=false",
            GetAwarenessFromDpiAwarenessContext(controller_context),
            GetAwarenessFromDpiAwarenessContext(render_context),
            GetAwarenessFromDpiAwarenessContext(thread_context),
            GetDpiForWindow(controller),
            GetDpiForWindow(render),
        );
        SetWindowPos(
            render,
            HWND_TOPMOST,
            controller_rect.left,
            controller_rect.top,
            controller_rect.right - controller_rect.left,
            controller_rect.bottom - controller_rect.top,
            SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
        // Keep the transparent Godot render HWND hidden.  The first canonical
        // move positions controller + render together, then reveals both.  This
        // prevents the (0,0) creation rectangle from appearing for one frame.
        ShowWindow(render, SW_HIDE);
        reposition_auxiliary_windows(controller);
        sync_input_proxy_visibility();
        println!("[native-spike] phase=render-surface-input-policy owner=native input=alpha-proxy render_click_through=true physics_committed=false");
        Ok(())
    }

    unsafe fn release_render_window(render: Hwnd) {
        if render != 0 {
            // Shutdown detach must stop native synchronization without touching
            // Godot's HWND geometry or extended styles. Mutating the adopted
            // render window while Godot is beginning teardown can race the
            // renderer/window backend and terminate Godot with 0xC0000005.
            // Godot owns and destroys this HWND after the detach/host-closed
            // handshake; the native host only relinquishes authority here.
            RENDER_WINDOW.store(0, Ordering::Relaxed);
        }
    }

    unsafe fn sync_render_window_to_controller(controller: Hwnd) {
        let render = RENDER_WINDOW.load(Ordering::Relaxed);
        if render == 0 || controller == 0 {
            return;
        }
        let mut controller_rect: Rect = std::mem::zeroed();
        let mut render_rect: Rect = std::mem::zeroed();
        if GetWindowRect(controller, &mut controller_rect) == 0
            || GetWindowRect(render, &mut render_rect) == 0
        {
            return;
        }
        let controller_bounds = PhysicalRect {
            left: controller_rect.left,
            top: controller_rect.top,
            width: controller_rect.right - controller_rect.left,
            height: controller_rect.bottom - controller_rect.top,
        };
        let render_bounds = PhysicalRect {
            left: render_rect.left,
            top: render_rect.top,
            width: render_rect.right - render_rect.left,
            height: render_rect.bottom - render_rect.top,
        };
        if !render_surface_needs_sync(controller_bounds, render_bounds) {
            return;
        }
        SetWindowPos(
            render,
            HWND_TOPMOST,
            controller_bounds.left,
            controller_bounds.top,
            controller_bounds.width,
            controller_bounds.height,
            SWP_NOACTIVATE,
        );
        println!(
            "[native-spike] phase=render-surface-reconciled controller_rect=({},{},{},{}) render_before=({},{},{},{}) physics_committed=false",
            controller_bounds.left,
            controller_bounds.top,
            controller_bounds.width,
            controller_bounds.height,
            render_bounds.left,
            render_bounds.top,
            render_bounds.width,
            render_bounds.height,
        );
    }

    unsafe fn toggle_click_through(hwnd: Hwnd) {
        let enabled = !CLICK_THROUGH.load(Ordering::Relaxed);
        CLICK_THROUGH.store(enabled, Ordering::Relaxed);
        let mut style = GetWindowLongPtrW(hwnd, GWLP_EXSTYLE);
        if enabled {
            style |= WS_EX_TRANSPARENT as isize | WS_EX_NOACTIVATE as isize;
        } else {
            style &= !(WS_EX_TRANSPARENT as isize);
            style |= WS_EX_NOACTIVATE as isize;
        }
        SetWindowLongPtrW(hwnd, GWLP_EXSTYLE, style);
        let render = RENDER_WINDOW.load(Ordering::Relaxed);
        if render != 0 {
            let mut render_style = GetWindowLongPtrW(render, GWLP_EXSTYLE);
            render_style |= WS_EX_TRANSPARENT as isize | WS_EX_NOACTIVATE as isize;
            SetWindowLongPtrW(render, GWLP_EXSTYLE, render_style);
        }
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
        reposition_auxiliary_windows(hwnd);
        sync_input_proxy_visibility();
        println!("[native-spike] click-through={enabled}");
    }

    unsafe fn log_placement(hwnd: Hwnd, phase: &str) {
        let mut rect: Rect = std::mem::zeroed();
        GetWindowRect(hwnd, &mut rect);
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut info = MonitorInfo {
            size: size_of::<MonitorInfo>() as Dword,
            monitor: std::mem::zeroed(),
            work: std::mem::zeroed(),
            flags: 0,
        };
        GetMonitorInfoW(monitor, &mut info);
        println!("[native-spike] phase={phase} hwnd={hwnd:#x} monitor={monitor:#x} dpi={} rect=({},{},{},{}) monitor_rect=({},{},{},{})", GetDpiForWindow(hwnd), rect.left, rect.top, rect.right, rect.bottom, info.monitor.left, info.monitor.top, info.monitor.right, info.monitor.bottom);
    }

    unsafe extern "system" fn collect_monitor(
        monitor: Hmonitor,
        _hdc: isize,
        _clip: *mut Rect,
        data: Lparam,
    ) -> Bool {
        let monitors = &mut *(data as *mut Vec<MonitorDescriptor>);
        let mut info = MonitorInfo {
            size: size_of::<MonitorInfo>() as Dword,
            monitor: std::mem::zeroed(),
            work: std::mem::zeroed(),
            flags: 0,
        };
        if GetMonitorInfoW(monitor, &mut info) == 0 {
            return 1;
        }
        let mut dpi_x = 96;
        let mut dpi_y = 96;
        if GetDpiForMonitor(monitor, 0, &mut dpi_x, &mut dpi_y) != 0 {
            dpi_x = 96;
        }
        monitors.push(derive_logical_monitor(
            monitor as usize,
            PhysicalRect {
                left: info.monitor.left,
                top: info.monitor.top,
                width: info.monitor.right - info.monitor.left,
                height: info.monitor.bottom - info.monitor.top,
            },
            dpi_x,
        ));
        1
    }

    unsafe fn enumerate_monitors() -> Vec<MonitorDescriptor> {
        let mut monitors: Vec<MonitorDescriptor> = Vec::new();
        EnumDisplayMonitors(
            0,
            null(),
            Some(collect_monitor),
            &mut monitors as *mut Vec<MonitorDescriptor> as Lparam,
        );
        monitors.sort_by(|left, right| {
            left.logical
                .left
                .partial_cmp(&right.logical.left)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        monitors
    }

    unsafe fn log_drag_event(hwnd: Hwnd, phase: &str) {
        let mut rect: Rect = std::mem::zeroed();
        if GetWindowRect(hwnd, &mut rect) == 0 {
            eprintln!("[native-spike] phase={phase} accepted=false reason=get-window-rect");
            return;
        }
        let bounds = PhysicalRect {
            left: rect.left,
            top: rect.top,
            width: rect.right - rect.left,
            height: rect.bottom - rect.top,
        };
        let monitors = enumerate_monitors();
        let Some((monitor_id, feet)) =
            native_bounds_to_canonical_anchor(bounds, presentation_anchor(), &monitors)
        else {
            eprintln!("[native-spike] phase={phase} accepted=false reason=outside-monitor rect=({},{},{},{})", rect.left, rect.top, rect.right, rect.bottom);
            return;
        };
        write_native_event(hwnd, phase, Some(feet));
        println!(
            "[native-spike] phase={phase} accepted=true source=native-drag-capture desktop_feet=({:.2},{:.2}) monitor={:#x} physical_rect=({},{},{},{}) physics_authority=runtime",
            feet.x,
            feet.y,
            monitor_id,
            rect.left,
            rect.top,
            rect.right,
            rect.bottom,
        );
    }

    unsafe fn poll_native_interaction(hwnd: Hwnd) {
        if CLICK_THROUGH.load(Ordering::Relaxed) {
            return;
        }

        let mut cursor = Point { x: 0, y: 0 };
        if GetCursorPos(&mut cursor) == 0 {
            return;
        }

        let in_visual = cursor_in_visual_hitbox(hwnd, &cursor);
        let in_menu = cursor_inside_window(MENU_WINDOW.load(Ordering::Relaxed));
        let in_submenu = cursor_inside_window(SUBMENU_WINDOW.load(Ordering::Relaxed));

        if DRAG_ACTIVE.load(Ordering::Relaxed) {
            suppress_hover_for_drag(hwnd);
            return;
        }
        if HOVER_REARM_REQUIRED.load(Ordering::Relaxed) {
            if !in_visual {
                HOVER_REARM_REQUIRED.store(false, Ordering::Relaxed);
                println!("[native-spike] phase=hover-lifecycle kind=menu visible=false source=drag-rearmed owner_unchanged=true");
            }
            return;
        }

        // Never infer a drag from the global mouse-button state. The old poll
        // path moved OCP even when Windows had delivered the original click to
        // Explorer, so desktop icon selection and companion dragging happened
        // at the same time. WM_NCHITTEST/HTCAPTION is now the sole drag owner;
        // this poll is hover-only.
        if in_visual || in_menu || in_submenu {
            if let Ok(mut deadline) = HOVER_LEAVE_AT.get_or_init(|| Mutex::new(None)).lock() {
                *deadline = None;
            }
        }

        if in_visual {
            KillTimer(hwnd, HOVER_CLOSE_TIMER);
            set_auxiliary_visibility(
                hwnd,
                MENU_WINDOW.load(Ordering::Relaxed),
                "menu",
                true,
                "hover-enter",
            );
        } else if !in_menu
            && !in_submenu
            && IsWindowVisible(MENU_WINDOW.load(Ordering::Relaxed)) != 0
        {
            let now = std::time::Instant::now();
            let mut close = false;
            if let Ok(mut deadline) = HOVER_LEAVE_AT.get_or_init(|| Mutex::new(None)).lock() {
                match *deadline {
                    Some(value) if now >= value => {
                        close = true;
                        *deadline = None;
                    }
                    Some(_) => {}
                    None => {
                        *deadline = Some(now + std::time::Duration::from_millis(700));
                    }
                }
            }
            if close {
                set_auxiliary_visibility(
                    hwnd,
                    MENU_WINDOW.load(Ordering::Relaxed),
                    "menu",
                    false,
                    "hover-grace-expired",
                );
                set_auxiliary_visibility(
                    hwnd,
                    SUBMENU_WINDOW.load(Ordering::Relaxed),
                    "submenu",
                    false,
                    "hover-grace-expired",
                );
            }
        }
    }

    unsafe fn finish_explicit_drag(hwnd: Hwnd, source: &str) {
        if !DRAG_ACTIVE.swap(false, Ordering::Relaxed) {
            return;
        }
        log_drag_event(hwnd, "drag-end");
        ReleaseCapture();
        reposition_auxiliary_windows(hwnd);
        println!("[native-spike] phase=drag-finished source={source} capture_released=true");
    }

    unsafe fn suppress_hover_for_drag(owner: Hwnd) {
        if HOVER_REARM_REQUIRED.swap(true, Ordering::Relaxed) {
            return;
        }
        KillTimer(owner, HOVER_CLOSE_TIMER);
        ShowWindow(MENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
        ShowWindow(SUBMENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
        sync_input_proxy_visibility();
        MENU_ACTIVE.store(false, Ordering::Relaxed);
        // Always notify Runtime even if the native mock window was already
        // hidden; the two presentation surfaces must not drift out of sync.
        write_native_event(owner, "hover-leave", None);
        println!("[native-spike] phase=hover-lifecycle kind=menu visible=false source=drag-begin owner_unchanged=true");
    }

    unsafe fn apply_runtime_move_request(hwnd: Hwnd) {
        let Some(path) = handoff_command_path() else {
            return;
        };
        let Ok(payload) = fs::read_to_string(path) else {
            return;
        };
        let is_move_request = payload.contains("\"status\":\"move-request\"");
        let is_restore_request = payload.contains("\"status\":\"restore-request\"");
        if (!is_move_request && !is_restore_request) || !payload.contains("\"token\":\"") {
            return;
        }
        let Ok(expected_token) = std::env::var("OCP_NATIVE_HOST_TOKEN") else {
            return;
        };
        let token_marker = "\"token\":\"";
        let Some(token) = payload
            .split(token_marker)
            .nth(1)
            .and_then(|value| value.split('\"').next())
        else {
            return;
        };
        if token != expected_token {
            return;
        }
        let Some(sequence) = json_number(&payload, "sequence") else {
            return;
        };
        // Visibility is authoritative across both native IPC channels. Chat can
        // become active while physics is still emitting walk/climb moves; apply
        // the generation carried by the move before any move de-duplication so
        // the floating companion is hidden even if the dedicated UI hide was
        // delayed or overwritten.
        if is_move_request {
            apply_runtime_visibility_generation(hwnd, &payload);
        }
        if LAST_MOVE_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
            return;
        }
        let Some(feet_x) = json_number(&payload, "desktop_feet_x")
            .or_else(|| json_array_number(&payload, "desktop_feet", 0))
        else {
            return;
        };
        let Some(feet_y) = json_number(&payload, "desktop_feet_y")
            .or_else(|| json_array_number(&payload, "desktop_feet", 1))
        else {
            return;
        };
        let monitors = enumerate_monitors();
        let monitor = monitor_for_logical_point(
            DesktopLogicalPoint {
                x: feet_x,
                y: feet_y,
            },
            &monitors,
        );
        let Some(_monitor) = monitor else { return };
        let contact = DesktopLogicalPoint {
            x: feet_x,
            y: feet_y,
        };
        let anchor = presentation_anchor();
        let attachment_state = json_string(&payload, "attachment_state").unwrap_or_default();
        let movement_state = json_string(&payload, "movement_state").unwrap_or_default();
        let surface_kind = json_string(&payload, "surface_kind").unwrap_or_default();
        if is_restore_request {
            let visibility_generation =
                json_number(&payload, "visibility_generation").unwrap_or(sequence) as isize;
            let previous_generation = LAST_VISIBILITY_GENERATION.load(Ordering::Relaxed);
            if visibility_generation < previous_generation
                || (visibility_generation == previous_generation
                    && !RUNTIME_VISIBILITY_DESIRED.load(Ordering::Relaxed))
            {
                return;
            }
            if visibility_generation > previous_generation {
                LAST_VISIBILITY_GENERATION.store(visibility_generation, Ordering::Relaxed);
            }
            RUNTIME_VISIBILITY_DESIRED.store(true, Ordering::Relaxed);
            // Keep the controller, render surface, and all auxiliary HWNDs
            // hidden until canonical placement is complete. Windows may
            // otherwise repaint Godot at its temporary restore coordinates.
            ShowWindow(hwnd, SW_HIDE);
            ShowWindow(RENDER_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(BUBBLE_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(MENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(SUBMENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed), SW_HIDE);
        }
        // The canonical surface remains 384 logical pixels. Convert it once
        // using the target monitor DPI; preserving a previous physical extent
        // makes the artwork 2x too large after a mixed-DPI handoff.
        let logical_extent = f64::from(native_logical_window_size());
        let placement = canonical_anchor_to_native_placement(
            contact,
            (logical_extent, logical_extent),
            anchor,
            &monitors,
        );
        let Some(mut placement) = placement else {
            return;
        };
        if should_align_grounded_to_work_area(&attachment_state, &movement_state, &surface_kind) {
            let monitor = placement.monitor_id as Hmonitor;
            let mut info = MonitorInfo {
                size: size_of::<MonitorInfo>() as Dword,
                monitor: std::mem::zeroed(),
                work: std::mem::zeroed(),
                flags: 0,
            };
            if GetMonitorInfoW(monitor, &mut info) != 0 {
                placement = align_grounded_placement_to_work_area(
                    placement,
                    PhysicalRect {
                        left: info.work.left,
                        top: info.work.top,
                        width: info.work.right - info.work.left,
                        height: info.work.bottom - info.work.top,
                    },
                    anchor.1,
                );
            }
        }
        LAST_MOVE_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
        CANONICAL_APPLYING.store(true, Ordering::Relaxed);
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            placement.bounds.left,
            placement.bounds.top,
            placement.bounds.width,
            placement.bounds.height,
            SWP_NOACTIVATE,
        );
        CANONICAL_APPLYING.store(false, Ordering::Relaxed);
        let initial_canonical_reveal =
            !is_restore_request && INITIAL_CANONICAL_REVEAL_PENDING.swap(false, Ordering::Relaxed);
        if is_restore_request || initial_canonical_reveal {
            sync_render_window_to_controller(hwnd);
            RUNTIME_VISIBILITY_DESIRED.store(true, Ordering::Relaxed);
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            ShowWindow(RENDER_WINDOW.load(Ordering::Relaxed), SW_SHOWNOACTIVATE);
            CANONICAL_SURFACE_REVEALED.store(true, Ordering::Relaxed);
            sync_input_proxy_visibility();
            if is_restore_request {
                println!(
					"[native-spike] phase=restore-reposition sequence={} desktop_feet=({:.2},{:.2}) monitor={} surface={} visible_after_placement=true",
					sequence, feet_x, feet_y, placement.monitor_id, surface_kind,
				);
            } else {
                println!(
					"[native-spike] phase=startup-reposition sequence={} desktop_feet=({:.2},{:.2}) monitor={} surface={} visible_after_placement=true",
					sequence, feet_x, feet_y, placement.monitor_id, surface_kind,
				);
                write_native_event(hwnd, "startup-repositioned", None);
            }
        } else {
            reposition_auxiliary_windows(hwnd);
        }
        println!(
            "[native-spike] phase=runtime-move sequence={} desktop_feet=({:.2},{:.2}) monitor={} movement={} attachment={} surface={} floor_aligned={} extent_policy=monitor-dpi physical_size=({},{}) physics_authority=runtime",
            sequence,
            feet_x,
            feet_y,
            placement.monitor_id,
            movement_state,
            attachment_state,
            surface_kind,
            should_align_grounded_to_work_area(&attachment_state, &movement_state, &surface_kind),
            placement.bounds.width,
            placement.bounds.height,
        );
    }

    fn json_number(payload: &str, key: &str) -> Option<f64> {
        let marker = format!("\"{key}\":");
        let value = payload.split(&marker).nth(1)?;
        value.split([',', '}']).next()?.trim().parse().ok()
    }

    fn json_bool(payload: &str, key: &str) -> Option<bool> {
        let marker = format!("\"{key}\":");
        let value = payload.split(&marker).nth(1)?.trim_start();
        if value.starts_with("true") {
            Some(true)
        } else if value.starts_with("false") {
            Some(false)
        } else {
            None
        }
    }

    fn presentation_anchor() -> (f64, f64) {
        (
            f64::from(f32::from_bits(
                PRESENTATION_ANCHOR_X.load(Ordering::Relaxed),
            )),
            f64::from(f32::from_bits(
                PRESENTATION_ANCHOR_Y.load(Ordering::Relaxed),
            )),
        )
    }

    unsafe fn apply_presentation_anchor(hwnd: Hwnd, anchor: (f64, f64)) {
        let next = (anchor.0.clamp(0.0, 1.0), anchor.1.clamp(0.0, 1.0));
        let previous = presentation_anchor();
        if (next.0 - previous.0).abs() < 0.0001 && (next.1 - previous.1).abs() < 0.0001 {
            return;
        }
        let mut rect: Rect = std::mem::zeroed();
        if GetWindowRect(hwnd, &mut rect) == 0 {
            return;
        }
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        let contact_x = f64::from(rect.left) + f64::from(width) * previous.0;
        let contact_y = f64::from(rect.top) + f64::from(height) * previous.1;
        PRESENTATION_ANCHOR_X.store((next.0 as f32).to_bits(), Ordering::Relaxed);
        PRESENTATION_ANCHOR_Y.store((next.1 as f32).to_bits(), Ordering::Relaxed);
        CANONICAL_APPLYING.store(true, Ordering::Relaxed);
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            (contact_x - f64::from(width) * next.0).round() as i32,
            (contact_y - f64::from(height) * next.1).round() as i32,
            width,
            height,
            SWP_NOACTIVATE,
        );
        CANONICAL_APPLYING.store(false, Ordering::Relaxed);
        reposition_auxiliary_windows(hwnd);
        println!(
            "[native-spike] phase=presentation-anchor-updated normalized=({:.3},{:.3}) canonical_contact_preserved=true",
            next.0, next.1
        );
    }

    unsafe fn apply_runtime_visibility_generation(hwnd: Hwnd, payload: &str) -> bool {
        let Some(generation) = json_number(payload, "visibility_generation") else {
            return false;
        };
        let generation = generation as isize;
        if generation <= 0 || generation <= LAST_VISIBILITY_GENERATION.load(Ordering::Relaxed) {
            return false;
        }
        let desired = json_bool(payload, "visibility_desired").unwrap_or(true);
        LAST_VISIBILITY_GENERATION.store(generation, Ordering::Relaxed);
        RUNTIME_VISIBILITY_DESIRED.store(desired, Ordering::Relaxed);
        let render = RENDER_WINDOW.load(Ordering::Relaxed);
        if desired {
            if CANONICAL_SURFACE_REVEALED.load(Ordering::Relaxed) {
                ShowWindow(hwnd, SW_HIDE);
                if render != 0 {
                    ShowWindow(render, SW_HIDE);
                }
                sync_render_window_to_controller(hwnd);
                ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                if render != 0 {
                    ShowWindow(render, SW_SHOWNOACTIVATE);
                }
                sync_input_proxy_visibility();
            }
        } else {
            ShowWindow(hwnd, SW_HIDE);
            if render != 0 {
                ShowWindow(render, SW_HIDE);
            }
            ShowWindow(BUBBLE_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(MENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(SUBMENU_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            ShowWindow(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed), SW_HIDE);
            sync_input_proxy_visibility();
        }
        println!(
            "[native-spike] phase=visibility-generation generation={} visible={} source=runtime",
            generation, desired
        );
        true
    }

    unsafe fn apply_runtime_auxiliary_request(hwnd: Hwnd) {
        let Some(path) = handoff_ui_command_path().or_else(handoff_command_path) else {
            return;
        };
        let Ok(payload) = fs::read_to_string(path) else {
            return;
        };
        let Ok(expected_token) = std::env::var("OCP_NATIVE_HOST_TOKEN") else {
            return;
        };
        let Some(token) = json_string(&payload, "token") else {
            return;
        };
        if token != expected_token {
            return;
        }
        let Some(sequence) = json_number(&payload, "sequence") else {
            return;
        };
        let status = json_string(&payload, "status").unwrap_or_default();
        let visibility_changed = apply_runtime_visibility_generation(hwnd, &payload);
        if status == "visibility-request" {
            if visibility_changed {
                println!("[native-spike] phase=render-hitbox-rearmed source=visibility-generation");
            }
        } else if status == "anchor-request" {
            if LAST_ANCHOR_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            LAST_ANCHOR_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            if let (Some(x), Some(y)) = (
                json_array_number(&payload, "normalized_anchor", 0),
                json_array_number(&payload, "normalized_anchor", 1),
            ) {
                apply_presentation_anchor(hwnd, (x, y));
            }
        } else if status == "hitbox-request" {
            if LAST_AUX_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            LAST_AUX_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            let values = (
                json_array_number(&payload, "normalized_hitbox", 0),
                json_array_number(&payload, "normalized_hitbox", 1),
                json_array_number(&payload, "normalized_hitbox", 2),
                json_array_number(&payload, "normalized_hitbox", 3),
            );
            if let (Some(left), Some(top), Some(width), Some(height)) = values {
                let candidate = (left as f32, top as f32, width as f32, height as f32);
                if candidate.0 >= 0.0
                    && candidate.1 >= 0.0
                    && candidate.2 > 0.0
                    && candidate.3 > 0.0
                    && candidate.0 + candidate.2 <= 1.0
                    && candidate.1 + candidate.3 <= 1.0
                {
                    if let Ok(mut hitbox) = RUNTIME_HITBOX.get_or_init(|| Mutex::new(None)).lock() {
                        *hitbox = Some(candidate);
                    }
                    reposition_auxiliary_windows(hwnd);
                    println!(
                        "[native-spike] phase=hitbox-updated normalized=({:.3},{:.3},{:.3},{:.3}) source=runtime",
                        candidate.0, candidate.1, candidate.2, candidate.3
                    );
                }
            }
        } else if status == "theme-request" {
            if LAST_THEME_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            LAST_THEME_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            let requested = json_string(&payload, "theme").unwrap_or_else(|| "solid".to_owned());
            let index = match requested.as_str() {
                "glass" => 1,
                "liquid" => 2,
                _ => 0,
            };
            THEME_INDEX.store(index, Ordering::Relaxed);
            if let Some(language) = json_string(&payload, "language") {
                UI_LANGUAGE_INDEX.store(
                    if normalize_hover_language(&language) == "th" {
                        1
                    } else {
                        0
                    },
                    Ordering::Relaxed,
                );
            }
            if let Some(scale) = json_number(&payload, "presentation_scale") {
                if let Some(scale_index) = companion_scale_preset_index(scale) {
                    ACTIVE_PRESENTATION_SCALE_INDEX.store(scale_index as i32, Ordering::Relaxed);
                }
            }
            if let Some(font_family) = json_string(&payload, "font_family") {
                let lock = BUBBLE_FONT.get_or_init(|| Mutex::new(String::from("Noto Sans Thai")));
                if let Ok(mut value) = lock.lock() {
                    *value = font_family;
                }
            }
            if let Some(text_scale) = json_number(&payload, "text_scale") {
                let lock = TEXT_SCALE.get_or_init(|| Mutex::new(1.15));
                if let Ok(mut value) = lock.lock() {
                    *value = text_scale.clamp(1.0, 1.80);
                }
            }
            if let Some(style) = json_string(&payload, "bubble_style") {
                let lock = BUBBLE_STYLE.get_or_init(|| Mutex::new(String::from("Rounded")));
                if let Ok(mut value) = lock.lock() {
                    *value = style;
                }
            }
            REDUCED_MOTION.store(
                json_bool(&payload, "reduced_motion").unwrap_or(false),
                Ordering::Relaxed,
            );
            apply_native_theme_transparency();
            // Recompute auxiliary geometry whenever text scale/theme changes.
            // Drawing, hover hit-testing and click routing now share the same
            // scaled row metrics, and the native popup bounds must match them.
            reposition_auxiliary_windows(hwnd);
            InvalidateRect(MENU_WINDOW.load(Ordering::Relaxed), null(), 1);
            InvalidateRect(SUBMENU_WINDOW.load(Ordering::Relaxed), null(), 1);
            InvalidateRect(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed), null(), 1);
            InvalidateRect(BUBBLE_WINDOW.load(Ordering::Relaxed), null(), 1);
            println!(
                "[native-spike] phase=theme-changed theme={} language={} font={} source=runtime",
                theme_name(index),
                current_ui_language(),
                BUBBLE_FONT
                    .get()
                    .and_then(|lock| lock.lock().ok().map(|value| value.clone()))
                    .unwrap_or_else(|| String::from("Noto Sans Thai"))
            );
            sync_aura_timer();
        } else if status == "sound-state" {
            if LAST_SOUND_STATE_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            let Some(master_muted) = json_bool(&payload, "master_muted") else {
                return;
            };
            let Some(sfx_enabled) = json_bool(&payload, "sfx_enabled") else {
                return;
            };
            LAST_SOUND_STATE_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            MASTER_SOUND_MUTED.store(master_muted, Ordering::Relaxed);
            CHARACTER_SFX_ENABLED.store(sfx_enabled, Ordering::Relaxed);
            InvalidateRect(SUBMENU_WINDOW.load(Ordering::Relaxed), null(), 1);
            println!(
                "[native-spike] phase=sound-state master_muted={master_muted} sfx_enabled={sfx_enabled} source=runtime"
            );
        } else if status == "presentation-geometry-state" {
            if LAST_PRESENTATION_SCALE_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            let Some(scale) = json_number(&payload, "scale") else {
                return;
            };
            let Some(index) = companion_scale_preset_index(scale) else {
                eprintln!(
                    "[native-spike] phase=presentation-geometry-rejected scale={scale:.2} source=runtime"
                );
                return;
            };
            let hitbox_values = (
                json_array_number(&payload, "normalized_hitbox", 0),
                json_array_number(&payload, "normalized_hitbox", 1),
                json_array_number(&payload, "normalized_hitbox", 2),
                json_array_number(&payload, "normalized_hitbox", 3),
            );
            let anchor_values = (
                json_array_number(&payload, "normalized_anchor", 0),
                json_array_number(&payload, "normalized_anchor", 1),
            );
            let (Some(left), Some(top), Some(width), Some(height)) = hitbox_values else {
                return;
            };
            let candidate = (left as f32, top as f32, width as f32, height as f32);
            if candidate.0 < 0.0
                || candidate.1 < 0.0
                || candidate.2 <= 0.0
                || candidate.3 <= 0.0
                || candidate.0 + candidate.2 > 1.0001
                || candidate.1 + candidate.3 > 1.0001
            {
                eprintln!(
                    "[native-spike] phase=presentation-geometry-rejected hitbox=({:.3},{:.3},{:.3},{:.3}) source=runtime",
                    candidate.0, candidate.1, candidate.2, candidate.3
                );
                return;
            }
            let (Some(anchor_x), Some(anchor_y)) = anchor_values else {
                return;
            };
            if let Ok(mut hitbox) = RUNTIME_HITBOX.get_or_init(|| Mutex::new(None)).lock() {
                *hitbox = Some(candidate);
            }
            apply_presentation_anchor(hwnd, (anchor_x, anchor_y));
            LAST_PRESENTATION_SCALE_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            ACTIVE_PRESENTATION_SCALE_INDEX.store(index as i32, Ordering::Relaxed);
            reposition_auxiliary_windows(hwnd);
            InvalidateRect(SUBMENU_WINDOW.load(Ordering::Relaxed), null(), 1);
            println!(
                "[native-spike] phase=presentation-geometry-active scale={scale:.2} segment={index} hitbox=({:.3},{:.3},{:.3},{:.3}) anchor=({:.3},{:.3}) source=runtime",
                candidate.0, candidate.1, candidate.2, candidate.3, anchor_x, anchor_y
            );
        } else if status == "presentation-scale-state" {
            if LAST_PRESENTATION_SCALE_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            let Some(scale) = json_number(&payload, "scale") else {
                return;
            };
            let Some(index) = companion_scale_preset_index(scale) else {
                eprintln!(
                    "[native-spike] phase=presentation-scale-rejected scale={scale:.2} source=runtime"
                );
                return;
            };
            LAST_PRESENTATION_SCALE_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            ACTIVE_PRESENTATION_SCALE_INDEX.store(index as i32, Ordering::Relaxed);
            InvalidateRect(SUBMENU_WINDOW.load(Ordering::Relaxed), null(), 1);
            println!(
                "[native-spike] phase=presentation-scale-active scale={scale:.2} segment={index} source=runtime"
            );
        } else if status == "character-picker-request" {
            if LAST_AUX_SEQUENCE.load(Ordering::Relaxed) == sequence as isize {
                return;
            }
            LAST_AUX_SEQUENCE.store(sequence as isize, Ordering::Relaxed);
            reposition_auxiliary_windows(hwnd);
            show_auxiliary_window(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed));
            println!("[native-spike] phase=character-picker visible=true source=runtime");
        }
    }

    fn json_array_number(payload: &str, key: &str, index: usize) -> Option<f64> {
        let marker = format!("\"{key}\":[");
        let value = payload.split(&marker).nth(1)?;
        value
            .split(']')
            .next()?
            .split(',')
            .nth(index)?
            .trim()
            .parse()
            .ok()
    }

    unsafe fn apply_next_canonical_position(hwnd: Hwnd) {
        let monitors = enumerate_monitors();
        if monitors.is_empty() {
            eprintln!("[native-spike] phase=canonical-rejected reason=no-monitors");
            return;
        }
        let sequence = CANONICAL_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let monitor = monitors[sequence % monitors.len()];
        let feet = DesktopLogicalPoint {
            x: monitor.logical.left + monitor.logical.width / 2.0,
            y: monitor.logical.top + monitor.logical.height - 32.0,
        };
        let Some(mut placement) =
            canonical_feet_to_native_placement(feet, (128.0, 128.0), &monitors)
        else {
            eprintln!("[native-spike] phase=canonical-rejected reason=outside-contract desktop_feet=({:.1},{:.1})", feet.x, feet.y);
            return;
        };
        let monitor_handle = placement.monitor_id as Hmonitor;
        let mut info = MonitorInfo {
            size: size_of::<MonitorInfo>() as Dword,
            monitor: std::mem::zeroed(),
            work: std::mem::zeroed(),
            flags: 0,
        };
        if GetMonitorInfoW(monitor_handle, &mut info) != 0 {
            placement = align_grounded_placement_to_work_area(
                placement,
                PhysicalRect {
                    left: info.work.left,
                    top: info.work.top,
                    width: info.work.right - info.work.left,
                    height: info.work.bottom - info.work.top,
                },
                presentation_anchor().1,
            );
        }
        let applied_feet =
            native_bounds_to_canonical_anchor(placement.bounds, presentation_anchor(), &monitors)
                .map(|(_, point)| point)
                .unwrap_or(feet);
        CANONICAL_APPLYING.store(true, Ordering::Relaxed);
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            placement.bounds.left,
            placement.bounds.top,
            placement.bounds.width,
            placement.bounds.height,
            SWP_NOACTIVATE,
        );
        CANONICAL_APPLYING.store(false, Ordering::Relaxed);
        let initial_demo_reveal = INITIAL_CANONICAL_REVEAL_PENDING.swap(false, Ordering::Relaxed)
            || !CANONICAL_SURFACE_REVEALED.load(Ordering::Relaxed);
        if initial_demo_reveal {
            // Physical multi-monitor acceptance can exercise Ctrl+Alt+P before
            // Runtime publishes its first canonical move. Mirror the normal
            // startup reveal contract so the transparent Godot render HWND and
            // input proxy do not remain hidden after a read-only placement.
            sync_render_window_to_controller(hwnd);
            RUNTIME_VISIBILITY_DESIRED.store(true, Ordering::Relaxed);
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            ShowWindow(RENDER_WINDOW.load(Ordering::Relaxed), SW_SHOWNOACTIVATE);
            CANONICAL_SURFACE_REVEALED.store(true, Ordering::Relaxed);
            sync_input_proxy_visibility();
            println!("[native-spike] phase=canonical-demo-reveal visible_after_placement=true");
        } else {
            reposition_auxiliary_windows(hwnd);
        }
        println!(
            "[native-spike] phase=canonical-apply source=read-only-demo sequence={} desktop_feet=({:.1},{:.1}) monitor={:#x} dpi={} rect=({},{},{},{})",
            sequence + 1,
            applied_feet.x,
            applied_feet.y,
            placement.monitor_id,
            monitor.dpi,
            placement.bounds.left,
            placement.bounds.top,
            placement.bounds.left + placement.bounds.width,
            placement.bounds.top + placement.bounds.height,
        );
    }

    unsafe fn apply_rounded_region(hwnd: Hwnd, width: i32, height: i32) {
        if hwnd == 0 || width <= 0 || height <= 0 {
            return;
        }
        // SetWindowRgn clips the native surface itself, including its
        // transparent corners. The region is owned by the window after a
        // successful SetWindowRgn call.
        let region = CreateRoundRectRgn(0, 0, width, height, 22, 22);
        if region != 0 {
            SetWindowRgn(hwnd, region, 1);
        }
    }

    unsafe fn apply_bubble_region(hwnd: Hwnd, width: i32, height: i32, style: &str) {
        if hwnd == 0 || width <= 0 || height <= 0 {
            return;
        }
        let radius = if style.eq_ignore_ascii_case("compact") {
            10
        } else if style.eq_ignore_ascii_case("soft") {
            30
        } else {
            22
        };
        let region = CreateRoundRectRgn(0, 0, width, height, radius, radius);
        if region != 0 {
            SetWindowRgn(hwnd, region, 1);
        }
    }

    unsafe fn reposition_auxiliary_windows(owner: Hwnd) {
        let mut owner_rect: Rect = std::mem::zeroed();
        if GetWindowRect(owner, &mut owner_rect) == 0 {
            return;
        }
        sync_render_window_to_controller(owner);
        let monitor = MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST);
        let mut info = MonitorInfo {
            size: size_of::<MonitorInfo>() as Dword,
            monitor: std::mem::zeroed(),
            work: std::mem::zeroed(),
            flags: 0,
        };
        if GetMonitorInfoW(monitor, &mut info) == 0 {
            return;
        }
        let owner_bounds = PhysicalRect {
            left: owner_rect.left,
            top: owner_rect.top,
            width: owner_rect.right - owner_rect.left,
            height: owner_rect.bottom - owner_rect.top,
        };
        let work = PhysicalRect {
            left: info.work.left,
            top: info.work.top,
            width: info.work.right - info.work.left,
            height: info.work.bottom - info.work.top,
        };
        // Auxiliary windows are siblings of the native host and are already
        // measured in physical pixels. Converting these dimensions by DPI a
        // second time made menus twice as large on the 192-DPI display.
        let gap = dpi_scaled(owner, 8);
        let menu = MENU_WINDOW.load(Ordering::Relaxed);
        let longest_label = auxiliary_labels(menu)
            .iter()
            .map(|(_, label)| localized_auxiliary_label(label).encode_utf16().count() as i32)
            .max()
            .unwrap_or(0);
        // Size from localized copy. UTF-16 units slightly overestimate Thai
        // combining marks, which is intentional: clipping is worse than a few
        // spare pixels and the result remains capped for compactness.
        let menu_logical_width = (92 + longest_label * 8).clamp(212, 312);
        let menu_width =
            ((dpi_scaled(owner, menu_logical_width) as f64) * current_text_scale()).round() as i32;
        let menu_row_count = auxiliary_labels(menu).len() as i32;
        let menu_height = ((dpi_scaled(owner, 48 + 32 * menu_row_count) as f64)
            * current_text_scale())
        .round() as i32;
        let bubble_style = BUBBLE_STYLE
            .get()
            .and_then(|lock| lock.lock().ok().map(|value| value.clone()))
            .unwrap_or_else(|| String::from("Rounded"));
        let bubble_width_factor = if bubble_style.eq_ignore_ascii_case("compact") {
            0.62
        } else if bubble_style.eq_ignore_ascii_case("soft") {
            0.78
        } else {
            0.72
        };
        let base_bubble_height = if bubble_style.eq_ignore_ascii_case("compact") {
            dpi_scaled(owner, 64)
        } else if bubble_style.eq_ignore_ascii_case("soft") {
            dpi_scaled(owner, 92)
        } else {
            dpi_scaled(owner, 80)
        };
        let bubble_height = ((base_bubble_height as f64) * current_text_scale()).round() as i32;
        let bubble_width = (owner_bounds.width as f32 * bubble_width_factor).round() as i32;
        // Place UI next to the declared visual hitbox instead of the full
        // transparent render client. This keeps the pointer travel distance
        // short for characters with large transparent frame padding.
        let visual_bounds = visual_hitbox_bounds(owner).unwrap_or(owner_bounds);
        // The popup must never consume the target that starts a native drag.
        // The margin makes the small 25%/50% target practical to acquire,
        // including when the character has been dropped at a monitor edge.
        let drag_safe_bounds =
            expand_physical_rect_within(visual_bounds, dpi_scaled(owner, 12), work);
        let input = INPUT_WINDOW.load(Ordering::Relaxed);
        if input != 0 {
            SetWindowPos(
                input,
                HWND_TOPMOST,
                visual_bounds.left,
                visual_bounds.top,
                visual_bounds.width,
                visual_bounds.height,
                SWP_NOACTIVATE,
            );
        }
        let normal_menu_size = (
            menu_width.clamp(dpi_scaled(owner, 220), dpi_scaled(owner, 340)),
            menu_height,
        );
        let compact_menu_size = (
            menu_width.clamp(dpi_scaled(owner, 176), dpi_scaled(owner, 220)),
            menu_height,
        );
        let menu_result = place_drag_safe_auxiliary_menu(
            drag_safe_bounds,
            normal_menu_size,
            compact_menu_size,
            work,
            gap,
        );
        MENU_DRAG_SAFE.store(menu_result.is_some(), Ordering::Relaxed);
        let group = place_auxiliary_group(
            visual_bounds,
            (
                bubble_width.max(dpi_scaled(
                    owner,
                    if bubble_style.eq_ignore_ascii_case("compact") {
                        180
                    } else {
                        200
                    },
                )),
                bubble_height,
            ),
            normal_menu_size,
            work,
            gap,
        );
        for (window, result, kind) in [(
            BUBBLE_WINDOW.load(Ordering::Relaxed),
            group.bubble,
            "bubble",
        )] {
            if window == 0 {
                continue;
            }
            SetWindowPos(
                window,
                HWND_TOPMOST,
                result.bounds.left,
                result.bounds.top,
                result.bounds.width,
                result.bounds.height,
                SWP_NOACTIVATE,
            );
            if kind == "bubble" {
                apply_bubble_region(
                    window,
                    result.bounds.width,
                    result.bounds.height,
                    &bubble_style,
                );
            } else {
                apply_rounded_region(window, result.bounds.width, result.bounds.height);
            }
            if IsWindowVisible(window) != 0 {
                println!(
                    "[native-spike] phase=aux-follow kind={kind} monitor={monitor:#x} placement={:?} rect=({},{},{},{}) owner_unchanged=true",
                    result.placement,
                    result.bounds.left,
                    result.bounds.top,
                    result.bounds.left + result.bounds.width,
                    result.bounds.top + result.bounds.height,
                );
            }
        }
        let menu = MENU_WINDOW.load(Ordering::Relaxed);
        if menu != 0 {
            if let Some(result) = menu_result {
                SetWindowPos(
                    menu,
                    HWND_TOPMOST,
                    result.bounds.left,
                    result.bounds.top,
                    result.bounds.width,
                    result.bounds.height,
                    SWP_NOACTIVATE,
                );
                apply_rounded_region(menu, result.bounds.width, result.bounds.height);
                if IsWindowVisible(menu) != 0 {
                    println!(
                        "[native-spike] phase=aux-follow kind=menu monitor={monitor:#x} placement={:?} rect=({},{},{},{}) drag_safe=true owner_unchanged=true",
                        result.placement,
                        result.bounds.left,
                        result.bounds.top,
                        result.bounds.left + result.bounds.width,
                        result.bounds.top + result.bounds.height,
                    );
                }
            } else {
                ShowWindow(menu, SW_HIDE);
                println!(
                    "[native-spike] phase=aux-placement kind=menu available=false reason=drag-safe-work-area"
                );
            }
        }
        let submenu = SUBMENU_WINDOW.load(Ordering::Relaxed);
        if submenu != 0 {
            let submenu_mode = SUBMENU_MODE.load(Ordering::Relaxed);
            let is_size_submenu = submenu_mode == 1;
            let is_sound_submenu = submenu_mode == 2;
            let submenu_width = if is_size_submenu {
                dpi_scaled(owner, 360).min(work.width)
            } else if is_sound_submenu {
                dpi_scaled(owner, 272).min(work.width)
            } else {
                (owner_bounds.width as f32 * 0.54).round() as i32
            };
            let submenu_logical_height = if is_size_submenu {
                44 + 48
            } else if is_sound_submenu {
                48 + 48 * 2
            } else {
                44 + 32 * 4
            };
            let submenu_height = ((dpi_scaled(owner, submenu_logical_height) as f64)
                * current_text_scale())
            .round() as i32;
            let submenu_result = menu_result.map(|menu_bounds| {
                let gap = dpi_scaled(owner, 2);
                // Actions, Size and Sound all use the same side-flyout contract:
                // anchor to the owning row, prefer the right side, flip left at
                // the monitor edge, and clamp into the work area instead of
                // hiding. Keeping one placement model also avoids surprising
                // movement when the pointer crosses between menu rows.
                let row_index = match submenu_mode {
                    0 => 0, // Actions
                    1 => 1, // Size
                    2 => 2, // Sound
                    _ => 0,
                };
                let anchor = auxiliary_layout(menu)
                    .and_then(|(header_height, row_height, _)| {
                        popup_row_bounds(menu_bounds.bounds, header_height, row_height, row_index)
                    })
                    .unwrap_or(menu_bounds.bounds);
                place_side_submenu(anchor, (submenu_width, submenu_height), work, gap)
            });
            // A visible primary menu now always has a placement for its
            // submenu; `false` only means the primary menu itself could not be
            // placed safely.
            SUBMENU_DRAG_SAFE.store(submenu_result.is_some(), Ordering::Relaxed);
            if let Some(result) = submenu_result {
                SetWindowPos(
                    submenu,
                    HWND_TOPMOST,
                    result.bounds.left,
                    result.bounds.top,
                    result.bounds.width,
                    result.bounds.height,
                    SWP_NOACTIVATE,
                );
                apply_rounded_region(submenu, result.bounds.width, result.bounds.height);
                if IsWindowVisible(submenu) != 0 {
                    println!(
                        "[native-spike] phase=aux-follow kind=submenu monitor={monitor:#x} placement={:?} rect=({},{},{},{}) drag_safe=true owner_unchanged=true",
                        result.placement,
                        result.bounds.left,
                        result.bounds.top,
                        result.bounds.left + result.bounds.width,
                        result.bounds.top + result.bounds.height,
                    );
                }
            } else {
                ShowWindow(submenu, SW_HIDE);
                println!(
                    "[native-spike] phase=aux-placement kind=submenu available=false reason=drag-safe-work-area"
                );
            }
        }
        let picker = CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed);
        if picker != 0 {
            let picker_width = (owner_bounds.width as f32 * 0.82).round() as i32;
            let picker_height =
                ((dpi_scaled(owner, 42 + 40 * 4) as f64) * current_text_scale()).round() as i32;
            let picker_x = (owner_bounds.left + owner_bounds.width / 2 - picker_width / 2)
                .clamp(work.left, work.left + work.width - picker_width);
            let picker_y = (owner_bounds.top - gap - picker_height)
                .clamp(work.top, work.top + work.height - picker_height);
            SetWindowPos(
                picker,
                HWND_TOPMOST,
                picker_x,
                picker_y,
                picker_width,
                picker_height,
                SWP_NOACTIVATE,
            );
            apply_rounded_region(picker, picker_width, picker_height);
        }
    }

    unsafe fn place_initial_fallback(hwnd: Hwnd) {
        if INITIAL_FALLBACK_PLACED.swap(true, Ordering::Relaxed) {
            return;
        }
        let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        let mut info = MonitorInfo {
            size: size_of::<MonitorInfo>() as Dword,
            monitor: std::mem::zeroed(),
            work: std::mem::zeroed(),
            flags: 0,
        };
        if GetMonitorInfoW(monitor, &mut info) == 0 {
            return;
        }
        let size = dpi_scaled(hwnd, native_logical_window_size());
        let x = info.work.left + ((info.work.right - info.work.left - size) / 2).max(0);
        let y = info.work.bottom - size;
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, size, size, SWP_NOACTIVATE);
        reposition_auxiliary_windows(hwnd);
        println!("[native-spike] phase=initial-placement-fallback rect=({x},{y},{},{}) source=monitor-work-area", x + size, y + size);
    }

    unsafe fn toggle_auxiliary(owner: Hwnd, window: Hwnd, kind: &str) {
        if window == 0 {
            return;
        }
        let visible = IsWindowVisible(window) != 0;
        if visible {
            hide_auxiliary_window(window);
        } else {
            reposition_auxiliary_windows(owner);
            if (kind == "menu" && !MENU_DRAG_SAFE.load(Ordering::Relaxed))
                || (kind == "submenu" && !SUBMENU_DRAG_SAFE.load(Ordering::Relaxed))
            {
                println!(
                    "[native-spike] phase=aux-visibility kind={kind} visible=false source=drag-safe-no-slot owner_unchanged=true"
                );
                return;
            }
            show_auxiliary_window(window);
            reposition_auxiliary_windows(owner);
        }
        sync_input_proxy_visibility();
        println!(
            "[native-spike] phase=aux-visibility kind={kind} visible={} owner_unchanged=true",
            !visible
        );
    }

    unsafe fn show_auxiliary_window(window: Hwnd) {
        if window == 0 {
            return;
        }
        // Layered popup fades and a 30-FPS aura repaint caused visible flashing
        // on the native hover surface, especially on ARM64. Prime the backing
        // surface while the HWND is still hidden, then reveal it atomically.
        // Never request a background erase: WM_PAINT owns every auxiliary pixel.
        AURA_FRAME.store(0, Ordering::Relaxed);
        InvalidateRect(window, null(), 0);
        UpdateWindow(window);
        ShowWindow(window, SW_SHOWNOACTIVATE);
        UpdateWindow(window);
        sync_aura_timer();
    }

    unsafe fn hide_auxiliary_window(window: Hwnd) {
        if window == 0 {
            return;
        }
        ShowWindow(window, SW_HIDE);
        sync_aura_timer();
    }

    unsafe fn sync_aura_timer() {
        let owner = MAIN_WINDOW.load(Ordering::Relaxed);
        if owner == 0 {
            return;
        }
        // Keep native quick-action surfaces static. Repainting layered popup
        // HWNDs every 33 ms looked like flicker on ARM64 and adds no functional
        // value. Theme/accent changes still invalidate the windows explicitly.
        KillTimer(owner, AURA_FRAME_TIMER);
        AURA_FRAME.store(0, Ordering::Relaxed);
    }

    unsafe fn set_auxiliary_visibility(
        owner: Hwnd,
        window: Hwnd,
        kind: &str,
        visible: bool,
        source: &str,
    ) {
        if window == 0 || (IsWindowVisible(window) != 0) == visible {
            return;
        }
        if visible {
            reposition_auxiliary_windows(owner);
            if (kind == "menu" && !MENU_DRAG_SAFE.load(Ordering::Relaxed))
                || (kind == "submenu" && !SUBMENU_DRAG_SAFE.load(Ordering::Relaxed))
            {
                println!(
                    "[native-spike] phase=hover-lifecycle kind={kind} visible=false source=drag-safe-no-slot owner_unchanged=true"
                );
                return;
            }
            show_auxiliary_window(window);
            reposition_auxiliary_windows(owner);
        } else {
            hide_auxiliary_window(window);
        }
        if kind == "submenu" {
            InvalidateRect(MENU_WINDOW.load(Ordering::Relaxed), null(), 0);
        }
        // Keep the character input proxy available for click/drag while
        // explicitly restoring interactive popups above it in the z-order.
        sync_input_proxy_visibility();
        println!("[native-spike] phase=hover-lifecycle kind={kind} visible={visible} source={source} owner_unchanged=true");
        if kind == "menu" {
            write_native_event(
                owner,
                if visible {
                    "hover-enter"
                } else {
                    "hover-leave"
                },
                None,
            );
        }
    }

    unsafe fn invalidate_auxiliary_hover_transition(hwnd: Hwnd, previous: i32, next: i32) {
        if previous == next {
            return;
        }
        let Some((header_height, row_height, row_count)) = auxiliary_layout(hwnd) else {
            return;
        };
        let mut client: Rect = std::mem::zeroed();
        if GetClientRect(hwnd, &mut client) == 0 {
            return;
        }

        // Size is a horizontal segmented control, so repaint its content strip
        // as one unit. Other menus only need the old/new rows invalidated.
        if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed)
            && SUBMENU_MODE.load(Ordering::Relaxed) == 1
        {
            let content = Rect {
                left: 0,
                top: header_height,
                right: client.right,
                bottom: client.bottom,
            };
            InvalidateRect(hwnd, &content, 0);
            return;
        }

        for row in [previous, next] {
            if row < 0 || row >= row_count {
                continue;
            }
            let dirty = Rect {
                left: 0,
                top: header_height + row * row_height,
                right: client.right,
                bottom: (header_height + (row + 1) * row_height).min(client.bottom),
            };
            InvalidateRect(hwnd, &dirty, 0);
        }
    }

    unsafe fn update_hover_item(hwnd: Hwnd, x: i32, y: i32) {
        let slot = if hwnd == MENU_WINDOW.load(Ordering::Relaxed) {
            &MENU_HOVER_ROW
        } else if hwnd == SUBMENU_WINDOW.load(Ordering::Relaxed) {
            &SUBMENU_HOVER_ROW
        } else if hwnd == CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed) {
            &PICKER_HOVER_ROW
        } else {
            return;
        };
        let next = auxiliary_item_at(hwnd, x, y).unwrap_or(-1);
        let previous = slot.swap(next, Ordering::Relaxed);
        invalidate_auxiliary_hover_transition(hwnd, previous, next);
    }

    unsafe fn sync_input_proxy_visibility() {
        let input = INPUT_WINDOW.load(Ordering::Relaxed);
        if input == 0 {
            return;
        }
        let owner = MAIN_WINDOW.load(Ordering::Relaxed);
        let render = RENDER_WINDOW.load(Ordering::Relaxed);
        let visible = input_proxy_should_be_visible(
            owner != 0 && IsWindowVisible(owner) != 0,
            render == 0 || IsWindowVisible(render) != 0,
            CLICK_THROUGH.load(Ordering::Relaxed),
        );
        ShowWindow(input, if visible { SW_SHOWNOACTIVATE } else { SW_HIDE });

        if visible {
            // Hover UI must remain interactive without sacrificing character
            // drag input. Reassert every visible auxiliary surface above the
            // alpha input proxy instead of hiding the proxy while menus are open.
            for surface in [
                BUBBLE_WINDOW.load(Ordering::Relaxed),
                MENU_WINDOW.load(Ordering::Relaxed),
                SUBMENU_WINDOW.load(Ordering::Relaxed),
                CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed),
            ] {
                if surface != 0 && IsWindowVisible(surface) != 0 {
                    SetWindowPos(
                        surface,
                        HWND_TOPMOST,
                        0,
                        0,
                        0,
                        0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                    );
                }
            }
        }
    }

    unsafe fn track_mouse_leave(hwnd: Hwnd, non_client: bool) {
        let mut event = TrackMouseEventData {
            size: size_of::<TrackMouseEventData>() as Dword,
            flags: TME_LEAVE | if non_client { TME_NONCLIENT } else { 0 },
            hwnd_track: hwnd,
            hover_time: 0,
        };
        TrackMouseEvent(&mut event);
    }

    unsafe fn cursor_inside_window(hwnd: Hwnd) -> bool {
        if hwnd == 0 || IsWindowVisible(hwnd) == 0 {
            return false;
        }
        let mut cursor: Point = std::mem::zeroed();
        let mut rect: Rect = std::mem::zeroed();
        GetCursorPos(&mut cursor) != 0
            && GetWindowRect(hwnd, &mut rect) != 0
            && cursor.x >= rect.left
            && cursor.x < rect.right
            && cursor.y >= rect.top
            && cursor.y < rect.bottom
    }

    unsafe fn cursor_in_visual_hitbox(hwnd: Hwnd, cursor: &Point) -> bool {
        if hwnd == 0 || IsWindowVisible(hwnd) == 0 {
            return false;
        }
        let mut rect: Rect = std::mem::zeroed();
        if GetWindowRect(hwnd, &mut rect) == 0 {
            return false;
        }
        visual_hitbox_bounds(hwnd).is_some_and(|bounds| bounds.contains((cursor.x, cursor.y)))
    }

    fn is_drag_input_window(hwnd: Hwnd) -> bool {
        hwnd == MAIN_WINDOW.load(Ordering::Relaxed) || hwnd == INPUT_WINDOW.load(Ordering::Relaxed)
    }

    unsafe fn visual_hitbox_bounds(hwnd: Hwnd) -> Option<PhysicalRect> {
        if hwnd == 0 || IsWindowVisible(hwnd) == 0 {
            return None;
        }
        let mut rect: Rect = std::mem::zeroed();
        if GetWindowRect(hwnd, &mut rect) == 0 {
            return None;
        }
        let (left, top, width, height) = visual_hitbox();
        let window_width = (rect.right - rect.left) as f32;
        let window_height = (rect.bottom - rect.top) as f32;
        let visual_left = (rect.left as f32 + window_width * left).round() as i32;
        let visual_top = (rect.top as f32 + window_height * top).round() as i32;
        let visual_width = (window_width * width).round().max(1.0) as i32;
        let visual_height = (window_height * height).round().max(1.0) as i32;
        // A 25% character is intentionally small, but it must remain usable.
        // Grow only the transparent input target (never the render HWND) to a
        // 64px physical minimum around the visible character.
        let minimum = 64;
        let target_width = visual_width.max(minimum).min(rect.right - rect.left);
        let target_height = visual_height.max(minimum).min(rect.bottom - rect.top);
        let centered_left = visual_left - (target_width - visual_width) / 2;
        let centered_top = visual_top - (target_height - visual_height) / 2;
        Some(PhysicalRect {
            left: centered_left.clamp(rect.left, rect.right - target_width),
            top: centered_top.clamp(rect.top, rect.bottom - target_height),
            width: target_width,
            height: target_height,
        })
    }

    unsafe fn toggle_active_attachment(hwnd: Hwnd) {
        let enabled = !ACTIVE_ATTACH.load(Ordering::Relaxed);
        ACTIVE_ATTACH.store(enabled, Ordering::Relaxed);
        if enabled {
            SetTimer(hwnd, ACTIVE_ATTACH_TIMER, 100, 0);
            follow_active_window(hwnd);
        } else {
            KillTimer(hwnd, ACTIVE_ATTACH_TIMER);
        }
        println!(
            "[native-spike] phase=active-attachment enabled={enabled} physics_committed=false"
        );
    }

    unsafe fn follow_active_window(companion: Hwnd) {
        let target = GetForegroundWindow();
        if target == 0
            || target == companion
            || target == RENDER_WINDOW.load(Ordering::Relaxed)
            || target == BUBBLE_WINDOW.load(Ordering::Relaxed)
            || target == MENU_WINDOW.load(Ordering::Relaxed)
        {
            return;
        }
        let mut target_rect: Rect = std::mem::zeroed();
        let mut companion_rect: Rect = std::mem::zeroed();
        if GetWindowRect(target, &mut target_rect) == 0
            || GetWindowRect(companion, &mut companion_rect) == 0
        {
            return;
        }
        let width = companion_rect.right - companion_rect.left;
        let height = companion_rect.bottom - companion_rect.top;
        let anchor = presentation_anchor();
        let contact_x = f64::from(target_rect.left + (target_rect.right - target_rect.left) / 2);
        let contact_y = f64::from(target_rect.top);
        let x = (contact_x - f64::from(width) * anchor.0).round() as i32;
        let y = (contact_y - f64::from(height) * anchor.1).round() as i32;
        SetWindowPos(companion, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
        reposition_auxiliary_windows(companion);
        println!(
            "[native-spike] phase=active-attachment-follow target={target:#x} companion_rect=({x},{y},{},{}) physics_committed=false",
            x + width,
            y + height
        );
    }

    pub unsafe fn run() -> Result<(), String> {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        register_bundled_ocp_font();
        let instance = GetModuleHandleW(null());
        let class = WndClassW {
            style: CS_HREDRAW | CS_VREDRAW,
            wnd_proc: Some(window_proc),
            class_extra: 0,
            window_extra: 0,
            instance,
            icon: 0,
            cursor: LoadCursorW(0, IDC_ARROW),
            background: 0,
            menu_name: null(),
            class_name: CLASS_NAME.as_ptr(),
        };
        if RegisterClassW(&class) == 0 {
            return Err("RegisterClassW failed".to_owned());
        }
        let embed_mode = std::env::var_os("OCP_NATIVE_HOST_EMBED").is_some();
        // In production embed mode this HWND is only the invisible native
        // controller. Do not create it visible and hide it afterward: that
        // leaves a compositor race where the diagnostic magenta client can
        // flash or remain visible behind the Godot render surface.
        // Create the production controller hidden first so Windows can never
        // expose the old diagnostic surface before layered alpha is configured.
        // After alpha=0 is applied below we show the HWND: input-proxy and hover
        // routing intentionally require IsWindowVisible(owner) to stay true.
        let controller_style = if embed_mode {
            WS_POPUP
        } else {
            WS_POPUP | WS_VISIBLE
        };
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            TITLE.as_ptr(),
            controller_style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            native_logical_window_size(),
            native_logical_window_size(),
            0,
            0,
            instance,
            null(),
        );
        if hwnd == 0 {
            return Err("CreateWindowExW failed".to_owned());
        }
        MAIN_WINDOW.store(hwnd, Ordering::Relaxed);
        SetLayeredWindowAttributes(hwnd, 0x00FF00FF, 255, LWA_COLORKEY);
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        );
        let handoff_mode = handoff_path().is_some();
        if embed_mode {
            // Production uses this HWND only as an invisible native controller.
            // Godot remains the single visible transparent character surface.
            let mut ex_style = GetWindowLongPtrW(hwnd, GWLP_EXSTYLE);
            ex_style |= WS_EX_TRANSPARENT as isize | WS_EX_NOACTIVATE as isize;
            SetWindowLongPtrW(hwnd, GWLP_EXSTYLE, ex_style);
            SetLayeredWindowAttributes(hwnd, 0, 0, LWA_ALPHA);
            // Keep the controller logically visible while remaining fully
            // transparent. The input proxy is an owned popup and its visibility
            // contract checks IsWindowVisible(owner); hiding this HWND disables
            // hover menus and drag capture entirely.
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        }
        if handoff_mode {
            write_host_handoff(hwnd)?;
        }
        RegisterHotKey(hwnd, HOTKEY_CLICK_THROUGH, MOD_CONTROL | MOD_ALT, VK_C);
        RegisterHotKey(hwnd, HOTKEY_QUIT, MOD_CONTROL | MOD_ALT, VK_Q);
        RegisterHotKey(hwnd, HOTKEY_CANONICAL_NEXT, MOD_CONTROL | MOD_ALT, VK_P);
        RegisterHotKey(hwnd, HOTKEY_BUBBLE, MOD_CONTROL | MOD_ALT, VK_B);
        RegisterHotKey(hwnd, HOTKEY_MENU, MOD_CONTROL | MOD_ALT, VK_M);
        RegisterHotKey(hwnd, HOTKEY_ACTIVE_ATTACH, MOD_CONTROL | MOD_ALT, VK_A);

        let bubble = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            TITLE.as_ptr(),
            WS_POPUP,
            0,
            0,
            220,
            80,
            hwnd,
            0,
            instance,
            null(),
        );
        let input = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            TITLE.as_ptr(),
            WS_POPUP,
            0,
            0,
            1,
            1,
            hwnd,
            0,
            instance,
            null(),
        );
        let menu = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            TITLE.as_ptr(),
            WS_POPUP,
            0,
            0,
            260,
            252,
            hwnd,
            0,
            instance,
            null(),
        );
        let submenu = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            TITLE.as_ptr(),
            WS_POPUP,
            0,
            0,
            180,
            144,
            hwnd,
            0,
            instance,
            null(),
        );
        let character_picker = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
            CLASS_NAME.as_ptr(),
            TITLE.as_ptr(),
            WS_POPUP,
            0,
            0,
            300,
            160,
            hwnd,
            0,
            instance,
            null(),
        );
        if input == 0 || bubble == 0 || menu == 0 || submenu == 0 || character_picker == 0 {
            DestroyWindow(hwnd);
            return Err("Create auxiliary window failed".to_owned());
        }
        INPUT_WINDOW.store(input, Ordering::Relaxed);
        BUBBLE_WINDOW.store(bubble, Ordering::Relaxed);
        MENU_WINDOW.store(menu, Ordering::Relaxed);
        SUBMENU_WINDOW.store(submenu, Ordering::Relaxed);
        CHARACTER_PICKER_WINDOW.store(character_picker, Ordering::Relaxed);
        SetLayeredWindowAttributes(bubble, 0x00FF00FF, 255, LWA_COLORKEY);
        // A value of 1 is the minimum non-zero layered-window alpha and keeps
        // the proxy hit-testable. Its WM_PAINT path uses neutral black so this
        // tiny alpha cannot tint the desktop purple around the character.
        SetLayeredWindowAttributes(input, 0, 1, LWA_ALPHA);
        // Suppress any DWM non-client shadow/glow on the invisible proxy too;
        // only Godot's per-pixel-alpha render HWND should be visually present.
        let input_nc_policy = DWMNCRP_DISABLED;
        DwmSetWindowAttribute(
            input,
            DWMWA_NCRENDERING_POLICY,
            &input_nc_policy as *const Dword as *const c_void,
            size_of::<Dword>() as Dword,
        );
        // Menus use alpha-only layering from their first paint; never prime
        // them with the magenta transparency key that can flash on reveal.
        apply_native_theme_transparency();
        reposition_auxiliary_windows(hwnd);
        sync_input_proxy_visibility();
        println!(
            "[native-spike] phase=input-proxy-ready alpha=1 neutral_rgb=0 dwm_nc=disabled hitbox_source=runtime owner_visible={} input_visible={} click_through={}",
            IsWindowVisible(hwnd) != 0,
            IsWindowVisible(input) != 0,
            CLICK_THROUGH.load(Ordering::Relaxed)
        );
        println!("[native-spike] ready: Ctrl+Alt+P canonical; Ctrl+Alt+B bubble; Ctrl+Alt+M menu; Ctrl+Alt+A active-window attach; Ctrl+Alt+C click-through; Ctrl+Alt+Q exits");
        log_placement(hwnd, "created");

        let mut message: Msg = std::mem::zeroed();
        let smoke_mode = std::env::var_os("OCP_NATIVE_SPIKE_SMOKE").is_some();
        let interactive_mode = std::env::var_os("OCP_NATIVE_INTERACTIVE").is_some();
        let production_mode = std::env::var_os("OCP_NATIVE_PRODUCTION_ENABLED").is_some();
        println!(
            "[native-spike] mode interactive={} production={} smoke={}",
            interactive_mode, production_mode, smoke_mode
        );
        let smoke_started = std::time::Instant::now();
        let mut smoke_positioned = false;
        let mut smoke_toggled = false;
        let mut smoke_auxiliary = false;
        let mut smoke_closed = false;
        let mut embedded_child: Hwnd = 0;
        let mut next_ui_ipc_poll = std::time::Instant::now();
        let mut next_lifecycle_ipc_poll = std::time::Instant::now();
        loop {
            if PeekMessageW(&mut message, 0, 0, 0, PM_REMOVE) != 0 {
                if message.message == 0x0012 {
                    break;
                }
                TranslateMessage(&message);
                DispatchMessageW(&message);
            } else {
                if handoff_mode && embed_mode && embedded_child != 0 {
                    poll_native_interaction(hwnd);
                }
                if smoke_mode
                    && !smoke_positioned
                    && smoke_started.elapsed() >= std::time::Duration::from_millis(50)
                {
                    apply_next_canonical_position(hwnd);
                    smoke_positioned = true;
                }
                if smoke_mode
                    && !smoke_toggled
                    && smoke_started.elapsed() >= std::time::Duration::from_millis(100)
                {
                    toggle_click_through(hwnd);
                    smoke_toggled = true;
                }
                if smoke_mode
                    && !smoke_auxiliary
                    && smoke_started.elapsed() >= std::time::Duration::from_millis(140)
                {
                    toggle_auxiliary(hwnd, BUBBLE_WINDOW.load(Ordering::Relaxed), "bubble");
                    toggle_auxiliary(hwnd, MENU_WINDOW.load(Ordering::Relaxed), "menu");
                    smoke_auxiliary = true;
                }
                if smoke_mode
                    && !handoff_mode
                    && !smoke_closed
                    && smoke_started.elapsed() >= std::time::Duration::from_millis(250)
                {
                    DestroyWindow(hwnd);
                    smoke_closed = true;
                }
                if handoff_mode
                    && embed_mode
                    && !smoke_closed
                    && embedded_child == 0
                    && handoff_contains("godot-ready")
                {
                    let payload = fs::read_to_string(handoff_path().expect("handoff path"))
                        .map_err(|error| format!("read Godot handoff failed: {error}"))?;
                    let marker = "\"godot_hwnd\":";
                    let child = payload
                        .split(marker)
                        .nth(1)
                        .and_then(|value| value.split([',', '}']).next())
                        .and_then(|value| value.parse::<isize>().ok())
                        .unwrap_or(0);
                    adopt_render_window(hwnd, child)?;
                    embedded_child = child;
                    place_initial_fallback(hwnd);
                    write_handoff_status("embedded", ",\"physics_committed\":false")?;
                    println!("[native-spike] phase=godot-surface-adopted controller={hwnd:#x} render={child:#x} top_level=true physics_committed=false");
                }
                if handoff_mode && embed_mode && !smoke_closed && embedded_child != 0 {
                    // Movement remains a 60 Hz-class path so native placement tracks
                    // Godot smoothly. Slower UI/lifecycle IPC is polled below.
                    apply_runtime_move_request(hwnd);
                    sync_render_window_to_controller(hwnd);
                    let now = std::time::Instant::now();
                    if now >= next_ui_ipc_poll {
                        apply_runtime_auxiliary_request(hwnd);
                        apply_runtime_bubble_request();
                        next_ui_ipc_poll = now + std::time::Duration::from_millis(50);
                    }
                    if now >= next_lifecycle_ipc_poll {
                        if handoff_contains("detach-request") {
                            release_render_window(embedded_child);
                            write_handoff_status("detached", ",\"physics_committed\":false")?;
                            println!("[native-spike] phase=godot-detached child={embedded_child:#x} physics_committed=false");
                        } else if handoff_contains("godot-exit-ready") {
                            write_handoff_status("host-closed", ",\"physics_committed\":false")?;
                            println!("[native-spike] phase=godot-exit-ready child={embedded_child:#x} physics_committed=false");
                            DestroyWindow(hwnd);
                            smoke_closed = true;
                        }
                        next_lifecycle_ipc_poll = now + std::time::Duration::from_millis(100);
                    }
                }
                if handoff_mode && !embed_mode && !smoke_closed && handoff_consumed() {
                    println!("[native-spike] phase=host-handoff-consumed physics_committed=false");
                    DestroyWindow(hwnd);
                    smoke_closed = true;
                }
                if handoff_mode
                    && !smoke_closed
                    && !interactive_mode
                    && !production_mode
                    && smoke_started.elapsed() >= std::time::Duration::from_secs(30)
                {
                    eprintln!("[native-spike] phase=host-handoff-timeout mode=noninteractive-nonproduction");
                    DestroyWindow(hwnd);
                    smoke_closed = true;
                }
                // Keep active pointer/menu interaction at the historical 125 Hz,
                // but do not wake the native host that often while the companion is
                // merely animating on the desktop. The render/controller sync only
                // needs a 60 Hz ceiling in the idle path; Godot owns animation and
                // physics state, while Win32 mouse messages still drive explicit drag.
                let interaction_active = DRAG_ACTIVE.load(Ordering::Relaxed)
                    || IsWindowVisible(MENU_WINDOW.load(Ordering::Relaxed)) != 0
                    || IsWindowVisible(SUBMENU_WINDOW.load(Ordering::Relaxed)) != 0
                    || IsWindowVisible(CHARACTER_PICKER_WINDOW.load(Ordering::Relaxed)) != 0;
                std::thread::sleep(std::time::Duration::from_millis(if interaction_active {
                    8
                } else {
                    16
                }));
            }
            expire_runtime_bubble();
        }
        UnregisterHotKey(hwnd, HOTKEY_CLICK_THROUGH);
        UnregisterHotKey(hwnd, HOTKEY_QUIT);
        UnregisterHotKey(hwnd, HOTKEY_CANONICAL_NEXT);
        UnregisterHotKey(hwnd, HOTKEY_BUBBLE);
        UnregisterHotKey(hwnd, HOTKEY_MENU);
        UnregisterHotKey(hwnd, HOTKEY_ACTIVE_ATTACH);
        println!("[native-spike] closed cleanly");
        Ok(())
    }
}

#[cfg(windows)]
fn main() {
    if let Err(error) = unsafe { windows_spike::run() } {
        eprintln!("[native-spike] ERROR: {error}");
        std::process::exit(1);
    }
}
