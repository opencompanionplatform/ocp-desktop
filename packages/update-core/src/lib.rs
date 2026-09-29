//! Signed application-update metadata and staged artifact verification.
//! ADR-0024 / SEC-050. This crate never replaces an installation.
#![forbid(unsafe_code)]

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use chrono::DateTime;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use semver::Version;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    time::Duration,
};

const SIGNING_PREFIX: &[u8] = b"OCP-UPDATE-SIGNING-V1\0";
pub const MAX_MANIFEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateManifest {
    pub schema: String,
    pub channel: String,
    pub version: String,
    pub published_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_notes_url: Option<String>,
    pub artifacts: Vec<UpdateArtifact>,
    pub signature: UpdateSignature,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UnsignedUpdateManifest {
    pub schema: String,
    pub channel: String,
    pub version: String,
    pub published_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_notes_url: Option<String>,
    pub artifacts: Vec<UpdateArtifact>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateArtifact {
    pub platform: String,
    pub arch: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateSignature {
    pub algorithm: String,
    pub key_id: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateError {
    ManifestTooLarge,
    InvalidJson,
    InvalidSchema,
    InvalidChannel,
    InvalidVersion,
    InvalidTimestamp,
    InvalidUrl,
    InvalidArtifact,
    DuplicateTarget,
    UnknownKey,
    InvalidKey,
    InvalidSignature,
    NoUpdate,
    UnsupportedTarget,
    SizeMismatch { expected: u64, actual: u64 },
    DigestMismatch,
    Io,
    Network,
}

impl std::fmt::Display for UpdateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SizeMismatch { expected, actual } => {
                write!(
                    f,
                    "artifact size mismatch: expected {expected}, got {actual}"
                )
            }
            other => write!(f, "{other:?}"),
        }
    }
}

impl std::error::Error for UpdateError {}

fn is_https(url: &str) -> bool {
    url.starts_with("https://") && url.len() > "https://".len()
}

fn is_lower_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn validate_unsigned(manifest: &UnsignedUpdateManifest) -> Result<(), UpdateError> {
    if manifest.schema != "ocp-update/1" {
        return Err(UpdateError::InvalidSchema);
    }
    if !matches!(manifest.channel.as_str(), "stable" | "beta" | "nightly") {
        return Err(UpdateError::InvalidChannel);
    }
    Version::parse(&manifest.version).map_err(|_| UpdateError::InvalidVersion)?;
    DateTime::parse_from_rfc3339(&manifest.published_at)
        .map_err(|_| UpdateError::InvalidTimestamp)?;
    if manifest
        .release_notes_url
        .as_deref()
        .is_some_and(|url| !is_https(url))
    {
        return Err(UpdateError::InvalidUrl);
    }
    if manifest.artifacts.is_empty() || manifest.artifacts.len() > 32 {
        return Err(UpdateError::InvalidArtifact);
    }
    let mut targets = BTreeSet::new();
    for artifact in &manifest.artifacts {
        if !matches!(artifact.platform.as_str(), "windows" | "macos")
            || !matches!(artifact.arch.as_str(), "x86_64" | "arm64")
            || !is_https(&artifact.url)
            || artifact.size == 0
            || !is_lower_hex_digest(&artifact.sha256)
        {
            return Err(UpdateError::InvalidArtifact);
        }
        if !targets.insert((&artifact.platform, &artifact.arch)) {
            return Err(UpdateError::DuplicateTarget);
        }
    }
    Ok(())
}

fn unsigned_from_signed(manifest: &UpdateManifest) -> UnsignedUpdateManifest {
    UnsignedUpdateManifest {
        schema: manifest.schema.clone(),
        channel: manifest.channel.clone(),
        version: manifest.version.clone(),
        published_at: manifest.published_at.clone(),
        release_notes_url: manifest.release_notes_url.clone(),
        artifacts: manifest.artifacts.clone(),
    }
}

fn signing_payload(unsigned: &UnsignedUpdateManifest) -> Result<Vec<u8>, UpdateError> {
    let canonical = serde_jcs::to_vec(unsigned).map_err(|_| UpdateError::InvalidJson)?;
    let mut payload = Vec::with_capacity(SIGNING_PREFIX.len() + canonical.len());
    payload.extend_from_slice(SIGNING_PREFIX);
    payload.extend_from_slice(&canonical);
    Ok(payload)
}

pub fn parse_manifest(bytes: &[u8]) -> Result<UpdateManifest, UpdateError> {
    if bytes.len() > MAX_MANIFEST_BYTES {
        return Err(UpdateError::ManifestTooLarge);
    }
    let manifest: UpdateManifest =
        serde_json::from_slice(bytes).map_err(|_| UpdateError::InvalidJson)?;
    validate_unsigned(&unsigned_from_signed(&manifest))?;
    if manifest.signature.algorithm != "ed25519"
        || manifest.signature.key_id.is_empty()
        || manifest.signature.key_id.len() > 128
    {
        return Err(UpdateError::InvalidSignature);
    }
    Ok(manifest)
}

pub fn sign_manifest(
    unsigned: UnsignedUpdateManifest,
    key_id: impl Into<String>,
    key: &SigningKey,
) -> Result<UpdateManifest, UpdateError> {
    validate_unsigned(&unsigned)?;
    let signature = key.sign(&signing_payload(&unsigned)?);
    Ok(UpdateManifest {
        schema: unsigned.schema,
        channel: unsigned.channel,
        version: unsigned.version,
        published_at: unsigned.published_at,
        release_notes_url: unsigned.release_notes_url,
        artifacts: unsigned.artifacts,
        signature: UpdateSignature {
            algorithm: "ed25519".to_owned(),
            key_id: key_id.into(),
            value: B64.encode(signature.to_bytes()),
        },
    })
}

pub fn verify_manifest(
    manifest: &UpdateManifest,
    expected_key_id: &str,
    key: &VerifyingKey,
) -> Result<(), UpdateError> {
    validate_unsigned(&unsigned_from_signed(manifest))?;
    if manifest.signature.algorithm != "ed25519" || manifest.signature.key_id != expected_key_id {
        return Err(UpdateError::UnknownKey);
    }
    let bytes = B64
        .decode(&manifest.signature.value)
        .map_err(|_| UpdateError::InvalidSignature)?;
    let signature = Signature::from_slice(&bytes).map_err(|_| UpdateError::InvalidSignature)?;
    key.verify(
        &signing_payload(&unsigned_from_signed(manifest))?,
        &signature,
    )
    .map_err(|_| UpdateError::InvalidSignature)
}

pub fn select_update<'a>(
    manifest: &'a UpdateManifest,
    current_version: &str,
    platform: &str,
    arch: &str,
) -> Result<&'a UpdateArtifact, UpdateError> {
    let current = Version::parse(current_version).map_err(|_| UpdateError::InvalidVersion)?;
    let offered = Version::parse(&manifest.version).map_err(|_| UpdateError::InvalidVersion)?;
    if offered <= current {
        return Err(UpdateError::NoUpdate);
    }
    manifest
        .artifacts
        .iter()
        .find(|artifact| artifact.platform == platform && artifact.arch == arch)
        .ok_or(UpdateError::UnsupportedTarget)
}

