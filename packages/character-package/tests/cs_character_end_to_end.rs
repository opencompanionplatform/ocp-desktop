//! I8B-2 foundation: a character package's entry — read out of a loaded
//! package's archive — parses and validates through this crate. This is the
//! seam the kernel/runtime uses to turn a `.ocp` into renderable character data
//! (`LoadedPackage` → entry bytes → `CharacterEntry`).
//!
//! The envelope's own validation (archive layout, per-asset SHA-256, Ed25519
//! signature) is `ocp-package-loader`'s test surface; here we construct a
//! `LoadedPackage` from the loader's real types and prove the **character
//! interior** pipeline on top of it — including that a package smuggling a code
//! field is rejected at the character layer (X3-E) even though the envelope
//! happily carried it.

use std::io::{Cursor, Read, Write};

use ocp_character_package::{parse_character_entry, validate};
use ocp_package_loader::{Asset, LoadedPackage, Manifest, PackageType, Publisher, SignatureBlock};
use zip::write::SimpleFileOptions;

const CHARACTER_JSON: &str = r#"{
  "schema": "character/1",
  "name": "Aiko",
  "renderer": "sprite-sheet-2d",
  "sprites": [{ "id": "body", "path": "assets/aiko.png", "frameSize": [96, 96] }],
  "animations": { "idle": { "frames": [0, 1], "fps": 2, "loop": true } },
  "behavior": "assets/behavior.json"
}"#;

fn zip_with(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut zw = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
    for (name, data) in entries {
        zw.start_file(*name, opts).unwrap();
        zw.write_all(data).unwrap();
    }
    zw.finish().unwrap().into_inner()
}

fn manifest() -> Manifest {
    Manifest {
        manifest_version: "0.1".into(),
        id: "character.aiko".into(),
        package_type: PackageType::Character,
        version: "1.0.0".into(),
        publisher: Publisher {
            id: "ocp.test".into(),
            key_id: "ed25519:test-1".into(),
        },
        license: "Apache-2.0".into(),
        entry: "assets/character.json".into(),
        assets: vec![
            Asset {
                path: "assets/character.json".into(),
                sha256: "x".into(),
            },
            Asset {
                path: "assets/aiko.png".into(),
                sha256: "x".into(),
            },
            Asset {
                path: "assets/behavior.json".into(),
                sha256: "x".into(),
            },
        ],
        signature: SignatureBlock {
            algorithm: "ed25519".into(),
            key_id: "ed25519:test-1".into(),
            digest: "sha256:x".into(),
            value: "base64:x".into(),
        },
    }
}

fn read_entry(pkg: &LoadedPackage) -> Vec<u8> {
    let mut archive = zip::ZipArchive::new(Cursor::new(pkg.archive_bytes.clone())).unwrap();
    let mut f = archive.by_name(&pkg.manifest.entry).unwrap();
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).unwrap();
    buf
}

#[test]
fn a_loaded_character_packages_entry_parses_and_validates() {
    let pkg = LoadedPackage {
        manifest: manifest(),
        archive_bytes: zip_with(&[
            ("manifest.json", b"{}"),
            ("assets/character.json", CHARACTER_JSON.as_bytes()),
            ("assets/aiko.png", b"\x89PNG\r\n\x1a\n"),
            ("assets/behavior.json", b"{\"rules\":[]}"),
        ]),
    };

    let entry = parse_character_entry(&read_entry(&pkg)).expect("entry parses");
    let declared: Vec<&str> = pkg
        .manifest
        .assets
        .iter()
        .map(|a| a.path.as_str())
        .collect();
    validate(&entry, &declared).expect("entry validates against the manifest's declared assets");

    assert_eq!(entry.name, "Aiko");
    assert_eq!(entry.renderer, "sprite-sheet-2d");
    assert!(entry.animations.contains_key("idle"));
    assert_eq!(entry.behavior.as_deref(), Some("assets/behavior.json"));
}

#[test]
fn a_character_package_smuggling_a_script_field_is_rejected_even_when_loaded() {
    let smuggled = CHARACTER_JSON.replace(
        "\"behavior\": \"assets/behavior.json\"",
        "\"behavior\": \"assets/behavior.json\", \"script\": \"evil()\"",
    );
    let pkg = LoadedPackage {
        manifest: manifest(),
        archive_bytes: zip_with(&[
            ("manifest.json", b"{}"),
            ("assets/character.json", smuggled.as_bytes()),
            ("assets/aiko.png", b"png"),
            ("assets/behavior.json", b"{}"),
        ]),
    };
    // The envelope carried it; the character layer (X3-E, deny_unknown_fields)
    // rejects the smuggled code field.
    assert!(parse_character_entry(&read_entry(&pkg)).is_err());
}
