//! I4 checklist item: "Quota enforcement demonstrated: runaway plugin →
//! Suspended (SEC-004)" — specifically with a plugin holding an OS telemetry
//! grant, not just the generic weather-overlay fixture in
//! `cs_plg_engine::quota_breach_through_engine_suspends`.
//!
//! Scenario: a plugin legitimately holds `telemetry: ["cpu"]` (it subscribes
//! to `ocp.plugin.os-telemetry-cpu-changed`) and is also granted publish
//! rights to its own alert topic, `ocp.plugin.telemetry-alert-raised` — a
//! plausible real design (warn other plugins/companion logic when CPU is
//! hot). A bug (missing debounce) makes it re-publish that alert on every
//! single event tick instead of only on a state change. The event-rate
//! quota (SEC-004) does not carve out an exception for plugins that hold a
//! telemetry grant — the guest's own `event_publish` calls are counted the
//! same as any other plugin's, proving telemetry access is not a backdoor
//! around quota containment. `publish_os_telemetry` (the *host's* own
//! sampling loop) is a separate, non-guest path and is deliberately exempt
//! (see `PluginHost::publish_os_telemetry` doc comment) — this test is about
//! the guest-invoked path a telemetry-aware plugin actually calls.
#![cfg(feature = "engine")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::engine::{load_and_start, EngineConfig, RunOutcome};
use ocp_plugin_host::verify::TrustStore;
use ocp_plugin_host::{HostConfig, PluginHost, PluginState};
use rand::rngs::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};

const PACKAGE: &[u8] = b"pretend-wasm-package-bytes";
const KEY_ID: &str = "ed25519:pub-test";
const PLUGIN_ID: &str = "com.example.overzealous-monitor";
const ALERT_TOPIC: &str = "ocp.plugin.telemetry-alert-raised";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn signed_manifest_json(key: &SigningKey) -> String {
    let digest = Sha256::digest(PACKAGE);
    let sig = key.sign(&digest);
    json!({
        "manifestVersion": "1.0",
        "id": PLUGIN_ID,
        "name": "Overzealous CPU Monitor",
        "version": "0.9.0",
        "publisher": { "id": "example-studio", "name": "Example Studio", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "entry": "overzealous-monitor.wasm",
        "signature": {
            "algorithm": "ed25519",
            "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "telemetry": ["cpu"],
            "events": {
                "subscribe": ["ocp.plugin.os-telemetry-cpu-changed"],
                "publish": [ALERT_TOPIC]
            }
        }
    })
    .to_string()
}

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

/// WAT skeleton: alert topic at offset 0 (33 bytes), "{}" payload at 40.
fn wat_module(start_body: &str) -> String {
    format!(
        r#"(module
  (import "ocp" "event_publish" (func $pub (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "ocp.plugin.telemetry-alert-raised")
  (data (i32.const 40) "{{}}")
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
fn telemetry_plugin_publish_flood_is_suspended_not_exempted() {
    // A tight ceiling makes the "missing debounce" bug bite fast without a
    // real wall-clock wait.
    let (host, bus) = activated_host(HostConfig {
        max_events_per_window: 5,
        window: Duration::from_secs(3600),
    });
    let alerts = bus.subscribe(ALERT_TOPIC);
    let suspended = bus.subscribe("ocp.plugin.suspended");

    // Simulates the bug: publish the alert on every tick, 10 ticks, with no
    // debounce guard — the same WAT-loop-with-early-break shape used by the
    // generic engine quota test, but this plugin's manifest carries a real
    // telemetry grant, which is the point being demonstrated here.
    let body = r#"    (local $i i32) (local $r i32)
    (block $done
      (loop $l
        (br_if $done (i32.ge_s (local.get $i) (i32.const 10)))
        (local.set $r (call $pub (i32.const 0) (i32.const 33) (i32.const 40) (i32.const 2)))
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
    .expect("contained, not an engine failure");

    assert_eq!(
        outcome,
        RunOutcome::Completed(-2),
        "ABI code -2 = quota breached, surfaced to the guest as a normal return, not a crash"
    );
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Suspended),
        "holding a telemetry grant does not exempt a plugin from the event-rate quota (SEC-004)"
    );
    assert!(
        suspended.try_recv().is_ok(),
        "ocp.plugin.suspended emitted so the rest of the system can react"
    );
    assert_eq!(
        std::iter::from_fn(|| alerts.try_recv().ok()).count(),
        5,
        "exactly the in-quota alerts were delivered before containment, not zero and not all 10"
    );

    // The grant itself is untouched by the suspension — this is containment,
    // not revocation; a future `resume()` (post-review, out of this test's
    // scope) would find the same telemetry capability still declared.
    assert!(
        host.lock().unwrap().state(PLUGIN_ID) != Some(PluginState::Rejected),
        "quota breach suspends, it never rejects/uninstalls the plugin (SEC-004 containment, not punishment)"
    );
}
