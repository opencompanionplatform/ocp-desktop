use ed25519_dalek::SigningKey;
use ocp_character_package::{parse_and_resolve, parse_v2, validate_v2, V2Error};
use ocp_package_builder::{build, AssetInput, BuildRequest, PackageIdentity, PackageType};
use ocp_package_loader::{load, TrustStore};

const V2: &str = r#"{
  "schema": "character/2",
  "id": "character.meowsom",
  "version": "2.0.0",
  "name": "Meowsom",
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
    "collisionHalfExtents": [48, 62],
    "feetAnchor": [0.5, 1.0]
  },
  "presentationProfile": {
    "baseScale": 1.0,
    "minimumUserScale": 0.5,
    "maximumUserScale": 2.0
  },
  "sprites": [{ "id": "body", "path": "assets/meowsom.png", "frameSize": [512, 512] }],
  "animations": {
    "idle": { "sprite": "body", "frames": [0, 1], "fps": 6, "loop": true },
    "climb_up": { "sprite": "body", "frames": [2, 3], "fps": 8, "loop": true }
  },
  "animationFallbacks": { "climb_ready": "climb_up", "wave": "idle" },
  "visualProfiles": {
    "default": {
      "contentBounds": [0.1, 0.05, 0.8, 0.9],
      "hitTestBounds": [0.1, 0.05, 0.8, 0.9],
      "scale": 1.0,
      "offset": [0.0, 0.0],
      "surfaceAnchor": [0.5, 1.0],
      "mirrorPolicy": "surface-normal"
    }
  }
}"#;

const V1: &str = r#"{
  "schema": "character/1",
  "name": "Legacy",
  "renderer": "sprite-sheet-2d",
  "sprites": [{ "id": "body", "path": "assets/legacy.png", "frameSize": [96, 96] }],
  "animations": { "idle": { "sprite": "body", "frames": [0], "fps": 2, "loop": true } }
}"#;

#[test]
fn v2_resolves_semantics_and_deterministic_collision_feet() {
    let resolved = parse_and_resolve(V2.as_bytes(), &["assets/meowsom.png"]).unwrap();
    assert_eq!(resolved.source_schema, "character/2");
    assert!(resolved.capabilities.surface_climb);
    assert_eq!(
        resolved.collision_feet_from_center([640.0, 850.0]),
        [640.0, 912.0]
    );
}

#[test]
fn v1_resolves_without_rewriting_the_legacy_contract() {
    let resolved = parse_and_resolve(V1.as_bytes(), &["assets/legacy.png"]).unwrap();
    assert_eq!(resolved.source_schema, "character/1");
    assert!(resolved.capabilities.basic_walk);
    assert!(!resolved.capabilities.surface_climb);
    assert_eq!(
        resolved.collision_feet_from_center([10.0, 20.0]),
        [10.0, 84.0]
    );
}

#[test]
fn v2_rejects_fallback_cycles() {
    let cyclic = V2.replace(
        "\"climb_ready\": \"climb_up\", \"wave\": \"idle\"",
        "\"climb_ready\": \"wave\", \"wave\": \"climb_ready\"",
    );
    let entry = parse_v2(cyclic.as_bytes()).unwrap();
    assert!(matches!(
        validate_v2(&entry, &["assets/meowsom.png"]),
        Err(V2Error::FallbackCycle(_))
    ));
}

#[test]
fn v2_rejects_collision_larger_than_logical_body() {
    let invalid = V2.replace("[48, 62]", "[65, 62]");
    let entry = parse_v2(invalid.as_bytes()).unwrap();
    assert!(matches!(
        validate_v2(&entry, &["assets/meowsom.png"]),
        Err(V2Error::InvalidBodyProfile(_))
    ));
}

#[test]
fn v2_rejects_unknown_fields_to_remain_data_only_and_strict() {
    let smuggled = V2.replace(
        "\"flight\": false",
        "\"flight\": false, \"script\": \"evil()\"",
    );
    assert!(matches!(
        parse_v2(smuggled.as_bytes()),
        Err(V2Error::Parse(_))
    ));
}

#[test]
fn v2_round_trips_through_the_signed_package_envelope() {
    let key = SigningKey::from_bytes(&[29; 32]);
    let request = BuildRequest {
        identity: PackageIdentity {
            id: "character.meowsom".to_owned(),
            package_type: PackageType::Character,
            version: "2.0.0".to_owned(),
            publisher_id: "ocp.test".to_owned(),
            key_id: "ed25519:character-v2-test".to_owned(),
            license: "Private-Test".to_owned(),
            entry: "assets/character.json".to_owned(),
        },
        asset_paths: vec![
            "assets/character.json".to_owned(),
            "assets/meowsom.png".to_owned(),
        ],
        assets: vec![
            AssetInput {
                path: "assets/character.json".to_owned(),
                bytes: V2.as_bytes().to_vec(),
            },
            AssetInput {
                path: "assets/meowsom.png".to_owned(),
                bytes: b"fixture-png".to_vec(),
            },
        ],
    };
    let archive = build(&request, &key).expect("signed character/2 package builds");
    let mut trust = TrustStore::new();
    trust.add_key("ed25519:character-v2-test", key.verifying_key());
    let loaded = load(&archive, &trust).expect("signed character/2 package loads");
    assert_eq!(loaded.manifest.entry, "assets/character.json");
    let resolved = parse_and_resolve(V2.as_bytes(), &["assets/meowsom.png"]).unwrap();
    assert_eq!(resolved.id.as_deref(), Some("character.meowsom"));
}
