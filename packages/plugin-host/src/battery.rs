//! Host-side battery telemetry (PLUGIN_API §7a, I4). Separate module and
//! feature from `telemetry.rs`'s CPU/memory sampling because it's a
//! genuinely different dependency: `sysinfo` dropped battery support
//! upstream, so this uses `starship-battery` instead — also a safe API, no
//! `unsafe` at any call site, keeping this crate's `#![forbid(unsafe_code)]`
//! intact (SEC-042).
//!
//! **Simplification, stated rather than silently assumed**: reports only
//! the first battery found. Multi-battery systems (rare — some
//! workstations, a handful of laptop models) would need either aggregation
//! or per-battery ids; not attempted this slice.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;

use crate::manifest::TelemetryKind;
use crate::PluginHost;

/// At or below this percent, `level` is `"low"` (EVENT_CATALOG schema).
/// Battery's concerning direction is low, unlike cpu/memory's high — a
/// separate threshold constant from `telemetry.rs`'s `HIGH_THRESHOLD_PERCENT`
/// on purpose, they are not the same axis.
const LOW_BATTERY_PERCENT: f32 = 20.0;

fn level(percent: f32) -> &'static str {
    if percent <= LOW_BATTERY_PERCENT {
        "low"
    } else {
        "normal"
    }
}

/// One battery reading.
pub struct BatteryReading {
    pub percent: f32,
    /// `true` when `starship_battery::State` is `Charging` or `Full` (i.e.
    /// gaining charge, or already full while still on AC). `starship-battery`
    /// doesn't expose a separate "physically on AC but net-discharging under
    /// heavy load" state, so that nuance isn't representable here — stated
    /// rather than silently glossed over.
    pub charging: bool,
}

/// Wraps `starship_battery::Manager`. Reports only the first battery found
/// (see module doc).
pub struct BatterySampler {
    manager: starship_battery::Manager,
}

impl BatterySampler {
    /// `Manager::new()` succeeds even on a machine with no battery at all
    /// (desktops, most CI runners) — it just sets up the OS query capability;
    /// `sample()` is what returns `None` in that case.
    pub fn new() -> Result<Self, starship_battery::Error> {
        Ok(Self {
            manager: starship_battery::Manager::new()?,
        })
    }

    /// `None` if the machine has no battery, or the OS query failed — both
    /// are facts to report as "nothing to sample," not something to crash
    /// or error over.
    pub fn sample(&mut self) -> Option<BatteryReading> {
        let mut batteries = self.manager.batteries().ok()?;
        let mut battery = batteries.next()?.ok()?;
        self.manager.refresh(&mut battery).ok()?;
        let percent = battery
            .state_of_charge()
            .get::<starship_battery::units::ratio::percent>();
        let charging = matches!(
            battery.state(),
            starship_battery::State::Charging | starship_battery::State::Full
        );
        Some(BatteryReading { percent, charging })
    }
}

/// One sampling pass — same shape as `telemetry::sample_once` but for the
/// separate `starship-battery` dependency. Quietly does nothing if the
/// machine has no battery, rather than erroring.
pub fn sample_battery_once(host: &Arc<Mutex<PluginHost>>, sampler: &mut BatterySampler) {
    let Some(reading) = sampler.sample() else {
        return;
    };
    let mut h = host.lock().expect("host lock");
    for id in h.active_telemetry_plugins() {
        let _ = h.publish_os_telemetry(
            &id,
            TelemetryKind::Battery,
            json!({
                "pluginId": id,
                "percent": reading.percent,
                "level": level(reading.percent),
                "charging": reading.charging,
            }),
        );
    }
}

/// Runs forever on its own thread — same pattern as
/// `telemetry::run_telemetry_loop` (not spawned automatically; whoever owns
/// the host, e.g. `ocp-kernel`, starts it explicitly, and independently of
/// the cpu/memory loop since these are two separate optional dependencies).
/// If the platform battery API is totally unavailable, this exits quietly
/// rather than looping on a broken sampler.
pub fn run_battery_loop(host: Arc<Mutex<PluginHost>>, interval: Duration) {
    let Ok(mut sampler) = BatterySampler::new() else {
        return;
    };
    loop {
        sample_battery_once(&host, &mut sampler);
        std::thread::sleep(interval);
    }
}
