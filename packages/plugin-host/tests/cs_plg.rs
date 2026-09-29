//! CS-PLG — Plugin Host conformance (TEST_STRATEGY §3.2 subset for the logic
//! slice): manifest validation, signature at install AND load, lifecycle
//! events, per-call capability enforcement, revocation, quota suspension.
//! Malicious fixtures per PDD_PLUGIN_HOST: over-grant calls, forged identity,
//! reserved-name manifests, wildcard grants, quota exhaustion.

use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_event_bus::InProcessBus;
use ocp_plugin_host::capability::CapabilityRequest;
use ocp_plugin_host::manifest::{Manifest, TelemetryKind};
use ocp_plugin_host::verify::TrustStore;
use ocp_plugin_host::{HostConfig, HostError, PluginHost, PluginState};
use rand::rngs::OsRng;
use serde_json::json;
use sha2::{Digest, Sha256};

const PACKAGE: &[u8] = b"pretend-wasm-package-bytes";
const KEY_ID: &str = "ed25519:pub-test";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A correctly signed manifest JSON + the trust store knowing the key.
fn signed_manifest_json(key: &SigningKey, tweak: impl FnOnce(&mut serde_json::Value)) -> String {
    let digest = Sha256::digest(PACKAGE);
    let sig = key.sign(&digest);
    let mut m = json!({
        "manifestVersion": "1.0",
        "id": "com.example.weather",
        "name": "Weather Overlay",
        "version": "1.2.0",
        "publisher": { "id": "example-studio", "name": "Example Studio", "keyId": KEY_ID },
        "license": "Apache-2.0",
        "entitlement": "free",
        "tier": "wasm",
        "entry": "weather.wasm",
        "signature": {
            "algorithm": "ed25519",
            "keyId": KEY_ID,
            "digest": format!("sha256:{}", hex(&digest)),
            "value": format!("base64:{}", B64.encode(sig.to_bytes()))
        },
        "capabilities": {
            "filesystem": [ { "path": "${plugin_data}/cache", "access": "read-write" } ],
            "network": [ { "host": "api.weather.example.com", "port": 443, "protocol": "https" } ],
            "events": {
                "publish": ["ocp.plugin.weather-updated"],
                "subscribe": ["ocp.companion.state-changed"]
            },
            "memory": [ { "scope": "plugin:com.example.weather", "access": "read-write" } ]
        }
    });
    tweak(&mut m);
    m.to_string()
}

fn host_with(key: &SigningKey, config: HostConfig) -> (PluginHost, InProcessBus) {
    let bus = InProcessBus::new();
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, key.verifying_key());
    (PluginHost::new(bus.clone(), trust, config), bus)
}

fn activated_plugin(host: &mut PluginHost, key: &SigningKey) -> String {
    let id = host
        .discover(&signed_manifest_json(key, |_| {}), None)
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");
    id
}

// --- Manifest validation (PLUGIN_API §2) ---

#[test]
fn valid_manifest_parses_and_validates() {
    let key = SigningKey::generate(&mut OsRng);
    let manifest: Manifest =
        serde_json::from_str(&signed_manifest_json(&key, |_| {})).expect("parse");
    manifest.validate().expect("validate");
}

#[test]
fn missing_mandatory_fields_rejected() {
    let key = SigningKey::generate(&mut OsRng);
    for field in ["license", "entitlement", "signature", "id"] {
        let json = signed_manifest_json(&key, |m| {
            m.as_object_mut().unwrap().remove(field);
        });
        assert!(
            serde_json::from_str::<Manifest>(&json).is_err(),
            "parsed without {field}"
        );
    }
}

#[test]
fn unknown_manifest_field_rejected() {
    let key = SigningKey::generate(&mut OsRng);
    let json = signed_manifest_json(&key, |m| {
        m["selfDeclaredTrust"] = json!("total");
    });
    assert!(serde_json::from_str::<Manifest>(&json).is_err());
}

