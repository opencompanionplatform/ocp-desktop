use ed25519_dalek::SigningKey;
use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::{Cursor, Read, Seek},
    path::Path,
};
use zip::ZipArchive;

#[derive(Debug, Deserialize)]
struct InputManifest {
    #[serde(rename = "manifestVersion")]
    manifest_version: String,
    id: String,
    #[serde(rename = "type")]
    package_type: String,
    version: String,
    publisher: Publisher,
    license: String,
    entry: String,
    assets: Vec<Asset>,
}
#[derive(Debug, Deserialize)]
struct Publisher {
    id: String,
    #[serde(rename = "keyId")]
    key_id: String,
}
#[derive(Debug, Deserialize)]
struct Asset {
    path: String,
    sha256: String,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn read_zip_member<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    for index in 0..archive.len() {
        let mut file = archive.by_index(index)?;
        if file.name().replace('\\', "/") == name.replace('\\', "/") {
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes)?;
            return Ok(bytes);
        }
    }
    Err(format!("ZIP member is unavailable: {name}").into())
}
fn decode_key(value: &str) -> Result<SigningKey, String> {
    let value = value.strip_prefix("hex:").unwrap_or(value);
    let bytes = hex_decode(value)?;
    if bytes.len() != 32 {
        return Err("signing key must be exactly 32 bytes".into());
    }
    let mut fixed = [0u8; 32];
    fixed.copy_from_slice(&bytes);
    Ok(SigningKey::from_bytes(&fixed))
}
fn hex_decode(value: &str) -> Result<Vec<u8>, String> {
    if !value.len().is_multiple_of(2) {
        return Err("hex value must have an even length".into());
    }
    (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&value[i..i + 2], 16).map_err(|_| "invalid hex".to_string()))
        .collect()
}
fn package_type(value: &str) -> Result<PackageType, String> {
    match value {
        "character" => Ok(PackageType::Character),
        "plugin" => Ok(PackageType::Plugin),
        "voice" => Ok(PackageType::Voice),
        "effect-pack" => Ok(PackageType::EffectPack),
        _ => Err(format!("unsupported package type: {value}")),
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        return Err("usage: ocp-package-signer <unsigned.ocp> <signed.ocp>".into());
    }
    let input = fs::read(&args[1])?;
    let mut archive = ZipArchive::new(Cursor::new(&input))?;
    let manifest_bytes = read_zip_member(&mut archive, "manifest.json")?;
    let manifest: InputManifest = serde_json::from_slice(&manifest_bytes)?;
    if manifest.manifest_version != "0.1" {
        return Err("unsupported manifest version".into());
    }
    let key = decode_key(&env::var("OCP_SIGNING_KEY_HEX")?)?;
    let key_id =
        env::var("OCP_SIGNING_KEY_ID").unwrap_or_else(|_| manifest.publisher.key_id.clone());
    let publisher_id =
        env::var("OCP_SIGNING_PUBLISHER_ID").unwrap_or_else(|_| manifest.publisher.id.clone());
    let mut assets = Vec::with_capacity(manifest.assets.len());
    for declared in &manifest.assets {
        let bytes = read_zip_member(&mut archive, &declared.path)?;
        let digest = hex(&Sha256::digest(&bytes));
        if digest != declared.sha256 {
            return Err(format!("asset digest mismatch: {}", declared.path).into());
        }
        assets.push(AssetInput {
            path: declared.path.clone(),
            bytes,
        });
    }
    let request = BuildRequest {
        identity: PackageIdentity {
            id: manifest.id,
            package_type: package_type(&manifest.package_type)?,
            version: manifest.version,
            publisher_id,
            key_id,
            license: manifest.license,
            entry: manifest.entry,
        },
        asset_paths: assets.iter().map(|a| a.path.clone()).collect(),
        assets,
    };
    let signed = build(&request, &key)?;
    if let Some(parent) = Path::new(&args[2]).parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    fs::write(&args[2], signed)?;
    println!("signed package: {}", args[2]);
    Ok(())
}
