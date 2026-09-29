use ocp_character_package::{
    parse_and_resolve, parse_v2, parse_v3, validate_v3, EffectAnchor, TeleportEffectMode,
    ThaiSpeechStyle, VoiceAgeGroup, VoiceGender,
};

const V3: &str = r#"{
  "schema": "character/3",
  "id": "character.sabai_sompoo",
  "version": "1.0.0",
  "name": "Sabai Sompoo",
  "renderer": "sprite-sheet-2d",
  "runtimeCompatibility": { "minimumRuntimeVersion": "0.1.0" },
  "capabilities": {
    "basicWalk": true,
    "jump": true,
    "surfaceSit": true,
    "surfaceClimb": true,
    "topHang": true,
    "flight": false
  },
  "bodyProfile": {
    "logicalSize": [128, 128],
    "collisionHalfExtents": [42, 62],
    "feetAnchor": [0.5, 1.0]
  },
  "presentationProfile": {
    "baseScale": 0.7,
    "minimumUserScale": 0.5,
    "maximumUserScale": 2.0
  },
  "presentation": {
    "descriptions": { "en": "A calm desktop companion.", "th": "เพื่อนคู่หูบนเดสก์ท็อปที่ใจเย็น" },
    "preview": { "path": "assets/preview.png" },
    "animationThumbnails": {
      "idle": { "path": "assets/thumbnails/idle.png" },
      "idle_neutral": { "path": "assets/thumbnails/idle_neutral.png" }
    }
  },
  "voiceProfile": {
    "presentation": "female",
    "age": "adult",
    "thaiSpeechStyle": "feminine"
  },
  "sprites": [{ "id": "idle", "path": "assets/idle.png", "frameSize": [512, 512] }],
  "animations": {
    "idle": { "sprite": "idle", "frames": [0, 1, 2, 3], "fps": 8, "loop": true }
  },
  "animationFallbacks": { "idle_neutral": "idle" },
  "visualProfiles": {
    "default": {
      "contentBounds": [0.0, 0.0, 1.0, 1.0],
      "hitTestBounds": [0.0, 0.0, 1.0, 1.0],
      "scale": 1.0,
      "offset": [0.0, 0.0],
      "mirrorPolicy": "facing",
      "mirrorSafe": false
    }
  },
  "audioProfile": {
    "clips": [
      {
        "id": "happy",
        "path": "assets/audio/happy.wav",
        "loop": false,
        "gainDb": -3,
        "startSeconds": 0.0,
        "endSeconds": 1.5,
        "fadeInSeconds": 0.02,
        "fadeOutSeconds": 0.1
      }
    ],
    "bindings": {
      "happy": { "clip": "happy", "start": "animation-start" }
    }
  },
  "effectsProfile": {
    "effects": [
      {
        "id": "aura",
        "type": "sprite-sheet",
        "path": "assets/effects/aura.png",
        "frameSize": [512, 512],
        "fps": 12,
        "frames": 24,
        "loop": true,
        "layer": "behind-character",
        "anchor": "body-center",
        "scale": 1.0,
        "offset": [0, 0]
      }
    ],
    "bindings": {
      "aura": { "effect": "aura" }
    },
    "teleport": {
      "mode": "runtime-default",
      "effectId": "portal.blue",
      "anchor": "below-feet",
      "scale": 1.0,
      "offset": [0, 0]
    }
  }
}"#;

fn declared() -> Vec<&'static str> {
    vec![
        "assets/preview.png",
        "assets/thumbnails/idle.png",
        "assets/thumbnails/idle_neutral.png",
        "assets/idle.png",
        "assets/audio/happy.wav",
        "assets/effects/aura.png",
    ]
}

