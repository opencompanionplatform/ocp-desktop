//! End-to-end: the `os-telemetry-monitor` example plugin (PLUGIN_API §7a,
//! I4), built against the SDK ONLY, run through the real Plugin Host engine.
//! Proves a real WASM guest can request OS telemetry sampling
//! (`telemetry_config`) and receive a real host-published
//! `ocp.plugin.os-telemetry-*-changed` fact back through the ordinary
//! `event_next` subscribe path — the actual "plugin built against SDK
//! alpha" bar I4's checklist sets, not just host-side logic exercised in
//! isolation (that's what `cs_plg_telemetry.rs` already covers).
//!
//! The wasm artifact is produced by `examples/build_os_telemetry_monitor.ps1`
//! (or `cargo build -p os-telemetry-monitor --target wasm32-wasip1 --release`).
//! If it is absent the test fails with instructions rather than silently
//! skipping — this is a gate, same as `e2e_example.rs`.
#![cfg(feature = "engine")]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::engine::{load_and_start, EngineConfig, RunOutcome};
use ocp_plugin_host::manifest::TelemetryKind;
use ocp_plugin_host::verify::TrustStore;
use ocp_plugin_host::{HostConfig, PluginHost};
use rand::rngs::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};

const KEY_ID: &str = "ed25519:pub-test";
const PLUGIN_ID: &str = "com.example.os-telemetry-monitor";

fn wasm_path() -> PathBuf {
    // examples/os-telemetry-monitor has its own target dir (outside the workspace).
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(
        "../../examples/os-telemetry-monitor/target/wasm32-wasip1/release/os_telemetry_monitor.wasm",
    )
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn signed_manifest(key: &SigningKey, package: &[u8]) -> String {
    let digest = Sha256::digest(package);
    let sig = key.sign(&digest);
    json!({
        "manifestVersion": "1.0",
        "id": PLUGIN_ID,
        "name": "OS Telemetry Monitor",
        "version": "0.1.0",
        "publisher": { "id": "example", "name": "Example", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "entry": "os_telemetry_monitor.wasm",
        "signature": {
            "algorithm": "ed25519", "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "telemetry": ["cpu", "memory"],
            "events": {
                "subscribe": [
                    "ocp.plugin.os-telemetry-cpu-changed",
                    "ocp.plugin.os-telemetry-memory-changed"
                ]
            },
            "memory": [ { "scope": format!("plugin:{PLUGIN_ID}"), "access": "read-write" } ]
        }
    })
    .to_string()
}

#[test]
fn example_plugin_requests_and_receives_os_telemetry() {
    let path = wasm_path();
    let wasm = std::fs::read(&path).unwrap_or_else(|_| {
        panic!(
            "example wasm not found at {}\n\
             build it first:  examples\\build_os_telemetry_monitor.ps1\n\
             (or: cargo build -p os-telemetry-monitor --target wasm32-wasip1 --release)",
            path.display()
        )
    });

    let key = SigningKey::generate(&mut OsRng);
    let bus = InProcessBus::new();
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, key.verifying_key());
    let mut host = PluginHost::new(bus.clone(), trust, HostConfig::default());

    let manifest = signed_manifest(&key, &wasm);
    let id = host.discover(&manifest, None).expect("discover");
    host.install(&id, &wasm, None).expect("install");
    host.activate(&id, &wasm, None).expect("activate"); // subscribes both topics now

    // Simulate the host's real OS-sampling loop (packages/plugin-host/src/telemetry.rs)
    // delivering one high CPU reading before the guest ever runs. Order
    // matters: activation must already have subscribed the topic on the bus.
    host.publish_os_telemetry(
        &id,
        TelemetryKind::Cpu,
        json!({ "pluginId": id, "percent": 91.0, "level": "high" }),
    )
    .expect("host publish should succeed — plugin holds the cpu grant");

    let host = Arc::new(Mutex::new(host));
    let outcome =
        load_and_start(host.clone(), PLUGIN_ID, &wasm, &EngineConfig::default()).expect("run");
    assert_eq!(outcome, RunOutcome::Completed(0), "entry returned non-zero");

    // The plugin persisted a "high readings seen" counter after draining the
    // queued event — read it back directly to prove the whole round trip
    // (telemetry_config request -> host publish -> event_next -> guest logic
    // -> memory_set) actually happened inside the real sandboxed guest, not
    // just that the process exited 0.
    let high_readings = host
        .lock()
        .unwrap()
        .host_memory_get(&id, "high_readings")
        .expect("memory read should succeed")
        .expect("plugin should have persisted a high_readings counter");
    assert_eq!(high_readings, 1u32.to_le_bytes().to_vec());
}
