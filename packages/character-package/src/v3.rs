use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::v2::{
    validate_v2, BodyProfile, Capabilities, CharacterEntryV2, PresentationProfile,
    ResolvedCharacter, RuntimeCompatibility, V2Error, VisualProfile, VoiceProfile,
};
use crate::{is_executable, Authorship, Clip, Expression, Sprite};

pub const SCHEMA_V3: &str = "character/3";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V3Error {
    Parse(String),
    UnsupportedSchema(String),
    Base(V2Error),
    InvalidPresentation(String),
    InvalidAudioProfile(String),
    InvalidEffectsProfile(String),
    InvalidAnimationMetadata(String),
    UndeclaredAsset(String),
    ExecutableAsset(String),
}

impl std::fmt::Display for V3Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for V3Error {}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterPresentation {
    /// Optional locale -> human-readable character description. Studio emits
    /// `en` and/or `th`; Runtime/Store may select the best available locale.
    #[serde(default)]
    pub descriptions: BTreeMap<String, String>,
    #[serde(default)]
    pub preview: Option<PreviewAsset>,
    /// Optional logical animation name -> packaged thumbnail image. Character/3
    /// keeps this backward-compatible so older packages may omit the map and
    /// Runtime can fall back to a generic/no-preview presentation.
    #[serde(default)]
    pub animation_thumbnails: BTreeMap<String, PreviewAsset>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PreviewAsset {
    pub path: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AudioProfile {
    #[serde(default)]
    pub clips: Vec<AudioClip>,
    #[serde(default)]
    pub bindings: BTreeMap<String, AudioBinding>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AudioClip {
    pub id: String,
    pub path: String,
    #[serde(default)]
    pub loop_: bool,
    #[serde(default)]
    pub gain_db: f32,
    #[serde(default)]
    pub start_seconds: f32,
    #[serde(default)]
    pub end_seconds: Option<f32>,
    #[serde(default)]
    pub fade_in_seconds: f32,
    #[serde(default)]
    pub fade_out_seconds: f32,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AudioBinding {
    pub clip: String,
    #[serde(default)]
    pub start: AudioStartTrigger,
    #[serde(default)]
    pub stop: Option<AudioStopTrigger>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AudioStartTrigger {
    #[default]
    AnimationStart,
    EffectStart,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum AudioStopTrigger {
    AnimationStop,
    EffectStop,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EffectsProfile {
    #[serde(default)]
    pub effects: Vec<EffectAsset>,
    #[serde(default)]
    pub bindings: BTreeMap<String, EffectBinding>,
    #[serde(default)]
    pub teleport: Option<TeleportEffect>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EffectAsset {
    pub id: String,
    #[serde(rename = "type")]
    pub effect_type: EffectType,
    pub path: String,
    pub frame_size: [u32; 2],
    pub fps: f32,
    pub frames: u32,
    #[serde(default)]
    pub loop_: bool,
    #[serde(default)]
    pub layer: EffectLayer,
    #[serde(default)]
    pub anchor: EffectAnchor,
    #[serde(default = "one")]
    pub scale: f32,
    #[serde(default)]
    pub offset: [f32; 2],
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EffectType {
    SpriteSheet,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EffectLayer {
    Background,
    #[default]
    BehindCharacter,
    FrontCharacter,
    UiOverlay,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EffectAnchor {
    BodyCenter,
    Head,
    Feet,
    #[default]
    BelowFeet,
    AboveHead,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EffectBinding {
    pub effect: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TeleportEffect {
    #[serde(default)]
    pub mode: TeleportEffectMode,
    #[serde(default)]
    pub effect_id: Option<String>,
    #[serde(default)]
    pub effect: Option<String>,
    #[serde(default)]
    pub anchor: EffectAnchor,
    #[serde(default = "one")]
    pub scale: f32,
    #[serde(default)]
    pub offset: [f32; 2],
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum TeleportEffectMode {
    #[default]
    RuntimeDefault,
    PackageOverride,
    Disabled,
}

/// Character/3 keeps Character/2's animation/body/presentation contract and
/// adds provider-neutral voice metadata plus signed presentation, SFX and visual
/// effect assets. These fields remain data-only: no provider voice id, credential,
/// script or executable asset is allowed in a character package.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterAction {
    pub animation: String,
    #[serde(default = "default_action_priority")]
    pub priority: String,
    #[serde(default = "default_true")]
    pub interruptible: bool,
    #[serde(default)]
    pub cooldown_ms: u64,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CharacterEntryV3 {
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
    #[serde(default)]
    pub presentation: CharacterPresentation,
    #[serde(default)]
    pub voice_profile: VoiceProfile,
    pub sprites: Vec<Sprite>,
    pub animations: BTreeMap<String, Clip>,
    #[serde(default)]
    pub animation_fallbacks: BTreeMap<String, String>,
    #[serde(default)]
    pub animation_roles: BTreeMap<String, String>,
    #[serde(default)]
    pub actions: BTreeMap<String, CharacterAction>,
    #[serde(default)]
    pub visual_profiles: BTreeMap<String, VisualProfile>,
    #[serde(default)]
    pub audio_profile: AudioProfile,
    #[serde(default)]
    pub effects_profile: EffectsProfile,
    #[serde(default)]
    pub expressions: BTreeMap<String, Expression>,
    #[serde(default)]
    pub authorship: Vec<Authorship>,
}

pub fn parse_v3(json: &[u8]) -> Result<CharacterEntryV3, V3Error> {
    serde_json::from_slice(json).map_err(|error| V3Error::Parse(error.to_string()))
}

pub fn validate_v3(entry: &CharacterEntryV3, declared: &[&str]) -> Result<(), V3Error> {
    if entry.schema != SCHEMA_V3 {
        return Err(V3Error::UnsupportedSchema(entry.schema.clone()));
    }

    let base = CharacterEntryV2 {
        schema: crate::v2::SCHEMA_V2.to_owned(),
        id: entry.id.clone(),
        version: entry.version.clone(),
        name: entry.name.clone(),
        renderer: entry.renderer.clone(),
        runtime_compatibility: entry.runtime_compatibility.clone(),
        capabilities: entry.capabilities.clone(),
        body_profile: entry.body_profile.clone(),
        presentation_profile: entry.presentation_profile.clone(),
        sprites: entry.sprites.clone(),
        animations: entry.animations.clone(),
        animation_fallbacks: entry.animation_fallbacks.clone(),
        visual_profiles: entry.visual_profiles.clone(),
        expressions: entry.expressions.clone(),
        authorship: entry.authorship.clone(),
    };
    validate_v2(&base, declared).map_err(V3Error::Base)?;

    let declared: BTreeSet<&str> = declared.iter().copied().collect();
    for (locale, description) in &entry.presentation.descriptions {
        let locale = locale.trim();
        let description = description.trim();
        if locale.is_empty()
            || locale.len() > 16
            || !locale
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || ch == '-')
        {
            return Err(V3Error::InvalidPresentation(format!(
                "description locale `{locale}` is invalid"
            )));
        }
        if description.is_empty() || description.chars().count() > 1200 {
            return Err(V3Error::InvalidPresentation(format!(
                "description `{locale}` must contain 1-1200 characters"
            )));
        }
    }
    if let Some(preview) = &entry.presentation.preview {
        validate_declared_data_asset(&preview.path, &declared)?;
        let lower = preview.path.to_ascii_lowercase();
        if !(lower.ends_with(".png") || lower.ends_with(".webp")) {
            return Err(V3Error::InvalidPresentation(
                "preview must be a PNG or WebP image".to_owned(),
            ));
        }
    }
    for (animation, thumbnail) in &entry.presentation.animation_thumbnails {
        if animation.trim().is_empty()
            || (!entry.animations.contains_key(animation)
                && !entry.animation_fallbacks.contains_key(animation))
        {
            return Err(V3Error::InvalidPresentation(format!(
                "animation thumbnail `{animation}` must reference a declared animation or fallback alias"
            )));
        }
        validate_declared_data_asset(&thumbnail.path, &declared)?;
        let lower = thumbnail.path.to_ascii_lowercase();
        if !(lower.ends_with(".png") || lower.ends_with(".webp")) {
            return Err(V3Error::InvalidPresentation(format!(
                "animation thumbnail `{animation}` must be a PNG or WebP image"
            )));
        }
    }

    let animation_target_exists = |name: &str| {
        entry.animations.contains_key(name) || entry.animation_fallbacks.contains_key(name)
    };
    for (role, target) in &entry.animation_roles {
        if role.trim().is_empty() || target.trim().is_empty() || !animation_target_exists(target) {
            return Err(V3Error::InvalidAnimationMetadata(format!(
                "animation role `{role}` references unknown animation or fallback `{target}`"
            )));
        }
    }
    for (name, action) in &entry.actions {
        if name.trim().is_empty()
            || action.animation.trim().is_empty()
            || !animation_target_exists(&action.animation)
        {
            return Err(V3Error::InvalidAnimationMetadata(format!(
                "action `{name}` references unknown animation or fallback `{}`",
                action.animation
            )));
        }
        if !matches!(
            action.priority.as_str(),
            "ambient" | "presentation" | "reaction" | "lifecycle"
        ) {
            return Err(V3Error::InvalidAnimationMetadata(format!(
                "action `{name}` has unsupported priority `{}`",
                action.priority
            )));
        }
    }

    let mut audio_ids = BTreeSet::new();
    for clip in &entry.audio_profile.clips {
        if clip.id.trim().is_empty() || !audio_ids.insert(clip.id.as_str()) {
            return Err(V3Error::InvalidAudioProfile(
                "audio clip ids must be non-empty and unique".to_owned(),
            ));
        }
        validate_declared_data_asset(&clip.path, &declared)?;
        let lower = clip.path.to_ascii_lowercase();
        if !(lower.ends_with(".ogg") || lower.ends_with(".wav")) {
            return Err(V3Error::InvalidAudioProfile(format!(
                "audio clip `{}` must be OGG or WAV",
                clip.id
            )));
        }
        if !clip.gain_db.is_finite()
            || !(-60.0..=12.0).contains(&clip.gain_db)
            || !clip.start_seconds.is_finite()
            || clip.start_seconds < 0.0
            || !clip.fade_in_seconds.is_finite()
            || clip.fade_in_seconds < 0.0
            || !clip.fade_out_seconds.is_finite()
            || clip.fade_out_seconds < 0.0
            || clip
                .end_seconds
                .is_some_and(|end| !end.is_finite() || end <= clip.start_seconds)
        {
            return Err(V3Error::InvalidAudioProfile(format!(
                "audio clip `{}` has invalid timing or gain",
                clip.id
            )));
        }
    }
    for (event, binding) in &entry.audio_profile.bindings {
        if event.trim().is_empty() || !audio_ids.contains(binding.clip.as_str()) {
            return Err(V3Error::InvalidAudioProfile(format!(
                "audio binding `{event}` references unknown clip `{}`",
                binding.clip
            )));
        }
    }

    let mut effect_ids = BTreeSet::new();
    for effect in &entry.effects_profile.effects {
        if effect.id.trim().is_empty() || !effect_ids.insert(effect.id.as_str()) {
            return Err(V3Error::InvalidEffectsProfile(
                "effect ids must be non-empty and unique".to_owned(),
            ));
        }
        validate_declared_data_asset(&effect.path, &declared)?;
        let lower = effect.path.to_ascii_lowercase();
        if !(lower.ends_with(".png") || lower.ends_with(".webp")) {
            return Err(V3Error::InvalidEffectsProfile(format!(
                "effect `{}` must be a PNG or WebP sprite sheet",
                effect.id
            )));
        }
        if effect.frame_size[0] == 0
            || effect.frame_size[1] == 0
            || effect.frames == 0
            || effect.frames > 256
            || !effect.fps.is_finite()
            || !(0.1..=60.0).contains(&effect.fps)
            || !effect.scale.is_finite()
            || effect.scale <= 0.0
        {
            return Err(V3Error::InvalidEffectsProfile(format!(
                "effect `{}` has invalid frame metadata",
                effect.id
            )));
        }
    }
    for (event, binding) in &entry.effects_profile.bindings {
        if event.trim().is_empty() || !effect_ids.contains(binding.effect.as_str()) {
            return Err(V3Error::InvalidEffectsProfile(format!(
                "effect binding `{event}` references unknown effect `{}`",
                binding.effect
            )));
        }
    }
    if let Some(teleport) = &entry.effects_profile.teleport {
        if !teleport.scale.is_finite() || teleport.scale <= 0.0 {
            return Err(V3Error::InvalidEffectsProfile(
                "teleport effect scale must be positive".to_owned(),
            ));
        }
        if teleport.mode == TeleportEffectMode::PackageOverride {
            let Some(effect) = teleport.effect.as_deref() else {
                return Err(V3Error::InvalidEffectsProfile(
                    "package-override teleport requires `effect`".to_owned(),
                ));
            };
            if !effect_ids.contains(effect) {
                return Err(V3Error::InvalidEffectsProfile(format!(
                    "teleport references unknown package effect `{effect}`"
                )));
            }
        }
    }

    Ok(())
}

fn validate_declared_data_asset(path: &str, declared: &BTreeSet<&str>) -> Result<(), V3Error> {
    if is_executable(path) {
        return Err(V3Error::ExecutableAsset(path.to_owned()));
    }
    if !declared.contains(path) {
        return Err(V3Error::UndeclaredAsset(path.to_owned()));
    }
    Ok(())
}

impl From<CharacterEntryV3> for ResolvedCharacter {
    fn from(value: CharacterEntryV3) -> Self {
        Self {
            source_schema: value.schema,
            id: Some(value.id),
            version: Some(value.version),
            name: value.name,
            renderer: value.renderer,
            capabilities: value.capabilities,
            body_profile: value.body_profile,
            presentation_profile: value.presentation_profile,
            voice_profile: Some(value.voice_profile),
            presentation: Some(value.presentation),
            audio_profile: Some(value.audio_profile),
            effects_profile: Some(value.effects_profile),
            sprites: value.sprites,
            animations: value.animations,
            animation_fallbacks: value.animation_fallbacks,
            visual_profiles: value.visual_profiles,
            expressions: value.expressions,
            authorship: value.authorship,
        }
    }
}

fn default_action_priority() -> String {
    "presentation".to_owned()
}

fn default_true() -> bool {
    true
}

fn one() -> f32 {
    1.0
}
