//! Runtime-owned immutable Store archive and verified filesystem projection.
#![forbid(unsafe_code)]

#[cfg(all(feature = "local-beta-trust", feature = "staging-marketplace-trust"))]
compile_error!("local-beta-trust and staging-marketplace-trust are mutually exclusive");
use ocp_local_packages::{Installer, RevocationStatus};
use ocp_package_loader::{load, LoadedPackage, PackageType, TrustStore};
use rusqlite::OptionalExtension;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Cursor, Read},
    path::Path,
    time::Instant,
};

pub struct Installed {
    pub id: String,
    pub version: String,
    pub package_type: &'static str,
    pub already_installed: bool,
}

pub struct TrustEvidence {
    pub mode: &'static str,
    pub sequence: u64,
    pub publisher_count: usize,
    pub revocation_stale: bool,
}

fn storage(error: impl std::fmt::Display) -> String {
    format!("Verified package storage: {error}")
}

#[cfg(not(feature = "local-beta-trust"))]
fn marketplace_bundle_path(root: &Path) -> std::path::PathBuf {
    root.join(".cloud-verified/trust/marketplace-bundle.json")
}

#[cfg(not(feature = "local-beta-trust"))]
fn persist_marketplace_bundle(root: &Path, bundle_json: &str) -> Result<(), String> {
    let path = marketplace_bundle_path(root);
    fs::create_dir_all(path.parent().ok_or("Invalid trust bundle path")?).map_err(storage)?;
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, bundle_json.as_bytes()).map_err(storage)?;
    if path.exists() {
        fs::remove_file(&path).map_err(storage)?;
    }
    fs::rename(&temporary, &path).map_err(storage)?;
    Ok(())
}

#[cfg(not(feature = "local-beta-trust"))]
fn cached_marketplace_bundle(root: &Path) -> Result<String, String> {
    fs::read_to_string(marketplace_bundle_path(root))
        .map_err(|_| "Marketplace trust bundle is not cached for this installation".to_owned())
}

fn persist_revocation_sequence(root: &Path, root_id: &str, sequence: u64) -> Result<(), String> {
    fs::create_dir_all(root.join(".cloud-verified")).map_err(storage)?;
    let db =
        rusqlite::Connection::open(root.join(".cloud-verified/trust.sqlite")).map_err(storage)?;
    db.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(storage)?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS revocation_sequence (root TEXT PRIMARY KEY, sequence INTEGER NOT NULL)")
        .map_err(storage)?;
    let sequence = i64::try_from(sequence).map_err(storage)?;
    let changed = db
        .execute(
            "INSERT INTO revocation_sequence(root,sequence) VALUES (?1,?2) ON CONFLICT(root) DO UPDATE SET sequence=excluded.sequence WHERE revocation_sequence.sequence<=excluded.sequence",
            rusqlite::params![root_id, sequence],
        )
        .map_err(storage)?;
    if changed != 1 {
        return Err("revocation-sequence-rollback".into());
    }
    Ok(())
}