pub fn verify_artifact(artifact: &UpdateArtifact, bytes: &[u8]) -> Result<(), UpdateError> {
    let actual = u64::try_from(bytes.len()).map_err(|_| UpdateError::InvalidArtifact)?;
    if actual != artifact.size {
        return Err(UpdateError::SizeMismatch {
            expected: artifact.size,
            actual,
        });
    }
    let digest = Sha256::digest(bytes);
    let actual_hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    if actual_hex != artifact.sha256 {
        return Err(UpdateError::DigestMismatch);
    }
    Ok(())
}

pub fn decode_verifying_key(value: &str) -> Result<VerifyingKey, UpdateError> {
    let bytes = B64.decode(value).map_err(|_| UpdateError::InvalidKey)?;
    let fixed: [u8; 32] = bytes.try_into().map_err(|_| UpdateError::InvalidKey)?;
    VerifyingKey::from_bytes(&fixed).map_err(|_| UpdateError::InvalidKey)
}

pub fn decode_signing_key(value: &str) -> Result<SigningKey, UpdateError> {
    let bytes = B64.decode(value).map_err(|_| UpdateError::InvalidKey)?;
    let fixed: [u8; 32] = bytes.try_into().map_err(|_| UpdateError::InvalidKey)?;
    Ok(SigningKey::from_bytes(&fixed))
}

