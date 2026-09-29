//! Deterministic OCP package builder for Package Specification v0.1.
#![forbid(unsafe_code)]

use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::{Signer, SigningKey};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{Cursor, Write},
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipWriter};

const PREFIX: &[u8] = b"OCP-PACKAGE-SIGNING-V0.1\0";
const SCHEMA: &str = include_str!("../../package-loader/schema/manifest-v0.1.schema.json");

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackageType {
    Character,
    Plugin,
    Voice,
    EffectPack,
}
impl PackageType {
    fn value(&self) -> &'static str {
        match self {
            Self::Character => "character",
            Self::Plugin => "plugin",
            Self::Voice => "voice",
            Self::EffectPack => "effect-pack",
        }
    }
}
#[derive(Debug, Clone)]
pub struct PackageIdentity {
    pub id: String,
    pub package_type: PackageType,
    pub version: String,
    pub publisher_id: String,
    pub key_id: String,
    pub license: String,
    pub entry: String,
}
#[derive(Debug, Clone)]
pub struct AssetInput {
    pub path: String,
    pub bytes: Vec<u8>,
}
#[derive(Debug, Clone)]
pub struct BuildRequest {
    pub identity: PackageIdentity,
    pub asset_paths: Vec<String>,
    pub assets: Vec<AssetInput>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildError {
    UnsafePath(String),
    DuplicatePath(String),
    MissingAsset(String),
    UndeclaredAsset(String),
    InvalidManifest,
    ArchiveWrite,
}
impl std::fmt::Display for BuildError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for BuildError {}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Manifest<'a> {
    manifest_version: &'static str,
    id: &'a str,
    #[serde(rename = "type")]
    package_type: &'a str,
    version: &'a str,
    publisher: Publisher<'a>,
    license: &'a str,
    entry: &'a str,
    assets: Vec<Asset<'a>>,
    signature: SignatureBlock<'a>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Publisher<'a> {
    id: &'a str,
    key_id: &'a str,
}
#[derive(Serialize)]
struct Asset<'a> {
    path: &'a str,
    sha256: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SignatureBlock<'a> {
    algorithm: &'static str,
    key_id: &'a str,
    digest: String,
    value: String,
}

