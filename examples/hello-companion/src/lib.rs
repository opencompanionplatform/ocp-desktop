//! Example OCP plugin. Depends only on `ocp-plugin-sdk` — it never sees a
//! kernel type (SEC-001 boundary). On activation it greets, remembers a
//! counter in its own memory scope, and publishes one event.
//!
//! Build: `cargo build -p hello-companion --target wasm32-wasip1 --release`
//! Run:   through the Plugin Host engine (see tests/e2e_example.rs).
//!
//! Uses std: the `wasm32-wasip1` target ships std with a global allocator and
//! panic handler, so an author writes ordinary Rust. The SDK stays `no_std`
//! so it also works for authors who choose `no_std`.

use ocp_plugin_sdk as ocp;

fn run() -> i32 {
    ocp::log(ocp::Level::Info, "hello-companion activated");

    // Persist a run counter in the plugin's own scope.
    let count = match ocp::mem_get("runs") {
        Ok(Some(bytes)) if bytes.len() == 1 => bytes[0] + 1,
        _ => 1,
    };
    if ocp::mem_set("runs", &[count]).is_err() {
        return 10;
    }

    // Publish one weather-updated event (payload = data field only).
    match ocp::publish("ocp.plugin.weather-updated", br#"{"tempC":21}"#) {
        Ok(()) => 0,
        Err(ocp::Error::CapabilityDenied) => 1,
        Err(ocp::Error::QuotaBreached) => 2,
        Err(_) => 3,
    }
}

ocp::ocp_plugin!(run);