pub fn fetch_https(url: &str, maximum_bytes: u64) -> Result<Vec<u8>, UpdateError> {
    fetch_https_with_timeout(url, maximum_bytes, Duration::from_secs(60))
}

/// Fetch an HTTPS resource with an explicit end-to-end deadline.
///
/// Update manifests stay on the short default timeout, while large signed
/// release artifacts may need a much longer deadline on inspected/corporate
/// networks. The byte limit remains authoritative in both cases.
pub fn fetch_https_with_timeout(
    url: &str,
    maximum_bytes: u64,
    timeout: Duration,
) -> Result<Vec<u8>, UpdateError> {
    if !is_https(url) || maximum_bytes == 0 || timeout.is_zero() {
        return Err(UpdateError::InvalidUrl);
    }
    let config = ureq::Agent::config_builder()
        .https_only(true)
        .timeout_global(Some(timeout))
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_recv_response(Some(Duration::from_secs(30)))
        .tls_config(
            ureq::tls::TlsConfig::builder()
                .provider(ureq::tls::TlsProvider::NativeTls)
                .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                .build(),
        )
        .build();
    let mut response = config
        .new_agent()
        .get(url)
        .call()
        .map_err(|_| UpdateError::Network)?;
    let bytes = response
        .body_mut()
        .with_config()
        .limit(maximum_bytes.saturating_add(1))
        .read_to_vec()
        .map_err(|_| UpdateError::Network)?;
    if u64::try_from(bytes.len()).map_err(|_| UpdateError::InvalidArtifact)? > maximum_bytes {
        return Err(UpdateError::SizeMismatch {
            expected: maximum_bytes,
            actual: bytes.len() as u64,
        });
    }
    Ok(bytes)
}