#[test]
fn wildcard_grants_rejected() {
    type Tweak = Box<dyn FnOnce(&mut serde_json::Value)>;
    let key = SigningKey::generate(&mut OsRng);
    let cases: Vec<Tweak> = vec![
        Box::new(|m: &mut serde_json::Value| {
            m["capabilities"]["filesystem"][0]["path"] = json!("*")
        }),
        Box::new(|m: &mut serde_json::Value| m["capabilities"]["network"][0]["host"] = json!("*")),
        Box::new(|m: &mut serde_json::Value| {
            m["capabilities"]["events"]["publish"] = json!(["ocp.plugin.*"])
        }),
    ];
    for tweak in cases {
        let manifest: Manifest =
            serde_json::from_str(&signed_manifest_json(&key, tweak)).expect("parse");
        assert!(manifest.validate().is_err(), "wildcard accepted");
    }
}

#[test]
fn reserved_lifecycle_topic_rejected() {
    let key = SigningKey::generate(&mut OsRng);
    let json = signed_manifest_json(&key, |m| {
        m["capabilities"]["events"]["publish"] = json!(["ocp.plugin.crashed"]);
    });
    let manifest: Manifest = serde_json::from_str(&json).expect("parse");
    assert!(
        manifest.validate().is_err(),
        "reserved lifecycle name accepted (TD-004)"
    );
}

#[test]
fn telemetry_capability_declares_and_validates() {
    // PLUGIN_API §7a (I4): a manifest may declare individual OS telemetry
    // sensors as their own capability list, separate from filesystem/network.
    let key = SigningKey::generate(&mut OsRng);
    let json = signed_manifest_json(&key, |m| {
        m["capabilities"]["telemetry"] = json!(["cpu", "foreground"]);
    });
    let manifest: Manifest = serde_json::from_str(&json).expect("parse");
    assert!(manifest.validate().is_ok(), "valid telemetry list rejected");
    assert_eq!(
        manifest.capabilities.telemetry,
        vec![TelemetryKind::Cpu, TelemetryKind::Foreground]
    );
}

#[test]
fn unknown_telemetry_kind_fails_to_parse() {
    // Not a `Manifest::validate()` failure — the enum itself has no such
    // variant, so this is rejected at deserialization (same pattern as
    // `Entitlement`/`Tier`), before validate() ever runs.
    let key = SigningKey::generate(&mut OsRng);
    let json = signed_manifest_json(&key, |m| {
        m["capabilities"]["telemetry"] = json!(["gpu"]);
    });
    assert!(
        serde_json::from_str::<Manifest>(&json).is_err(),
        "unknown telemetry kind parsed"
    );
}

#[test]
fn reserved_os_telemetry_topic_rejected() {
    // A plugin cannot self-declare a publish topic in the host-owned
    // os-telemetry family (PLUGIN_API §7a) — only the Plugin Host's own
    // sampling loop may publish real readings; a plugin claiming this topic
    // could otherwise forge sensor data.
    let key = SigningKey::generate(&mut OsRng);
    let json = signed_manifest_json(&key, |m| {
        m["capabilities"]["events"]["publish"] = json!(["ocp.plugin.os-telemetry-cpu-changed"]);
    });
    let manifest: Manifest = serde_json::from_str(&json).expect("parse");
    assert!(
        manifest.validate().is_err(),
        "reserved os-telemetry topic accepted"
    );
}

#[test]
fn cross_scope_memory_rejected_in_alpha() {
    let key = SigningKey::generate(&mut OsRng);
    let json = signed_manifest_json(&key, |m| {
        m["capabilities"]["memory"][0]["scope"] = json!("user-profile");
    });
    let manifest: Manifest = serde_json::from_str(&json).expect("parse");
    assert!(
        manifest.validate().is_err(),
        "cross-scope memory accepted (SEC-020)"
    );
}

// --- Signature & lifecycle (PLUGIN_API §3, SEC-010) ---

#[test]
fn lifecycle_happy_path_emits_contract_events() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(&key, HostConfig::default());
    let plugin_family = bus.subscribe("ocp.plugin.");
    let marketplace = bus.subscribe("ocp.marketplace.package-verified");

    let id = activated_plugin(&mut host, &key);
    assert_eq!(host.state(&id), Some(PluginState::Active));

    let seen: Vec<String> = std::iter::from_fn(|| plugin_family.try_recv().ok())
        .map(|e| e.event_type)
        .collect();
    assert_eq!(
        seen,
        vec![
            "ocp.plugin.discovered",
            "ocp.plugin.installed",
            "ocp.plugin.activated",
            "ocp.plugin.capability-granted",
        ],
        "lifecycle event sequence (PLUGIN_API §3)"
    );
    assert!(marketplace.try_recv().is_ok(), "package-verified missing");
}