fn trust(
    root: &Path,
    marketplace_bundle_json: &str,
) -> Result<(TrustStore, TrustEvidence), String> {
    #[cfg(feature = "local-beta-trust")]
    {
        let _ = marketplace_bundle_json;
        let verified = ocp_package_loader::beta_trust::verify(
            include_str!("../trust/local-beta-bundle.json"),
            include_str!("../trust/local-beta-root.json"),
            chrono::Utc::now().timestamp(),
        )
        .map_err(str::to_owned)?;
        let pin: serde_json::Value =
            serde_json::from_str(include_str!("../trust/local-beta-root.json")).map_err(storage)?;
        let root_id = pin["keyId"].as_str().ok_or("invalid-root-pin")?;
        persist_revocation_sequence(root, root_id, verified.sequence)?;
        Ok((
            verified.store,
            TrustEvidence {
                mode: "local-beta",
                sequence: verified.sequence,
                publisher_count: 1,
                revocation_stale: verified.revocation_stale,
            },
        ))
    }
    #[cfg(all(
        not(feature = "local-beta-trust"),
        feature = "staging-marketplace-trust"
    ))]
    {
        if marketplace_bundle_json.trim().is_empty() {
            return Err("Marketplace staging trust bundle is missing".into());
        }
        let pinned_root = option_env!("OCP_MARKETPLACE_STAGING_TRUST_ROOT_JSON")
            .ok_or("Marketplace staging trust root is not configured in this Runtime build")?;
        let verified = ocp_package_loader::marketplace_trust::verify_staging(
            marketplace_bundle_json,
            pinned_root,
            chrono::Utc::now().timestamp(),
        )
        .map_err(str::to_owned)?;
        persist_revocation_sequence(root, &verified.root_key_id, verified.sequence)?;
        persist_marketplace_bundle(root, marketplace_bundle_json)?;
        Ok((
            verified.store,
            TrustEvidence {
                mode: "marketplace-staging",
                sequence: verified.sequence,
                publisher_count: verified.publisher_count,
                revocation_stale: false,
            },
        ))
    }
    #[cfg(not(any(feature = "local-beta-trust", feature = "staging-marketplace-trust")))]
    {
        if marketplace_bundle_json.trim().is_empty() {
            return Err("Marketplace trust bundle is missing".into());
        }
        let pinned_root = option_env!("OCP_MARKETPLACE_TRUST_ROOT_JSON")
            .ok_or("Marketplace trust root is not configured in this Runtime build")?;
        let verified = ocp_package_loader::marketplace_trust::verify(
            marketplace_bundle_json,
            pinned_root,
            chrono::Utc::now().timestamp(),
        )
        .map_err(str::to_owned)?;
        persist_revocation_sequence(root, &verified.root_key_id, verified.sequence)?;
        persist_marketplace_bundle(root, marketplace_bundle_json)?;
        Ok((
            verified.store,
            TrustEvidence {
                mode: "marketplace-release",
                sequence: verified.sequence,
                publisher_count: verified.publisher_count,
                revocation_stale: false,
            },
        ))
    }
}

pub fn install(
    source: &Path,
    root: &Path,
    sha: &str,
    key: &str,
    signature: &str,
    marketplace_bundle_json: &str,
) -> Result<(Installed, TrustEvidence), String> {
    let bytes = fs::read(source).map_err(storage)?;
    if sha.len() != 64 || format!("{:x}", Sha256::digest(&bytes)) != sha.to_ascii_lowercase() {
        return Err("Cloud package SHA-256 mismatch".into());
    }
    let (trust, evidence) = trust(root, marketplace_bundle_json)?;
    let package = load(&bytes, &trust).map_err(|e| format!("Package verification: {e}"))?;
    if package.manifest.signature.key_id != key || package.manifest.signature.value != signature {
        return Err("Cloud signature metadata mismatch".into());
    }
    Ok((install_bytes(&bytes, root, &trust)?, evidence))
}

fn archive_path(root: &Path, id: &str, version: &str) -> std::path::PathBuf {
    root.join(".cloud-verified/archives")
        .join(id)
        .join(format!("{version}.ocp"))
}

pub(super) fn member(package: &LoadedPackage, name: &str) -> Result<Vec<u8>, String> {
    let mut zip = zip::ZipArchive::new(Cursor::new(&package.archive_bytes)).map_err(storage)?;
    let mut data = Vec::new();
    zip.by_name(name)
        .map_err(storage)?
        .read_to_end(&mut data)
        .map_err(storage)?;
    Ok(data)
}

