//! Foreground-window and mouse-idle-time OS queries (PLUGIN_API §7a, I4).
//!
//! This is the one crate in the workspace that permits `unsafe` code.
//! CODING_STANDARD.md's Safety section lists it as an audited exception,
//! alongside `packages/plugin-host`'s wasmtime internals and
//! `packages/plugin-sdk`'s guest ABI boundary. Neither of the two sensors
//! here -- "what window has focus" and "how long since the last
//! keystroke/click" -- exist as WASI-portable or `sysinfo`-covered
//! concepts; they only exist as native OS calls, so unlike `sysinfo`
//! (cpu/memory, `packages/plugin-host/src/telemetry.rs`) and
//! `starship-battery` (`packages/plugin-host/src/battery.rs`), there is no
//! safe cross-platform crate to reach for.
//!
//! Windows-first per ROADMAP: the Windows implementation uses the
//! `windows` crate's raw Win32 bindings. Every call is still `unsafe` at
//! the call site even for something as innocuous as `GetTickCount64` --
//! windows-rs's policy marks all FFI into arbitrary OS code as requiring
//! caller review, not only the calls that can literally corrupt memory.
//! On non-Windows targets both functions return `None` -- a stated,
//! honest "not implemented here yet" rather than a compile failure, so
//! `cargo test --workspace` stays green on Linux/macOS CI (the
//! cross-platform-from-the-start decision, Sprint 2) while the real
//! functionality is Windows-only for now.

#[cfg(windows)]
mod windows_impl {
    use windows::core::PWSTR;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::SystemInformation::GetTickCount64;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId,
    };

    /// `(window title, process file name)`. `process file name` is empty
    /// if the owning process couldn't be queried (e.g. a protected/system
    /// process this call lacks rights for) -- a real, honest partial
    /// result, not an error.
    pub fn foreground_window() -> Option<(String, String)> {
        // SAFETY: takes no arguments; cannot itself violate memory safety.
        // May return an invalid handle if there is genuinely no foreground
        // window at this instant (e.g. a transient desktop-switch moment),
        // handled below.
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.is_invalid() {
            return None;
        }

        let mut title_buf = [0u16; 512];
        // SAFETY: `title_buf` is a valid mutable slice of exactly the
        // length passed; `GetWindowTextW` never writes past it (documented
        // Win32 contract) and returns the number of chars actually written.
        let len = unsafe { GetWindowTextW(hwnd, &mut title_buf) };
        let title = String::from_utf16_lossy(&title_buf[..len.max(0) as usize]);

        let mut pid: u32 = 0;
        // SAFETY: `&mut pid` is a live, correctly-typed `u32` out-parameter;
        // the returned thread id is intentionally discarded.
        let _tid = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };

        let process_name = if pid == 0 {
            String::new()
        } else {
            process_name_for_pid(pid).unwrap_or_default()
        };
        Some((title, process_name))
    }

    fn process_name_for_pid(pid: u32) -> Option<String> {
        // SAFETY: `pid` is a plain integer the OS validates itself;
        // `OpenProcess` returns `Err` for anything invalid rather than
        // relying on any precondition we'd need to uphold ourselves.
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?;

        let mut buf = [0u16; 260]; // MAX_PATH
        let mut size = buf.len() as u32;
        let pwstr = PWSTR(buf.as_mut_ptr());
        // SAFETY: `pwstr` points into `buf`, a live buffer of exactly
        // `size` u16 elements as passed; `handle` is the valid handle
        // returned by the successful `OpenProcess` call directly above.
        let result =
            unsafe { QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, pwstr, &mut size) };
        // SAFETY: `handle` was opened by us just above and is closed here
        // exactly once, matching Win32's handle-ownership contract.
        unsafe {
            let _ = CloseHandle(handle);
        }
        result.ok()?;

        let full_path = String::from_utf16_lossy(&buf[..size as usize]);
        Some(
            full_path
                .rsplit(['\\', '/'])
                .next()
                .unwrap_or(&full_path)
                .to_owned(),
        )
    }

    /// Milliseconds since the last keyboard/mouse input, system-wide.
    pub fn mouse_idle_ms() -> Option<u64> {
        let mut info = LASTINPUTINFO {
            cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        // SAFETY: `info` is a live, correctly `cbSize`-initialized
        // `LASTINPUTINFO` -- the Win32 contract requires `cbSize` set
        // before the call so the API can validate struct-layout
        // compatibility across Windows versions.
        let ok = unsafe { GetLastInputInfo(&mut info) };
        if !ok.as_bool() {
            return None;
        }
        // SAFETY: takes no arguments; cannot violate memory safety.
        let now = unsafe { GetTickCount64() };
        // `dwTime` is a u32 ms-since-boot tick count; truncating `now` to
        // u32 and using `wrapping_sub` computes the correct elapsed time
        // even across the ~49.7-day u32 wraparound (the standard technique
        // for tick-count deltas), as long as the machine hasn't been up
        // *and* idle for more than one full wrap between input events -- an
        // extreme edge case, not handled specially.
        let now_ticks = now as u32;
        Some(u64::from(now_ticks.wrapping_sub(info.dwTime)))
    }
}

#[cfg(not(windows))]
mod fallback {
    pub fn foreground_window() -> Option<(String, String)> {
        None
    }

    pub fn mouse_idle_ms() -> Option<u64> {
        None
    }
}

#[cfg(not(windows))]
pub use fallback::{foreground_window, mouse_idle_ms};
#[cfg(windows)]
pub use windows_impl::{foreground_window, mouse_idle_ms};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreground_window_never_panics() {
        // Smoke test only -- whether it returns Some or None depends on
        // whatever OS/session this runs under (headless CI runners may
        // have no interactive desktop at all).
        let _ = foreground_window();
    }

    #[test]
    fn mouse_idle_ms_never_panics() {
        let _ = mouse_idle_ms();
    }
}
