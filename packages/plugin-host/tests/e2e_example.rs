//! End-to-end: the `hello-companion` example plugin, built against the SDK
//! ONLY, run through the real Plugin Host engine. This is the I1 proof that
//! an author needs the SDK (not a kernel checkout) and that a real
//! `wasm32-wasip1` guest works over PLUGIN_ABI v1.
//!
//! The wasm artifact is produced by `examples/build_example.ps1`
//! (or `cargo build -p hello-companion --target wasm32-wasip1 --release`).
//! If it is absent the test fails with instructions rather than silently
//! skipping — this is a gate.
#![cfg(feature = "engine")]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::engine::{load_and_start, EngineConfig, RunOutcome};
use ocp_plugin_host::verify::TrustStore;
use ocp_plugin_host::{HostConfig, PluginHost, PluginState};
use rand::rngs::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};

const KEY_ID: &str = "ed25519:pub-test";
const PLUGIN_ID: &str = "com.example.hello";

fn wasm_path() -> PathBuf {
    // examples/hello-companion has its own target dir (outside the workspace).
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples/hello-companion/target/wasm32-wasip1/release/hello_companion.wasm")
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
        "name": "Hello Companion",
        "version": "0.1.0",
        "publisher": { "id": "example", "name": "Example", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "entry": "hello_companion.wasm",
        "signature": {
            "algorithm": "ed25519", "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "events": { "publish": ["ocp.plugin.weather-updated"] },
            "memory": [ { "scope": "plugin:com.example.hello", "access": "read-write" } ]
        }
    })
    .to_string()
}

#[test]
fn example_plugin_runs_end_to_end() {
    let path = wasm_path();
    let wasm = std::fs::read(&path).unwrap_or_else(|_| {
        panic!(
            "example wasm not found at {}\n\
             build it first:  examples\\build_example.ps1\n\
             (or: cargo build -p hello-companion --target wasm32-wasip1 --release)",
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
    host.activate(&id, &wasm, None).expect("activate");

    let published = bus.subscribe("ocp.plugin.weather-updated");
    let host = Arc::new(Mutex::new(host));

    let outcome =
        load_and_start(host.clone(), PLUGIN_ID, &wasm, &EngineConfig::default()).expect("run");
    assert_eq!(outcome, RunOutcome::Completed(0), "entry returned non-zero");

    let env = published
        .try_recv()
        .expect("example must publish one event");
    assert_eq!(env.source, PLUGIN_ID, "identity stamped by host (X1-S)");
    assert_eq!(env.event_type, "ocp.plugin.weather-updated");

    // Run again: the counter it persisted must have advanced (memory scope works).
    let outcome2 =
        load_and_start(host.clone(), PLUGIN_ID, &wasm, &EngineConfig::default()).expect("run 2");
    assert_eq!(outcome2, RunOutcome::Completed(0));
    assert_eq!(
        host.lock().unwrap().state(PLUGIN_ID),
        Some(PluginState::Active)
    );
}
