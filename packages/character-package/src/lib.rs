//! I8B — the character-package **entry schema** (`character/1`).
//!
//! A `type=character` `.ocp` archive's `manifest.entry` points at a JSON asset
//! (e.g. `assets/character.json`) whose shape this crate defines, parses, and
//! validates. The envelope around it — archive layout, per-asset SHA-256,
//! Ed25519 signature (PACKAGE_CONTRACT v0.1) — is `ocp-package-loader`'s job;
//! this crate never re-validates the envelope, only the character interior.
//!
//! Data-only by construction (THREAT_MODEL **X3-E**): a character package
//! carries *data* — sprite images, frame indices, a declarative behavior
//! [RuleSet] reference — and **never executable code**. Enforcement is
//! mechanical, not a review promise:
//! - the struct is `deny_unknown_fields`, so a smuggled `script`/`code`/`exec`
//!   field fails to parse (`Parse`);
//! - no referenced asset may be executable (`.wasm`) — [`CharacterError::ExecutableAsset`];
//! - `behavior` must reference a `.json` RuleSet, never a script or binary.
//!   Only `type=plugin` packages carry WASM, and those go through the Plugin
//!   Host, not this loader — RFC-0008 §5.
//!
//! Renderer is `sprite-sheet-2d` for v1 (RFC-0009 §5.1: the simplest thing a
//! marketplace creator can author). The field is a string, not a closed enum,
//! precisely so a future `spine-2d` / `live2d` / `model-3d` renderer is an
//! *additive* value that older runtimes reject cleanly ([`CharacterError::UnsupportedRenderer`])
//! rather than fail to parse.

#![forbid(unsafe_code)]

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub mod v2;
pub mod v3;
pub use v2::{
    parse_and_resolve, parse_v2, validate_v2, CharacterEntryV2, ResolvedCharacter, ThaiSpeechStyle,
    V2Error, VoiceAgeGroup, VoiceGender, VoiceProfile,
};
pub use v3::{
    parse_v3, validate_v3, AudioBinding, AudioClip, AudioProfile, AudioStartTrigger,
    AudioStopTrigger, CharacterEntryV3, CharacterPresentation, EffectAnchor, EffectAsset,
    EffectBinding, EffectLayer, EffectType, EffectsProfile, PreviewAsset, TeleportEffect,
    TeleportEffectMode, V3Error, SCHEMA_V3,
};

/// The only entry schema this crate version understands.
pub const SCHEMA: &str = "character/1";
/// The only renderer v1 implements (RFC-0009 §5.1, sprite-sheet-first).
pub const RENDERER_SPRITE_SHEET_2D: &str = "sprite-sheet-2d";
/// §7's default resting animation — every character must define it so behavior
/// always has an idle to fall back to (RUNTIME_API §7).
pub const REQUIRED_ANIMATION: &str = "idle";

/// A validation failure. Structural (`Parse`) vs semantic (the rest); every
/// variant names exactly what a fixture violated so tests and a future Studio
/// linter can key off it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CharacterError {
    /// Malformed JSON, a wrong-typed field, or a smuggled unknown field
    /// (`deny_unknown_fields` — the X3-E data-only guard for stray code fields).
    Parse(String),
    /// `schema` is not `character/1`.
    UnsupportedSchema(String),
    /// `renderer` is not one this version implements (v1: `sprite-sheet-2d`).
    UnsupportedRenderer(String),
    /// `name` is empty.
    EmptyName,
    /// No animations declared.
    NoAnimations,
    /// The mandatory `idle` animation is missing (RUNTIME_API §7).
    MissingIdleAnimation(String),
    /// A referenced path is not declared in the manifest's `assets` (so its
    /// bytes and digest were never validated by the envelope loader).
    UndeclaredAsset(String),
    /// A referenced asset is executable (`.wasm`) — never allowed in a
    /// character package (X3-E).
    ExecutableAsset(String),
    /// `behavior` does not reference a `.json` RuleSet (data-only, not a script).
    NonJsonBehavior(String),
    /// A clip references a sprite id that no `sprites[]` entry defines.
    UnknownSpriteRef { animation: String, sprite: String },
}

impl std::fmt::Display for CharacterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for CharacterError {}