fn install_bytes(bytes: &[u8], root: &Path, trust: &TrustStore) -> Result<Installed, String> {
    let package = load(bytes, trust).map_err(|e| format!("Package verification: {e}"))?;
    let entry = member(&package, &package.manifest.entry)?;
    let declared: Vec<&str> = package
        .manifest
        .assets
        .iter()
        .map(|a| a.path.as_str())
        .collect();
    let package_type = match package.manifest.package_type {
        PackageType::Character => {
            let resolved =
                ocp_character_package::parse_and_resolve(&entry, &declared).map_err(storage)?;
            if resolved
                .id
                .as_ref()
                .is_some_and(|id| id != &package.manifest.id)
                || resolved
                    .version
                    .as_ref()
                    .is_some_and(|version| version != &package.manifest.version)
            {
                return Err("Character entry identity does not match the signed manifest".into());
            }
            "character"
        }
        PackageType::EffectPack => {
            ocp_effect_package::parse_and_validate(
                &entry,
                &package.manifest.id,
                &package.manifest.version,
                &declared,
            )
            .map_err(storage)?;
            "effect-pack"
        }
        _ => return Err("Package type is not installable by the desktop marketplace".into()),
    };
    let id = &package.manifest.id;
    let version = &package.manifest.version;
    let target = root.join(id).join(version);
    let archive = archive_path(root, id, version);
    let already_installed = target.exists();
    if already_installed {
        // Never replace an unsigned local POC or silently heal a corrupt version.
        if !archive.is_file() {
            return Err(
                "Existing version has no verified Store archive; preserve it before installing"
                    .into(),
            );
        }
        verify_projection(&target, &package)?;
    }
    if archive.exists() && fs::read(&archive).map_err(storage)? != bytes {
        return Err("Immutable Store archive mismatch".into());
    }
    let mut installer = Installer::open(root.join(".cloud-verified")).map_err(storage)?;
    let db = rusqlite::Connection::open(root.join(".cloud-verified/installer.sqlite"))
        .map_err(storage)?;
    let active: Option<String> = db
        .query_row(
            "SELECT version FROM installed WHERE id=?1 AND active=1",
            [id],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage)?;
    if let Some(active) = active {
        if semver::Version::parse(version).map_err(storage)?
            < semver::Version::parse(&active).map_err(storage)?
        {
            return Err("DowngradeRejected: use explicit rollback".into());
        }
    }
    installer
        .install(bytes, trust, &RevocationStatus::Fresh(Default::default()))
        .map_err(storage)?;
    // AlreadyInstalled in the shared installer does not validate the stored file.
    if fs::read(&archive).map_err(storage)? != bytes {
        return Err("Stored archive mismatch".into());
    }
    if !already_installed {
        let staging = root.join(format!(".staging-{id}-{version}"));
        fs::create_dir(&staging).map_err(storage)?;
        for relative in std::iter::once("manifest.json").chain(declared.iter().copied()) {
            let output = staging.join(relative);
            fs::create_dir_all(output.parent().ok_or("Invalid destination")?).map_err(storage)?;
            fs::write(output, member(&package, relative)?).map_err(storage)?;
        }
        verify_projection(&staging, &package)?;
        fs::create_dir_all(target.parent().ok_or("Invalid destination")?).map_err(storage)?;
        fs::rename(&staging, &target).map_err(storage)?;
    }
    verify_projection(&target, &package)?;
    Ok(Installed {
        id: id.clone(),
        version: version.clone(),
        package_type,
        already_installed,
    })
}

