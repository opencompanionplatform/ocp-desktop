use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use ocp_package_loader::marketplace_trust::verify;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const CONTEXT: &[u8] = b"OCP-MARKETPLACE-TRUST-V1\0";

fn hex(key: &SigningKey) -> String {
    key.verifying_key()
        .as_bytes()
        .iter()
        .map(|value| format!("{value:02x}"))
        .collect()
}

fn identity(role: &str, key: &SigningKey) -> String {
    format!(
        "ed25519:marketplace-{role}-{:x}",
        Sha256::digest(key.verifying_key().as_bytes())
    )
}

fn envelope(payload: Value, signer: &SigningKey) -> Value {
    let canonical = serde_jcs::to_vec(&payload).unwrap();
    let mut message = CONTEXT.to_vec();
    message.extend_from_slice(&canonical);
    json!({
        "payloadBase64": B64.encode(&canonical),
        "signatureBase64": B64.encode(signer.sign(&message).to_bytes()),
    })
}

fn bundle(revoked_key_ids: Vec<&str>) -> (String, String, i64) {
    // Public deterministic test seeds only. They are not production credentials.
    let root = SigningKey::from_bytes(&[11; 32]);
    let registry = SigningKey::from_bytes(&[12; 32]);
    let revocation = SigningKey::from_bytes(&[13; 32]);
    let creator_a = SigningKey::from_bytes(&[14; 32]);
    let creator_b = SigningKey::from_bytes(&[15; 32]);
    let now = 1_800_000_000_i64;

    let root_id = identity("root", &root);
    let registry_id = identity("publisher-registry", &registry);
    let revocation_id = identity("revocation", &revocation);
    let root_payload = json!({
        "keyId": root_id,
        "publicKeyHex": hex(&root),
        "issuedAt": now - 60,
        "expiresAt": now + 365 * 86_400,
        "trustDomain": "marketplace-release",
        "custody": "offline-root",
    });
    let registry_payload = json!({
        "schema": 1,
        "type": "intermediate",
        "role": "publisher-registry",
        "issuerKeyId": root_payload["keyId"],
        "keyId": registry_id,
        "publicKeyHex": hex(&registry),
        "issuedAt": now - 30,
        "expiresAt": now + 90 * 86_400,
        "trustDomain": "marketplace-release",
    });
    let revocation_payload = json!({
        "schema": 1,
        "type": "intermediate",
        "role": "revocation",
        "issuerKeyId": root_payload["keyId"],
        "keyId": revocation_id,
        "publicKeyHex": hex(&revocation),
        "issuedAt": now - 30,
        "expiresAt": now + 90 * 86_400,
        "trustDomain": "marketplace-release",
    });
    let publisher_a = json!({
        "schema": 1,
        "type": "publisher",
        "issuerKeyId": registry_payload["keyId"],
        "publisherId": "publisher.creator-a",
        "keyId": "ed25519:creator-a-1",
        "publicKeyHex": hex(&creator_a),
        "issuedAt": now - 10,
        "expiresAt": now + 60 * 86_400,
        "trustDomain": "marketplace-release",
    });
    let publisher_b = json!({
        "schema": 1,
        "type": "publisher",
        "issuerKeyId": registry_payload["keyId"],
        "publisherId": "publisher.creator-b",
        "keyId": "ed25519:creator-b-1",
        "publicKeyHex": hex(&creator_b),
        "issuedAt": now - 10,
        "expiresAt": now + 60 * 86_400,
        "trustDomain": "marketplace-release",
    });
    let revocations = json!({
        "schema": 1,
        "type": "revocations",
        "issuerKeyId": revocation_payload["keyId"],
        "sequence": 7,
        "issuedAt": now - 10,
        "expiresAt": now + 86_400,
        "trustDomain": "marketplace-release",
        "revokedKeyIds": revoked_key_ids,
        "revokedPackages": [{"packageId": "character.revoked", "version": "1.0.0"}],
    });
    let bundle = json!({
        "schema": 2,
        "root": root_payload,
        "registryCertificate": envelope(registry_payload, &root),
        "revocationCertificate": envelope(revocation_payload, &root),
        "publisherEndorsements": [
            envelope(publisher_a, &registry),
            envelope(publisher_b, &registry),
        ],
        "revocations": envelope(revocations, &revocation),
    });
    (bundle.to_string(), bundle["root"].to_string(), now)
}

#[test]
fn production_bundle_accepts_multiple_endorsed_publishers() {
    let (bundle, root, now) = bundle(vec![]);
    let verified = verify(&bundle, &root, now).unwrap();
    assert_eq!(verified.sequence, 7);
    assert_eq!(verified.publisher_count, 2);
    assert!(verified
        .root_key_id
        .starts_with("ed25519:marketplace-root-"));
}

#[test]
fn revoked_creator_key_does_not_disable_unrelated_publishers() {
    let (bundle, root, now) = bundle(vec!["ed25519:creator-a-1"]);
    let verified = verify(&bundle, &root, now).unwrap();
    assert_eq!(verified.publisher_count, 1);
}

#[test]
fn wrong_domain_pin_and_stale_revocations_fail_closed() {
    let (bundle, root, now) = bundle(vec![]);
    let mut wrong_root: Value = serde_json::from_str(&root).unwrap();
    wrong_root["trustDomain"] = "local-beta".into();
    assert!(verify(&bundle, &wrong_root.to_string(), now).is_err());
    assert!(verify(&bundle, &root, now + 2 * 86_400).is_err());
}

#[test]
fn revoking_a_trust_role_key_invalidates_the_whole_chain() {
    let (clean_bundle, root, now) = bundle(vec![]);
    let root_id = serde_json::from_str::<Value>(&clean_bundle).unwrap()["root"]["keyId"]
        .as_str()
        .unwrap()
        .to_owned();
    let (revoked_bundle, revoked_root, revoked_now) = bundle(vec![&root_id]);
    assert_eq!(root, revoked_root);
    assert_eq!(now, revoked_now);
    assert!(verify(&revoked_bundle, &root, now).is_err());
}
