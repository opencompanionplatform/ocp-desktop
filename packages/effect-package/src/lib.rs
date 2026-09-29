//! Data-only visual effect package contract.
//! Effect packs never contain executable code. Runtime renders a bounded set
//! of built-in renderer presets from declarative JSON.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SCHEMA_VERSION: &str = "1.0";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EffectPackEntry {
    pub schema_version: String,
    pub id: String,
    pub name: String,
    pub version: String,
    pub slots: EffectSlots,
    #[serde(default)]
    pub progression: Option<ProgressionStyle>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EffectSlots {
    #[serde(default)]
    pub body_aura: Option<EffectSlot>,
    #[serde(default)]
    pub ground_rune: Option<EffectSlot>,
    #[serde(default)]
    pub level_up_burst: Option<EffectSlot>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EffectSlot {
    pub renderer: Renderer,
    pub anchor: Anchor,
    pub layer: Layer,
    pub looped: bool,
    pub fps: u16,
    pub duration_ms: u32,
    pub intensity: u8,
    pub speed_permille: u16,
    pub tint: String,
    #[serde(default)]
    pub scale_mode: Option<ScaleMode>,
    #[serde(default)]
    pub scale: Option<f64>,
    #[serde(default)]
    pub offset_x: Option<f64>,
    #[serde(default)]
    pub offset_y: Option<f64>,
    #[serde(default)]
    pub z_index: Option<i32>,
    #[serde(default)]
    pub max_height_ratio: Option<f64>,
    #[serde(default)]
    pub content_bounds: Option<ContentBounds>,
    #[serde(default)]
    pub preset: Option<String>,
    #[serde(default)]
    pub asset: Option<String>,
    #[serde(default)]
    pub frame_width: Option<u32>,
    #[serde(default)]
    pub frame_height: Option<u32>,
    #[serde(default)]
    pub frame_count: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Renderer {
    ProceduralRingsV1,
    SpriteSheet2d,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Anchor {
    CharacterCenter,
    CharacterFeet,
    CharacterFeetBottom,
    CharacterAboveHead,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ScaleMode {
    CharacterWidth,
    CharacterHeight,
    NativeSurface,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ContentBounds {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Layer {
    FrontFx,
    BackAura,
    GroundRune,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProgressionStyle {
    pub mode: ProgressionMode,
    #[serde(default)]
    pub variants: Vec<ProgressionVariant>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum ProgressionMode {
    None,
    Level,
    BondRank,
    LevelAndBond,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProgressionVariant {
    pub id: String,
    pub min_level: u16,
    pub min_bond_rank: BondRank,
    #[serde(default)]
    pub slot_overrides: BTreeMap<String, SlotStyleOverride>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "kebab-case")]
pub enum BondRank {
    Stranger,
    Friend,
    CloseFriend,
    Partner,
    BestCompanion,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SlotStyleOverride {
    #[serde(default)]
    pub tint: Option<String>,
    #[serde(default)]
    pub intensity: Option<u8>,
    #[serde(default)]
    pub speed_permille: Option<u16>,
    #[serde(default)]
    pub preset: Option<String>,
}

pub fn parse_and_validate(
    bytes: &[u8],
    package_id: &str,
    package_version: &str,
    declared_assets: &[&str],
) -> Result<EffectPackEntry, String> {
    let entry: EffectPackEntry =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid effect entry: {e}"))?;
    validate(&entry, package_id, package_version, declared_assets)?;
    Ok(entry)
}

pub fn validate(
    entry: &EffectPackEntry,
    package_id: &str,
    package_version: &str,
    declared_assets: &[&str],
) -> Result<(), String> {
    if entry.schema_version != SCHEMA_VERSION {
        return Err("unsupported effect-pack schemaVersion".into());
    }
    if entry.id != package_id || entry.version != package_version {
        return Err("effect-pack entry identity does not match manifest".into());
    }
    if entry.name.trim().is_empty() || entry.name.chars().count() > 120 {
        return Err("effect-pack name is invalid".into());
    }

    let slots = [
        ("bodyAura", entry.slots.body_aura.as_ref()),
        ("groundRune", entry.slots.ground_rune.as_ref()),
        ("levelUpBurst", entry.slots.level_up_burst.as_ref()),
    ];
    if slots.iter().all(|(_, slot)| slot.is_none()) {
        return Err("effect-pack must define at least one slot".into());
    }
    for (name, slot) in slots {
        if let Some(slot) = slot {
            validate_slot(name, slot, declared_assets)?;
        }
    }

    if let Some(progression) = &entry.progression {
        if progression.variants.len() > 16 {
            return Err("effect-pack progression has too many variants".into());
        }
        let mut previous_level = 0;
        for variant in &progression.variants {
            if variant.id.trim().is_empty() || variant.id.len() > 64 {
                return Err("effect-pack progression variant id is invalid".into());
            }
            if variant.min_level == 0
                || variant.min_level > 200
                || variant.min_level < previous_level
            {
                return Err("effect-pack progression minLevel is invalid".into());
            }
            previous_level = variant.min_level;
            for (slot_name, style) in &variant.slot_overrides {
                if !matches!(
                    slot_name.as_str(),
                    "bodyAura" | "groundRune" | "levelUpBurst"
                ) {
                    return Err("effect-pack progression references unknown slot".into());
                }
                validate_override(style)?;
            }
        }
    }
    Ok(())
}

fn validate_slot(name: &str, slot: &EffectSlot, declared_assets: &[&str]) -> Result<(), String> {
    if !(1..=60).contains(&slot.fps)
        || !(100..=30_000).contains(&slot.duration_ms)
        || slot.intensity > 100
        || !(100..=3_000).contains(&slot.speed_permille)
        || !valid_color(&slot.tint)
    {
        return Err(format!("effect-pack slot {name} timing/style is invalid"));
    }
    if slot
        .scale
        .is_some_and(|value| !value.is_finite() || !(0.1..=4.0).contains(&value))
        || slot
            .offset_x
            .is_some_and(|value| !value.is_finite() || value.abs() > 512.0)
        || slot
            .offset_y
            .is_some_and(|value| !value.is_finite() || value.abs() > 512.0)
        || slot
            .z_index
            .is_some_and(|value| !(-100..=100).contains(&value))
        || slot
            .max_height_ratio
            .is_some_and(|value| !value.is_finite() || !(0.1..=3.0).contains(&value))
    {
        return Err(format!("effect-pack slot {name} placement is invalid"));
    }

    match slot.renderer {
        Renderer::ProceduralRingsV1 => {
            if slot.asset.is_some()
                || slot.frame_width.is_some()
                || slot.frame_height.is_some()
                || slot.frame_count.is_some()
                || slot.content_bounds.is_some()
            {
                return Err(format!(
                    "procedural slot {name} cannot declare sprite fields"
                ));
            }
            let preset = slot.preset.as_deref().unwrap_or("");
            if !matches!(preset, "halo" | "rune" | "burst") {
                return Err(format!("effect-pack slot {name} has unsupported preset"));
            }
        }
        Renderer::SpriteSheet2d => {
            let asset = slot
                .asset
                .as_deref()
                .ok_or_else(|| format!("sprite slot {name} is missing asset"))?;
            if !asset.starts_with("assets/") || !declared_assets.contains(&asset) {
                return Err(format!("sprite slot {name} references undeclared asset"));
            }
            let width = slot.frame_width.unwrap_or(0);
            let height = slot.frame_height.unwrap_or(0);
            let count = slot.frame_count.unwrap_or(0);
            if width == 0
                || height == 0
                || width > 2048
                || height > 2048
                || count == 0
                || count > 120
            {
                return Err(format!("sprite slot {name} frame metadata is invalid"));
            }
            let authored_rgba_bytes = u64::from(width)
                .saturating_mul(u64::from(height))
                .saturating_mul(u64::from(count))
                .saturating_mul(4);
            if authored_rgba_bytes > 256 * 1024 * 1024 {
                return Err(format!("sprite slot {name} exceeds decoded memory budget"));
            }
            if let Some(bounds) = &slot.content_bounds {
                let x2 = bounds.x.checked_add(bounds.width);
                let y2 = bounds.y.checked_add(bounds.height);
                if bounds.width == 0
                    || bounds.height == 0
                    || x2.is_none_or(|value| value > width)
                    || y2.is_none_or(|value| value > height)
                {
                    return Err(format!("sprite slot {name} content bounds are invalid"));
                }
            }
            if slot.preset.is_some() {
                return Err(format!(
                    "sprite slot {name} cannot declare procedural preset"
                ));
            }
        }
    }
    Ok(())
}

fn validate_override(value: &SlotStyleOverride) -> Result<(), String> {
    if value.tint.as_deref().is_some_and(|v| !valid_color(v))
        || value.intensity.is_some_and(|v| v > 100)
        || value
            .speed_permille
            .is_some_and(|v| !(100..=3_000).contains(&v))
        || value
            .preset
            .as_deref()
            .is_some_and(|v| !matches!(v, "halo" | "rune" | "burst"))
    {
        return Err("effect-pack progression override is invalid".into());
    }
    Ok(())
}

fn valid_color(value: &str) -> bool {
    let bytes = value.as_bytes();
    (bytes.len() == 7 || bytes.len() == 9)
        && bytes.first() == Some(&b'#')
        && bytes[1..].iter().all(u8::is_ascii_hexdigit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry() -> EffectPackEntry {
        serde_json::from_value(serde_json::json!({
            "schemaVersion":"1.0",
            "id":"effect.starter-neon",
            "name":"OCP Starter FX",
            "version":"1.0.0",
            "slots":{
                "bodyAura":{
                    "renderer":"procedural-rings-v1",
                    "anchor":"character-center",
                    "layer":"back-aura",
                    "looped":true,
                    "fps":30,
                    "durationMs":4000,
                    "intensity":70,
                    "speedPermille":600,
                    "tint":"#22D3EE",
                    "preset":"halo"
                },
                "groundRune":{
                    "renderer":"procedural-rings-v1",
                    "anchor":"character-feet",
                    "layer":"ground-rune",
                    "looped":true,
                    "fps":30,
                    "durationMs":5000,
                    "intensity":80,
                    "speedPermille":500,
                    "tint":"#38BDF8",
                    "preset":"rune"
                },
                "levelUpBurst":{
                    "renderer":"procedural-rings-v1",
                    "anchor":"character-above-head",
                    "layer":"front-fx",
                    "looped":false,
                    "fps":30,
                    "durationMs":1400,
                    "intensity":100,
                    "speedPermille":1000,
                    "tint":"#FACC15",
                    "preset":"burst"
                }
            },
            "progression":{
                "mode":"bond-rank",
                "variants":[
                    {"id":"stranger","minLevel":1,"minBondRank":"stranger","slotOverrides":{}},
                    {"id":"partner","minLevel":1,"minBondRank":"partner","slotOverrides":{"bodyAura":{"tint":"#C084FC","intensity":90}}}
                ]
            }
        })).unwrap()
    }

    #[test]
    fn starter_contract_is_valid() {
        validate(&entry(), "effect.starter-neon", "1.0.0", &[]).unwrap();
    }

    #[test]
    fn character_feet_bottom_anchor_matches_runtime_contract() {
        let mut value = serde_json::to_value(entry()).unwrap();
        value["slots"]["levelUpBurst"]["anchor"] = serde_json::json!("character-feet-bottom");
        value["slots"]["levelUpBurst"]["scaleMode"] = serde_json::json!("character-height");
        value["slots"]["levelUpBurst"]["scale"] = serde_json::json!(1.05);
        value["slots"]["levelUpBurst"]["offsetX"] = serde_json::json!(0);
        value["slots"]["levelUpBurst"]["offsetY"] = serde_json::json!(0);
        value["slots"]["levelUpBurst"]["zIndex"] = serde_json::json!(30);
        value["slots"]["levelUpBurst"]["maxHeightRatio"] = serde_json::json!(1.6);
        let parsed: EffectPackEntry = serde_json::from_value(value).unwrap();
        assert_eq!(
            parsed.slots.level_up_burst.as_ref().unwrap().anchor,
            Anchor::CharacterFeetBottom
        );
        validate(&parsed, "effect.starter-neon", "1.0.0", &[]).unwrap();
    }

    #[test]
    fn executable_or_unknown_renderer_is_rejected() {
        let mut value = serde_json::to_value(entry()).unwrap();
        value["slots"]["bodyAura"]["renderer"] = serde_json::json!("script");
        assert!(serde_json::from_value::<EffectPackEntry>(value).is_err());
    }

    #[test]
    fn progression_level_is_bounded() {
        let mut value = entry();
        value.progression.as_mut().unwrap().variants[0].min_level = 201;
        assert!(validate(&value, "effect.starter-neon", "1.0.0", &[]).is_err());
    }
}