fn safe_asset_path(path: &str) -> bool {
    path.starts_with("assets/")
        && path.len() > 7
        && !path.contains('\\')
        && !path.starts_with('/')
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn append_field(payload: &mut Vec<u8>, value: &[u8]) {
    payload.extend((value.len() as u64).to_be_bytes());
    payload.extend(value);
}

/// Builds a byte-stable `.ocp` ZIP. The signing key is borrowed and never persisted.
pub fn build(request: &BuildRequest, signing_key: &SigningKey) -> Result<Vec<u8>, BuildError> {
    let mut declared = BTreeSet::new();
    for path in &request.asset_paths {
        if !safe_asset_path(path) {
            return Err(BuildError::UnsafePath(path.clone()));
        }
        if !declared.insert(path.clone()) {
            return Err(BuildError::DuplicatePath(path.clone()));
        }
    }
    if !declared.contains(&request.identity.entry) {
        return Err(BuildError::MissingAsset(request.identity.entry.clone()));
    }
    let mut supplied = BTreeMap::new();
    for asset in &request.assets {
        if !safe_asset_path(&asset.path) {
            return Err(BuildError::UnsafePath(asset.path.clone()));
        }
        if supplied.insert(asset.path.clone(), &asset.bytes).is_some() {
            return Err(BuildError::DuplicatePath(asset.path.clone()));
        }
    }
    for path in &declared {
        if !supplied.contains_key(path) {
            return Err(BuildError::MissingAsset(path.clone()));
        }
    }
    for path in supplied.keys() {
        if !declared.contains(path) {
            return Err(BuildError::UndeclaredAsset(path.clone()));
        }
    }
    let assets = declared
        .iter()
        .map(|path| Asset {
            path,
            sha256: hex(&Sha256::digest(supplied[path])),
        })
        .collect();
    let unsigned = Manifest {
        manifest_version: "0.1",
        id: &request.identity.id,
        package_type: request.identity.package_type.value(),
        version: &request.identity.version,
        publisher: Publisher {
            id: &request.identity.publisher_id,
            key_id: &request.identity.key_id,
        },
        license: &request.identity.license,
        entry: &request.identity.entry,
        assets,
        signature: SignatureBlock {
            algorithm: "ed25519",
            key_id: &request.identity.key_id,
            digest: String::new(),
            value: String::new(),
        },
    };
    let mut unsigned_value =
        serde_json::to_value(&unsigned).map_err(|_| BuildError::InvalidManifest)?;
    unsigned_value
        .as_object_mut()
        .ok_or(BuildError::InvalidManifest)?
        .remove("signature");
    let jcs = serde_jcs::to_vec(&unsigned_value).map_err(|_| BuildError::InvalidManifest)?;
    let mut payload = PREFIX.to_vec();
    append_field(&mut payload, &jcs);
    for path in &declared {
        append_field(&mut payload, path.as_bytes());
        append_field(&mut payload, supplied[path]);
    }
    let digest = Sha256::digest(payload);
    let signature = signing_key.sign(&digest);
    let manifest = Manifest {
        signature: SignatureBlock {
            algorithm: "ed25519",
            key_id: &request.identity.key_id,
            digest: format!("sha256:{}", hex(&digest)),
            value: format!("base64:{}", B64.encode(signature.to_bytes())),
        },
        ..unsigned
    };
    let manifest_value =
        serde_json::to_value(&manifest).map_err(|_| BuildError::InvalidManifest)?;
    let schema = serde_json::from_str(SCHEMA).map_err(|_| BuildError::InvalidManifest)?;
    jsonschema::draft202012::validate(&schema, &manifest_value)
        .map_err(|_| BuildError::InvalidManifest)?;
    let manifest_bytes = serde_json::to_vec(&manifest).map_err(|_| BuildError::InvalidManifest)?;
    let mut output = Cursor::new(Vec::new());
    let mut zip = ZipWriter::new(&mut output);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
    zip.start_file("manifest.json", options)
        .map_err(|_| BuildError::ArchiveWrite)?;
    zip.write_all(&manifest_bytes)
        .map_err(|_| BuildError::ArchiveWrite)?;
    for path in &declared {
        zip.start_file(path, options)
            .map_err(|_| BuildError::ArchiveWrite)?;
        zip.write_all(supplied[path])
            .map_err(|_| BuildError::ArchiveWrite)?;
    }
    zip.finish().map_err(|_| BuildError::ArchiveWrite)?;
    Ok(output.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ocp_package_loader::{load, TrustStore};
    fn request(package_type: PackageType) -> BuildRequest {
        BuildRequest {
            identity: PackageIdentity {
                id: "example.package".into(),
                package_type,
                version: "1.0.0".into(),
                publisher_id: "example.publisher".into(),
                key_id: "ed25519:test-1".into(),
                license: "Apache-2.0".into(),
                entry: "assets/main.json".into(),
            },
            asset_paths: vec!["assets/main.json".into()],
            assets: vec![AssetInput {
                path: "assets/main.json".into(),
                bytes: br#"{"name":"example"}"#.to_vec(),
            }],
        }
    }
    fn key() -> SigningKey {
        SigningKey::from_bytes(&[7; 32])
    }
    fn trust(key: &SigningKey) -> TrustStore {
        let mut store = TrustStore::new();
        store.add_key("ed25519:test-1", key.verifying_key());
        store
    }
    #[test]
    fn cs_pkg_bld_deterministic_output() {
        let input = request(PackageType::Character);
        let key = key();
        assert_eq!(build(&input, &key).unwrap(), build(&input, &key).unwrap());
    }
    #[test]
    fn cs_pkg_bld_round_trips_all_package_types_through_loader() {
        let key = key();
        let trust = trust(&key);
        for kind in [
            PackageType::Character,
            PackageType::Plugin,
            PackageType::Voice,
            PackageType::EffectPack,
        ] {
            assert!(load(&build(&request(kind), &key).unwrap(), &trust).is_ok());
        }
    }
    #[test]
    fn cs_pkg_bld_rejects_invalid_asset_sets() {
        let key = key();
        let mut duplicate = request(PackageType::Character);
        duplicate.asset_paths.push("assets/main.json".into());
        assert!(matches!(
            build(&duplicate, &key),
            Err(BuildError::DuplicatePath(_))
        ));
        let mut unsafe_path = request(PackageType::Character);
        unsafe_path.asset_paths = vec!["assets/../secret".into()];
        assert!(matches!(
            build(&unsafe_path, &key),
            Err(BuildError::UnsafePath(_))
        ));
        let mut invalid = request(PackageType::Character);
        invalid.identity.id = "INVALID".into();
        assert!(matches!(
            build(&invalid, &key),
            Err(BuildError::InvalidManifest)
        ));
        let mut missing = request(PackageType::Character);
        missing.assets.clear();
        assert!(matches!(
            build(&missing, &key),
            Err(BuildError::MissingAsset(_))
        ));
        let mut undeclared = request(PackageType::Character);
        undeclared.assets.push(AssetInput {
            path: "assets/extra.json".into(),
            bytes: vec![],
        });
        assert!(matches!(
            build(&undeclared, &key),
            Err(BuildError::UndeclaredAsset(_))
        ));
    }
}
