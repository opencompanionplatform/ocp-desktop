use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_package_loader::beta_trust::verify;
use serde_json::Value;
use sha2::{Digest, Sha256};
const FIXTURE: &str = include_str!("fixtures/local-beta/bundle.json");
fn input() -> (Value, String, i64) {
    let b: Value = serde_json::from_str(FIXTURE).unwrap();
    let pin = b["root"].to_string();
    let now = b["root"]["issuedAt"].as_i64().unwrap() + 1;
    (b, pin, now)
}
#[test]
fn node_ceremony_interoperates_with_rust() {
    let (_, pin, now) = input();
    let trust = verify(FIXTURE, &pin, now).unwrap();
    assert_eq!(trust.sequence, 1);
    assert!(!trust.revocation_stale);
}
#[test]
fn signature_pin_domain_and_expiry_fail_closed() {
    let (b, pin, now) = input();
    for field in [
        "registryCertificate",
        "revocationCertificate",
        "publisherEndorsement",
        "revocations",
    ] {
        let mut changed = b.clone();
        changed[field]["signatureBase64"] = "AAAAAAAA".into();
        assert!(verify(&changed.to_string(), &pin, now).is_err());
    }
    let mut wrong_pin: Value = serde_json::from_str(&pin).unwrap();
    wrong_pin["trustDomain"] = "production".into();
    assert!(verify(FIXTURE, &wrong_pin.to_string(), now).is_err());
    assert!(verify(FIXTURE, &pin, now - 60).is_err());
    assert!(verify(FIXTURE, &pin, now + 91 * 86400).is_err());
}
#[test]
fn stale_signed_revocations_warn_without_disabling_chain_validation() {
    let (_, pin, now) = input();
    assert!(
        verify(FIXTURE, &pin, now + 8 * 86400)
            .unwrap()
            .revocation_stale
    );
}

// Public deterministic test seeds, unrelated to the owner's offline keys.
fn signed_test_bundle(change: impl FnOnce(&mut Value)) -> (String, String, i64) {
    let (mut bundle, _, now) = input();
    let keys = [
        SigningKey::from_bytes(&[1; 32]),
        SigningKey::from_bytes(&[2; 32]),
        SigningKey::from_bytes(&[3; 32]),
    ];
    let roles = ["root", "publisher-registry", "revocation"];
    let ids: Vec<String> = keys
        .iter()
        .zip(roles)
        .map(|(key, role)| {
            format!(
                "ed25519:beta-{role}-{:x}",
                Sha256::digest(key.verifying_key().as_bytes())
            )
        })
        .collect();
    let hex = |key: &SigningKey| {
        key.verifying_key()
            .as_bytes()
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>()
    };
    bundle["root"]["keyId"] = ids[0].clone().into();
    bundle["root"]["publicKeyHex"] = hex(&keys[0]).into();
    let fields = [
        "registryCertificate",
        "revocationCertificate",
        "publisherEndorsement",
        "revocations",
    ];
    let mut payloads = serde_json::json!({});
    for field in fields {
        payloads[field] = serde_json::from_slice(
            &B64.decode(bundle[field]["payloadBase64"].as_str().unwrap())
                .unwrap(),
        )
        .unwrap();
    }
    for (field, index) in [("registryCertificate", 1), ("revocationCertificate", 2)] {
        payloads[field]["keyId"] = ids[index].clone().into();
        payloads[field]["publicKeyHex"] = hex(&keys[index]).into();
        payloads[field]["issuerKeyId"] = ids[0].clone().into();
    }
    payloads["publisherEndorsement"]["issuerKeyId"] = ids[1].clone().into();
    payloads["revocations"]["issuerKeyId"] = ids[2].clone().into();
    change(&mut payloads);
    for (field, index) in [
        (fields[0], 0),
        (fields[1], 0),
        (fields[2], 1),
        (fields[3], 2),
    ] {
        let payload = serde_jcs::to_vec(&payloads[field]).unwrap();
        let mut message = b"OCP-LOCAL-BETA-TRUST-V1\0".to_vec();
        message.extend_from_slice(&payload);
        bundle[field]["payloadBase64"] = B64.encode(payload).into();
        bundle[field]["signatureBase64"] = B64.encode(keys[index].sign(&message).to_bytes()).into();
    }
    (bundle.to_string(), bundle["root"].to_string(), now)
}

#[test]
fn valid_signatures_cannot_override_roles_domains_revocation_or_schema() {
    let (bundle, pin, now) = signed_test_bundle(|_| {});
    assert!(verify(&bundle, &pin, now).is_ok());
    for (field, property, value) in [
        (
            "registryCertificate",
            "role",
            serde_json::json!("revocation"),
        ),
        (
            "publisherEndorsement",
            "trustDomain",
            serde_json::json!("production"),
        ),
        (
            "publisherEndorsement",
            "extraPermission",
            serde_json::json!(true),
        ),
        ("revocations", "sequence", serde_json::json!(0)),
        (
            "revocations",
            "revokedKeyIds",
            serde_json::json!(["ed25519:primary-20260903"]),
        ),
    ] {
        let (bundle, pin, now) = signed_test_bundle(|p| p[field][property] = value);
        assert!(verify(&bundle, &pin, now).is_err(), "{field}.{property}");
    }
}
