//! Package signature verification — ADR-0011, SEC-010.
//! Verified at install AND at every load; plugin identity is bound from the
//! verified signature, never from guest claims (SEC-020, X1-S).

use std::collections::HashMap;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::manifest::Manifest;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VerifyError {
    UnknownKey(String),
    DigestMismatch,
    BadEncoding(&'static str),
    BadSignature,
}

impl core::fmt::Display for VerifyError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::UnknownKey(k) => write!(f, "signing key not in trust store (ADR-0011): {k}"),
            Self::DigestMismatch => write!(f, "package digest mismatch (SEC-010)"),
            Self::BadEncoding(what) => write!(f, "malformed signature block field: {what}"),
            Self::BadSignature => write!(f, "signature verification failed (SEC-010)"),
        }
    }
}

impl std::error::Error for VerifyError {}

/// Marketplace-anchored publisher keys (ADR-0011). Alpha: in-memory map;
/// revocation lists (SEC-012) attach here later.
#[derive(Default, Clone)]
pub struct TrustStore {
    keys: HashMap<String, VerifyingKey>,
}

impl TrustStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_key(&mut self, key_id: impl Into<String>, key: VerifyingKey) {
        self.keys.insert(key_id.into(), key);
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Verify the package against the manifest signature block.
/// Digest = sha256 over the package bytes; signature = Ed25519 over the raw
/// 32-byte digest, by the publisher key named in `signature.keyId`.
pub fn verify_package(
    manifest: &Manifest,
    package_bytes: &[u8],
    trust: &TrustStore,
) -> Result<(), VerifyError> {
    let digest = Sha256::digest(package_bytes);

    let declared = manifest
        .signature
        .digest
        .strip_prefix("sha256:")
        .ok_or(VerifyError::BadEncoding("digest prefix"))?;
    if declared != hex(&digest) {
        return Err(VerifyError::DigestMismatch);
    }

    let key = trust
        .keys
        .get(&manifest.signature.key_id)
        .ok_or_else(|| VerifyError::UnknownKey(manifest.signature.key_id.clone()))?;

    let sig_b64 = manifest
        .signature
        .value
        .strip_prefix("base64:")
        .ok_or(VerifyError::BadEncoding("value prefix"))?;
    let sig_bytes = B64
        .decode(sig_b64)
        .map_err(|_| VerifyError::BadEncoding("value base64"))?;
    let signature =
        Signature::from_slice(&sig_bytes).map_err(|_| VerifyError::BadEncoding("value length"))?;

    key.verify(&digest, &signature)
        .map_err(|_| VerifyError::BadSignature)
}