#[test]
fn forged_signature_rejected_at_install() {
    let key = SigningKey::generate(&mut OsRng);
    let intruder = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(&key, HostConfig::default());
    let rejected = bus.subscribe("ocp.plugin.rejected");

    // Manifest signed by a key the trust store does not vouch for that keyId.
    let digest = Sha256::digest(PACKAGE);
    let forged_sig = intruder.sign(&digest);
    let json = signed_manifest_json(&key, |m| {
        m["signature"]["value"] = json!(format!("base64:{}", B64.encode(forged_sig.to_bytes())));
    });
    let id = host.discover(&json, None).expect("discover");
    assert!(matches!(
        host.install(&id, PACKAGE, None),
        Err(HostError::Verify(_))
    ));
    assert_eq!(host.state(&id), Some(PluginState::Rejected));
    assert!(rejected.try_recv().is_ok());
}

#[test]
fn tampered_package_rejected_at_load_even_after_install() {
    // SEC-010: verified at install AND at every load.
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, _bus) = host_with(&key, HostConfig::default());
    let id = host
        .discover(&signed_manifest_json(&key, |_| {}), None)
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    let tampered = b"pretend-wasm-package-bytes-EVIL";
    assert!(matches!(
        host.activate(&id, tampered, None),
        Err(HostError::Verify(_))
    ));
    assert_eq!(host.state(&id), Some(PluginState::Rejected));
}

// --- Capability enforcement (SEC-002) + revocation (SEC-001) ---

#[test]
fn over_grant_call_denied_logged_and_contained() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, _bus) = host_with(&key, HostConfig::default());
    let id = activated_plugin(&mut host, &key);

    // Granted: exactly api.weather.example.com:443/https.
    host.check_capability(
        &id,
        &CapabilityRequest::Net {
            host: "api.weather.example.com".into(),
            port: 443,
            protocol: "https".into(),
        },
    )
    .expect("granted call");

    // Malicious: different host, and file write outside granted root.
    for bad in [
        CapabilityRequest::Net {
            host: "exfil.evil.example".into(),
            port: 443,
            protocol: "https".into(),
        },
        CapabilityRequest::FsWrite("${plugin_data}/cache/../../etc/passwd".into()),
        CapabilityRequest::FsWrite("/etc/passwd".into()),
        CapabilityRequest::Publish("ocp.memory.record-written".into()),
        CapabilityRequest::MemWrite("user-profile".into()),
    ] {
        assert!(
            matches!(
                host.check_capability(&id, &bad),
                Err(HostError::Capability(_))
            ),
            "over-grant call allowed: {bad:?}"
        );
    }
    assert_eq!(host.audit.len(), 5, "denials must be audit-logged (X1-R)");
    assert_eq!(
        host.state(&id),
        Some(PluginState::Active),
        "denial is not death"
    );
}

#[test]
fn telemetry_grant_is_per_kind_not_all_or_nothing() {
    // THREAT_MODEL companion-risk-3 / SEC-011: each telemetry sensor is
    // independently consentable. Granting `cpu` must never imply `foreground`
    // (the more sensitive one — it reveals what the user is doing).
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, _bus) = host_with(&key, HostConfig::default());
    let id = host
        .discover(
            &signed_manifest_json(&key, |m| {
                m["capabilities"]["telemetry"] = json!(["cpu"]);
            }),
            None,
        )
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");

    host.check_capability(&id, &CapabilityRequest::TelemetryConfig(TelemetryKind::Cpu))
        .expect("granted kind denied");
    assert!(
        host.check_capability(
            &id,
            &CapabilityRequest::TelemetryConfig(TelemetryKind::Foreground)
        )
        .is_err(),
        "ungranted telemetry kind allowed"
    );
}

#[test]
fn telemetry_grant_is_revocable() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, _bus) = host_with(&key, HostConfig::default());
    let id = host
        .discover(
            &signed_manifest_json(&key, |m| {
                m["capabilities"]["telemetry"] = json!(["battery"]);
            }),
            None,
        )
        .expect("discover");
    host.install(&id, PACKAGE, None).expect("install");
    host.activate(&id, PACKAGE, None).expect("activate");

    let req = CapabilityRequest::TelemetryConfig(TelemetryKind::Battery);
    host.check_capability(&id, &req)
        .expect("granted before revoke");
    let removed = host.revoke(&id, &req, false, None).expect("revoke");
    assert!(removed, "revoke reported nothing removed");
    assert!(
        host.check_capability(&id, &req).is_err(),
        "revoked telemetry kind still allowed"
    );
}

