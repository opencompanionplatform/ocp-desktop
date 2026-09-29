//! CS-PLG telemetry subset — PLUGIN_API §7a (I4). Certifies: the host's own
//! `publish_os_telemetry` is grant-gated and re-checks at publish time
//! (SEC-001), `active_telemetry_plugins` only surfaces plugins that can
//! actually receive something, and `TelemetrySampler` returns sane
//! real-world CPU/memory percentages via `sysinfo` (no OS mocking needed —
//! this is real host machine data, same as any developer machine running
//! the suite).
#![cfg(feature = "os-telemetry")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::manifest::TelemetryKind;
use ocp_plugin_host::telemetry::{sample_once, TelemetrySampler};
use ocp_plugin_host::verify::TrustStore;
use ocp_plugin_host::{HostConfig, PluginHost};
use rand::rngs::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};

const PACKAGE: &[u8] = b"pretend-wasm-package-bytes";
const KEY_ID: &str = "ed25519:pub-test";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn signed_manifest_json(key: &SigningKey, telemetry: &[&str]) -> String {
    let digest = Sha256::digest(PACKAGE);
    let sig = key.sign(&digest);
    json!({
        "manifestVersion": "1.0",
        "id": "com.example.sysmon",
        "name": "System Monitor",
        "version": "1.0.0",
        "publisher": { "id": "example-studio", "name": "Example Studio", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "tier": "wasm",
        "entry": "sysmon.wasm",
        "signature": {
            "algorithm": "ed25519",
            "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "events": {
                "subscribe": ["ocp.plugin.os-telemetry-cpu-changed", "ocp.plugin.os-telemetry-memory-changed"]
            },
            "telemetry": telemetry
        }
    })
    .to_string()
}

fn activated_host_with_telemetry(
    telemetry: &[&str],
) -> (Arc<Mutex<PluginHost>>, InProcessBus, String) {
    let key = SigningKey::generate(&mut OsRng);
    let bus = InProcessBus::new();
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, key.verifying_key());
    let mut host = PluginHost::new(bus.clone(), trust, HostConfig::default());
    let id = host
        .discover(&signed_manifest_json(&key, telemetry), None)
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");
    (Arc::new(Mutex::new(host)), bus, id)
}

#[test]
fn active_telemetry_plugins_only_lists_grant_holders() {
    let (host_none, _bus, _id_none) = activated_host_with_telemetry(&[]);
    assert!(
        host_none
            .lock()
            .unwrap()
            .active_telemetry_plugins()
            .is_empty(),
        "plugin with no telemetry grant should not be listed"
    );

    let (host_cpu, _bus2, id_cpu) = activated_host_with_telemetry(&["cpu"]);
    assert_eq!(
        host_cpu.lock().unwrap().active_telemetry_plugins(),
        vec![id_cpu]
    );
}

#[test]
fn publish_os_telemetry_respects_the_grant() {
    let (host, bus, id) = activated_host_with_telemetry(&["cpu"]);
    let cpu_events = bus.subscribe("ocp.plugin.os-telemetry-cpu-changed");

    host.lock()
        .unwrap()
        .publish_os_telemetry(
            &id,
            TelemetryKind::Cpu,
            json!({ "pluginId": id, "percent": 12.5, "level": "normal" }),
        )
        .expect("granted kind should publish");
    let env = cpu_events
        .recv_timeout(Duration::from_millis(500))
        .expect("cpu event should arrive");
    assert_eq!(
        env.source, "plugin-host",
        "host, not the guest, is the source (X1-S)"
    );

    assert!(
        host.lock()
            .unwrap()
            .publish_os_telemetry(&id, TelemetryKind::Memory, json!({ "percent": 5.0 }))
            .is_err(),
        "ungranted telemetry kind must not publish"
    );
}

#[test]
fn sampler_returns_sane_real_percentages() {
    // Real host machine data (no OS mocking) — just checking the range is
    // sane, not a specific value.
    let mut sampler = TelemetrySampler::new();
    let cpu = sampler.sample_cpu_percent();
    let mem = sampler.sample_memory_percent();
    assert!(
        (0.0..=100.0).contains(&cpu),
        "cpu percent out of range: {cpu}"
    );
    assert!(
        (0.0..=100.0).contains(&mem),
        "memory percent out of range: {mem}"
    );
}

#[test]
fn sample_once_publishes_cpu_and_memory_to_a_granted_plugin() {
    let (host, bus, _id) = activated_host_with_telemetry(&["cpu", "memory"]);
    let cpu_events = bus.subscribe("ocp.plugin.os-telemetry-cpu-changed");
    let mem_events = bus.subscribe("ocp.plugin.os-telemetry-memory-changed");

    let mut sampler = TelemetrySampler::new();
    sample_once(&host, &mut sampler);

    cpu_events
        .recv_timeout(Duration::from_millis(500))
        .expect("cpu event should arrive from sample_once");
    mem_events
        .recv_timeout(Duration::from_millis(500))
        .expect("memory event should arrive from sample_once");
}