/// The `character/1` entry document.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterEntry {
    /// Must equal [`SCHEMA`].
    pub schema: String,
    pub name: String,
    /// Rendering pipeline — v1 only [`RENDERER_SPRITE_SHEET_2D`]; string (not a
    /// closed enum) so future renderers are additive.
    pub renderer: String,
    pub sprites: Vec<Sprite>,
    /// §7 animation vocabulary name → clip. `idle` is required.
    pub animations: BTreeMap<String, Clip>,
    /// Emotion name → expression (RFC-0008 §4.1). Optional; unmapped emotions
    /// fall back at the runtime.
    #[serde(default)]
    pub expressions: BTreeMap<String, Expression>,
    /// Reserved (RFC-0009 out of scope) — a Voice pack ref for I7's voice path.
    #[serde(default)]
    pub voice_id: Option<String>,
    /// Path to a behavior RuleSet JSON asset (I3, data-only). Optional.
    #[serde(default)]
    pub behavior: Option<String>,
    /// Per-component authorship/license (RFC-0007 §9 — required from v1 in the
    /// spec; empty is allowed structurally so a validator, not the parser,
    /// decides how strict a given surface is).
    #[serde(default)]
    pub authorship: Vec<Authorship>,
}

/// A sprite sheet: an image asset + its per-frame cell size.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Sprite {
    pub id: String,
    pub path: String,
    /// `[width, height]` of one frame cell, in pixels.
    pub frame_size: [u32; 2],
}

/// One §7 animation: an ordered list of frame indices at a playback rate.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Clip {
    /// Which sprite sheet these frame indices index. Defaults to the first
    /// declared sprite when omitted (single-sheet characters).
    #[serde(default)]
    pub sprite: Option<String>,
    pub frames: Vec<u32>,
    pub fps: f32,
    #[serde(default, rename = "loop")]
    pub loop_: bool,
}

/// An expression (RFC-0008 §4.1): frame indices the Expression module shows for
/// an emotion.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Expression {
    #[serde(default)]
    pub sprite: Option<String>,
    pub frames: Vec<u32>,
}

/// Per-component authorship + license (RFC-0007 §9).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Authorship {
    pub component: String,
    pub author: String,
    pub license: String,
}

/// Parse an entry document's bytes. A smuggled unknown field (the X3-E code
/// guard) surfaces here as [`CharacterError::Parse`] via `deny_unknown_fields`.
pub fn parse_character_entry(json: &[u8]) -> Result<CharacterEntry, CharacterError> {
    serde_json::from_slice(json).map_err(|e| CharacterError::Parse(e.to_string()))
}

pub(crate) fn is_executable(path: &str) -> bool {
    let p = path.to_ascii_lowercase();
    p.ends_with(".wasm") || p.ends_with(".exe") || p.ends_with(".dll") || p.ends_with(".so")
}

