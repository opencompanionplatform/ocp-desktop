//! Immutable OCP package loader โ€” Package Specification v0.1, ADR-0011/0017.
#![forbid(unsafe_code)]

pub mod beta_trust;
pub mod marketplace_trust;

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashMap},
    io::{Cursor, Read},
};
use zip::ZipArchive;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    InvalidArchive,
    ManifestParse,
    ManifestSchema,
    UnsafePath,
    DuplicatePath,
    MissingAsset(String),
    UndeclaredMember(String),
    AssetDigestMismatch(String),
    SignatureDigestMismatch,
    SignatureVerificationFailed,
    UnknownKey(String),
    PublisherMismatch,
    Revoked,
}
impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for LoadError {}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub manifest_version: String,
    pub id: String,
    #[serde(rename = "type")]
    pub package_type: PackageType,
    pub version: String,
    pub publisher: Publisher,
    pub license: String,
    pub entry: String,
    pub assets: Vec<Asset>,
    pub signature: SignatureBlock,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PackageType {
    Character,
    Plugin,
    Voice,
    #[serde(rename = "effect-pack")]
    EffectPack,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Publisher {
    pub id: String,
    pub key_id: String,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Asset {
    pub path: String,
    pub sha256: String,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignatureBlock {
    pub algorithm: String,
    pub key_id: String,
    pub digest: String,
    pub value: String,
}

#[derive(Default, Clone)]
pub struct TrustStore {
    keys: HashMap<String, VerifyingKey>,
    publishers: HashMap<String, String>,
    revoked_packages: BTreeSet<(String, String)>,
}
impl TrustStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
    pub fn add_key(&mut self, id: impl Into<String>, key: VerifyingKey) {
        self.keys.insert(id.into(), key);
    }
    pub fn add_publisher_key(&mut self, id: String, publisher: String, key: VerifyingKey) {
        self.publishers.insert(id.clone(), publisher);
        self.keys.insert(id, key);
    }
    pub fn revoke_package(&mut self, id: String, version: String) {
        self.revoked_packages.insert((id, version));
    }
}
#[derive(Debug)]
pub struct LoadedPackage {
    pub manifest: Manifest,
    pub archive_bytes: Vec<u8>,
}

const SCHEMA: &str = include_str!("../schema/manifest-v0.1.schema.json");
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains('\\')
        && !path.starts_with('/')
        && path
            .split('/')
            .all(|s| !s.is_empty() && s != "." && s != "..")
}
fn u64be(value: usize) -> [u8; 8] {
    (value as u64).to_be_bytes()
}

fn central_directory_names(bytes: &[u8]) -> Result<Vec<String>, LoadError> {
    const EOCD: [u8; 4] = [0x50, 0x4b, 0x05, 0x06];
    const CENTRAL: [u8; 4] = [0x50, 0x4b, 0x01, 0x02];
    let start = bytes.len().saturating_sub(65_557);
    let eocd = bytes[start..]
        .windows(4)
        .rposition(|window| window == EOCD)
        .map(|offset| start + offset)
        .ok_or(LoadError::InvalidArchive)?;
    if eocd + 22 > bytes.len() {
        return Err(LoadError::InvalidArchive);
    }
    let entries = u16::from_le_bytes([bytes[eocd + 10], bytes[eocd + 11]]) as usize;
    let offset = u32::from_le_bytes([
        bytes[eocd + 16],
        bytes[eocd + 17],
        bytes[eocd + 18],
        bytes[eocd + 19],
    ]) as usize;
    let mut cursor = offset;
    let mut names = Vec::with_capacity(entries);
    for _ in 0..entries {
        if cursor + 46 > bytes.len() || bytes[cursor..cursor + 4] != CENTRAL {
            return Err(LoadError::InvalidArchive);
        }
        let name_len = u16::from_le_bytes([bytes[cursor + 28], bytes[cursor + 29]]) as usize;
        let extra_len = u16::from_le_bytes([bytes[cursor + 30], bytes[cursor + 31]]) as usize;
        let comment_len = u16::from_le_bytes([bytes[cursor + 32], bytes[cursor + 33]]) as usize;
        let name_start = cursor + 46;
        let name_end = name_start
            .checked_add(name_len)
            .ok_or(LoadError::InvalidArchive)?;
        let next = name_end
            .checked_add(extra_len)
            .and_then(|n| n.checked_add(comment_len))
            .ok_or(LoadError::InvalidArchive)?;
        if next > bytes.len() {
            return Err(LoadError::InvalidArchive);
        }
        let name =
            std::str::from_utf8(&bytes[name_start..name_end]).map_err(|_| LoadError::UnsafePath)?;
        names.push(name.to_owned());
        cursor = next;
    }
    Ok(names)
}
pub fn load(bytes: &[u8], trust: &TrustStore) -> Result<LoadedPackage, LoadError> {
    let mut declared_members = BTreeSet::new();
    for name in central_directory_names(bytes)? {
        if !safe_path(&name) {
            return Err(LoadError::UnsafePath);
        }
        if !declared_members.insert(name) {
            return Err(LoadError::DuplicatePath);
        }
    }
    let mut archive = ZipArchive::new(Cursor::new(bytes)).map_err(|_| LoadError::InvalidArchive)?;
    let mut members = BTreeSet::new();
    let mut contents = HashMap::new();
    for index in 0..archive.len() {
        let mut file = archive
            .by_index(index)
            .map_err(|_| LoadError::InvalidArchive)?;
        let name = file.name().to_owned();
        if file.is_dir() {
            continue;
        }
        if !safe_path(&name) {
            return Err(LoadError::UnsafePath);
        }
        if !members.insert(name.clone()) {
            return Err(LoadError::DuplicatePath);
        }
        if name != "manifest.json" && !name.starts_with("assets/") {
            return Err(LoadError::UndeclaredMember(name));
        }
        let mut data = Vec::new();
        file.read_to_end(&mut data)
            .map_err(|_| LoadError::InvalidArchive)?;
        contents.insert(name, data);
    }
    let raw_manifest = contents
        .get("manifest.json")
        .ok_or(LoadError::MissingAsset("manifest.json".into()))?;
    let value: serde_json::Value =
        serde_json::from_slice(raw_manifest).map_err(|_| LoadError::ManifestParse)?;
    let schema: serde_json::Value =
        serde_json::from_str(SCHEMA).map_err(|_| LoadError::ManifestSchema)?;
    jsonschema::draft202012::validate(&schema, &value).map_err(|_| LoadError::ManifestSchema)?;
    let manifest: Manifest =
        serde_json::from_value(value.clone()).map_err(|_| LoadError::ManifestSchema)?;
    if manifest.publisher.key_id != manifest.signature.key_id {
        return Err(LoadError::ManifestSchema);
    }
    if trust
        .publishers
        .get(&manifest.signature.key_id)
        .is_some_and(|publisher| publisher != &manifest.publisher.id)
    {
        return Err(LoadError::PublisherMismatch);
    }
    if trust
        .revoked_packages
        .contains(&(manifest.id.clone(), manifest.version.clone()))
    {
        return Err(LoadError::Revoked);
    }
    let mut declared = BTreeSet::new();
    for asset in &manifest.assets {
        if !safe_path(&asset.path) || !asset.path.starts_with("assets/") {
            return Err(LoadError::UnsafePath);
        }
        if !declared.insert(asset.path.clone()) {
            return Err(LoadError::DuplicatePath);
        }
        let data = contents
            .get(&asset.path)
            .ok_or_else(|| LoadError::MissingAsset(asset.path.clone()))?;
        if hex(&Sha256::digest(data)) != asset.sha256 {
            return Err(LoadError::AssetDigestMismatch(asset.path.clone()));
        }
    }
    for member in &members {
        if member != "manifest.json" && !declared.contains(member) {
            return Err(LoadError::UndeclaredMember(member.clone()));
        }
    }
    let mut unsigned = value;
    unsigned
        .as_object_mut()
        .ok_or(LoadError::ManifestSchema)?
        .remove("signature");
    let manifest_jcs = serde_jcs::to_vec(&unsigned).map_err(|_| LoadError::ManifestSchema)?;
    let mut payload = Vec::from(&b"OCP-PACKAGE-SIGNING-V0.1\0"[..]);
    payload.extend(u64be(manifest_jcs.len()));
    payload.extend(manifest_jcs);
    for path in &declared {
        let data = &contents[path];
        payload.extend(u64be(path.len()));
        payload.extend(path.as_bytes());
        payload.extend(u64be(data.len()));
        payload.extend(data);
    }
    let digest = Sha256::digest(payload);
    if manifest.signature.digest != format!("sha256:{}", hex(&digest)) {
        return Err(LoadError::SignatureDigestMismatch);
    }
    let key = trust
        .keys
        .get(&manifest.signature.key_id)
        .ok_or_else(|| LoadError::UnknownKey(manifest.signature.key_id.clone()))?;
    let signature = B64
        .decode(
            manifest
                .signature
                .value
                .strip_prefix("base64:")
                .ok_or(LoadError::SignatureVerificationFailed)?,
        )
        .map_err(|_| LoadError::SignatureVerificationFailed)?;
    let signature =
        Signature::from_slice(&signature).map_err(|_| LoadError::SignatureVerificationFailed)?;
    key.verify_strict(&digest, &signature)
        .map_err(|_| LoadError::SignatureVerificationFailed)?;
    Ok(LoadedPackage {
        manifest,
        archive_bytes: bytes.to_vec(),
    })
}
