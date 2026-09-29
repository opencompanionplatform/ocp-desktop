//! Build a **real signed `.ocp`** from the character exported by Character Studio
//! (or the runtime baker) into `OCP_CHARACTER_DIR` โ€” the CLI form of the Studio's
//! Build button until it calls the builder in-process. Reads `character.json` +
//! the sprite it references, normalizes the in-package layout, signs with
//! `package-builder` (Ed25519, PACKAGE_CONTRACT v0.1), and proves the result
//! loads + validates round-trip.
//!
//! Usage:
//!   $env:OCP_CHARACTER_DIR = "$env:TEMP\ocp-character"   # where Studio exported
//!   cargo run -p ocp-character-package --example pack_character

use std::io::Read;
use std::path::PathBuf;

use ed25519_dalek::SigningKey;
use ocp_character_package::{parse_character_entry, validate};
use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};
use ocp_package_loader::{load, TrustStore};

const KEY_ID: &str = "ed25519:demo-1";

fn character_dir() -> PathBuf {
    std::env::var_os("OCP_CHARACTER_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("ocp-character"))
}

/// A valid PACKAGE_CONTRACT id (`character.<lowercase-alnum>`) from a name.
fn package_id(name: &str) -> String {
    let slug: String = name
        .to_ascii_lowercase()
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect();
    format!(
        "character.{}",
        if slug.is_empty() {
            "custom".to_owned()
        } else {
            slug
        }
    )
}

fn main() {
    let dir = character_dir();

    // The character Studio / the runtime baker exported here.
    let Ok(char_json) = std::fs::read(dir.join("character.json")) else {
        eprintln!(
            "no character.json in {} โ€” export one from Character Studio (Studio.tscn) first, or run \
             the runtime once with OCP_CHARACTER_DIR set to bake the sample.",
            dir.display()
        );
        std::process::exit(1);
    };
    let mut entry = match parse_character_entry(&char_json) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("character.json is invalid: {e}");
            std::process::exit(1);
        }
    };

    // Read the sprite from the path the entry declares (relative to the dir),
    // then normalize the in-package path so the packaged `.ocp` is self-consistent.
    // I8C-2 multi-sheet: read + normalize EVERY declared sprite. Each becomes
    // `assets/<id>.png` in the package, and the entry's paths are rewritten to
    // match so a multi-sheet character (idle.png/wave.png/โ€ฆ) packs correctly.
    let mut asset_paths = vec!["assets/character.json".to_owned()];
    let mut sprite_assets: Vec<AssetInput> = Vec::new();
    for sprite in &mut entry.sprites {
        let src = sprite.path.clone();
        let Ok(bytes) = std::fs::read(dir.join(&src)) else {
            eprintln!(
                "the sprite `{src}` that character.json references is missing under {}",
                dir.display()
            );
            std::process::exit(1);
        };
        let in_pkg = format!("assets/{}.png", sprite.id);
        sprite.path = in_pkg.clone();
        asset_paths.push(in_pkg.clone());
        sprite_assets.push(AssetInput {
            path: in_pkg,
            bytes,
        });
    }
    let normalized = serde_json::to_vec(&entry).expect("re-serialize the entry");

    let signing_key = SigningKey::from_bytes(&[7u8; 32]); // demo key (real key = keystore, I8D)
    let mut assets = vec![AssetInput {
        path: "assets/character.json".to_owned(),
        bytes: normalized,
    }];
    assets.extend(sprite_assets);
    let request = BuildRequest {
        identity: PackageIdentity {
            id: package_id(&entry.name),
            package_type: PackageType::Character,
            version: "1.0.0".to_owned(),
            publisher_id: "ocp.demo".to_owned(),
            key_id: KEY_ID.to_owned(),
            license: "CC-BY-4.0".to_owned(),
            entry: "assets/character.json".to_owned(),
        },
        asset_paths,
        assets,
    };

    let ocp = match build(&request, &signing_key) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("build failed: {e:?}");
            std::process::exit(1);
        }
    };
    let out = dir.join(format!(
        "{}.ocp",
        package_id(&entry.name).trim_start_matches("character.")
    ));
    if let Err(e) = std::fs::write(&out, &ocp) {
        eprintln!("could not write {}: {e}", out.display());
        std::process::exit(1);
    }
    println!(
        "built {} ({} bytes) for character '{}'",
        out.display(),
        ocp.len(),
        entry.name
    );

    // Round-trip: load (signature + digests) + validate (character interior).
    let mut trust = TrustStore::new();
    trust.add_key(KEY_ID, signing_key.verifying_key());
    let pkg = match load(&ocp, &trust) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("the .ocp did NOT load: {e:?}");
            std::process::exit(1);
        }
    };
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&pkg.archive_bytes[..]))
        .expect("archive re-opens");
    let mut entry_bytes = Vec::new();
    archive
        .by_name(&pkg.manifest.entry)
        .expect("entry present")
        .read_to_end(&mut entry_bytes)
        .expect("entry reads");
    let packed = parse_character_entry(&entry_bytes).expect("entry parses");
    let declared: Vec<&str> = pkg
        .manifest
        .assets
        .iter()
        .map(|a| a.path.as_str())
        .collect();
    validate(&packed, &declared).expect("entry validates");

    println!(
        "loads + validates โ…  (id = {}, name = {:?}, animations = {:?})",
        pkg.manifest.id,
        packed.name,
        packed.animations.keys().collect::<Vec<_>>()
    );
    println!("\nSet OCP_CHARACTER_PACKAGE to this .ocp and run the kernel โ€” the runtime renders your character.");
}
