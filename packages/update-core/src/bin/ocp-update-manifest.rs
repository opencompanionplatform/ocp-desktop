use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ocp_release_core::{
    decode_signing_key, decode_verifying_key, parse_manifest, sign_manifest, verify_artifact,
    verify_manifest, UnsignedUpdateManifest,
};
use std::{env, fs, process::ExitCode};

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("sign") if args.len() == 4 => sign(&args[2], &args[3]),
        Some("verify") if args.len() == 6 => verify(&args[2], &args[3], &args[4], &args[5]),
        _ => Err("usage: ocp-update-manifest sign <unsigned.json> <signed.json> | verify <signed.json> <artifact> <platform> <arch>".into()),
    }
}

fn sign(input: &str, output_path: &str) -> Result<(), String> {
    let encoded = env::var("OCP_UPDATE_SIGNING_KEY_B64")
        .map_err(|_| "OCP_UPDATE_SIGNING_KEY_B64 is not set".to_owned())?;
    let key = decode_signing_key(&encoded).map_err(|error| error.to_string())?;
    let unsigned: UnsignedUpdateManifest =
        serde_json::from_slice(&fs::read(input).map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())?;
    let key_id =
        env::var("OCP_UPDATE_SIGNING_KEY_ID").unwrap_or_else(|_| "ocp-update-dev-1".to_owned());
    let manifest = sign_manifest(unsigned, key_id, &key).map_err(|error| error.to_string())?;
    let output = serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?;
    fs::write(output_path, output).map_err(|error| error.to_string())?;
    println!("signed manifest written to {output_path}");
    println!(
        "publicKeyBase64={}",
        B64.encode(key.verifying_key().to_bytes())
    );
    Ok(())
}

fn verify(
    manifest_path: &str,
    artifact_path: &str,
    platform: &str,
    arch: &str,
) -> Result<(), String> {
    let manifest = parse_manifest(&fs::read(manifest_path).map_err(|error| error.to_string())?)
        .map_err(|error| error.to_string())?;
    if manifest.artifacts.len() != 1 {
        return Err("U1 release workflow requires exactly one artifact per manifest".to_owned());
    }
    let key_id = env::var("OCP_UPDATE_SIGNING_KEY_ID")
        .map_err(|_| "OCP_UPDATE_SIGNING_KEY_ID is not set".to_owned())?;
    let public_key = decode_verifying_key(
        &env::var("OCP_UPDATE_PUBLIC_KEY_B64")
            .map_err(|_| "OCP_UPDATE_PUBLIC_KEY_B64 is not set".to_owned())?,
    )
    .map_err(|error| error.to_string())?;
    verify_manifest(&manifest, &key_id, &public_key).map_err(|error| error.to_string())?;
    let artifact = &manifest.artifacts[0];
    if artifact.platform != platform || artifact.arch != arch {
        return Err(format!(
            "target mismatch: manifest={}/{}, requested={platform}/{arch}",
            artifact.platform, artifact.arch
        ));
    }
    let file_name = std::path::Path::new(artifact_path)
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "artifact path has no UTF-8 filename".to_owned())?;
    let declared_name = artifact
        .url
        .rsplit('/')
        .next()
        .ok_or_else(|| "artifact URL has no filename".to_owned())?;
    if file_name != declared_name {
        return Err(format!(
            "artifact filename mismatch: manifest={declared_name}, file={file_name}"
        ));
    }
    verify_artifact(
        artifact,
        &fs::read(artifact_path).map_err(|error| error.to_string())?,
    )
    .map_err(|error| error.to_string())?;
    println!("signed metadata and artifact verified for {platform}/{arch}");
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("ocp-update-manifest: {error}");
            ExitCode::FAILURE
        }
    }
}
