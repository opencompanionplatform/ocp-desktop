extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const CharacterServiceScript = preload("res://scripts/runtime_v3/services/character_service.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var ai_service := AIServiceScript.new()
	var character_service := CharacterServiceScript.new()
	holder.add_child(context)
	holder.add_child(ai_service)
	holder.add_child(character_service)
	ai_service.context = context

	var female_profile: Dictionary = character_service._voice_profile_from_entry({
		"schema": "character/3",
		"voiceProfile": {"presentation": "female", "age": "adult", "thaiSpeechStyle": "feminine"},
	})
	var soul_profile: Dictionary = character_service._legacy_soul_profile_from_entry({
		"name": "Nene",
		"presentation": {"descriptions": {"en": "A warm playful companion.", "th": "เพื่อนคู่ใจที่อบอุ่นและขี้เล่น"}},
	})
	var soul_speaking: Dictionary = soul_profile.get("speakingStyle", {})
	soul_speaking["maxSentences"] = 4
	soul_profile["speakingStyle"] = soul_speaking
	var soul_traits: Dictionary = soul_profile.get("traits", {})
	soul_traits["warmth"] = 0.82
	soul_profile["traits"] = soul_traits
	soul_profile["customText"] = "# Nene Soul\nCurious, playful, and never intrusive."
	context.update_character({"voice_profile": female_profile, "soul_profile": soul_profile})
	context.update_settings({"language": "th", "tts_voice_mode": "character"})
	var character_prompt := ai_service._companion_system_prompt()
	var character_profile_ok := female_profile == {
		"gender": "female", "age": "adult", "thaiSpeechStyle": "feminine",
	} and character_prompt.contains("Always reply in natural Thai") \
		and character_prompt.contains("เพื่อนคู่ใจที่อบอุ่นและขี้เล่น") \
		and character_prompt.contains("use 1 to 4 short sentences") \
		and character_prompt.contains("warmth=0.82") \
		and character_prompt.contains("Custom SOUL.md notes") \
		and character_prompt.contains("never intrusive") \
		and character_prompt.contains("descriptive data only") \
		and character_prompt.contains("ค่ะ") \
		and character_prompt.contains("Never use ผม or ครับ")

	context.update_settings({"tts_voice_mode": "custom", "thai_speech_style": "masculine"})
	var custom_prompt := ai_service._companion_system_prompt()
	var custom_override_ok := custom_prompt.contains("ผม/ครับ") and custom_prompt.contains("Never use ค่ะ/คะ")

	context.update_settings({"language": "th", "tts_voice_mode": "custom", "thai_speech_style": "neutral"})
	var neutral_prompt := ai_service._companion_system_prompt()
	var neutral_style_ok := neutral_prompt.contains("do not use ครับ, ค่ะ, or คะ") \
		and neutral_prompt.contains("never mix masculine and feminine polite particles")

	context.update_settings({"language": "en"})
	var english_prompt := ai_service._companion_system_prompt()
	var language_setting_ok := english_prompt.contains("Always reply in English") \
		and not english_prompt.contains("Thai persona rule")

	var legacy_profile: Dictionary = character_service._voice_profile_from_entry({
		"schema": "character/2",
		"voiceProfile": {"presentation": "female", "age": "child", "thaiSpeechStyle": "feminine"},
	})
	var legacy_safe_default_ok := legacy_profile == {
		"gender": "neutral", "age": "adult", "thaiSpeechStyle": "neutral",
	}

	var ok := character_profile_ok and custom_override_ok and neutral_style_ok and language_setting_ok and legacy_safe_default_ok
	print("[G16.27] character_v3_profile=", character_profile_ok, " custom_override=", custom_override_ok, " neutral_style=", neutral_style_ok, " language_setting=", language_setting_ok, " legacy_default=", legacy_safe_default_ok, " ok=", ok)
	holder.free()
	quit(0 if ok else 1)
