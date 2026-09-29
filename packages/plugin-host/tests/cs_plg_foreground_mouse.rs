//! CS-PLG foreground/mouse subset — PLUGIN_API §7a (I4). Separate from
//! `cs_plg_telemetry.rs`/`cs_plg_battery.rs` because these two sensors are
//! backed by `ocp-os-sensors`, the one crate in the workspace with `unsafe`
//! FFI (CODING_STANDARD.md Safety exception).
//!
//! Deliberately tolerant of "no reading available": headless CI runners may
//! have no interactive desktop session at all, so `None` from the OS query
//! is an expected outcome, not a test failure. Only the capability-gating
//! logic is asserted strictly, since it doesn't require a real OS reading.
#![cfg(feature = "foreground-mouse-telemetry")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::foreground_mouse::{sample_foreground_once, sample_mouse_once};
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
        "id": "com.example.focus-watch",
        "name": "Focus Watch",
        "version": "1.0.0",
        "publisher": { "id": "example-studio", "name": "Example Studio", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "tier": "wasm",
        "entry": "focus-watch.wasm",
        "signature": {
            "algorithm": "ed25519",
            "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "events": {
                "subscribe": [
                    "ocp.plugin.os-telemetry-foreground-changed",
                    "ocp.plugin.os-telemetry-mouse-changed"
                ]
            },
            "telemetry": telemetry
        }
    })
    .to_string()
}

fn activated_host(telemetry: &[&str]) -> (PluginHost, InProcessBus, String) {
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
    (host, bus, id)
}

#[test]
fn publish_foreground_telemetry_respects_the_grant() {
    let (mut host, bus, id) = activated_host(&["foreground"]);
    let events = bus.subscribe("ocp.plugin.os-telemetry-foreground-changed");
    host.publish_os_telemetry(
        &id,
        TelemetryKind::Foreground,
        json!({ "pluginId": id, "windowTitle": "Notepad", "processName": "notepad.exe" }),
    )
    .expect("granted foreground kind should publish");
    let env = events
        .recv_timeout(Duration::from_millis(500))
        .expect("foreground event should arrive");
    assert_eq!(env.source, "plugin-host");

    assert!(
        host.publish_os_telemetry(
            &id,
            TelemetryKind::Mouse,
            json!({ "pluginId": id, "state": "idle", "idleMs": 90_000 }),
        )
        .is_err(),
        "ungranted mouse kind must not publish for a foreground-only plugin"
    );
}

#[test]
fn publish_mouse_telemetry_respects_the_grant() {
    let (mut host, bus, id) = activated_host(&["mouse"]);
    let events = bus.subscribe("ocp.plugin.os-telemetry-mouse-changed");
    host.publish_os_telemetry(
        &id,
        TelemetryKind::Mouse,
        json!({ "pluginId": id, "state": "active", "idleMs": 500 }),
    )
    .expect("granted mouse kind should publish");
    let env = events
        .recv_timeout(Duration::from_millis(500))
        .expect("mouse event should arrive");
    assert_eq!(env.source, "plugin-host");
}

#[test]
fn sample_foreground_and_mouse_once_never_panic_regardless_of_environment() {
    let (host, _bus, _id) = activated_host(&["foreground", "mouse"]);
    let host = Arc::new(Mutex::new(host));
    sample_foreground_once(&host); // must not panic even with no desktop session
    sample_mouse_once(&host);
}
