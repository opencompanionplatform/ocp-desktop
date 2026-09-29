use base64::{engine::general_purpose::STANDARD as B64, Engine as _};
use ed25519_dalek::VerifyingKey;
use ocp_package_loader::{load, LoadError, TrustStore};
use std::io::{Cursor, Write};
use zip::write::SimpleFileOptions;

const KEY: &str = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=";
fn trust() -> TrustStore {
    let bytes: [u8; 32] = B64.decode(KEY).unwrap().try_into().unwrap();
    let mut store = TrustStore::new();
    store.add_key("ed25519:test-1", VerifyingKey::from_bytes(&bytes).unwrap());
    store
}
fn archive(entries: Vec<(&str, Vec<u8>)>) -> Vec<u8> {
    let mut out = Cursor::new(Vec::new());
    let mut zip = zip::ZipWriter::new(&mut out);
    let opt = SimpleFileOptions::default();
    for (path, data) in entries {
        zip.start_file(path, opt).unwrap();
        zip.write_all(&data).unwrap();
    }
    zip.finish().unwrap();
    out.into_inner()
}
fn fixture_root(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/valid")
        .join(name)
}
fn fixture(name: &str, extra: Option<(&str, &[u8])>) -> Vec<u8> {
    let root = fixture_root(name);
    let manifest = std::fs::read(root.join("manifest.json")).unwrap();
    let asset = std::fs::read(root.join("assets/main.json")).unwrap();
    let mut entries = vec![("manifest.json", manifest), ("assets/main.json", asset)];
    if let Some((path, data)) = extra {
        entries.push((path, data.to_vec()));
    }
    archive(entries)
}
fn manifest() -> serde_json::Value {
    serde_json::from_slice(
        &std::fs::read(fixture_root("character-aiko").join("manifest.json")).unwrap(),
    )
    .unwrap()
}
fn character_asset() -> Vec<u8> {
    std::fs::read(fixture_root("character-aiko").join("assets/main.json")).unwrap()
}
fn package_with_manifest(value: serde_json::Value, asset: Option<Vec<u8>>) -> Vec<u8> {
    let mut entries = vec![("manifest.json", serde_json::to_vec(&value).unwrap())];
    if let Some(asset) = asset {
        entries.push(("assets/main.json", asset));
    }
    archive(entries)
}
#[test]
fn cs_pkg_all_types_load_and_preserve_bytes() {
    for name in ["character-aiko", "plugin-example", "voice-example"] {
        let bytes = fixture(name, None);
        let loaded = load(&bytes, &trust()).unwrap();
        assert_eq!(loaded.archive_bytes, bytes);
    }
}
#[test]
fn cs_pkg_rejects_non_zip() {
    assert_eq!(
        load(b"not a zip", &trust()).unwrap_err(),
        LoadError::InvalidArchive
    );
}

#[test]
fn cs_pkg_binds_endorsed_publisher_and_enforces_package_revocation() {
    let bytes = fixture("character-aiko", None);
    let package = load(&bytes, &trust()).unwrap();
    let key: [u8; 32] = B64.decode(KEY).unwrap().try_into().unwrap();
    let mut bound = TrustStore::new();
    bound.add_publisher_key(
        "ed25519:test-1".into(),
        "wrong.publisher".into(),
        VerifyingKey::from_bytes(&key).unwrap(),
    );
    assert_eq!(
        load(&bytes, &bound).unwrap_err(),
        LoadError::PublisherMismatch
    );
    bound.add_publisher_key(
        "ed25519:test-1".into(),
        package.manifest.publisher.id,
        VerifyingKey::from_bytes(&key).unwrap(),
    );
    assert!(load(&bytes, &bound).is_ok());
    bound.revoke_package(package.manifest.id, package.manifest.version);
    assert_eq!(load(&bytes, &bound).unwrap_err(), LoadError::Revoked);
}
#[test]
fn cs_pkg_rejects_undeclared_member() {
    let bytes = fixture("character-aiko", Some(("assets/extra.txt", b"x")));
    assert!(matches!(
        load(&bytes, &trust()),
        Err(LoadError::UndeclaredMember(_))
    ));
}
#[test]
fn cs_pkg_rejects_schema_missing_asset_digest_and_signature_failures() {
    let no_asset = package_with_manifest(manifest(), None);
    assert!(matches!(
        load(&no_asset, &trust()),
        Err(LoadError::MissingAsset(_))
    ));
    let bad_asset = package_with_manifest(manifest(), Some(b"changed".to_vec()));
    assert!(matches!(
        load(&bad_asset, &trust()),
        Err(LoadError::AssetDigestMismatch(_))
    ));
    let mut bad_digest = manifest();
    bad_digest["signature"]["digest"] = serde_json::json!(
        "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    );
    assert!(matches!(
        load(
            &package_with_manifest(bad_digest, Some(character_asset())),
            &trust()
        ),
        Err(LoadError::SignatureDigestMismatch)
    ));
    let mut bad_sig = manifest();
    bad_sig["signature"]["value"]=serde_json::json!("base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==");
    assert!(matches!(
        load(
            &package_with_manifest(bad_sig, Some(character_asset())),
            &trust()
        ),
        Err(LoadError::SignatureVerificationFailed)
    ));
    assert!(matches!(
        load(&archive(vec![("manifest.json", b"{}".to_vec())]), &trust()),
        Err(LoadError::ManifestSchema)
    ));
}

#[test]
fn cs_pkg_rejects_unsafe_and_duplicate_paths() {
    let unsafe_archive = archive(vec![
        ("manifest.json", serde_json::to_vec(&manifest()).unwrap()),
        ("../escape.txt", b"x".to_vec()),
    ]);
    assert!(matches!(
        load(&unsafe_archive, &trust()),
        Err(LoadError::UnsafePath)
    ));

    // The writer rejects duplicate names itself. Forge one by replacing a
    // same-length member name in every ZIP header after creation.
    let mut duplicate_archive = archive(vec![
        ("manifest.json", serde_json::to_vec(&manifest()).unwrap()),
        ("assets/one.json", b"first".to_vec()),
        ("assets/two.json", b"second".to_vec()),
    ]);
    for offset in 0..=duplicate_archive.len() - b"assets/two.json".len() {
        if duplicate_archive[offset..].starts_with(b"assets/two.json") {
            duplicate_archive[offset..offset + b"assets/two.json".len()]
                .copy_from_slice(b"assets/one.json");
        }
    }
    let duplicate_result = load(&duplicate_archive, &trust());
    assert!(
        matches!(duplicate_result, Err(LoadError::DuplicatePath)),
        "{duplicate_result:?}"
    );
}
