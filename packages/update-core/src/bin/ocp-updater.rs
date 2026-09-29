use ocp_release_core::{
    decode_verifying_key, fetch_https, fetch_https_with_timeout, parse_manifest, select_update,
    stage_verified_artifact, verify_manifest, MAX_MANIFEST_BYTES,
};
use std::{
    collections::HashMap,
    env, fs,
    path::{Path, PathBuf},
    process::ExitCode,
    time::Duration,
};

const ARTIFACT_FETCH_TIMEOUT_SECONDS: u64 = 60 * 60;

fn options(args: &[String]) -> Result<HashMap<String, String>, String> {
    if args.first().map(String::as_str) != Some("check") {
        return Err("expected command: check".into());
    }
    let mut output = HashMap::new();
    let mut index = 1;
    while index < args.len() {
        let name = args[index].strip_prefix("--").ok_or("expected --option")?;
        let value = args.get(index + 1).ok_or("missing option value")?;
        if output.insert(name.to_owned(), value.clone()).is_some() {
            return Err(format!("duplicate --{name}"));
        }
        index += 2;
    }
    Ok(output)
}

fn required<'a>(values: &'a HashMap<String, String>, name: &str) -> Result<&'a str, String> {
    values
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| format!("missing --{name}"))
}

fn artifact_name(url: &str) -> Result<&str, String> {
    url.rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .ok_or_else(|| "artifact URL has no filename".to_owned())
}

fn status_path(values: &HashMap<String, String>) -> Option<PathBuf> {
    values.get("status-file").map(PathBuf::from)
}

fn write_status(
    path: Option<&Path>,
    state: &str,
    message: &str,
    version: Option<&str>,
    artifact_path: Option<&Path>,
) {
    let Some(path) = path else { return };
    let Some(parent) = path.parent() else { return };
    let _ = fs::create_dir_all(parent);
    let mut status = serde_json::json!({
        "state": state,
        "message": message,
    });
    if let Some(version) = version {
        status["version"] = serde_json::Value::String(version.to_owned());
    }
    if let Some(artifact_path) = artifact_path {
        status["artifactPath"] = serde_json::Value::String(artifact_path.display().to_string());
    }
    let temporary = path.with_extension("json.tmp");
    if let Ok(bytes) = serde_json::to_vec_pretty(&status) {
        if fs::write(&temporary, bytes).is_ok() {
            let _ = fs::rename(temporary, path);
        }
    }
}

fn run() -> Result<(), String> {
    let raw: Vec<String> = env::args().skip(1).collect();
    let values = options(&raw)?;
    let status = status_path(&values);
    write_status(
        status.as_deref(),
        "checking",
        "Checking for signed updates",
        None,
        None,
    );
    let manifest_url = required(&values, "manifest-url")?;
    let manifest_bytes =
        fetch_https(manifest_url, MAX_MANIFEST_BYTES as u64).map_err(|error| error.to_string())?;
    let manifest = parse_manifest(&manifest_bytes).map_err(|error| error.to_string())?;
    let key = decode_verifying_key(required(&values, "public-key-base64")?)
        .map_err(|error| error.to_string())?;
    verify_manifest(&manifest, required(&values, "key-id")?, &key)
        .map_err(|error| error.to_string())?;
    let artifact = match select_update(
        &manifest,
        required(&values, "current-version")?,
        required(&values, "platform")?,
        required(&values, "arch")?,
    ) {
        Ok(artifact) => artifact,
        Err(ocp_release_core::UpdateError::NoUpdate) => {
            write_status(
                status.as_deref(),
                "no_update",
                "No update available; installation was not modified",
                Some(&manifest.version),
                None,
            );
            return Ok(());
        }
        Err(error) => return Err(error.to_string()),
    };
    let bytes = fetch_https_with_timeout(
        &artifact.url,
        artifact.size,
        Duration::from_secs(ARTIFACT_FETCH_TIMEOUT_SECONDS),
    )
    .map_err(|error| error.to_string())?;
    let staged = stage_verified_artifact(
        Path::new(required(&values, "staging-dir")?),
        artifact_name(&artifact.url)?,
        artifact,
        &bytes,
    )
    .map_err(|error| error.to_string())?;
    println!(
        "verified update {} staged at {}",
        manifest.version,
        staged.display()
    );
    println!("installation was not modified (U1 staging-only gate)");
    write_status(
        status.as_deref(),
        "staged",
        &format!(
            "Update {} staged; installation was not modified",
            manifest.version
        ),
        Some(&manifest.version),
        Some(&staged),
    );
    Ok(())
}

fn main() -> ExitCode {
    let raw: Vec<String> = env::args().skip(1).collect();
    let status = options(&raw).ok().and_then(|values| status_path(&values));
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            write_status(
                status.as_deref(),
                "error",
                &format!("Update check failed: {error}"),
                None,
                None,
            );
            eprintln!("ocp-release-check: {error}");
            ExitCode::FAILURE
        }
    }
}
