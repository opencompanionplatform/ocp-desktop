//! Explicit Local Beta endorsement verifier (ADR-0056). Contains no pinned keys.
use crate::TrustStore;
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Root {
    key_id: String,
    public_key_hex: String,
    issued_at: i64,
    expires_at: i64,
    trust_domain: String,
    custody: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Envelope {
    payload_base64: String,
    signature_base64: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Bundle {
    schema: u8,
    root: Root,
    registry_certificate: Envelope,
    revocation_certificate: Envelope,
    publisher_endorsement: Envelope,
    revocations: Envelope,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Intermediate {
    schema: u8,
    #[serde(rename = "type")]
    kind: String,
    role: String,
    issuer_key_id: String,
    key_id: String,
    public_key_hex: String,
    issued_at: i64,
    expires_at: i64,
    trust_domain: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Publisher {
    schema: u8,
    #[serde(rename = "type")]
    kind: String,
    issuer_key_id: String,
    publisher_id: String,
    key_id: String,
    public_key_hex: String,
    issued_at: i64,
    expires_at: i64,
    trust_domain: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RevokedPackage {
    package_id: String,
    version: String,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Revocations {
    schema: u8,
    #[serde(rename = "type")]
    kind: String,
    issuer_key_id: String,
    sequence: u64,
    issued_at: i64,
    expires_at: i64,
    trust_domain: String,
    revoked_key_ids: Vec<String>,
    revoked_packages: Vec<RevokedPackage>,
}
fn require(value: bool, code: &'static str) -> Result<(), &'static str> {
    if value {
        Ok(())
    } else {
        Err(code)
    }
}
fn key(hex: &str) -> Result<VerifyingKey, &'static str> {
    require(
        hex.len() == 64
            && hex
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "invalid-public-key",
    )?;
    let mut raw = [0; 32];
    for (i, v) in raw.iter_mut().enumerate() {
        *v = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).map_err(|_| "invalid-public-key")?;
    }
    let key = VerifyingKey::from_bytes(&raw).map_err(|_| "invalid-public-key")?;
    require(!key.is_weak(), "weak-public-key")?;
    Ok(key)
}
fn identity(role: &str, key: &VerifyingKey) -> String {
    format!("ed25519:beta-{role}-{:x}", Sha256::digest(key.as_bytes()))
}
fn validity(
    issued: i64,
    expires: i64,
    now: i64,
    days: i64,
    stale_allowed: bool,
) -> Result<(), &'static str> {
    require(
        issued >= 0
            && issued <= now
            && expires > issued
            && expires
                .checked_sub(issued)
                .is_some_and(|span| span <= days * 86400)
            && (stale_allowed || now < expires),
        "trust-validity-rejected",
    )
}
fn signed<T: DeserializeOwned + Serialize>(
    envelope: Envelope,
    issuer: &VerifyingKey,
) -> Result<T, &'static str> {
    require(
        envelope.payload_base64.len() <= 32768 && envelope.signature_base64.len() == 88,
        "trust-envelope-size",
    )?;
    let payload = B64
        .decode(&envelope.payload_base64)
        .map_err(|_| "trust-base64")?;
    let sig = B64
        .decode(&envelope.signature_base64)
        .map_err(|_| "trust-base64")?;
    require(
        B64.encode(&payload) == envelope.payload_base64
            && B64.encode(&sig) == envelope.signature_base64,
        "trust-base64",
    )?;
    let mut message = b"OCP-LOCAL-BETA-TRUST-V1\0".to_vec();
    message.extend_from_slice(&payload);
    issuer
        .verify_strict(
            &message,
            &Signature::from_slice(&sig).map_err(|_| "trust-signature")?,
        )
        .map_err(|_| "trust-signature")?;
    let parsed: T = serde_json::from_slice(&payload).map_err(|_| "trust-schema")?;
    require(
        serde_jcs::to_vec(&parsed).map_err(|_| "trust-canonical")? == payload,
        "trust-canonical",
    )?;
    Ok(parsed)
}
fn intermediate(
    envelope: Envelope,
    root: &Root,
    role: &str,
    now: i64,
) -> Result<(Intermediate, VerifyingKey), &'static str> {
    let cert: Intermediate = signed(envelope, &key(&root.public_key_hex)?)?;
    let public = key(&cert.public_key_hex)?;
    require(
        cert.schema == 1
            && cert.kind == "intermediate"
            && cert.role == role
            && cert.trust_domain == "local-beta"
            && cert.issuer_key_id == root.key_id
            && cert.key_id == identity(role, &public)
            && cert.issued_at >= root.issued_at
            && cert.expires_at <= root.expires_at,
        "intermediate-rejected",
    )?;
    validity(cert.issued_at, cert.expires_at, now, 90, false)?;
    Ok((cert, public))
}

pub struct VerifiedTrust {
    pub store: TrustStore,
    pub sequence: u64,
    pub revocation_stale: bool,
}
pub fn verify(bundle: &str, pin: &str, now: i64) -> Result<VerifiedTrust, &'static str> {
    require(
        bundle.len() <= 65536 && pin.len() <= 4096,
        "trust-input-size",
    )?;
    let bundle: Bundle = serde_json::from_str(bundle).map_err(|_| "trust-schema")?;
    let root: Root = serde_json::from_str(pin).map_err(|_| "trust-pin-schema")?;
    let root_key = key(&root.public_key_hex)?;
    require(
        bundle.schema == 1
            && bundle.root == root
            && root.trust_domain == "local-beta"
            && root.custody == "single-owner"
            && root.key_id == identity("root", &root_key),
        "root-pin-mismatch",
    )?;
    validity(root.issued_at, root.expires_at, now, 90, false)?;
    let (registry, registry_key) = intermediate(
        bundle.registry_certificate,
        &root,
        "publisher-registry",
        now,
    )?;
    let (revocation, revocation_key) =
        intermediate(bundle.revocation_certificate, &root, "revocation", now)?;
    let publisher: Publisher = signed(bundle.publisher_endorsement, &registry_key)?;
    let publisher_key = key(&publisher.public_key_hex)?;
    require(
        publisher.schema == 1
            && publisher.kind == "publisher"
            && publisher.trust_domain == "local-beta"
            && publisher.issuer_key_id == registry.key_id
            && !publisher.publisher_id.is_empty()
            && publisher.publisher_id.len() <= 128
            && publisher.key_id.starts_with("ed25519:")
            && publisher.key_id.len() <= 256
            && publisher.issued_at >= registry.issued_at
            && publisher.expires_at <= registry.expires_at,
        "publisher-endorsement-rejected",
    )?;
    validity(publisher.issued_at, publisher.expires_at, now, 90, false)?;
    let keys = [
        root_key.as_bytes(),
        registry_key.as_bytes(),
        revocation_key.as_bytes(),
        publisher_key.as_bytes(),
    ];
    for i in 0..keys.len() {
        for j in i + 1..keys.len() {
            require(keys[i] != keys[j], "trust-role-key-reuse")?;
        }
    }
    let revoked: Revocations = signed(bundle.revocations, &revocation_key)?;
    require(
        revoked.schema == 1
            && revoked.kind == "revocations"
            && revoked.trust_domain == "local-beta"
            && revoked.issuer_key_id == revocation.key_id
            && revoked.sequence > 0
            && revoked.issued_at >= revocation.issued_at
            && revoked.expires_at <= revocation.expires_at,
        "revocations-rejected",
    )?;
    validity(revoked.issued_at, revoked.expires_at, now, 7, true)?;
    for id in [
        &root.key_id,
        &registry.key_id,
        &revocation.key_id,
        &publisher.key_id,
    ] {
        require(!revoked.revoked_key_ids.contains(id), "signing-key-revoked")?;
    }
    let mut store = TrustStore::new();
    store.add_publisher_key(publisher.key_id, publisher.publisher_id, publisher_key);
    for item in revoked.revoked_packages {
        store.revoke_package(item.package_id, item.version);
    }
    Ok(VerifiedTrust {
        store,
        sequence: revoked.sequence,
        revocation_stale: now >= revoked.expires_at,
    })
}
