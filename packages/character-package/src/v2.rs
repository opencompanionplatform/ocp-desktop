use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::{is_executable, Authorship, CharacterEntry, Clip, Expression, Sprite};

pub const SCHEMA_V2: &str = "character/2";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2Error {
    Parse(String),
    UnsupportedSchema(String),
    UnsupportedRenderer(String),
    EmptyIdentity,
    MissingIdleAnimation,
    UndeclaredAsset(String),
    ExecutableAsset(String),
    UnknownSpriteRef { animation: String, sprite: String },
    InvalidBodyProfile(String),
    InvalidPresentationProfile(String),
    InvalidVisualProfile(String),
    UnknownFallbackTarget(String),
    FallbackCycle(String),
}

impl std::fmt::Display for V2Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for V2Error {}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterEntryV2 {
    pub schema: String,
    pub id: String,
    pub version: String,
    pub name: String,
    pub renderer: String,
    pub runtime_compatibility: RuntimeCompatibility,
    #[serde(default)]
    pub capabilities: Capabilities,
    pub body_profile: BodyProfile,
    #[serde(default)]
    pub presentation_profile: PresentationProfile,
    pub sprites: Vec<Sprite>,
    pub animations: BTreeMap<String, Clip>,
    #[serde(default)]
    pub animation_fallbacks: BTreeMap<String, String>,
    #[serde(default)]
    pub visual_profiles: BTreeMap<String, VisualProfile>,
    #[serde(default)]
    pub expressions: BTreeMap<String, Expression>,
    #[serde(default)]
    pub authorship: Vec<Authorship>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeCompatibility {
    pub minimum_runtime_version: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capabilities {
    #[serde(default)]
    pub basic_walk: bool,
    #[serde(default)]
    pub jump: bool,
    #[serde(default)]
    pub surface_sit: bool,
    #[serde(default)]
    pub surface_climb: bool,
    #[serde(default)]
    pub top_hang: bool,
    #[serde(default)]
    pub flight: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BodyProfile {
    pub logical_size: [f32; 2],
    pub collision_half_extents: [f32; 2],
    pub feet_anchor: [f32; 2],
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PresentationProfile {
    #[serde(default = "one")]
    pub base_scale: f32,
    #[serde(default = "default_minimum_scale")]
    pub minimum_user_scale: f32,
    #[serde(default = "default_maximum_scale")]
    pub maximum_user_scale: f32,
}

impl Default for PresentationProfile {
    fn default() -> Self {
        Self {
            base_scale: one(),
            minimum_user_scale: default_minimum_scale(),
            maximum_user_scale: default_maximum_scale(),
        }
    }
}

/// Semantic TTS preference carried by a character package. This is only an
/// automatic voice-selection hint; it never embeds audio, credentials, or a
/// provider-specific voice asset. An explicit user voice selection overrides it.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VoiceProfile {
    /// Desired TTS voice presentation, not the character's identity.
    #[serde(default)]
    pub presentation: VoiceGender,
    #[serde(default)]
    pub age: VoiceAgeGroup,
    #[serde(default)]
    pub thai_speech_style: ThaiSpeechStyle,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum VoiceGender {
    Male,
    Female,
    #[default]
    Neutral,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum VoiceAgeGroup {
    Child,
    #[default]
    Adult,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ThaiSpeechStyle {
    Feminine,
    Masculine,
    #[default]
    Neutral,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VisualProfile {
    #[serde(default = "full_bounds")]
    pub content_bounds: [f32; 4],
    #[serde(default = "full_bounds")]
    pub hit_test_bounds: [f32; 4],
    #[serde(default = "one")]
    pub scale: f32,
    #[serde(default)]
    pub offset: [f32; 2],
    #[serde(default)]
    pub surface_anchor: Option<[f32; 2]>,
    #[serde(default)]
    pub mirror_policy: MirrorPolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mirror_safe: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum MirrorPolicy {
    #[default]
    None,
    Facing,
    SurfaceNormal,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResolvedCharacter {
    pub source_schema: String,
    pub id: Option<String>,
    pub version: Option<String>,
    pub name: String,
    pub renderer: String,
    pub capabilities: Capabilities,
    pub body_profile: BodyProfile,
    pub presentation_profile: PresentationProfile,
    pub voice_profile: Option<VoiceProfile>,
    pub presentation: Option<crate::v3::CharacterPresentation>,
    pub audio_profile: Option<crate::v3::AudioProfile>,
    pub effects_profile: Option<crate::v3::EffectsProfile>,
    pub sprites: Vec<Sprite>,
    pub animations: BTreeMap<String, Clip>,
    pub animation_fallbacks: BTreeMap<String, String>,
    pub visual_profiles: BTreeMap<String, VisualProfile>,
    pub expressions: BTreeMap<String, Expression>,
    pub authorship: Vec<Authorship>,
}

impl ResolvedCharacter {
    pub fn collision_feet_from_center(&self, center: [f32; 2]) -> [f32; 2] {
        [
            center[0],
            center[1] + self.body_profile.collision_half_extents[1],
        ]
    }
}

impl From<CharacterEntry> for ResolvedCharacter {
    fn from(value: CharacterEntry) -> Self {
        Self {
            source_schema: crate::SCHEMA.to_owned(),
            id: None,
            version: None,
            name: value.name,
            renderer: value.renderer,
            capabilities: Capabilities {
                basic_walk: true,
                ..Capabilities::default()
            },
            body_profile: BodyProfile {
                logical_size: [128.0, 128.0],
                collision_half_extents: [64.0, 64.0],
                feet_anchor: [0.5, 1.0],
            },
            presentation_profile: PresentationProfile::default(),
            voice_profile: None,
            presentation: None,
            audio_profile: None,
            effects_profile: None,
            sprites: value.sprites,
            animations: value.animations,
            animation_fallbacks: BTreeMap::new(),
            visual_profiles: BTreeMap::from([("default".to_owned(), VisualProfile::default())]),
            expressions: value.expressions,
            authorship: value.authorship,
        }
    }
}

impl From<CharacterEntryV2> for ResolvedCharacter {
    fn from(value: CharacterEntryV2) -> Self {
        Self {
            source_schema: value.schema,
            id: Some(value.id),
            version: Some(value.version),
            name: value.name,
            renderer: value.renderer,
            capabilities: value.capabilities,
            body_profile: value.body_profile,
            presentation_profile: value.presentation_profile,
            voice_profile: None,
            presentation: None,
            audio_profile: None,
            effects_profile: None,
            sprites: value.sprites,
            animations: value.animations,
            animation_fallbacks: value.animation_fallbacks,
            visual_profiles: value.visual_profiles,
            expressions: value.expressions,
            authorship: value.authorship,
        }
    }
}

impl Default for VisualProfile {
    fn default() -> Self {
        Self {
            content_bounds: full_bounds(),
            hit_test_bounds: full_bounds(),
            scale: one(),
            offset: [0.0, 0.0],
            surface_anchor: None,
            mirror_policy: MirrorPolicy::None,
            mirror_safe: None,
        }
    }
}

fn one() -> f32 {
    1.0
}
fn default_minimum_scale() -> f32 {
    0.5
}
fn default_maximum_scale() -> f32 {
    2.0
}
fn full_bounds() -> [f32; 4] {
    [0.0, 0.0, 1.0, 1.0]
}
fn finite_positive(value: f32) -> bool {
    value.is_finite() && value > 0.0
}
fn normalized(value: f32) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}

pub fn parse_v2(json: &[u8]) -> Result<CharacterEntryV2, V2Error> {
    serde_json::from_slice(json).map_err(|error| V2Error::Parse(error.to_string()))
}

pub fn parse_and_resolve(json: &[u8], declared: &[&str]) -> Result<ResolvedCharacter, V2Error> {
    let schema = serde_json::from_slice::<serde_json::Value>(json)
        .map_err(|error| V2Error::Parse(error.to_string()))?
        .get("schema")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| V2Error::Parse("missing string field `schema`".to_owned()))?
        .to_owned();

    match schema.as_str() {
        crate::SCHEMA => {
            let entry = crate::parse_character_entry(json)
                .map_err(|error| V2Error::Parse(error.to_string()))?;
            crate::validate(&entry, declared).map_err(|error| V2Error::Parse(error.to_string()))?;
            Ok(entry.into())
        }
        SCHEMA_V2 => {
            let entry = parse_v2(json)?;
            validate_v2(&entry, declared)?;
            Ok(entry.into())
        }
        crate::v3::SCHEMA_V3 => {
            let entry =
                crate::v3::parse_v3(json).map_err(|error| V2Error::Parse(error.to_string()))?;
            crate::v3::validate_v3(&entry, declared)
                .map_err(|error| V2Error::Parse(error.to_string()))?;
            Ok(entry.into())
        }
        _ => Err(V2Error::UnsupportedSchema(schema)),
    }
}

pub fn validate_v2(entry: &CharacterEntryV2, declared: &[&str]) -> Result<(), V2Error> {
    if entry.schema != SCHEMA_V2 {
        return Err(V2Error::UnsupportedSchema(entry.schema.clone()));
    }
    if entry.renderer != crate::RENDERER_SPRITE_SHEET_2D {
        return Err(V2Error::UnsupportedRenderer(entry.renderer.clone()));
    }
    if entry.id.trim().is_empty() || entry.version.trim().is_empty() || entry.name.trim().is_empty()
    {
        return Err(V2Error::EmptyIdentity);
    }
    if !entry.animations.contains_key(crate::REQUIRED_ANIMATION) {
        return Err(V2Error::MissingIdleAnimation);
    }
    if !entry
        .body_profile
        .logical_size
        .iter()
        .copied()
        .all(finite_positive)
        || !entry
            .body_profile
            .collision_half_extents
            .iter()
            .copied()
            .all(finite_positive)
        || !entry
            .body_profile
            .feet_anchor
            .iter()
            .copied()
            .all(normalized)
    {
        return Err(V2Error::InvalidBodyProfile(
            "non-finite or out-of-range body value".to_owned(),
        ));
    }
    if entry.body_profile.collision_half_extents[0] * 2.0 > entry.body_profile.logical_size[0]
        || entry.body_profile.collision_half_extents[1] * 2.0 > entry.body_profile.logical_size[1]
    {
        return Err(V2Error::InvalidBodyProfile(
            "collision exceeds logical size".to_owned(),
        ));
    }
    let presentation = &entry.presentation_profile;
    if !finite_positive(presentation.base_scale)
        || !finite_positive(presentation.minimum_user_scale)
        || !finite_positive(presentation.maximum_user_scale)
        || presentation.minimum_user_scale > presentation.maximum_user_scale
    {
        return Err(V2Error::InvalidPresentationProfile(
            "invalid scale range".to_owned(),
        ));
    }

    let declared: BTreeSet<&str> = declared.iter().copied().collect();
    let sprite_ids: BTreeSet<&str> = entry
        .sprites
        .iter()
        .map(|sprite| sprite.id.as_str())
        .collect();
    for sprite in &entry.sprites {
        if is_executable(&sprite.path) {
            return Err(V2Error::ExecutableAsset(sprite.path.clone()));
        }
        if !declared.contains(sprite.path.as_str()) {
            return Err(V2Error::UndeclaredAsset(sprite.path.clone()));
        }
    }
    for (name, clip) in &entry.animations {
        if let Some(sprite) = &clip.sprite {
            if !sprite_ids.contains(sprite.as_str()) {
                return Err(V2Error::UnknownSpriteRef {
                    animation: name.clone(),
                    sprite: sprite.clone(),
                });
            }
        }
    }
    for (name, profile) in &entry.visual_profiles {
        validate_visual_profile(profile)
            .map_err(|reason| V2Error::InvalidVisualProfile(format!("{name}: {reason}")))?;
    }
    validate_fallbacks(entry)?;
    Ok(())
}

fn validate_visual_profile(profile: &VisualProfile) -> Result<(), &'static str> {
    for bounds in [profile.content_bounds, profile.hit_test_bounds] {
        if !bounds.iter().copied().all(normalized)
            || bounds[2] <= 0.0
            || bounds[3] <= 0.0
            || bounds[0] + bounds[2] > 1.0
            || bounds[1] + bounds[3] > 1.0
        {
            return Err("invalid normalized bounds");
        }
    }
    if !finite_positive(profile.scale) || !profile.offset.iter().all(|value| value.is_finite()) {
        return Err("invalid scale or offset");
    }
    if profile
        .surface_anchor
        .is_some_and(|anchor| !anchor.iter().copied().all(normalized))
    {
        return Err("invalid surface anchor");
    }
    Ok(())
}

fn validate_fallbacks(entry: &CharacterEntryV2) -> Result<(), V2Error> {
    for source in entry.animation_fallbacks.keys() {
        let mut seen = BTreeSet::new();
        let mut current = source.as_str();
        while let Some(next) = entry.animation_fallbacks.get(current) {
            if !seen.insert(current) {
                return Err(V2Error::FallbackCycle(source.clone()));
            }
            current = next;
        }
        if !entry.animations.contains_key(current) {
            return Err(V2Error::UnknownFallbackTarget(current.to_owned()));
        }
    }
    Ok(())
}