pub fn stage_verified_artifact(
    staging_dir: &Path,
    file_name: &str,
    artifact: &UpdateArtifact,
    bytes: &[u8],
) -> Result<std::path::PathBuf, UpdateError> {
    verify_artifact(artifact, bytes)?;
    if file_name.is_empty()
        || file_name == "."
        || file_name == ".."
        || file_name.contains('/')
        || file_name.contains('\\')
    {
        return Err(UpdateError::InvalidArtifact);
    }
    fs::create_dir_all(staging_dir).map_err(|_| UpdateError::Io)?;
    let temporary = staging_dir.join(format!(".{file_name}.partial"));
    let destination = staging_dir.join(file_name);
    if destination.exists() {
        let existing = fs::read(&destination).map_err(|_| UpdateError::Io)?;
        verify_artifact(artifact, &existing)?;
        return Ok(destination);
    }
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|_| UpdateError::Io)?;
    if output
        .write_all(bytes)
        .and_then(|()| output.sync_all())
        .is_err()
    {
        drop(output);
        let _ = fs::remove_file(&temporary);
        return Err(UpdateError::Io);
    }
    drop(output);
    fs::rename(&temporary, &destination).map_err(|_| UpdateError::Io)?;
    Ok(destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> SigningKey {
        SigningKey::from_bytes(&[42; 32])
    }

    fn unsigned(bytes: &[u8]) -> UnsignedUpdateManifest {
        let hash: String = Sha256::digest(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        UnsignedUpdateManifest {
            schema: "ocp-update/1".into(),
            channel: "stable".into(),
            version: "1.2.0".into(),
            published_at: "2026-08-13T00:00:00Z".into(),
            release_notes_url: Some("https://github.com/opencompanionplatform/ocp-releases/releases/tag/v1.2.0".into()),
            artifacts: vec![UpdateArtifact {
                platform: "windows".into(),
                arch: "arm64".into(),
                url: "https://github.com/opencompanionplatform/ocp-releases/releases/download/v1.2.0/ocp-windows-arm64.zip".into(),
                size: bytes.len() as u64,
                sha256: hash,
            }],
        }
    }

    #[test]
    fn signed_manifest_selects_newer_matching_target() {
        let key = key();
        let manifest = sign_manifest(unsigned(b"artifact"), "test-key", &key).unwrap();
        verify_manifest(&manifest, "test-key", &key.verifying_key()).unwrap();
        assert!(select_update(&manifest, "1.1.9", "windows", "arm64").is_ok());
    }

    #[test]
    fn tampered_metadata_and_wrong_key_are_rejected() {
        let key = key();
        let mut manifest = sign_manifest(unsigned(b"artifact"), "test-key", &key).unwrap();
        manifest.version = "9.9.9".into();
        assert_eq!(
            verify_manifest(&manifest, "test-key", &key.verifying_key()),
            Err(UpdateError::InvalidSignature)
        );
        let manifest = sign_manifest(unsigned(b"artifact"), "test-key", &key).unwrap();
        assert_eq!(
            verify_manifest(&manifest, "other-key", &key.verifying_key()),
            Err(UpdateError::UnknownKey)
        );
    }

    #[test]
    fn downgrade_unsupported_target_and_duplicate_target_are_rejected() {
        let key = key();
        let manifest = sign_manifest(unsigned(b"artifact"), "test-key", &key).unwrap();
        assert_eq!(
            select_update(&manifest, "1.2.0", "windows", "arm64"),
            Err(UpdateError::NoUpdate)
        );
        assert_eq!(
            select_update(&manifest, "1.1.0", "macos", "arm64"),
            Err(UpdateError::UnsupportedTarget)
        );
        let mut invalid = unsigned(b"artifact");
        invalid.artifacts.push(invalid.artifacts[0].clone());
        assert_eq!(
            sign_manifest(invalid, "test-key", &key),
            Err(UpdateError::DuplicateTarget)
        );
    }

    #[test]
    fn invalid_urls_and_unknown_fields_are_rejected() {
        let key = key();
        let mut invalid = unsigned(b"artifact");
        invalid.artifacts[0].url = "http://example.test/update.zip".into();
        assert_eq!(
            sign_manifest(invalid, "test-key", &key),
            Err(UpdateError::InvalidArtifact)
        );
        let raw = br#"{"schema":"ocp-update/1","extra":true}"#;
        assert_eq!(parse_manifest(raw), Err(UpdateError::InvalidJson));
    }

    #[test]
    fn artifact_length_and_digest_are_verified() {
        let key = key();
        let manifest = sign_manifest(unsigned(b"artifact"), "test-key", &key).unwrap();
        let artifact = &manifest.artifacts[0];
        verify_artifact(artifact, b"artifact").unwrap();
        assert!(matches!(
            verify_artifact(artifact, b"short"),
            Err(UpdateError::SizeMismatch { .. })
        ));
        let mut wrong = artifact.clone();
        wrong.sha256 = "0".repeat(64);
        assert_eq!(
            verify_artifact(&wrong, b"artifact"),
            Err(UpdateError::DigestMismatch)
        );
    }

    #[test]
    fn staging_writes_only_verified_bytes_to_a_safe_filename() {
        let key = key();
        let manifest = sign_manifest(unsigned(b"artifact"), "test-key", &key).unwrap();
        let artifact = &manifest.artifacts[0];
        let staging = std::env::temp_dir().join(format!(
            "ocp-release-core-{}-staging-test",
            std::process::id()
        ));
        if staging.exists() {
            std::fs::remove_dir_all(&staging).unwrap();
        }
        let path =
            stage_verified_artifact(&staging, "artifact.zip", artifact, b"artifact").unwrap();
        assert_eq!(std::fs::read(path).unwrap(), b"artifact");
        assert_eq!(
            stage_verified_artifact(&staging, "../escape.zip", artifact, b"artifact"),
            Err(UpdateError::InvalidArtifact)
        );
        std::fs::remove_dir_all(staging).unwrap();
    }
}
