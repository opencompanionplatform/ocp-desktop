//! CS-PLG battery subset — PLUGIN_API §7a (I4). Separate from
//! `cs_plg_telemetry.rs` because battery uses a genuinely different
//! dependency (`starship-battery`, not `sysinfo`).
//!
//! Deliberately tolerant of "no battery present": most CI runners (and any
//! desktop) have zero batteries, and that is a fact to handle gracefully,
//! not a test failure. Only the capability-gating test needs a real grant
//! check, which doesn't require an actual battery to exist.
#![cfg(feature = "battery-telemetry")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::battery::{sample_battery_once, BatterySampler};
use ocp_plugin_host::manifest::TelemetryKind;
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
        "id": "com.example.battery-watch",
        "name": "Battery Watch",
        "version": "1.0.0",
        "publisher": { "id": "example-studio", "name": "Example Studio", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "tier": "wasm",
        "entry": "battery-watch.wasm",
        "signature": {
            "algorithm": "ed25519",
            "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "events": { "subscribe": ["ocp.plugin.os-telemetry-battery-changed"] },
            "telemetry": telemetry
        }
    })
    .to_string()
}

#[test]
fn battery_sampler_constructs_without_requiring_a_battery_to_exist() {
    // Manager::new() sets up the OS query capability; it must not require an
    // actual battery to be present (desktops, most CI runners have none).
    BatterySampler::new().expect("BatterySampler::new should succeed even with no battery");
}

#[test]
fn sample_returns_sane_values_or_none_if_no_battery_present() {
    let mut sampler = BatterySampler::new().expect("construct");
    if let Some(reading) = sampler.sample() {
        assert!(
            (0.0..=100.0).contains(&reading.percent),
            "battery percent out of range: {}",
            reading.percent
        );
    }
    // `None` (no battery on this machine) is an equally valid outcome —
    // deliberately no assertion forcing `Some` here.
}

#[test]
fn publish_battery_telemetry_respects_the_grant() {
    // Capability-gating logic only — doesn't require a real battery reading,
    // same style as cs_plg_telemetry.rs's cpu/memory grant test.
    let key = SigningKey::generate(&mut OsRng);
    let bus = InProcessBus::new();
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, key.verifying_key());
    let mut host = PluginHost::new(bus.clone(), trust, HostConfig::default());
    let id = host
        .discover(&signed_manifest_json(&key, &["battery"]), None)
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");

    let battery_events = bus.subscribe("ocp.plugin.os-telemetry-battery-changed");
    host.publish_os_telemetry(
        &id,
        TelemetryKind::Battery,
        json!({ "pluginId": id, "percent": 15.0, "level": "low", "charging": false }),
    )
    .expect("granted battery kind should publish");
    let env = battery_events
        .recv_timeout(Duration::from_millis(500))
        .expect("battery event should arrive");
    assert_eq!(env.source, "plugin-host");

    assert!(
        host.publish_os_telemetry(
            &id,
            TelemetryKind::Cpu,
            json!({ "pluginId": id, "percent": 50.0, "level": "normal" }),
        )
        .is_err(),
        "ungranted cpu kind must not publish for a battery-only plugin"
    );
}

#[test]
fn sample_battery_once_never_panics_regardless_of_hardware() {
    // End-to-end plumbing check: with a real activated plugin holding the
    // battery grant, one sampling pass must complete without panicking
    // whether or not this machine actually has a battery.
    let key = SigningKey::generate(&mut OsRng);
    let bus = InProcessBus::new();
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, key.verifying_key());
    let mut host = PluginHost::new(bus.clone(), trust, HostConfig::default());
    let id = host
        .discover(&signed_manifest_json(&key, &["battery"]), None)
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");
    let _ = id;

    let host = Arc::new(Mutex::new(host));
    let mut sampler = BatterySampler::new().expect("construct");
    sample_battery_once(&host, &mut sampler); // must not panic
}
