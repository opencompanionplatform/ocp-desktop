//! CS-PLG engine subset — PLUGIN_ABI v1 conformance on real WASM execution.
//! Guests are WAT modules (no WASI needed), certifying: ABI shape check,
//! §7 imports through the sandbox boundary, capability denial codes,
//! quota suspension, fuel containment (SEC-004).
#![cfg(feature = "engine")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::engine::{load_and_start, EngineConfig, EngineError, RunOutcome};
use ocp_plugin_host::verify::TrustStore;
use ocp_plugin_host::{HostConfig, PluginHost, PluginState};
use rand::rngs::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};

const PACKAGE: &[u8] = b"pretend-wasm-package-bytes";
const KEY_ID: &str = "ed25519:pub-test";
const PLUGIN_ID: &str = "com.example.weather";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn signed_manifest_json(key: &SigningKey) -> String {
    let digest = Sha256::digest(PACKAGE);
    let sig = key.sign(&digest);
    json!({
        "manifestVersion": "1.0",
        "id": PLUGIN_ID,
        "name": "Weather Overlay",
        "version": "1.2.0",
        "publisher": { "id": "example-studio", "name": "Example Studio", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "entry": "weather.wasm",
        "signature": {
            "algorithm": "ed25519",
            "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "events": { "publish": ["ocp.plugin.weather-updated"] }
        }
    })
    .to_string()
}

/// Activated host wrapped for the engine + the shared bus.
fn activated_host(config: HostConfig) -> (Arc<Mutex<PluginHost>>, InProcessBus) {
    let key = SigningKey::generate(&mut OsRng);
    let bus = InProcessBus::new();
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, key.verifying_key());
    let mut host = PluginHost::new(bus.clone(), trust, config);
    let id = host
        .discover(&signed_manifest_json(&key), None)
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");
    (Arc::new(Mutex::new(host)), bus)
}

/// WAT skeleton: topic at offset 0, payload "{}" at offset 63.
fn wat_module(start_body: &str) -> String {
    format!(
        r#"(module
  (import "ocp" "event_publish" (func $pub (param i32 i32 i32 i32) (result i32)))
  (import "ocp" "log" (func $log (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "ocp.plugin.weather-updated")
  (data (i32.const 32) "ocp.memory.record-written")
  (data (i32.const 63) "{{}}")
  (func (export "ocp_abi_version") (result i32) i32.const 1)
  (func (export "ocp_alloc") (param i32) (result i32) i32.const 4096)
  (func (export "ocp_free") (param i32 i32))
  (func (export "ocp_start") (result i32)
{start_body}
  )
)"#
    )
}

#[test]
fn wat_guest_publishes_through_engine() {
    let (host, bus) = activated_host(HostConfig::default());
    let published = bus.subscribe("ocp.plugin.weather-updated");
    let wat =
        wat_module("    (call $pub (i32.const 0) (i32.const 26) (i32.const 63) (i32.const 2))");
    let outcome = load_and_start(
        host.clone(),
        PLUGIN_ID,
        wat.as_bytes(),
        &EngineConfig::default(),
    )
    .expect("run");
    assert_eq!(outcome, RunOutcome::Completed(0));
    let env = published.try_recv().expect("delivered");
    assert_eq!(
        env.source, PLUGIN_ID,
        "identity from host, not guest (X1-S)"
    );
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Active)
    );
}

#[test]
fn ungranted_topic_gets_capability_code_and_plugin_survives() {
    let (host, bus) = activated_host(HostConfig::default());
    let other = bus.subscribe("ocp.memory.record-written");
    let wat =
        wat_module("    (call $pub (i32.const 32) (i32.const 25) (i32.const 63) (i32.const 2))");
    let outcome = load_and_start(
        host.clone(),
        PLUGIN_ID,
        wat.as_bytes(),
        &EngineConfig::default(),
    )
    .expect("run");
    assert_eq!(
        outcome,
        RunOutcome::Completed(-1),
        "ABI code -1 = capability denied"
    );
    assert!(
        other.try_recv().is_err(),
        "denied publish must never reach the bus"
    );
    let h = host.lock().unwrap();
    assert_eq!(
        h.state(PLUGIN_ID),
        Some(PluginState::Active),
        "denial is not death"
    );
    assert!(!h.audit.is_empty(), "denial audit-logged (X1-R)");
}

