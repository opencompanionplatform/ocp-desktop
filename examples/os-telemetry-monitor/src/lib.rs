//! Example OCP plugin — proves PLUGIN_API §7a end-to-end: requests OS
//! telemetry sampling from the host (`ocp_telemetry_config`), then reacts to
//! whatever the host's real sampling loop delivers back as ordinary
//! subscribed events (`ocp_event_next`). Depends only on `ocp-plugin-sdk`
//! (SEC-001 boundary) — same shape as `hello-companion`, but for I4 instead
//! of I1.
//!
//! Build: `cargo build -p os-telemetry-monitor --target wasm32-wasip1 --release`
//! Run:   through the Plugin Host engine (see tests/e2e_os_telemetry.rs).
//!
//! Uses std: the `wasm32-wasip1` target ships std with a global allocator and
//! panic handler, so an author writes ordinary Rust (same note as
//! `hello-companion` — the SDK itself stays `no_std`).

use ocp_plugin_sdk as ocp;

fn run() -> i32 {
    ocp::log(ocp::Level::Info, "os-telemetry-monitor activated");

    // Advisory: ask the host's sampling loop to flag readings at/above 80%.
    // The host may clamp to its own floor (PLUGIN_API §7a) — a real author
    // would tune this per sensor and per companion personality.
    let _ = ocp::telemetry_config("cpu", ocp::TelemetryMode::Threshold, 80);
    let _ = ocp::telemetry_config("memory", ocp::TelemetryMode::Threshold, 80);

    // Running count of "high" readings seen, persisted in this plugin's own
    // memory scope (reuses the same mem_get/mem_set pattern hello-companion
    // demonstrated for I1 — nothing new about memory here, just applied to
    // a second real use case).
    let mut high_readings: u32 = match ocp::mem_get("high_readings") {
        Ok(Some(bytes)) if bytes.len() == 4 => {
            u32::from_le_bytes(bytes.try_into().expect("checked len == 4"))
        }
        _ => 0,
    };

    // Drain whatever the host's sampling loop already delivered. Bounded —
    // no plugin may block or loop unboundedly under the fuel quota
    // (SEC-004); this cap is just tidy, the fuel quota is the real backstop.
    let mut handled = 0u32;
    while let Ok(Some(bytes)) = ocp::next_event() {
        handled += 1;
        if let Ok(text) = ocp::bytes_to_string(bytes) {
            ocp::log(ocp::Level::Info, &text);
            if text.contains("\"level\":\"high\"") {
                high_readings += 1;
            }
        }
        if handled >= 16 {
            break;
        }
    }

    if ocp::mem_set("high_readings", &high_readings.to_le_bytes()).is_err() {
        return 10;
    }
    0
}

ocp::ocp_plugin!(run);
