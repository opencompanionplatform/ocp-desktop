//! SQLite-backed immutable Local Registry for OCP packages.
#![forbid(unsafe_code)]

use ocp_package_loader::{load, LoadError, PackageType, TrustStore};
use rusqlite::{params, Connection, OptionalExtension};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageMetadata {
    pub id: String,
    pub package_type: String,
    pub version: String,
    pub digest: String,
    pub signature_key_id: String,
    pub manifest: serde_json::Value,
    pub published_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegistryError {
    Validation(LoadError),
    DuplicateVersion,
    PackageNotFound,
    VersionNotFound,
    Storage,
}
impl std::fmt::Display for RegistryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for RegistryError {}

/// Storage boundary used by future Registry API adapters. It never exposes a filesystem layout.
pub trait RegistryStorage {
    fn publish(
        &mut self,
        archive: &[u8],
        trust: &TrustStore,
    ) -> Result<PackageMetadata, RegistryError>;
    fn list(&self) -> Result<Vec<PackageMetadata>, RegistryError>;
    fn metadata(&self, id: &str, version: &str) -> Result<PackageMetadata, RegistryError>;
    fn download(&self, id: &str, version: &str) -> Result<Vec<u8>, RegistryError>;
    fn rollback(&mut self, id: &str, version: &str) -> Result<(), RegistryError>;
    fn recommended_version(&self, id: &str) -> Result<String, RegistryError>;
}

pub struct SqliteRegistry {
    connection: Connection,
}
impl SqliteRegistry {
    pub fn open_in_memory() -> Result<Self, RegistryError> {
        Self::open(":memory:")
    }
    pub fn open(path: &str) -> Result<Self, RegistryError> {
        let connection = Connection::open(path).map_err(|_| RegistryError::Storage)?;
        connection.execute_batch("PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS packages (id TEXT NOT NULL, version TEXT NOT NULL, package_type TEXT NOT NULL, digest TEXT NOT NULL, signature_key_id TEXT NOT NULL, manifest TEXT NOT NULL, published_at TEXT NOT NULL, archive BLOB NOT NULL, PRIMARY KEY (id, version));
            CREATE TABLE IF NOT EXISTS recommendations (id TEXT PRIMARY KEY, version TEXT NOT NULL, FOREIGN KEY (id, version) REFERENCES packages(id, version));")
            .map_err(|_| RegistryError::Storage)?;
        Ok(Self { connection })
    }
}
fn type_name(package_type: &PackageType) -> &'static str {
    match package_type {
        PackageType::Character => "character",
        PackageType::Plugin => "plugin",
        PackageType::Voice => "voice",
        PackageType::EffectPack => "effect-pack",
    }
}
fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<PackageMetadata> {
    Ok(PackageMetadata {
        id: row.get(0)?,
        package_type: row.get(1)?,
        version: row.get(2)?,
        digest: row.get(3)?,
        signature_key_id: row.get(4)?,
        manifest: serde_json::from_str(&row.get::<_, String>(5)?)
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
        published_at: row.get(6)?,
    })
}
impl RegistryStorage for SqliteRegistry {
    fn publish(
        &mut self,
        archive: &[u8],
        trust: &TrustStore,
    ) -> Result<PackageMetadata, RegistryError> {
        let loaded = load(archive, trust).map_err(RegistryError::Validation)?;
        let metadata = PackageMetadata {
            id: loaded.manifest.id.clone(),
            package_type: type_name(&loaded.manifest.package_type).into(),
            version: loaded.manifest.version.clone(),
            digest: loaded.manifest.signature.digest.clone(),
            signature_key_id: loaded.manifest.signature.key_id.clone(),
            manifest: serde_json::to_value(&loaded.manifest).map_err(|_| RegistryError::Storage)?,
            published_at: time::OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)
                .map_err(|_| RegistryError::Storage)?,
        };
        let transaction = self
            .connection
            .transaction()
            .map_err(|_| RegistryError::Storage)?;
        let inserted = transaction.execute("INSERT INTO packages (id, version, package_type, digest, signature_key_id, manifest, published_at, archive) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)", params![metadata.id, metadata.version, metadata.package_type, metadata.digest, metadata.signature_key_id, metadata.manifest.to_string(), metadata.published_at, archive]).map_err(|error| if error.sqlite_error_code() == Some(rusqlite::ErrorCode::ConstraintViolation) { RegistryError::DuplicateVersion } else { RegistryError::Storage })?;
        debug_assert_eq!(inserted, 1);
        transaction.execute("INSERT INTO recommendations (id, version) VALUES (?1, ?2) ON CONFLICT(id) DO NOTHING", params![metadata.id, metadata.version]).map_err(|_| RegistryError::Storage)?;
        transaction.commit().map_err(|_| RegistryError::Storage)?;
        Ok(metadata)
    }
    fn list(&self) -> Result<Vec<PackageMetadata>, RegistryError> {
        let mut statement = self.connection.prepare("SELECT id, package_type, version, digest, signature_key_id, manifest, published_at FROM packages ORDER BY id, version").map_err(|_| RegistryError::Storage)?;
        let rows = statement
            .query_map([], row)
            .map_err(|_| RegistryError::Storage)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|_| RegistryError::Storage)
    }
    fn metadata(&self, id: &str, version: &str) -> Result<PackageMetadata, RegistryError> {
        self.connection.query_row("SELECT id, package_type, version, digest, signature_key_id, manifest, published_at FROM packages WHERE id = ?1 AND version = ?2", params![id, version], row).optional().map_err(|_| RegistryError::Storage)?.ok_or(RegistryError::VersionNotFound)
    }
    fn download(&self, id: &str, version: &str) -> Result<Vec<u8>, RegistryError> {
        self.connection
            .query_row(
                "SELECT archive FROM packages WHERE id = ?1 AND version = ?2",
                params![id, version],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| RegistryError::Storage)?
            .ok_or(RegistryError::VersionNotFound)
    }
    fn rollback(&mut self, id: &str, version: &str) -> Result<(), RegistryError> {
        let exists: Option<u8> = self
            .connection
            .query_row(
                "SELECT 1 FROM packages WHERE id = ?1 AND version = ?2",
                params![id, version],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| RegistryError::Storage)?;
        if exists.is_none() {
            return Err(RegistryError::VersionNotFound);
        }
        self.connection.execute("INSERT INTO recommendations (id, version) VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET version = excluded.version", params![id, version]).map_err(|_| RegistryError::Storage)?;
        Ok(())
    }
    fn recommended_version(&self, id: &str) -> Result<String, RegistryError> {
        self.connection
            .query_row(
                "SELECT version FROM recommendations WHERE id = ?1",
                [id],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| RegistryError::Storage)?
            .ok_or(RegistryError::PackageNotFound)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::SigningKey;
    use ocp_package_builder::{
        build, AssetInput, BuildRequest, PackageIdentity, PackageType as BuildType,
    };
    fn key() -> SigningKey {
        SigningKey::from_bytes(&[9; 32])
    }
    fn trust(key: &SigningKey) -> TrustStore {
        let mut trust = TrustStore::new();
        trust.add_key("ed25519:test-1", key.verifying_key());
        trust
    }
    fn archive(kind: BuildType, version: &str) -> Vec<u8> {
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
    #[test]
    fn cs_reg_all_types_publish_catalog_download_and_verify() {
        let key = key();
        let trust = trust(&key);
        let mut registry = SqliteRegistry::open_in_memory().unwrap();
        for kind in [BuildType::Character, BuildType::Plugin, BuildType::Voice] {
            let bytes = archive(
                kind,
                match registry.list().unwrap().len() {
                    0 => "1.0.0",
                    1 => "1.0.1",
                    _ => "1.0.2",
                },
            );
            let published = registry.publish(&bytes, &trust).unwrap();
            assert_eq!(
                load(
                    &registry
                        .download("example.package", &published.version)
                        .unwrap(),
                    &trust
                )
                .unwrap()
                .archive_bytes,
                bytes
            );
        }
        let catalog = registry.list().unwrap();
        assert_eq!(catalog.len(), 3);
        assert_eq!(catalog[0].package_type, "character");
        assert_eq!(catalog[1].package_type, "plugin");
        assert_eq!(catalog[2].package_type, "voice");
        let metadata = registry.metadata("example.package", "1.0.1").unwrap();
        assert_eq!(metadata.package_type, "plugin");
    }
    #[test]
    fn cs_reg_rejects_duplicate_and_untrusted_without_overwrite() {
        let key = key();
        let trust = trust(&key);
        let bytes = archive(BuildType::Character, "1.0.0");
        let mut registry = SqliteRegistry::open_in_memory().unwrap();
        registry.publish(&bytes, &trust).unwrap();
        assert_eq!(
            registry.publish(&bytes, &trust).unwrap_err(),
            RegistryError::DuplicateVersion
        );
        let empty = TrustStore::new();
        assert!(matches!(
            registry.publish(&archive(BuildType::Voice, "2.0.0"), &empty),
            Err(RegistryError::Validation(_))
        ));
        assert_eq!(registry.list().unwrap().len(), 1);
    }
    #[test]
    fn cs_reg_rollback_only_moves_recommendation() {
        let key = key();
        let trust = trust(&key);
        let mut registry = SqliteRegistry::open_in_memory().unwrap();
        let old = archive(BuildType::Character, "1.0.0");
        let new = archive(BuildType::Character, "2.0.0");
        registry.publish(&old, &trust).unwrap();
        registry.publish(&new, &trust).unwrap();
        registry.rollback("example.package", "1.0.0").unwrap();
        assert_eq!(
            registry.recommended_version("example.package").unwrap(),
            "1.0.0"
        );
        assert_eq!(registry.download("example.package", "2.0.0").unwrap(), new);
    }
    #[test]
    fn cs_reg_sqlite_persists_exact_archive_and_metadata() {
        let key = key();
        let trust = trust(&key);
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("registry.sqlite");
        let archive = archive(BuildType::Voice, "1.0.0");
        {
            let mut registry = SqliteRegistry::open(database.to_str().unwrap()).unwrap();
            registry.publish(&archive, &trust).unwrap();
        }
        let registry = SqliteRegistry::open(database.to_str().unwrap()).unwrap();
        let metadata = registry.metadata("example.package", "1.0.0").unwrap();
        assert_eq!(metadata.package_type, "voice");
        assert_eq!(
            registry.download("example.package", "1.0.0").unwrap(),
            archive
        );
    }
}
