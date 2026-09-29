//! Read-only investigation tool. A publisher signature match is NOT an
//! endorsement chain, an installation authorization, or a Runtime trust update.
use ed25519_dalek::VerifyingKey;
use ocp_package_loader::{load, TrustStore};
use serde::Deserialize;
use sha2::{Digest, Sha256};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Expected {
    package_id: String,
    version: String,
    publisher_id: String,
    key_id: String,
    public_key_hex: String,
    sha256: String,
}

fn inspect(bytes: &[u8], expected: &Expected) -> Result<(), &'static str> {
    if expected.sha256.len() != 64 || !expected.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid-expected-sha256");
    }
    if format!("{:x}", Sha256::digest(bytes)) != expected.sha256.to_ascii_lowercase() {
        return Err("archive-sha256-mismatch");
    }
    let hex = &expected.public_key_hex;
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid-public-key");
    }
    let mut raw = [0u8; 32];
    for (i, byte) in raw.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).map_err(|_| "invalid-public-key")?;
    }
    let key = VerifyingKey::from_bytes(&raw).map_err(|_| "invalid-public-key")?;
    // Ephemeral diagnostic key set only: never persisted or given to Runtime.
    let mut keys = TrustStore::new();
    keys.add_key(&expected.key_id, key);
    let loaded = load(bytes, &keys).map_err(|_| "package-signature-manifest-or-assets-rejected")?;
    let manifest = loaded.manifest;
    if manifest.id != expected.package_id
        || manifest.version != expected.version
        || manifest.publisher.id != expected.publisher_id
        || manifest.publisher.key_id != expected.key_id
        || manifest.signature.key_id != expected.key_id
    {
        return Err("package-identity-mismatch");
    }
    Ok(())
}

fn main() {
    let result = (|| {
        let args: Vec<_> = std::env::args_os().collect();
        if args.len() != 3 {
            return Err(
                "usage: check_publisher_artifact <archive.ocp> <expected-public-metadata.json>",
            );
        }
        let metadata = std::fs::read(&args[2]).map_err(|_| "cannot-read-public-metadata")?;
        let expected: Expected =
            serde_json::from_slice(&metadata).map_err(|_| "invalid-public-metadata")?;
        let bytes = std::fs::read(&args[1]).map_err(|_| "cannot-read-archive")?;
        inspect(&bytes, &expected)
    })();
    match result {
        Ok(()) => {
            println!("artifactIntegrity=verified");
            println!("publisherSignature=verified-against-supplied-public-key");
            println!("publisherEndorsement=not-verified");
            println!("runtimeTrust=unchanged");
            println!("installation=not-attempted");
            // Never return the success code used by installation acceptance.
            std::process::exit(2);
        }
        Err(code) => {
            eprintln!("artifactVerification={code}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    use std::io::{Cursor, Write};
    use zip::write::SimpleFileOptions;

    fn fixture(tamper: bool) -> (Vec<u8>, Expected) {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/valid/character-aiko");
        let mut out = Cursor::new(Vec::new());
        let mut zip = zip::ZipWriter::new(&mut out);
        for path in ["manifest.json", "assets/main.json"] {
            zip.start_file(path, SimpleFileOptions::default()).unwrap();
            let mut bytes = std::fs::read(root.join(path)).unwrap();
            if tamper && path != "manifest.json" {
                bytes.push(b' ');
            }
            zip.write_all(&bytes).unwrap();
        }
        zip.finish().unwrap();
        let bytes = out.into_inner();
        let key = STANDARD
            .decode("11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
            .unwrap();
        let expected = Expected {
            package_id: "character.aiko".into(),
            version: "1.0.0".into(),
            publisher_id: "ocp.example".into(),
            key_id: "ed25519:test-1".into(),
            public_key_hex: key.iter().map(|b| format!("{b:02x}")).collect(),
            sha256: format!("{:x}", Sha256::digest(&bytes)),
        };
        (bytes, expected)
    }

    #[test]
    fn verifies_real_loader_fixture() {
        let (bytes, expected) = fixture(false);
        assert_eq!(inspect(&bytes, &expected), Ok(()));
    }

    #[test]
    fn rejects_wrong_archive_hash_before_signature() {
        let (bytes, mut expected) = fixture(false);
        expected.sha256 = "0".repeat(64);
        assert_eq!(inspect(&bytes, &expected), Err("archive-sha256-mismatch"));
    }

    #[test]
    fn rejects_asset_tampering_even_with_matching_archive_hash() {
        let (bytes, expected) = fixture(true);
        assert_eq!(
            inspect(&bytes, &expected),
            Err("package-signature-manifest-or-assets-rejected")
        );
    }

    #[test]
    fn rejects_wrong_key_and_publisher_binding() {
        let (bytes, mut expected) = fixture(false);
        expected.publisher_id = "another.publisher".into();
        assert_eq!(inspect(&bytes, &expected), Err("package-identity-mismatch"));
        expected.publisher_id = "ocp.example".into();
        expected.key_id = "ed25519:another-key".into();
        assert_eq!(
            inspect(&bytes, &expected),
            Err("package-signature-manifest-or-assets-rejected")
        );
    }

    #[test]
    fn rejects_non_ascii_key_without_panicking() {
        let (bytes, mut expected) = fixture(false);
        expected.public_key_hex = "ก".repeat(22);
        assert_eq!(inspect(&bytes, &expected), Err("invalid-public-key"));
    }
}
