//! Production Marketplace trust-chain verifier.
//!
//! The Runtime pins only the long-lived public root. The current signed bundle
//! can be delivered by Cloud because every certificate, publisher endorsement,
//! and revocation payload is verified back to that pinned root.
#![forbid(unsafe_code)]

use crate::TrustStore;
use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};

const PRODUCTION_DOMAIN: &str = "marketplace-release";
const PRODUCTION_CUSTODY: &str = "offline-root";
const STAGING_DOMAIN: &str = "marketplace-staging";
const STAGING_CUSTODY: &str = "online-staging";
const SIGNING_CONTEXT: &[u8] = b"OCP-MARKETPLACE-TRUST-V1\0";
const MAX_BUNDLE_BYTES: usize = 512 * 1024;
const MAX_PUBLISHERS: usize = 256;

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Root {
    key_id: String,
    public_key_hex: String,
    issued_at: i64,
    expires_at: i64,
    trust_domain: String,
    custody: String,
}

#[derive(Clone, Deserialize)]
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
    publisher_endorsements: Vec<Envelope>,
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
    let mut raw = [0_u8; 32];
    for (index, byte) in raw.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[2 * index..2 * index + 2], 16)
            .map_err(|_| "invalid-public-key")?;
    }
    let key = VerifyingKey::from_bytes(&raw).map_err(|_| "invalid-public-key")?;
    require(!key.is_weak(), "weak-public-key")?;
    Ok(key)
}

fn identity(role: &str, key: &VerifyingKey) -> String {
    format!(
        "ed25519:marketplace-{role}-{:x}",
        Sha256::digest(key.as_bytes())
    )
}

fn validity(issued: i64, expires: i64, now: i64, max_days: i64) -> Result<(), &'static str> {
    require(
        issued >= 0
            && issued <= now
            && expires > issued
            && now < expires
            && expires
                .checked_sub(issued)
                .is_some_and(|span| span <= max_days * 86_400),
        "trust-validity-rejected",
    )
}

fn signed<T: DeserializeOwned + Serialize>(
    envelope: Envelope,
    issuer: &VerifyingKey,
) -> Result<T, &'static str> {
    require(
        envelope.payload_base64.len() <= 131_072 && envelope.signature_base64.len() == 88,
        "trust-envelope-size",
    )?;
    let payload = B64
        .decode(&envelope.payload_base64)
        .map_err(|_| "trust-base64")?;
    let signature = B64
        .decode(&envelope.signature_base64)
        .map_err(|_| "trust-base64")?;
    require(
        B64.encode(&payload) == envelope.payload_base64
            && B64.encode(&signature) == envelope.signature_base64,
        "trust-base64",
    )?;
    let mut message = SIGNING_CONTEXT.to_vec();
    message.extend_from_slice(&payload);
    issuer
        .verify_strict(
            &message,
            &Signature::from_slice(&signature).map_err(|_| "trust-signature")?,
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
    trust_domain: &str,
) -> Result<(Intermediate, VerifyingKey), &'static str> {
    let certificate: Intermediate = signed(envelope, &key(&root.public_key_hex)?)?;
    let public_key = key(&certificate.public_key_hex)?;
    require(
        certificate.schema == 1
            && certificate.kind == "intermediate"
            && certificate.role == role
            && certificate.trust_domain == trust_domain
            && certificate.issuer_key_id == root.key_id
            && certificate.key_id == identity(role, &public_key)
            && certificate.issued_at >= root.issued_at
            && certificate.expires_at <= root.expires_at,
        "intermediate-rejected",
    )?;
    validity(certificate.issued_at, certificate.expires_at, now, 180)?;
    Ok((certificate, public_key))
}

pub struct VerifiedMarketplaceTrust {
    pub store: TrustStore,
    pub root_key_id: String,
    pub sequence: u64,
    pub publisher_count: usize,
}