#[test]
fn v3_accepts_voice_preview_audio_and_effect_profiles() {
    let entry = parse_v3(V3.as_bytes()).expect("character/3 parses");
    validate_v3(&entry, &declared()).expect("character/3 validates");
    assert_eq!(entry.visual_profiles["default"].mirror_safe, Some(false));
    let resolved = parse_and_resolve(V3.as_bytes(), &declared()).unwrap();
    let profile = resolved.voice_profile.expect("voice profile resolved");
    assert_eq!(profile.presentation, VoiceGender::Female);
    assert_eq!(profile.age, VoiceAgeGroup::Adult);
    assert_eq!(profile.thai_speech_style, ThaiSpeechStyle::Feminine);
    let presentation = resolved.presentation.expect("presentation resolved");
    assert_eq!(presentation.descriptions["en"], "A calm desktop companion.");
    assert_eq!(presentation.descriptions["th"], "เพื่อนคู่หูบนเดสก์ท็อปที่ใจเย็น");
    assert_eq!(presentation.preview.unwrap().path, "assets/preview.png");
    assert_eq!(
        presentation.animation_thumbnails["idle"].path,
        "assets/thumbnails/idle.png"
    );
    assert_eq!(
        presentation.animation_thumbnails["idle_neutral"].path,
        "assets/thumbnails/idle_neutral.png"
    );
    let audio = resolved.audio_profile.expect("audio profile resolved");
    assert_eq!(audio.clips[0].id, "happy");
    let effects = resolved.effects_profile.expect("effects profile resolved");
    let teleport = effects.teleport.expect("teleport profile resolved");
    assert_eq!(teleport.mode, TeleportEffectMode::RuntimeDefault);
    assert_eq!(teleport.anchor, EffectAnchor::BelowFeet);
}

#[test]
fn v3_accepts_webp_sprites_and_ogg_sfx() {
    let optimized = V3
        .replace("assets/idle.png", "assets/idle.webp")
        .replace("assets/preview.png", "assets/preview.webp")
        .replace("assets/audio/happy.wav", "assets/audio/happy.ogg");
    let entry = parse_v3(optimized.as_bytes()).expect("optimized character/3 parses");
    validate_v3(
        &entry,
        &[
            "assets/preview.webp",
            "assets/thumbnails/idle.png",
            "assets/thumbnails/idle_neutral.png",
            "assets/idle.webp",
            "assets/audio/happy.ogg",
            "assets/effects/aura.png",
        ],
    )
    .expect("webp/ogg character/3 validates");
}

#[test]
fn character_2_stays_strict_and_rejects_v3_fields() {
    let minimal_v2 = r#"{
      "schema":"character/2",
      "id":"character.test",
      "version":"1.0.0",
      "name":"Test",
      "renderer":"sprite-sheet-2d",
      "runtimeCompatibility":{"minimumRuntimeVersion":"0.1.0"},
      "bodyProfile":{"logicalSize":[128,128],"collisionHalfExtents":[42,62],"feetAnchor":[0.5,1.0]},
      "sprites":[{"id":"idle","path":"assets/idle.png","frameSize":[512,512]}],
      "animations":{"idle":{"sprite":"idle","frames":[0],"fps":8,"loop":true}}
    }"#;
    assert!(parse_v2(minimal_v2.as_bytes()).is_ok());

    let illegal_v2 = minimal_v2.replace(
        "\"sprites\"",
        "\"presentation\":{\"preview\":{\"path\":\"assets/preview.png\"}},\"sprites\"",
    );
    assert!(parse_v2(illegal_v2.as_bytes()).is_err());
}

#[test]
fn v3_rejects_unknown_voice_enum_values() {
    let invalid = V3.replace("\"age\": \"adult\"", "\"age\": \"ancient\"");
    assert!(parse_v3(invalid.as_bytes()).is_err());
}

#[test]
fn v3_rejects_undeclared_preview_audio_or_effect_assets() {
    let entry = parse_v3(V3.as_bytes()).unwrap();
    assert!(validate_v3(&entry, &["assets/idle.png"]).is_err());
}

