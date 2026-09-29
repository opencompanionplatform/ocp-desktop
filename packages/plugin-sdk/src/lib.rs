//! OCP Plugin SDK alpha — safe guest-side bindings for PLUGIN_ABI v1.
//!
//! A plugin author depends only on this crate. It provides:
//! - the required ABI exports (`ocp_abi_version`, `ocp_alloc`, `ocp_free`)
//!   via the [`ocp_plugin!`] macro, so authors write only their logic;
//! - safe wrappers over the `"ocp"` host imports with the `(ptr, len)` and
//!   buffer-too-small protocols handled internally (ABI §2, §3).
//!
//! The SDK pulls in **nothing** from the kernel — the guest cannot reach host
//! internals, only the imported functions (SEC-001 boundary).
//!
//! Off-wasm (host tests, `cargo test` on a normal target) the extern imports
//! are replaced by stubs so the crate still compiles; real behavior only
//! exists inside the sandbox.

#![no_std]

/// Public so the `ocp_plugin!` macro can name `alloc` types through `$crate`
/// (`$crate::__alloc::...`) regardless of whether the caller crate declared
/// `extern crate alloc` — works for both `no_std` and `std` plugins.
#[doc(hidden)]
pub extern crate alloc as __alloc;

use __alloc::string::String;
use __alloc::vec;
use __alloc::vec::Vec;

/// ABI version this SDK speaks (PLUGIN_ABI §1).
pub const ABI_VERSION: i32 = 1;

/// Log severities (ABI §3 `log`).
#[repr(i32)]
#[derive(Clone, Copy)]
pub enum Level {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

/// Host-call failures surfaced to guest code (ABI §4 negative codes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    CapabilityDenied,
    QuotaBreached,
    InvalidArgs,
    HostInternal,
    /// A non-standard negative code.
    Other(i32),
}

impl Error {
    fn from_code(code: i32) -> Self {
        match code {
            -1 => Self::CapabilityDenied,
            -2 => Self::QuotaBreached,
            -3 => Self::InvalidArgs,
            -4 => Self::HostInternal,
            other => Self::Other(other),
        }
    }
}

pub type Result<T> = core::result::Result<T, Error>;

// --- Host imports (module "ocp", PLUGIN_ABI §3) ------------------------------

#[cfg(target_family = "wasm")]
mod imports {
    #[link(wasm_import_module = "ocp")]
    extern "C" {
        pub fn log(level: i32, ptr: i32, len: i32) -> i32;
        pub fn event_publish(t_ptr: i32, t_len: i32, p_ptr: i32, p_len: i32) -> i32;
        pub fn event_next(buf_ptr: i32, buf_len: i32) -> i32;
        pub fn memory_get(k_ptr: i32, k_len: i32, buf_ptr: i32, buf_len: i32) -> i32;
        pub fn memory_set(k_ptr: i32, k_len: i32, v_ptr: i32, v_len: i32) -> i32;
        pub fn memory_delete(k_ptr: i32, k_len: i32) -> i32;
        pub fn telemetry_config(k_ptr: i32, k_len: i32, mode: i32, value: i64) -> i32;
    }
}

// Off-wasm stubs so the crate builds on the host for unit tests.
#[cfg(not(target_family = "wasm"))]
mod imports {
    pub unsafe fn log(_l: i32, _p: i32, _n: i32) -> i32 {
        0
    }
    pub unsafe fn event_publish(_a: i32, _b: i32, _c: i32, _d: i32) -> i32 {
        0
    }
    pub unsafe fn event_next(_p: i32, _n: i32) -> i32 {
        0
    }
    pub unsafe fn memory_get(_a: i32, _b: i32, _c: i32, _d: i32) -> i32 {
        0
    }
    pub unsafe fn memory_set(_a: i32, _b: i32, _c: i32, _d: i32) -> i32 {
        0
    }
    pub unsafe fn memory_delete(_a: i32, _b: i32) -> i32 {
        0
    }
    pub unsafe fn telemetry_config(_a: i32, _b: i32, _c: i32, _d: i64) -> i32 {
        0
    }
}

fn parts(s: &[u8]) -> (i32, i32) {
    (s.as_ptr() as i32, s.len() as i32)
}

/// Grows the buffer once when the host signals `-needed` (ABI §3 protocol).
fn read_into_buffer(mut call: impl FnMut(i32, i32) -> i32) -> Result<Option<Vec<u8>>> {
    let mut buf = vec![0u8; 256];
    let rc = call(buf.as_mut_ptr() as i32, buf.len() as i32);
    if rc == 0 {
        return Ok(None);
    }
    if rc > 0 {
        buf.truncate(rc as usize);
        return Ok(Some(buf));
    }
    // rc < 0: either a needed-size hint or an error code. Payloads are always
    // larger than the 4 reserved error codes, so |rc| > 4 means "grow".
    let needed = rc.unsigned_abs() as usize;
    if needed <= 4 {
        return Err(Error::from_code(rc));
    }
    let mut buf = vec![0u8; needed];
    let rc2 = call(buf.as_mut_ptr() as i32, buf.len() as i32);
    if rc2 < 0 {
        return Err(Error::from_code(rc2));
    }
    buf.truncate(rc2 as usize);
    Ok(Some(buf))
}

fn check(rc: i32) -> Result<()> {
    if rc >= 0 {
        Ok(())
    } else {
        Err(Error::from_code(rc))
    }
}