#[test]
fn fs_grant_respects_segment_boundary() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, _bus) = host_with(&key, HostConfig::default());
    let id = activated_plugin(&mut host, &key);
    host.check_capability(
        &id,
        &CapabilityRequest::FsRead("${plugin_data}/cache/today.json".into()),
    )
    .expect("inside root");
    assert!(host
        .check_capability(
            &id,
            &CapabilityRequest::FsRead("${plugin_data}/cache-evil/x".into()),
        )
        .is_err());
}

#[test]
fn revocation_applies_on_next_call() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(&key, HostConfig::default());
    let revoked_events = bus.subscribe("ocp.plugin.capability-revoked");
    let id = activated_plugin(&mut host, &key);

    let net = CapabilityRequest::Net {
        host: "api.weather.example.com".into(),
        port: 443,
        protocol: "https".into(),
    };
    host.check_capability(&id, &net).expect("before revocation");
    assert!(host.revoke(&id, &net, false, None).expect("revoke"));
    assert!(matches!(
        host.check_capability(&id, &net),
        Err(HostError::Capability(_))
    ));
    assert!(revoked_events.try_recv().is_ok());
    assert_eq!(host.state(&id), Some(PluginState::Active));
}

#[test]
fn revocation_can_suspend_unusable_plugin() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(&key, HostConfig::default());
    let suspended = bus.subscribe("ocp.plugin.suspended");
    let id = activated_plugin(&mut host, &key);
    let net = CapabilityRequest::Net {
        host: "api.weather.example.com".into(),
        port: 443,
        protocol: "https".into(),
    };
    host.revoke(&id, &net, true, None).expect("revoke");
    assert_eq!(host.state(&id), Some(PluginState::Suspended));
    assert!(suspended.try_recv().is_ok());
}

// --- Quotas (SEC-004, X1-D) ---

#[test]
fn event_rate_breach_suspends_never_kills_host() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(
        &key,
        HostConfig {
            max_events_per_window: 5,
            window: Duration::from_secs(3600),
        },
    );
    let suspended = bus.subscribe("ocp.plugin.suspended");
    let published = bus.subscribe("ocp.plugin.weather-updated");
    let id = activated_plugin(&mut host, &key);

    for _ in 0..5 {
        host.host_publish(&id, "ocp.plugin.weather-updated", json!({}), None)
            .expect("within quota");
    }
    assert!(matches!(
        host.host_publish(&id, "ocp.plugin.weather-updated", json!({}), None),
        Err(HostError::QuotaBreached)
    ));
    assert_eq!(host.state(&id), Some(PluginState::Suspended));
    assert!(suspended.try_recv().is_ok());
    // The 5 in-quota events were delivered; the host is still alive for others.
    assert_eq!(std::iter::from_fn(|| published.try_recv().ok()).count(), 5);
}

#[test]
fn published_envelope_carries_verified_identity_as_source() {
    // X1-S: identity from the host, never guest claims.
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(&key, HostConfig::default());
    let published = bus.subscribe("ocp.plugin.weather-updated");
    let id = activated_plugin(&mut host, &key);
    host.host_publish(&id, "ocp.plugin.weather-updated", json!({"t": 21}), None)
        .expect("publish");
    let env = published.try_recv().expect("delivered");
    assert_eq!(env.source, id);
}

// --- Crash containment (SEC-001) ---

#[test]
fn crash_suspends_and_emits_fact() {
    let key = SigningKey::generate(&mut OsRng);
    let (mut host, bus) = host_with(&key, HostConfig::default());
    let crashed = bus.subscribe("ocp.plugin.crashed");
    let id = activated_plugin(&mut host, &key);
    host.report_crash(&id, None).expect("crash report");
    assert_eq!(host.state(&id), Some(PluginState::Suspended));
    assert!(crashed.try_recv().is_ok());
    // Resume repeats the load-time check (SEC-010) and works with intact bytes.
    host.resume(&id, PACKAGE, None).expect("resume");
    assert_eq!(host.state(&id), Some(PluginState::Active));
}
