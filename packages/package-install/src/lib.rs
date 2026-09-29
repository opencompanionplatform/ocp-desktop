//! Offline-capable immutable OCP Runtime Installer.
#![forbid(unsafe_code)]

use ocp_package_loader::{load, LoadError, LoadedPackage, TrustStore};
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct PackageRef {
    pub id: String,
    pub version: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevocationStatus {
    Fresh(BTreeSet<PackageRef>),
    Stale,
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallerWarning {
    RevocationStale,
}
#[derive(Debug)]
pub struct LoadOutcome {
    pub package: LoadedPackage,
    pub warnings: Vec<InstallerWarning>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallOutcome {
    Installed,
    AlreadyInstalled,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallerError {
    Validation(LoadError),
    Revoked,
    DowngradeRejected,
    ImmutableVersionConflict,
    NotInstalled,
    Storage,
}
impl std::fmt::Display for InstallerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for InstallerError {}

pub struct Installer {
    root: PathBuf,
    connection: Connection,
}
impl Installer {
    pub fn open(root: impl AsRef<Path>) -> Result<Self, InstallerError> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join("archives")).map_err(|_| InstallerError::Storage)?;
        let connection =
            Connection::open(root.join("installer.sqlite")).map_err(|_| InstallerError::Storage)?;
        connection.execute_batch("CREATE TABLE IF NOT EXISTS installed (id TEXT NOT NULL, version TEXT NOT NULL, archive_path TEXT NOT NULL, digest TEXT NOT NULL, active INTEGER NOT NULL, PRIMARY KEY(id, version));").map_err(|_| InstallerError::Storage)?;
        Ok(Self { root, connection })
    }
    pub fn install(
        &mut self,
        bytes: &[u8],
        trust: &TrustStore,
        revocation: &RevocationStatus,
    ) -> Result<InstallOutcome, InstallerError> {
        let package = load(bytes, trust).map_err(InstallerError::Validation)?;
        let id = package.manifest.id.clone();
        let version = package.manifest.version.clone();
        self.check_revocation(&id, &version, revocation)?;
        let digest = hex(&Sha256::digest(bytes));
        if let Some((existing, active)) = self
            .connection
            .query_row(
                "SELECT digest, active FROM installed WHERE id=?1 AND version=?2",
                params![id, version],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
            )
            .optional()
            .map_err(|_| InstallerError::Storage)?
        {
            if existing == digest {
                return Ok(InstallOutcome::AlreadyInstalled);
            }
            let _ = active;
            return Err(InstallerError::ImmutableVersionConflict);
        }
        if let Some(current) = self
            .connection
            .query_row(
                "SELECT version FROM installed WHERE id=?1 AND active=1",
                [&id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|_| InstallerError::Storage)?
        {
            if version_cmp(&version, &current).is_lt() {
                return Err(InstallerError::DowngradeRejected);
            }
        }
        let archive = self.archive_path(&id, &version);
        fs::create_dir_all(archive.parent().ok_or(InstallerError::Storage)?)
            .map_err(|_| InstallerError::Storage)?;
        let temporary = archive.with_extension("ocp.tmp");
        fs::write(&temporary, bytes).map_err(|_| InstallerError::Storage)?;
        fs::rename(&temporary, &archive).map_err(|_| InstallerError::Storage)?;
        let persisted = fs::read(&archive).map_err(|_| InstallerError::Storage)?;
        if load(&persisted, trust).is_err() {
            let _ = fs::remove_file(&archive);
            return Err(InstallerError::Validation(LoadError::InvalidArchive));
        }
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| InstallerError::Storage)?;
        transaction
            .execute("UPDATE installed SET active=0 WHERE id=?1", [&id])
            .map_err(|_| InstallerError::Storage)?;
        transaction.execute("INSERT INTO installed (id,version,archive_path,digest,active) VALUES (?1,?2,?3,?4,1)", params![id, version, archive.to_string_lossy(), digest]).map_err(|_| InstallerError::Storage)?;
        transaction.commit().map_err(|_| InstallerError::Storage)?;
        Ok(InstallOutcome::Installed)
    }
    pub fn load(
        &self,
        id: &str,
        trust: &TrustStore,
        revocation: &RevocationStatus,
    ) -> Result<LoadOutcome, InstallerError> {
        let (version, path): (String, String) = self
            .connection
            .query_row(
                "SELECT version,archive_path FROM installed WHERE id=?1 AND active=1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|_| InstallerError::Storage)?
            .ok_or(InstallerError::NotInstalled)?;
        self.check_revocation(id, &version, revocation)?;
        let bytes = fs::read(path).map_err(|_| InstallerError::Storage)?;
        let package = load(&bytes, trust).map_err(InstallerError::Validation)?;
        Ok(LoadOutcome {
            package,
            warnings: warning(revocation),
        })
    }
    pub fn rollback(
        &mut self,
        id: &str,
        version: &str,
        trust: &TrustStore,
        revocation: &RevocationStatus,
    ) -> Result<LoadOutcome, InstallerError> {
        let path: String = self
            .connection
            .query_row(
                "SELECT archive_path FROM installed WHERE id=?1 AND version=?2",
                params![id, version],
                |row| row.get(0),
            )
            .optional()
            .map_err(|_| InstallerError::Storage)?
            .ok_or(InstallerError::NotInstalled)?;
        self.check_revocation(id, version, revocation)?;
        let bytes = fs::read(path).map_err(|_| InstallerError::Storage)?;
        let package = load(&bytes, trust).map_err(InstallerError::Validation)?;
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| InstallerError::Storage)?;
        transaction
            .execute("UPDATE installed SET active=0 WHERE id=?1", [id])
            .map_err(|_| InstallerError::Storage)?;
        transaction
            .execute(
                "UPDATE installed SET active=1 WHERE id=?1 AND version=?2",
                params![id, version],
            )
            .map_err(|_| InstallerError::Storage)?;
        transaction.commit().map_err(|_| InstallerError::Storage)?;
        Ok(LoadOutcome {
            package,
            warnings: warning(revocation),
        })
    }
    pub fn uninstall(&mut self, id: &str) -> Result<(), InstallerError> {
        self.connection
            .execute("DELETE FROM installed WHERE id=?1", [id])
            .map_err(|_| InstallerError::Storage)?;
        let directory = self.root.join("archives").join(id);
        if directory.exists() {
            fs::remove_dir_all(directory).map_err(|_| InstallerError::Storage)?;
        }
        Ok(())
    }
    fn archive_path(&self, id: &str, version: &str) -> PathBuf {
        self.root
            .join("archives")
            .join(id)
            .join(format!("{version}.ocp"))
    }
    fn check_revocation(
        &self,
        id: &str,
        version: &str,
        status: &RevocationStatus,
    ) -> Result<(), InstallerError> {
        if let RevocationStatus::Fresh(items) = status {
            if items.contains(&PackageRef {
                id: id.into(),
                version: version.into(),
            }) {
                return Err(InstallerError::Revoked);
            }
        }
        Ok(())
    }
}
fn warning(status: &RevocationStatus) -> Vec<InstallerWarning> {
    if matches!(status, RevocationStatus::Fresh(_)) {
        vec![]
    } else {
        vec![InstallerWarning::RevocationStale]
    }
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn version_cmp(left: &str, right: &str) -> std::cmp::Ordering {
    fn parse(value: &str) -> (Vec<u64>, bool, String) {
        let (core, pre) = value.split_once('-').unwrap_or((value, ""));
        let parts = core
            .split('.')
            .map(|part| part.parse().unwrap_or(0))
            .collect();
        (parts, pre.is_empty(), pre.to_owned())
    }
    let (a, a_release, a_pre) = parse(left);
    let (b, b_release, b_pre) = parse(right);
    a.cmp(&b)
        .then(a_release.cmp(&b_release))
        .then(a_pre.cmp(&b_pre))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;
    use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};
    fn key() -> SigningKey {
        SigningKey::from_bytes(&[4; 32])
    }
    fn trust(key: &SigningKey) -> TrustStore {
        let mut trust = TrustStore::new();
        trust.add_key("ed25519:test-1", key.verifying_key());
        trust
    }
    fn archive(kind: PackageType, version: &str) -> Vec<u8> {
        build(
            &BuildRequest {
                identity: PackageIdentity {
                    id: "example.package".into(),
                    package_type: kind,
                    version: version.into(),
                    publisher_id: "example.publisher".into(),
                    key_id: "ed25519:test-1".into(),
                    license: "Apache-2.0".into(),
                    entry: "assets/main.json".into(),
                },
                asset_paths: vec!["assets/main.json".into()],
                assets: vec![AssetInput {
                    path: "assets/main.json".into(),
                    bytes: b"{}".to_vec(),
                }],
            },
            &key(),
        )
        .unwrap()
    }
    fn installer() -> Installer {
        Installer::open(tempfile::tempdir().unwrap().keep()).unwrap()
    }
    #[test]
    fn cs_inst_all_types_install_and_load() {
        let key = key();
        let trust = trust(&key);
        for kind in [
            PackageType::Character,
            PackageType::Plugin,
            PackageType::Voice,
            PackageType::EffectPack,
        ] {
            let mut i = installer();
            i.install(
                &archive(kind, "1.0.0"),
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new()),
            )
            .unwrap();
            assert_eq!(
                i.load(
                    "example.package",
                    &trust,
                    &RevocationStatus::Fresh(BTreeSet::new())
                )
                .unwrap()
                .package
                .manifest
                .version,
                "1.0.0"
            );
        }
    }
    #[test]
    fn cs_inst_tamper_downgrade_and_rollback() {
        let key = key();
        let trust = trust(&key);
        let mut i = installer();
        i.install(
            &archive(PackageType::Character, "1.0.0"),
            &trust,
            &RevocationStatus::Fresh(BTreeSet::new()),
        )
        .unwrap();
        i.install(
            &archive(PackageType::Character, "2.0.0"),
            &trust,
            &RevocationStatus::Fresh(BTreeSet::new()),
        )
        .unwrap();
        assert!(matches!(
            i.install(
                &archive(PackageType::Character, "1.5.0"),
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new())
            ),
            Err(InstallerError::DowngradeRejected)
        ));
        assert_eq!(
            i.rollback(
                "example.package",
                "1.0.0",
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new())
            )
            .unwrap()
            .package
            .manifest
            .version,
            "1.0.0"
        );
    }
    #[test]
    fn cs_inst_revocation_and_stale_warning() {
        let key = key();
        let trust = trust(&key);
        let mut i = installer();
        i.install(
            &archive(PackageType::Voice, "1.0.0"),
            &trust,
            &RevocationStatus::Fresh(BTreeSet::new()),
        )
        .unwrap();
        assert_eq!(
            i.load("example.package", &trust, &RevocationStatus::Unavailable)
                .unwrap()
                .warnings,
            vec![InstallerWarning::RevocationStale]
        );
        let mut revoked = BTreeSet::new();
        revoked.insert(PackageRef {
            id: "example.package".into(),
            version: "1.0.0".into(),
        });
        assert!(matches!(
            i.load("example.package", &trust, &RevocationStatus::Fresh(revoked)),
            Err(InstallerError::Revoked)
        ));
    }
    #[test]
    fn cs_inst_tampered_archive_is_rejected_at_load() {
        let key = key();
        let trust = trust(&key);
        let mut installer = installer();
        installer
            .install(
                &archive(PackageType::Character, "1.0.0"),
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new()),
            )
            .unwrap();
        std::fs::write(
            installer.archive_path("example.package", "1.0.0"),
            b"tampered",
        )
        .unwrap();
        assert!(matches!(
            installer.load(
                "example.package",
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new())
            ),
            Err(InstallerError::Validation(_))
        ));
    }

    #[test]
    fn cs_inst_uninstall_removes_local_install_state() {
        let key = key();
        let trust = trust(&key);
        let mut installer = installer();
        installer
            .install(
                &archive(PackageType::Plugin, "1.0.0"),
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new()),
            )
            .unwrap();
        installer.uninstall("example.package").unwrap();
        assert!(matches!(
            installer.load(
                "example.package",
                &trust,
                &RevocationStatus::Fresh(BTreeSet::new())
            ),
            Err(InstallerError::NotInstalled)
        ));
    }
}