/// Validate a parsed entry against the manifest's declared asset paths
/// (`ocp-package-loader` already proved those exist + match their digests).
/// `declared` is that manifest asset-path set.
pub fn validate(entry: &CharacterEntry, declared: &[&str]) -> Result<(), CharacterError> {
    if entry.schema != SCHEMA {
        return Err(CharacterError::UnsupportedSchema(entry.schema.clone()));
    }
    if entry.renderer != RENDERER_SPRITE_SHEET_2D {
        return Err(CharacterError::UnsupportedRenderer(entry.renderer.clone()));
    }
    if entry.name.trim().is_empty() {
        return Err(CharacterError::EmptyName);
    }
    if entry.animations.is_empty() {
        return Err(CharacterError::NoAnimations);
    }
    if !entry.animations.contains_key(REQUIRED_ANIMATION) {
        return Err(CharacterError::MissingIdleAnimation(
            REQUIRED_ANIMATION.to_owned(),
        ));
    }

    let declared_set: std::collections::BTreeSet<&str> = declared.iter().copied().collect();
    let sprite_ids: std::collections::BTreeSet<&str> =
        entry.sprites.iter().map(|s| s.id.as_str()).collect();

    // Every sprite asset must be declared + non-executable (X3-E).
    for sprite in &entry.sprites {
        if is_executable(&sprite.path) {
            return Err(CharacterError::ExecutableAsset(sprite.path.clone()));
        }
        if !declared_set.contains(sprite.path.as_str()) {
            return Err(CharacterError::UndeclaredAsset(sprite.path.clone()));
        }
    }

    // Clips/expressions may only reference declared sprite ids.
    for (name, clip) in &entry.animations {
        if let Some(sid) = &clip.sprite {
            if !sprite_ids.contains(sid.as_str()) {
                return Err(CharacterError::UnknownSpriteRef {
                    animation: name.clone(),
                    sprite: sid.clone(),
                });
            }
        }
    }
    for (name, expr) in &entry.expressions {
        if let Some(sid) = &expr.sprite {
            if !sprite_ids.contains(sid.as_str()) {
                return Err(CharacterError::UnknownSpriteRef {
                    animation: name.clone(),
                    sprite: sid.clone(),
                });
            }
        }
    }

    // Behavior must be a declared, non-executable `.json` RuleSet (data-only).
    if let Some(behavior) = &entry.behavior {
        if is_executable(behavior) || !behavior.to_ascii_lowercase().ends_with(".json") {
            return Err(CharacterError::NonJsonBehavior(behavior.clone()));
        }
        if !declared_set.contains(behavior.as_str()) {
            return Err(CharacterError::UndeclaredAsset(behavior.clone()));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"{
        "schema": "character/1",
        "name": "Aiko",
        "renderer": "sprite-sheet-2d",
        "sprites": [{ "id": "body", "path": "assets/aiko.png", "frameSize": [96, 96] }],
        "animations": {
            "idle": { "frames": [0, 1], "fps": 2, "loop": true },
            "wave": { "sprite": "body", "frames": [2, 3, 4, 5], "fps": 6 }
        },
        "expressions": { "happy": { "frames": [10] } },
        "voiceId": null,
        "behavior": "assets/behavior.json",
        "authorship": [{ "component": "sprites", "author": "Warin", "license": "CC-BY-4.0" }]
    }"#;

    fn declared() -> Vec<&'static str> {
        vec!["assets/aiko.png", "assets/behavior.json"]
    }

    #[test]
    fn a_valid_character_entry_parses_and_validates() {
        let entry = parse_character_entry(VALID.as_bytes()).expect("valid entry parses");
        assert_eq!(entry.name, "Aiko");
        assert_eq!(entry.renderer, RENDERER_SPRITE_SHEET_2D);
        assert!(entry.animations["idle"].loop_);
        assert_eq!(entry.animations["wave"].frames, vec![2, 3, 4, 5]);
        validate(&entry, &declared()).expect("valid entry passes validation");
    }

    #[test]
    fn a_smuggled_code_field_is_rejected_at_parse_x3e() {
        // The whole X3-E point: a character package can't carry executable
        // content. An unknown `script` field never parses (deny_unknown_fields).
        let smuggled = VALID.replace(
            "\"voiceId\": null,",
            "\"voiceId\": null, \"script\": \"os.system('rm -rf /')\",",
        );
        assert!(matches!(
            parse_character_entry(smuggled.as_bytes()),
            Err(CharacterError::Parse(_))
        ));
    }

    #[test]
    fn a_wasm_sprite_asset_is_rejected_as_executable() {
        let bad = VALID.replace("assets/aiko.png", "assets/aiko.wasm");
        let entry = parse_character_entry(bad.as_bytes()).unwrap();
        assert_eq!(
            validate(&entry, &["assets/aiko.wasm", "assets/behavior.json"]),
            Err(CharacterError::ExecutableAsset(
                "assets/aiko.wasm".to_owned()
            ))
        );
    }

    #[test]
    fn a_non_json_behavior_is_rejected() {
        let bad = VALID.replace("assets/behavior.json", "assets/behavior.wasm");
        let entry = parse_character_entry(bad.as_bytes()).unwrap();
        assert_eq!(
            validate(&entry, &["assets/aiko.png", "assets/behavior.wasm"]),
            Err(CharacterError::NonJsonBehavior(
                "assets/behavior.wasm".to_owned()
            ))
        );
    }

    #[test]
    fn a_future_renderer_is_cleanly_unsupported_not_a_parse_error() {
        let three_d = VALID.replace("sprite-sheet-2d", "model-3d");
        let entry = parse_character_entry(three_d.as_bytes()).expect("renderer is an open string");
        assert_eq!(
            validate(&entry, &declared()),
            Err(CharacterError::UnsupportedRenderer("model-3d".to_owned()))
        );
    }

    #[test]
    fn an_undeclared_sprite_asset_is_rejected() {
        let entry = parse_character_entry(VALID.as_bytes()).unwrap();
        // Manifest never declared the png -> its bytes/digest were unverified.
        assert_eq!(
            validate(&entry, &["assets/behavior.json"]),
            Err(CharacterError::UndeclaredAsset(
                "assets/aiko.png".to_owned()
            ))
        );
    }

    #[test]
    fn a_character_without_idle_is_rejected() {
        let no_idle = VALID.replace("\"idle\"", "\"walk\"");
        let entry = parse_character_entry(no_idle.as_bytes()).unwrap();
        assert_eq!(
            validate(&entry, &declared()),
            Err(CharacterError::MissingIdleAnimation("idle".to_owned()))
        );
    }

    #[test]
    fn a_clip_referencing_an_unknown_sprite_is_rejected() {
        let bad = VALID.replace("\"sprite\": \"body\"", "\"sprite\": \"ghost\"");
        let entry = parse_character_entry(bad.as_bytes()).unwrap();
        assert_eq!(
            validate(&entry, &declared()),
            Err(CharacterError::UnknownSpriteRef {
                animation: "wave".to_owned(),
                sprite: "ghost".to_owned()
            })
        );
    }
}
