//! Host-side OS telemetry sampling (PLUGIN_API §7a, I4). Runs entirely in
//! the native Plugin Host process — the WASM guest never touches an OS API
//! directly, so ADR-0007's sandbox guarantee holds unchanged. Windows-first
//! per ROADMAP, but CPU/memory sampling here uses `sysinfo` (safe, no
//! `unsafe` at any call site, genuinely cross-platform), so it happens to
//! build and run identically on Linux/macOS too — a bonus for CI parity,
//! not a scope change.
//!
//! **Slice scope**: only `cpu` and `memory` are implemented. `battery`,
//! `foreground`, and `mouse` are deliberately NOT here yet:
//! - `sysinfo` removed battery support upstream (the ecosystem's answer is
//!   the separate `starship-battery` crate) — a distinct, not-yet-approved
//!   dependency decision.
//! - `foreground`/`mouse` have no safe cross-platform crate at all; they
//!   need real OS-native calls (`GetForegroundWindow`, `GetLastInputInfo` on
//!   Windows) which are `unsafe` FFI — this crate is
//!   `#![forbid(unsafe_code)]` (SEC-042), so landing those three sensor
//!   kinds is a deliberate follow-up decision (a dedicated crate with a
//!   narrow, audited `unsafe` exception, same shape as `plugin-sdk`'s ABI
//!   boundary in CODING_STANDARD.md), not something to slip in quietly here.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;

use crate::manifest::TelemetryKind;
use crate::PluginHost;

/// A raw percentage at or above this is reported as `level: "high"`
/// (EVENT_CATALOG schema). Arbitrary default; a per-plugin override via
/// `telemetry_config`'s threshold mode is not wired yet (advisory-only
/// today, see PLUGIN_API §7a) — noted here rather than silently ignored.
const HIGH_THRESHOLD_PERCENT: f32 = 80.0;

fn level(percent: f32) -> &'static str {
    if percent >= HIGH_THRESHOLD_PERCENT {
        "high"
    } else {
        "normal"
    }
}

/// Samples CPU/memory via `sysinfo`. One instance lives for the whole
/// sampling loop's lifetime — there is exactly one real CPU/memory to read,
/// regardless of how many plugins are listening.
pub struct TelemetrySampler {
    sys: sysinfo::System,
}

impl TelemetrySampler {
    /// Establishes the baseline `sysinfo` needs for an accurate first CPU
    /// reading: its own docs recommend refresh, wait
    /// `MINIMUM_CPU_UPDATE_INTERVAL`, refresh again, before the first
    /// `global_cpu_usage()` call means anything. Only paid once, at
    /// construction — subsequent `sample_cpu_percent` calls are cheap and
    /// accurate as long as they're spaced further apart than that interval
    /// (true for any sampling loop slower than ~200ms).
    #[must_use]
    pub fn new() -> Self {
        let mut sys = sysinfo::System::new_all();
        sys.refresh_cpu_usage();
        std::thread::sleep(sysinfo::MINIMUM_CPU_UPDATE_INTERVAL);
        sys.refresh_cpu_usage();
        Self { sys }
    }

    /// 0.0..=100.0.
    pub fn sample_cpu_percent(&mut self) -> f32 {
        self.sys.refresh_cpu_usage();
        self.sys.global_cpu_usage()
    }

    /// 0.0..=100.0.
    pub fn sample_memory_percent(&mut self) -> f32 {
        self.sys.refresh_memory();
        let total = self.sys.total_memory();
        if total == 0 {
            return 0.0;
        }
        (self.sys.used_memory() as f64 / total as f64 * 100.0) as f32
    }
}

impl Default for TelemetrySampler {
    fn default() -> Self {
        Self::new()
    }
}

/// One sampling pass: reads CPU + memory once, publishes to every plugin
/// that's Active and holds the matching grant (`PluginHost::publish_os_telemetry`
/// silently no-ops a plugin that lacks the specific kind's grant — same
/// re-check-at-delivery shape as `host_event_next`'s subscribe check, so
/// runtime revocation, SEC-001, takes effect immediately).
///
/// Kept separate from `run_telemetry_loop` below so it's unit-testable
/// without a real sleep-driven background thread.
pub fn sample_once(host: &Arc<Mutex<PluginHost>>, sampler: &mut TelemetrySampler) {
    let cpu = sampler.sample_cpu_percent();
    let mem = sampler.sample_memory_percent();
    let mut h = host.lock().expect("host lock");
    for id in h.active_telemetry_plugins() {
        let _ = h.publish_os_telemetry(
            &id,
            TelemetryKind::Cpu,
            json!({ "pluginId": id, "percent": cpu, "level": level(cpu) }),
        );
        let _ = h.publish_os_telemetry(
            &id,
            TelemetryKind::Memory,
            json!({ "pluginId": id, "percent": mem, "level": level(mem) }),
        );
    }
}

/// Runs forever on its own thread. Deliberately **not** spawned automatically
/// by `PluginHost::new` — whoever owns the host (e.g. `ocp-kernel`) spawns
/// this explicitly, so unit tests never get a background thread they didn't
/// ask for and `sample_once` stays independently testable.
pub fn run_telemetry_loop(host: Arc<Mutex<PluginHost>>, interval: Duration) {
    let mut sampler = TelemetrySampler::new();
    loop {
        sample_once(&host, &mut sampler);
        std::thread::sleep(interval);
    }
}