#[test]
fn v3_keeps_animation_thumbnails_optional_for_older_character_3_packages() {
    let legacy = V3.replace(
        ",\n    \"animationThumbnails\": {\n      \"idle\": { \"path\": \"assets/thumbnails/idle.png\" },\n      \"idle_neutral\": { \"path\": \"assets/thumbnails/idle_neutral.png\" }\n    }",
        "",
    );
    let entry = parse_v3(legacy.as_bytes()).expect("legacy character/3 parses");
    validate_v3(
        &entry,
        &[
            "assets/preview.png",
            "assets/idle.png",
            "assets/audio/happy.wav",
            "assets/effects/aura.png",
        ],
    )
    .expect("legacy character/3 without thumbnails remains valid");
    assert!(entry.presentation.animation_thumbnails.is_empty());
}

#[test]
fn v3_rejects_animation_thumbnail_for_unknown_logical_animation() {
    let invalid = V3.replace(
        "\"idle_neutral\": { \"path\": \"assets/thumbnails/idle_neutral.png\" }",
        "\"dance\": { \"path\": \"assets/thumbnails/idle_neutral.png\" }",
    );
    let entry = parse_v3(invalid.as_bytes()).unwrap();
    assert!(validate_v3(&entry, &declared()).is_err());
}

#[test]
fn v3_rejects_unknown_audio_binding_clip() {
    let invalid = V3.replace("\"clip\": \"happy\"", "\"clip\": \"missing\"");
    let entry = parse_v3(invalid.as_bytes()).unwrap();
    assert!(validate_v3(&entry, &declared()).is_err());
}

#[test]
fn package_override_teleport_requires_a_declared_package_effect() {
    let invalid = V3
        .replace(
            "\"mode\": \"runtime-default\"",
            "\"mode\": \"package-override\"",
        )
        .replace(
            "\"effectId\": \"portal.blue\",",
            "\"effect\": \"missing-portal\",",
        );
    let entry = parse_v3(invalid.as_bytes()).unwrap();
    assert!(validate_v3(&entry, &declared()).is_err());
}

#[test]
fn v3_accepts_animation_roles_and_declarative_actions() {
    let extended = V3.replace(
        "\"animationFallbacks\": { \"idle_neutral\": \"idle\" },",
        "\"animationFallbacks\": { \"idle_neutral\": \"idle\", \"hang_left\": \"idle\" },\n  \"animationRoles\": { \"hang.left\": \"hang_left\", \"drag.hold\": \"idle\" },\n  \"actions\": { \"charge_power\": { \"animation\": \"idle\", \"priority\": \"presentation\", \"interruptible\": true, \"cooldownMs\": 2500 } },",
    );
    let entry = parse_v3(extended.as_bytes()).expect("animation metadata parses");
    validate_v3(&entry, &declared()).expect("animation metadata validates");
    assert_eq!(entry.animation_roles["hang.left"], "hang_left");
    assert_eq!(entry.actions["charge_power"].animation, "idle");
    assert_eq!(entry.actions["charge_power"].cooldown_ms, 2500);
}

#[test]
fn v3_rejects_animation_role_with_unknown_target() {
    let invalid = V3.replace(
        "\"animationFallbacks\": { \"idle_neutral\": \"idle\" },",
        "\"animationFallbacks\": { \"idle_neutral\": \"idle\" },\n  \"animationRoles\": { \"hang.left\": \"missing_animation\" },",
    );
    let entry = parse_v3(invalid.as_bytes()).unwrap();
    assert!(validate_v3(&entry, &declared()).is_err());
}

#[test]
fn v3_rejects_action_with_unknown_animation() {
    let invalid = V3.replace(
        "\"animationFallbacks\": { \"idle_neutral\": \"idle\" },",
        "\"animationFallbacks\": { \"idle_neutral\": \"idle\" },\n  \"actions\": { \"bomb_drop\": { \"animation\": \"missing_animation\" } },",
    );
    let entry = parse_v3(invalid.as_bytes()).unwrap();
    assert!(validate_v3(&entry, &declared()).is_err());
}
