use std::{env, fs, process};

use ocp_character_package::{parse_and_resolve, parse_v2};

fn main() {
    let Some(path) = env::args().nth(1) else {
        eprintln!("usage: cargo run -p ocp-character-package --example validate_character -- <character.json>");
        process::exit(2);
    };
    let bytes = fs::read(&path).unwrap_or_else(|error| {
        eprintln!("cannot read {path}: {error}");
        process::exit(2);
    });
    let entry = parse_v2(&bytes).unwrap_or_else(|error| {
        eprintln!("invalid character/2 JSON: {error}");
        process::exit(1);
    });
    let declared_owned: Vec<String> = entry
        .sprites
        .iter()
        .map(|sprite| sprite.path.clone())
        .collect();
    let declared: Vec<&str> = declared_owned.iter().map(String::as_str).collect();
    let resolved = parse_and_resolve(&bytes, &declared).unwrap_or_else(|error| {
        eprintln!("invalid character/2 contract: {error}");
        process::exit(1);
    });
    println!(
        "character/2 validation PASS id={} animations={} sprites={}",
        resolved.id.as_deref().unwrap_or("<missing>"),
        resolved.animations.len(),
        resolved.sprites.len()
    );
}