/// Write a log line (ABI §3 `log`).
pub fn log(level: Level, message: &str) {
    let (p, n) = parts(message.as_bytes());
    // Logging failures are non-fatal by contract; ignore the code.
    unsafe {
        let _ = imports::log(level as i32, p, n);
    }
}

/// Publish an event. `payload_json` is the `data` field only; the host builds
/// and validates the envelope and stamps identity (ABI §3, X1-S).
pub fn publish(topic: &str, payload_json: &[u8]) -> Result<()> {
    let (tp, tn) = parts(topic.as_bytes());
    let (pp, pn) = parts(payload_json);
    check(unsafe { imports::event_publish(tp, tn, pp, pn) })
}

/// Pull the next subscribed event, or `None` if the queue is empty.
pub fn next_event() -> Result<Option<Vec<u8>>> {
    read_into_buffer(|ptr, len| unsafe { imports::event_next(ptr, len) })
}

/// Read a value from the plugin's own memory scope.
pub fn mem_get(key: &str) -> Result<Option<Vec<u8>>> {
    let (kp, kn) = parts(key.as_bytes());
    read_into_buffer(|ptr, len| unsafe { imports::memory_get(kp, kn, ptr, len) })
}

/// Write a value to the plugin's own memory scope.
pub fn mem_set(key: &str, value: &[u8]) -> Result<()> {
    let (kp, kn) = parts(key.as_bytes());
    let (vp, vn) = parts(value);
    check(unsafe { imports::memory_set(kp, kn, vp, vn) })
}

/// Delete a key from the plugin's own memory scope.
pub fn mem_delete(key: &str) -> Result<()> {
    let (kp, kn) = parts(key.as_bytes());
    check(unsafe { imports::memory_delete(kp, kn) })
}

/// Sampling mode for [`telemetry_config`] (PLUGIN_ABI §3, PLUGIN_API §7a).
#[repr(i32)]
#[derive(Clone, Copy)]
pub enum TelemetryMode {
    /// `value` is a sampling interval in milliseconds.
    IntervalMs = 0,
    /// `value` is a threshold (percent for cpu/memory/battery, idle-ms for mouse).
    Threshold = 1,
}

/// Advisory request to the host's own OS-sampling loop for one sensor kind
/// (`"cpu"`, `"memory"`, `"battery"`, `"foreground"`, or `"mouse"` —
/// PLUGIN_API §7a). The host may clamp to its own floor. This call does not
/// itself return a reading: sampled values arrive later as ordinary
/// `ocp.plugin.os-telemetry-*-changed` events through [`next_event`], on
/// whichever of those topics the manifest also declared in
/// `capabilities.events.subscribe` — `telemetry_config` only gates and tunes
/// the host's sampling, it is not a separate delivery channel.
pub fn telemetry_config(kind: &str, mode: TelemetryMode, value: i64) -> Result<()> {
    let (kp, kn) = parts(kind.as_bytes());
    check(unsafe { imports::telemetry_config(kp, kn, mode as i32, value) })
}

/// UTF-8 helper for guests that keep event payloads as strings.
pub fn bytes_to_string(bytes: Vec<u8>) -> Result<String> {
    String::from_utf8(bytes).map_err(|_| Error::InvalidArgs)
}

// --- Required ABI exports (ABI §1) -------------------------------------------

/// Emit the mandatory ABI exports and wire `ocp_start` to the author's entry
/// function `fn() -> i32`. Authors write one function and call this once.
///
/// ```ignore
/// use ocp_plugin_sdk as ocp;
/// fn run() -> i32 { ocp::log(ocp::Level::Info, "hello"); 0 }
/// ocp::ocp_plugin!(run);
/// ```
#[macro_export]
macro_rules! ocp_plugin {
    ($entry:path) => {
        #[no_mangle]
        pub extern "C" fn ocp_abi_version() -> i32 {
            $crate::ABI_VERSION
        }

        /// Bump-allocate `len` bytes and hand the pointer to the host (ABI §2).
        #[no_mangle]
        pub extern "C" fn ocp_alloc(len: i32) -> i32 {
            let mut buf: $crate::__alloc::vec::Vec<u8> =
                $crate::__alloc::vec::Vec::with_capacity(len as usize);
            let ptr = buf.as_mut_ptr() as i32;
            ::core::mem::forget(buf);
            ptr
        }

        /// Reclaim a buffer previously handed out (ABI §2).
        #[no_mangle]
        pub extern "C" fn ocp_free(ptr: i32, len: i32) {
            unsafe {
                let _ = $crate::__alloc::vec::Vec::from_raw_parts(ptr as *mut u8, 0, len as usize);
            }
        }

        #[no_mangle]
        pub extern "C" fn ocp_start() -> i32 {
            $entry()
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_code_mapping_matches_abi() {
        assert_eq!(Error::from_code(-1), Error::CapabilityDenied);
        assert_eq!(Error::from_code(-2), Error::QuotaBreached);
        assert_eq!(Error::from_code(-3), Error::InvalidArgs);
        assert_eq!(Error::from_code(-4), Error::HostInternal);
        assert_eq!(Error::from_code(-99), Error::Other(-99));
    }

    #[test]
    fn check_treats_nonnegative_as_ok() {
        assert!(check(0).is_ok());
        assert!(check(42).is_ok());
        assert_eq!(check(-2), Err(Error::QuotaBreached));
    }
}
