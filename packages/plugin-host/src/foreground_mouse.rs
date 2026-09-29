//! Host-side foreground-window and mouse-idle telemetry (PLUGIN_API §7a,
//! I4). Delegates all OS-specific work to `ocp-os-sensors` — the one crate
//! in this workspace with `unsafe` FFI (CODING_STANDARD.md Safety
//! exception) — so this module needs no `unsafe` itself and stays inside
//! this crate's own `#![forbid(unsafe_code)]` (SEC-042).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;

use crate::manifest::TelemetryKind;
use crate::PluginHost;

/// At/above this many idle milliseconds, mouse state is `"idle"`
/// (EVENT_CATALOG schema).
const MOUSE_IDLE_THRESHOLD_MS: u64 = 60_000; // 60s

fn mouse_state(idle_ms: u64) -> &'static str {
    if idle_ms >= MOUSE_IDLE_THRESHOLD_MS {
        "idle"
    } else {
        "active"
    }
}

/// Basic hygiene for untrusted OS-provided text (a window title can contain
/// anything, including control characters) before it enters an envelope a
/// downstream Behavior Engine rule might eventually surface in a bubble.
/// Mirrors the spirit of RUNTIME_API §5's rendering rule without taking a
/// cross-crate dependency on `ocp-runtime-api` for one helper — worth
/// reconsidering if more host-side telemetry ends up needing the same
/// treatment.
fn sanitize(input: &str) -> String {
    const MAX_CHARS: usize = 256;
    input
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_CHARS)
        .collect()
}

/// One sampling pass for the foreground-window sensor. No-ops quietly if
/// the OS query returned nothing (e.g. no interactive desktop session —
/// true of most headless CI runners), same tolerant shape as
/// `battery::sample_battery_once`.
pub fn sample_foreground_once(host: &Arc<Mutex<PluginHost>>) {
    let Some((window_title, process_name)) = ocp_os_sensors::foreground_window() else {
        return;
    };
    let window_title = sanitize(&window_title);
    let process_name = sanitize(&process_name);
    let mut h = host.lock().expect("host lock");
    for id in h.active_telemetry_plugins() {
        let _ = h.publish_os_telemetry(
            &id,
            TelemetryKind::Foreground,
            json!({ "pluginId": id, "windowTitle": window_title, "processName": process_name }),
        );
    }
}

/// One sampling pass for the mouse-idle sensor.
pub fn sample_mouse_once(host: &Arc<Mutex<PluginHost>>) {
    let Some(idle_ms) = ocp_os_sensors::mouse_idle_ms() else {
        return;
    };
    let mut h = host.lock().expect("host lock");
    for id in h.active_telemetry_plugins() {
        let _ = h.publish_os_telemetry(
            &id,
            TelemetryKind::Mouse,
            json!({ "pluginId": id, "state": mouse_state(idle_ms), "idleMs": idle_ms }),
        );
    }
}

/// Runs forever on its own thread — same pattern as
/// `telemetry::run_telemetry_loop`/`battery::run_battery_loop` (not spawned
/// automatically; whoever owns the host starts it explicitly, independently
/// of the other two sensor loops).
pub fn run_foreground_loop(host: Arc<Mutex<PluginHost>>, interval: Duration) {
    loop {
        sample_foreground_once(&host);
        std::thread::sleep(interval);
    }
}

/// Runs forever on its own thread, same shape as `run_foreground_loop`.
pub fn run_mouse_loop(host: Arc<Mutex<PluginHost>>, interval: Duration) {
    loop {
        sample_mouse_once(&host);
        std::thread::sleep(interval);
    }
}
