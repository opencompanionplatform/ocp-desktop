use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::{Cursor, Read},
};
use zip::ZipArchive;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn string<'a>(value: &'a Value, field: &str) -> Result<&'a str, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("missing {field}"))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 5 {
        return Err("usage: check_release_candidate <candidate.ocp> <version> <publisher-id> <publisher-key-id>".into());
    }
    let version = &args[2];
    let publisher_id = &args[3];
    let publisher_key_id = &args[4];
    let bytes = fs::read(&args[1])?;
    let mut zip = ZipArchive::new(Cursor::new(bytes))?;
    let mut manifest_bytes = Vec::new();
    zip.by_name("manifest.json")?
        .read_to_end(&mut manifest_bytes)?;
    let manifest: Value = serde_json::from_slice(&manifest_bytes)?;
    if string(&manifest, "manifestVersion")? != "0.1"
        || string(&manifest, "version")? != version
        || string(&manifest, "type")? != "character"
        || manifest.get("signature").is_some()
    {
        return Err("candidate manifest identity is invalid".into());
    }
    let package_id = string(&manifest, "id")?.to_owned();
    let entry = string(&manifest, "entry")?.to_owned();
    let publisher = manifest.get("publisher").ok_or("publisher missing")?;
    if string(publisher, "id")? != publisher_id || string(publisher, "keyId")? != publisher_key_id {
        return Err("candidate publisher binding is invalid".into());
    }
    let assets = manifest
        .get("assets")
        .and_then(Value::as_array)
        .ok_or("assets missing")?;
    let mut entry_seen = false;
    for asset in assets {
        let path = string(asset, "path")?;
        let expected = string(asset, "sha256")?;
        let mut data = Vec::new();
        zip.by_name(path)?.read_to_end(&mut data)?;
        if hex(&Sha256::digest(&data)) != expected {
            return Err(format!("asset digest mismatch: {path}").into());
        }
        if path == entry {
            entry_seen = true;
            let character: Value = serde_json::from_slice(&data)?;
            if string(&character, "id")? != package_id || string(&character, "version")? != version
            {
                return Err("character entry identity/version mismatch".into());
            }
        }
    }
    if !entry_seen {
        return Err("entry asset is missing".into());
    }
    println!("release candidate verified: id={package_id} version={version} publisher={publisher_id} assets={}", assets.len());
    Ok(())
}