/// Verify a Cloud-delivered Marketplace bundle against the public root pinned
/// into the Runtime build. The Cloud service is transport only; it cannot add
/// publishers or alter revocations without the corresponding trust-chain keys.
fn verify_profile(
    bundle_json: &str,
    pinned_root_json: &str,
    now: i64,
    trust_domain: &str,
    custody: &str,
    revocation_max_days: i64,
) -> Result<VerifiedMarketplaceTrust, &'static str> {
    require(
        bundle_json.len() <= MAX_BUNDLE_BYTES && pinned_root_json.len() <= 4096,
        "trust-input-size",
    )?;
    let bundle: Bundle = serde_json::from_str(bundle_json).map_err(|_| "trust-schema")?;
    let root: Root = serde_json::from_str(pinned_root_json).map_err(|_| "trust-pin-schema")?;
    let root_key = key(&root.public_key_hex)?;
    require(
        bundle.schema == 2
            && bundle.root == root
            && root.trust_domain == trust_domain
            && root.custody == custody
            && root.key_id == identity("root", &root_key),
        "root-pin-mismatch",
    )?;
    validity(root.issued_at, root.expires_at, now, 1_825)?;

    let (registry, registry_key) = intermediate(
        bundle.registry_certificate,
        &root,
        "publisher-registry",
        now,
        trust_domain,
    )?;
    let (revocation, revocation_key) = intermediate(
        bundle.revocation_certificate,
        &root,
        "revocation",
        now,
        trust_domain,
    )?;

    let revoked: Revocations = signed(bundle.revocations, &revocation_key)?;
    require(
        revoked.schema == 1
            && revoked.kind == "revocations"
            && revoked.trust_domain == trust_domain
            && revoked.issuer_key_id == revocation.key_id
            && revoked.sequence > 0
            && revoked.issued_at >= revocation.issued_at
            && revoked.expires_at <= revocation.expires_at,
        "revocations-rejected",
    )?;
    validity(
        revoked.issued_at,
        revoked.expires_at,
        now,
        revocation_max_days,
    )?;
    for key_id in [&root.key_id, &registry.key_id, &revocation.key_id] {
        require(
            !revoked.revoked_key_ids.contains(key_id),
            "trust-role-key-revoked",
        )?;
    }

    require(
        !bundle.publisher_endorsements.is_empty()
            && bundle.publisher_endorsements.len() <= MAX_PUBLISHERS,
        "publisher-count-rejected",
    )?;

    let mut role_keys = vec![
        *root_key.as_bytes(),
        *registry_key.as_bytes(),
        *revocation_key.as_bytes(),
    ];
    let mut seen_key_ids = std::collections::BTreeSet::new();
    let mut store = TrustStore::new();
    let mut publisher_count = 0_usize;

    for envelope in bundle.publisher_endorsements {
        let publisher: Publisher = signed(envelope, &registry_key)?;
        let publisher_key = key(&publisher.public_key_hex)?;
        require(
            publisher.schema == 1
                && publisher.kind == "publisher"
                && publisher.trust_domain == trust_domain
                && publisher.issuer_key_id == registry.key_id
                && !publisher.publisher_id.is_empty()
                && publisher.publisher_id.len() <= 128
                && publisher.key_id.starts_with("ed25519:")
                && publisher.key_id.len() <= 256
                && publisher.issued_at >= registry.issued_at
                && publisher.expires_at <= registry.expires_at,
            "publisher-endorsement-rejected",
        )?;
        validity(publisher.issued_at, publisher.expires_at, now, 180)?;
        require(
            seen_key_ids.insert(publisher.key_id.clone()),
            "duplicate-publisher-key-id",
        )?;
        require(
            role_keys
                .iter()
                .all(|existing| existing != publisher_key.as_bytes()),
            "trust-role-key-reuse",
        )?;
        role_keys.push(*publisher_key.as_bytes());

        if revoked.revoked_key_ids.contains(&publisher.key_id) {
            continue;
        }
        store.add_publisher_key(publisher.key_id, publisher.publisher_id, publisher_key);
        publisher_count += 1;
    }
    require(publisher_count > 0, "no-active-publishers")?;

    for item in revoked.revoked_packages {
        require(
            !item.package_id.is_empty()
                && item.package_id.len() <= 128
                && !item.version.is_empty()
                && item.version.len() <= 128,
            "revoked-package-rejected",
        )?;
        store.revoke_package(item.package_id, item.version);
    }

    Ok(VerifiedMarketplaceTrust {
        store,
        root_key_id: root.key_id,
        sequence: revoked.sequence,
        publisher_count,
    })
}

pub fn verify(
    bundle_json: &str,
    pinned_root_json: &str,
    now: i64,
) -> Result<VerifiedMarketplaceTrust, &'static str> {
    verify_profile(
        bundle_json,
        pinned_root_json,
        now,
        PRODUCTION_DOMAIN,
        PRODUCTION_CUSTODY,
        7,
    )
}

pub fn verify_staging(
    bundle_json: &str,
    pinned_root_json: &str,
    now: i64,
) -> Result<VerifiedMarketplaceTrust, &'static str> {
    verify_profile(
        bundle_json,
        pinned_root_json,
        now,
        STAGING_DOMAIN,
        STAGING_CUSTODY,
        30,
    )
}