fn verify_projection(target: &Path, package: &LoadedPackage) -> Result<(), String> {
    let canonical = fs::canonicalize(target).map_err(storage)?;
    // Parse the immutable archive once for the whole projection check. The old
    // implementation rebuilt ZipArchive for every member, which made a
    // 60+ asset managed character spend seconds repeatedly reparsing the same
    // central directory during startup. Security semantics stay identical:
    // every projected byte is still compared with its signed archive member.
    let mut zip = zip::ZipArchive::new(Cursor::new(&package.archive_bytes)).map_err(storage)?;
    for relative in std::iter::once("manifest.json")
        .chain(package.manifest.assets.iter().map(|a| a.path.as_str()))
    {
        let file = target.join(relative);
        if !fs::canonicalize(&file)
            .map_err(storage)?
            .starts_with(&canonical)
        {
            return Err("Installed asset escapes package directory".into());
        }
        let installed = fs::read(file).map_err(storage)?;
        let mut archived = Vec::new();
        zip.by_name(relative)
            .map_err(storage)?
            .read_to_end(&mut archived)
            .map_err(storage)?;
        if installed != archived {
            return Err(format!("Installed file verification failed: {relative}"));
        }
    }
    Ok(())
}

fn installer_tracks_version(root: &Path, id: &str, version: &str) -> Result<bool, String> {
    let db_path = root.join(".cloud-verified/installer.sqlite");
    if !db_path.is_file() {
        return Ok(false);
    }
    let db =
        rusqlite::Connection::open_with_flags(db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(storage)?;
    let tracked: Option<i64> = db
        .query_row(
            "SELECT 1 FROM installed WHERE id=?1 AND version=?2 LIMIT 1",
            rusqlite::params![id, version],
            |row| row.get(0),
        )
        .optional()
        .map_err(storage)?;
    Ok(tracked.is_some())
}

/// Local/manual packages may be signed by Studio, but a signature alone does
/// not make them Store-managed. Cloud management is established only by the
/// immutable Store archive or the installer database. Once an installer row
/// exists, a missing/tampered archive still fails closed below.
pub fn verify_installed(target: &Path) -> Result<Option<LoadedPackage>, String> {
    let verify_started = Instant::now();
    let version = target
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("Invalid package version")?;
    let parent = target.parent().ok_or("Invalid package directory")?;
    let id = parent
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("Invalid package id")?;
    let root = parent.parent().ok_or("Invalid repository")?;
    // Classification must not parse local projection files. Local/manual
    // packages can use different JSON encodings and are validated by their
    // package-specific service. Store-managed identity comes only from
    // immutable installer evidence.
    let exact_archive = archive_path(root, id, version);
    let managed = id == "character.sabai-sompoo"
        || exact_archive.is_file()
        || installer_tracks_version(root, id, version)?;
    if !managed {
        return Ok(None);
    }
    #[cfg(feature = "local-beta-trust")]
    let marketplace_bundle = String::new();
    #[cfg(not(feature = "local-beta-trust"))]
    let marketplace_bundle = cached_marketplace_bundle(root)?;
    let trust_started = Instant::now();
    let (trust, _) = trust(root, &marketplace_bundle)?;
    let trust_ms = trust_started.elapsed().as_millis();
    let archive_started = Instant::now();
    let bytes = fs::read(archive_path(root, id, version)).map_err(storage)?;
    let db = rusqlite::Connection::open_with_flags(
        root.join(".cloud-verified/installer.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(storage)?;
    let expected: String = db
        .query_row(
            "SELECT digest FROM installed WHERE id=?1 AND version=?2",
            rusqlite::params![id, version],
            |row| row.get(0),
        )
        .map_err(storage)?;
    if format!("{:x}", Sha256::digest(&bytes)) != expected {
        return Err("Immutable installed archive digest mismatch".into());
    }
    let archive_ms = archive_started.elapsed().as_millis();
    let package_started = Instant::now();
    let package = load(&bytes, &trust).map_err(|e| format!("Package verification: {e}"))?;
    let package_ms = package_started.elapsed().as_millis();
    if package.manifest.id != id || package.manifest.version != version {
        return Err("Installed identity mismatch".into());
    }
    let projection_started = Instant::now();
    verify_projection(target, &package)?;
    let projection_ms = projection_started.elapsed().as_millis();
    println!(
        "[PackageVerifyTiming] package={id}@{version} trust_ms={trust_ms} archive_ms={archive_ms} package_ms={package_ms} projection_ms={projection_ms} total_ms={}",
        verify_started.elapsed().as_millis()
    );
    Ok(Some(package))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ocp_package_loader::load;

    fn local_bible_fixture() -> Option<Vec<u8>> {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../poc-assets/bible/bible.ocp");
        fs::read(path).ok()
    }

    #[test]
    fn signed_local_package_is_not_misclassified_as_store_managed() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("effect.local-signed").join("1.0.0");
        fs::create_dir_all(&target).unwrap();
        fs::write(
            target.join("manifest.json"),
            br#"{"manifestVersion":"0.1","id":"effect.local-signed","type":"effect-pack","version":"1.0.0","entry":"assets/effect.json","signature":{"algorithm":"ed25519","keyId":"ed25519:test","digest":"sha256:test","value":"base64:test"}}"#,
        )
        .unwrap();
        assert!(verify_installed(&target).unwrap().is_none());
    }

    #[test]
    fn stale_archive_parent_directory_does_not_make_local_package_managed() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("effect.local").join("1.0.0");
        fs::create_dir_all(&target).unwrap();
        fs::write(
            target.join("manifest.json"),
            br#"{"manifestVersion":"0.1","id":"effect.local","type":"effect-pack","version":"1.0.0","entry":"assets/effect.json"}"#,
        )
        .unwrap();
        fs::create_dir_all(
            temp.path()
                .join(".cloud-verified/archives")
                .join("effect.local"),
        )
        .unwrap();
        assert!(verify_installed(&target).unwrap().is_none());
    }

    #[test]
    fn installer_database_marker_keeps_missing_archive_fail_closed() {
        let temp = tempfile::tempdir().unwrap();
        let target = temp.path().join("effect.managed").join("1.0.0");
        fs::create_dir_all(&target).unwrap();
        fs::write(
            target.join("manifest.json"),
            br#"{"manifestVersion":"0.1","id":"effect.managed","type":"effect-pack","version":"1.0.0","entry":"assets/effect.json"}"#,
        )
        .unwrap();
        fs::create_dir_all(temp.path().join(".cloud-verified")).unwrap();
        let db = rusqlite::Connection::open(temp.path().join(".cloud-verified/installer.sqlite"))
            .unwrap();
        db.execute_batch(
            "CREATE TABLE installed (id TEXT NOT NULL, version TEXT NOT NULL, digest TEXT NOT NULL);
             INSERT INTO installed(id,version,digest) VALUES ('effect.managed','1.0.0','deadbeef');",
        )
        .unwrap();
        assert!(verify_installed(&target).is_err());
    }
    #[test]
    #[ignore = "requires the owner's downloaded public Store artifact"]
    fn supplied_store_archive_install_load_and_repeat() {
        let path = std::env::var("OCP_TEST_SIGNED_ARCHIVE").unwrap();
        let bytes = fs::read(&path).unwrap();
        let mut zip = zip::ZipArchive::new(Cursor::new(&bytes)).unwrap();
        let mut raw = Vec::new();
        zip.by_name("manifest.json")
            .unwrap()
            .read_to_end(&mut raw)
            .unwrap();
        let manifest: serde_json::Value = serde_json::from_slice(&raw).unwrap();
        let sha = format!("{:x}", Sha256::digest(&bytes));
        let key = manifest["signature"]["keyId"].as_str().unwrap();
        let sig = manifest["signature"]["value"].as_str().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let marketplace_bundle = std::env::var("OCP_TEST_MARKETPLACE_BUNDLE")
            .ok()
            .and_then(|path| fs::read_to_string(path).ok())
            .unwrap_or_default();
        let result = install(
            Path::new(&path),
            temp.path(),
            &sha,
            key,
            sig,
            &marketplace_bundle,
        );
        #[cfg(all(
            not(feature = "local-beta-trust"),
            feature = "staging-marketplace-trust"
        ))]
        {
            if marketplace_bundle.is_empty() {
                assert!(
                    result.is_err(),
                    "staging trust requires an explicit marketplace bundle"
                );
                return;
            }
            let (first, evidence) = result.unwrap_or_else(|error| {
                panic!("staging marketplace package verification failed: {error}")
            });
            assert!(!first.already_installed);
            assert_eq!(evidence.mode, "marketplace-staging");
            assert!(evidence.publisher_count >= 1);
        }
        #[cfg(not(any(feature = "local-beta-trust", feature = "staging-marketplace-trust")))]
        {
            if marketplace_bundle.is_empty() {
                assert!(
                    result.is_err(),
                    "release trust requires an explicit marketplace bundle"
                );
                return;
            }
            let (first, evidence) = result
                .unwrap_or_else(|error| panic!("marketplace package verification failed: {error}"));
            assert!(!first.already_installed);
            assert_eq!(evidence.mode, "marketplace-release");
            assert!(evidence.publisher_count >= 1);
        }
        #[cfg(feature = "local-beta-trust")]
        {
            let (first, evidence) = result.unwrap();
            assert!(!first.already_installed);
            assert!(!evidence.revocation_stale);
            assert_eq!(evidence.mode, "local-beta");
            let target = temp.path().join(&first.id).join(&first.version);
            assert!(verify_installed(&target).unwrap().is_some());
            assert!(
                install(Path::new(&path), temp.path(), &sha, key, sig, "")
                    .unwrap()
                    .0
                    .already_installed
            );
            fs::write(target.join("manifest.json"), b"{}").unwrap();
            assert!(verify_installed(&target).is_err());
            assert!(install(Path::new(&path), temp.path(), &sha, key, sig, "").is_err());
            let db = rusqlite::Connection::open(temp.path().join(".cloud-verified/trust.sqlite"))
                .unwrap();
            db.execute("UPDATE revocation_sequence SET sequence=2", [])
                .unwrap();
            assert!(
                trust(temp.path(), "").is_err(),
                "reject older signed revocations"
            );
        }
    }
    #[test]
    fn repeat_install_is_idempotent_and_tampering_rejected() {
        let Some(bible) = local_bible_fixture() else {
            eprintln!(
                "skipping local Bible fixture test: poc-assets are intentionally not tracked"
            );
            return;
        };
        let tmp = tempfile::tempdir().unwrap();
        let trust = crate::poc_character_trust_store().unwrap();
        let package = load(&bible, &trust).unwrap();
        let target = tmp
            .path()
            .join(&package.manifest.id)
            .join(&package.manifest.version);
        assert!(
            !install_bytes(&bible, tmp.path(), &trust)
                .unwrap()
                .already_installed
        );
        assert!(
            install_bytes(&bible, tmp.path(), &trust)
                .unwrap()
                .already_installed
        );
        verify_projection(&target, &package).unwrap();
        fs::write(target.join(&package.manifest.entry), b"tampered").unwrap();
        assert!(verify_projection(&target, &package).is_err());
        assert!(install_bytes(&bible, tmp.path(), &trust).is_err());
    }
    #[test]
    fn existing_local_directory_is_never_overwritten() {
        let Some(bible) = local_bible_fixture() else {
            eprintln!(
                "skipping local Bible fixture test: poc-assets are intentionally not tracked"
            );
            return;
        };
        let tmp = tempfile::tempdir().unwrap();
        let trust = crate::poc_character_trust_store().unwrap();
        let package = load(&bible, &trust).unwrap();
        let target = tmp
            .path()
            .join(&package.manifest.id)
            .join(&package.manifest.version);
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("manifest.json"), b"local-poc").unwrap();
        assert!(install_bytes(&bible, tmp.path(), &trust).is_err());
        assert_eq!(
            fs::read(target.join("manifest.json")).unwrap(),
            b"local-poc"
        );
    }
}
