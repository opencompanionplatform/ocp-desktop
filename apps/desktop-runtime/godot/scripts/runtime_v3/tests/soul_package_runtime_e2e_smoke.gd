extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const CharacterServiceScript = preload("res://scripts/runtime_v3/services/character_service.gd")
const AutonomousControllerScript = preload("res://scripts/runtime_v3/controllers/autonomous_floor_walk_controller.gd")


func _initialize() -> void:
	call_deferred("_run")


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


func _run() -> void:
	var root := ProjectSettings.globalize_path("user://soul-package-runtime-e2e")
	var assets := root.path_join("assets")
	DirAccess.make_dir_recursive_absolute(assets)

	var soul := {
		"schema": "soul/1",
		"mode": "custom",
		"source": "studio-custom-v1",
		"identity": {
			"name": "Soul E2E",
			"descriptions": {
				"en": "A warm, playful and proactive desktop companion.",
				"th": "เพื่อนคู่ใจที่อบอุ่น ขี้เล่น และกระตือรือร้น",
			},
		},
		"traits": {
			"warmth": 0.9,
			"humor": 0.75,
			"formality": 0.25,
			"initiative": 0.85,
			"energy": 0.8,
			"talkativeness": 0.7,
			"movement": 0.82,
		},
		"speakingStyle": {
			"concise": true,
			"maxSentences": 4,
			"formality": 0.25,
			"humor": 0.75,
			"warmth": 0.9,
		},
		"behavior": {
			"initiative": 0.85,
			"energy": 0.8,
			"movement": 0.82,
			"restSeconds": 16.0,
			"walkSeconds": 13.0,
			"hangSettleSeconds": 0.85,
		},
		"customText": "# Soul E2E\nPlayful and proactive, but never intrusive.",
	}
	var soul_json_path := assets.path_join("soul.json")
	var soul_md_path := assets.path_join("SOUL.md")
	var fixture_written := _write_text(soul_json_path, JSON.stringify(soul, "  ")) \
		and _write_text(soul_md_path, "# Soul E2E\nPlayful and proactive, but never intrusive.\n")

	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var character_service := CharacterServiceScript.new()
	var ai_service := AIServiceScript.new()
	var autonomous := AutonomousControllerScript.new()
	for node in [context, character_service, ai_service, autonomous]:
		holder.add_child(node)
	character_service.context = context
	ai_service.context = context
	autonomous.configure(context, null, null, null)

	var entry := {
		"schema": "character/3",
		"name": "Soul E2E",
		"presentation": {
			"descriptions": {
				"en": "Legacy fallback description",
				"th": "คำอธิบายสำรอง",
			},
		},
	}
	var profile: Dictionary = character_service._soul_profile_from_package(root, entry)
	context.update_character({"soul_profile": profile, "voice_profile": {"thaiSpeechStyle": "neutral"}})
	context.update_settings({"language": "en", "tts_voice_mode": "character"})

	var prompt := ai_service._companion_system_prompt()
	var tuned := autonomous._behavior_profile(0)
	var soul_md_present: bool = FileAccess.file_exists(soul_md_path) \
		and FileAccess.get_file_as_string(soul_md_path).contains("never intrusive")
	var profile_traits_value: Variant = profile.get("traits", {})
	var profile_traits: Dictionary = profile_traits_value if profile_traits_value is Dictionary else {}
	var parse_ok: bool = str(profile.get("schema", "")) == "soul/1" \
		and str(profile.get("mode", "")) == "custom" \
		and is_equal_approx(float(profile_traits.get("warmth", 0.0)), 0.9) \
		and str(profile.get("customText", "")).contains("never intrusive")
	var prompt_ok: bool = prompt.contains("A warm, playful and proactive desktop companion") \
		and prompt.contains("Custom SOUL.md notes") \
		and prompt.contains("never intrusive") \
		and prompt.contains("use 1 to 4 short sentences") \
		and prompt.contains("warmth=0.90")
	var behavior_ok: bool = float(tuned.get("walk_seconds", 0.0)) > 11.0 \
		and float(tuned.get("rest_seconds", 99.0)) < 18.0 \
		and is_equal_approx(float(tuned.get("hang_settle_seconds", 0.0)), 0.85)
	var ok: bool = fixture_written and soul_md_present and parse_ok and prompt_ok and behavior_ok
	print("[SoulPackageE2E] fixture=", fixture_written, " soul_md=", soul_md_present, " parse=", parse_ok, " prompt=", prompt_ok, " behavior=", behavior_ok, " ok=", ok)

	holder.free()
	DirAccess.remove_absolute(soul_json_path)
	DirAccess.remove_absolute(soul_md_path)
	DirAccess.remove_absolute(assets)
	DirAccess.remove_absolute(root)
	quit(0 if ok else 1)