#[test]
fn missing_abi_export_rejects_plugin() {
    let (host, _bus) = activated_host(HostConfig::default());
    // No ocp_start export.
    let wat = r#"(module
  (memory (export "memory") 1)
  (func (export "ocp_abi_version") (result i32) i32.const 1)
  (func (export "ocp_alloc") (param i32) (result i32) i32.const 4096)
  (func (export "ocp_free") (param i32 i32))
)"#;
    let err = load_and_start(
        host.clone(),
        PLUGIN_ID,
        wat.as_bytes(),
        &EngineConfig::default(),
    )
    .expect_err("must fail");
    assert!(matches!(err, EngineError::MissingExport(_)));
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Rejected)
    );
}

#[test]
fn wrong_abi_version_rejects_plugin() {
    let (host, _bus) = activated_host(HostConfig::default());
    let wat = r#"(module
  (memory (export "memory") 1)
  (func (export "ocp_abi_version") (result i32) i32.const 99)
  (func (export "ocp_alloc") (param i32) (result i32) i32.const 4096)
  (func (export "ocp_free") (param i32 i32))
  (func (export "ocp_start") (result i32) i32.const 0)
)"#;
    let err = load_and_start(
        host.clone(),
        PLUGIN_ID,
        wat.as_bytes(),
        &EngineConfig::default(),
    )
    .expect_err("must fail");
    assert!(matches!(err, EngineError::AbiMismatch(99)));
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Rejected)
    );
}

#[test]
fn runaway_guest_contained_by_fuel() {
    let (host, bus) = activated_host(HostConfig::default());
    let crashed = bus.subscribe("ocp.plugin.crashed");
    let wat = wat_module("    (loop $l (br $l))\n    i32.const 0");
    let outcome = load_and_start(
        host.clone(),
        PLUGIN_ID,
        wat.as_bytes(),
        &EngineConfig {
            fuel: 10_000,
            ..EngineConfig::default()
        },
    )
    .expect("contained, not an engine failure");
    assert_eq!(outcome, RunOutcome::Crashed);
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Suspended)
    );
    assert!(
        crashed.try_recv().is_ok(),
        "ocp.plugin.crashed emitted (SEC-004)"
    );
}

#[test]
fn quota_breach_through_engine_suspends() {
    let (host, bus) = activated_host(HostConfig {
        max_events_per_window: 5,
        window: Duration::from_secs(3600),
    });
    let published = bus.subscribe("ocp.plugin.weather-updated");
    let suspended = bus.subscribe("ocp.plugin.suspended");
    // Publish 10 times; keep the last return code.
    let body = r#"    (local $i i32) (local $r i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_s (local.get $i) (i32.const 10)))
        (local.set $r (call $pub (i32.const 0) (i32.const 26) (i32.const 63) (i32.const 2)))
        (br_if $done (i32.lt_s (local.get $r) (i32.const 0)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
    (local.get $r)"#;
    let outcome = load_and_start(
        host.clone(),
        PLUGIN_ID,
        wat_module(body).as_bytes(),
        &EngineConfig::default(),
    )
    .expect("run");
    assert_eq!(
        outcome,
        RunOutcome::Completed(-2),
        "ABI code -2 = quota breached"
    );
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Suspended)
    );
    assert!(suspended.try_recv().is_ok());
    assert_eq!(
        std::iter::from_fn(|| published.try_recv().ok()).count(),
        5,
        "exactly the in-quota events delivered"
    );
}
