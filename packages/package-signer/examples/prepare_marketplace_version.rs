use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    env, fs,
    io::{Cursor, Read, Write},
    path::Path,
};
use zip::{write::SimpleFileOptions, CompressionMethod, ZipArchive, ZipWriter};

fn valid_version(value: &str) -> bool {
    let parts: Vec<&str> = value.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

fn safe_asset_path(value: &str) -> bool {
    value.starts_with("assets/")
        && !value.contains('\\')
        && !value.contains("//")
        && !value
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn required_string<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("missing or invalid {field}"))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 6 {
        return Err("usage: prepare_marketplace_version <source.ocp> <output-unsigned.ocp> <version> <publisher-id> <publisher-key-id>".into());
    }
    let source = Path::new(&args[1]);
    let output = Path::new(&args[2]);
    let version = &args[3];
    let publisher_id = &args[4];
    let publisher_key_id = &args[5];
    if !valid_version(version)
        || publisher_id.is_empty()
        || publisher_id.len() > 128
        || !publisher_key_id.starts_with("ed25519:")
        || publisher_key_id.len() > 256
    {
        return Err("invalid release identity".into());
    }
    if output.exists() {
        return Err("output already exists; release candidates are never overwritten".into());
    }

    let input = fs::read(source)?;
    let mut archive = ZipArchive::new(Cursor::new(input))?;
    let mut manifest_bytes = Vec::new();
    archive
        .by_name("manifest.json")?
        .read_to_end(&mut manifest_bytes)?;
    let mut manifest: Value = serde_json::from_slice(&manifest_bytes)?;
    if required_string(&manifest, "manifestVersion")? != "0.1"
        || required_string(&manifest, "type")? != "character"
    {
        return Err("source package is not a supported character manifest".into());
    }
    let package_id = required_string(&manifest, "id")?.to_owned();
    let entry = required_string(&manifest, "entry")?.to_owned();
    if !safe_asset_path(&entry) {
        return Err("source package entry path is unsafe".into());
    }

    let assets = manifest
        .get("assets")
        .and_then(Value::as_array)
        .ok_or("manifest assets are missing")?;
    if assets.is_empty() || assets.len() > 4096 {
        return Err("manifest asset count is invalid".into());
    }
    let mut paths = Vec::with_capacity(assets.len());
    let mut seen = BTreeSet::new();
    for asset in assets {
        let path = required_string(asset, "path")?.to_owned();
        if !safe_asset_path(&path) || !seen.insert(path.clone()) {
            return Err("manifest contains unsafe or duplicate asset path".into());
        }
        paths.push(path);
    }
    if !seen.contains(&entry) {
        return Err("manifest entry is not declared as an asset".into());
    }

    let mut rebuilt_assets: Vec<(String, Vec<u8>)> = Vec::with_capacity(paths.len());
    for path in &paths {
        let mut bytes = Vec::new();
        archive.by_name(path)?.read_to_end(&mut bytes)?;
        if path == &entry {
            let mut character: Value = serde_json::from_slice(&bytes)?;
            if required_string(&character, "id")? != package_id
                || !required_string(&character, "schema")?.starts_with("character/")
            {
                return Err("character entry identity does not match package".into());
            }
            character["version"] = Value::String(version.clone());
            bytes = serde_json::to_vec_pretty(&character)?;
            bytes.push(b'\n');
        }
        rebuilt_assets.push((path.clone(), bytes));
    }

    manifest["version"] = Value::String(version.clone());
    manifest["publisher"]["id"] = Value::String(publisher_id.clone());
    manifest["publisher"]["keyId"] = Value::String(publisher_key_id.clone());
    if let Some(object) = manifest.as_object_mut() {
        object.remove("signature");
    }
    let manifest_assets = manifest
        .get_mut("assets")
        .and_then(Value::as_array_mut)
        .ok_or("manifest assets are missing")?;
    for (index, (_, bytes)) in rebuilt_assets.iter().enumerate() {
        manifest_assets[index]["sha256"] = Value::String(hex(&Sha256::digest(bytes)));
    }
    let manifest_output = serde_json::to_vec_pretty(&manifest)?;

    if let Some(parent) = output.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)?;
        }
    }
    let mut out = Cursor::new(Vec::new());
    {
        let mut zip = ZipWriter::new(&mut out);
        let opts = SimpleFileOptions::default().compression_method(CompressionMethod::Stored);
        zip.start_file("manifest.json", opts)?;
        zip.write_all(&manifest_output)?;
        for (path, bytes) in &rebuilt_assets {
            zip.start_file(path, opts)?;
            zip.write_all(bytes)?;
        }
        zip.finish()?;
    }
    fs::write(output, out.into_inner())?;
    println!("marketplace release candidate prepared: id={package_id} version={version} assets={} output={}", rebuilt_assets.len(), output.display());
    Ok(())
}
