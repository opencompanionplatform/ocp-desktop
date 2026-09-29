extends SceneTree

const EffectPackServiceScript = preload("res://scripts/runtime_v3/services/effect_pack_service.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var service = EffectPackServiceScript.new()
	root.add_child(service)
	service.character_effect_profiles_file = "user://runtime/character_effect_profiles_smoke.json"
	var profile_abs := ProjectSettings.globalize_path(service.character_effect_profiles_file)
	DirAccess.remove_absolute(profile_abs)

	var stranger_ok := service.set_preview_rank("stranger")
	var stranger_slot := {"tint": "#FFFFFF", "intensity": 10, "speedPermille": 900}
	service._apply_standard_rank_palette("bodyAura", stranger_slot)
	stranger_ok = stranger_ok 		and str(stranger_slot.get("tint", "")) == "#22D3EE" 		and int(stranger_slot.get("intensity", 0)) == 70 		and int(stranger_slot.get("speedPermille", 0)) == 1000 		and str(stranger_slot.get("_rankPreset", "")) == "Calm Cyan" 		and bool(stranger_slot.get("_colorize", false))

	var partner_ok := service.set_preview_rank("partner")
	var partner_slot := {}
	service._apply_standard_rank_palette("groundRune", partner_slot)
	partner_ok = partner_ok 		and str(partner_slot.get("tint", "")) == "#D946EF" 		and str(partner_slot.get("_rankPreset", "")) == "Partner Bloom"

	var best_ok := service.set_preview_rank("best-companion")
	var best_slot := {}
	service._apply_standard_rank_palette("levelUpBurst", best_slot)
	best_ok = best_ok 		and str(best_slot.get("tint", "")) == "#FEF3C7" 		and int(best_slot.get("intensity", 0)) == 100 		and str(best_slot.get("_rankPreset", "")) == "Golden Companion"

	var sample_item := {"packageId": "effect.video-neon", "version": "1.0.0"}
	var legacy_aura := {"anchor": "character-center", "scale": 1.15, "offsetY": -6}
	var legacy_rune := {"anchor": "character-feet", "scale": 1.45, "offsetY": -8}
	var legacy_burst := {"anchor": "character-center", "scale": 1.30, "offsetY": -24}
	service._apply_video_neon_v1_placement_compatibility("bodyAura", sample_item, legacy_aura)
	service._apply_video_neon_v1_placement_compatibility("groundRune", sample_item, legacy_rune)
	service._apply_video_neon_v1_placement_compatibility("levelUpBurst", sample_item, legacy_burst)
	var sample_compat_ok := is_equal_approx(float(legacy_aura.get("scale", 0.0)), 1.12) \
		and is_equal_approx(float(legacy_rune.get("scale", 0.0)), 1.40) \
		and int(legacy_rune.get("offsetY", -1)) == 0 \
		and str(legacy_burst.get("anchor", "")) == "character-feet-bottom" \
		and is_equal_approx(float(legacy_burst.get("scale", 0.0)), 1.10) \
		and int(legacy_burst.get("offsetY", -1)) == 0

	var save_result := service.save_character_profile("character.sabai-sompoo", "groundRune", {
		"fps": 12,
		"startFrame": 3,
		"endFrame": 35,
		"scale": 1.18,
		"offsetX": 2,
		"offsetY": -4,
		"anchor": "character-feet",
		"scaleMode": "character-width",
	})
	var invalid_save := service.save_character_profile("../unsafe", "groundRune", {"scale": 1.0})
	var invalid_id_ok := not bool(invalid_save.get("ok", false))
	var profile := service.character_profile("character.sabai-sompoo")
	var slots := profile.get("slots", {}) as Dictionary
	var saved := slots.get("groundRune", {}) as Dictionary
	var reload_service = EffectPackServiceScript.new()
	root.add_child(reload_service)
	reload_service.character_effect_profiles_file = service.character_effect_profiles_file
	var reloaded := reload_service.character_profile("character.sabai-sompoo")
	var reloaded_slot := (reloaded.get("slots", {}) as Dictionary).get("groundRune", {}) as Dictionary
	var persistence_ok := bool(save_result.get("ok", false)) 		and is_equal_approx(float(saved.get("scale", 0.0)), 1.18) 		and int(saved.get("startFrame", -1)) == 3 		and int(saved.get("endFrame", -1)) == 35 		and int(saved.get("offsetY", 0)) == -4 		and is_equal_approx(float(reloaded_slot.get("scale", 0.0)), 1.18)

	service.set_preview_rank("friend")
	var merged := {"scale": 1.45, "offsetY": -8}
	service._apply_standard_rank_palette("groundRune", merged)
	service._apply_character_profile("character.sabai-sompoo", "groundRune", merged)
	var merge_order_ok := str(merged.get("tint", "")) == "#60A5FA" 		and str(merged.get("_rankPreset", "")) == "Friendly Blue" 		and is_equal_approx(float(merged.get("scale", 0.0)), 1.18) 		and int(merged.get("offsetY", 0)) == -4 		and str(merged.get("_characterProfile", "")) == "character.sabai-sompoo"

	var reset_result := service.reset_character_profile("character.sabai-sompoo", "groundRune")
	var reset_ok := bool(reset_result.get("ok", false)) 		and service.character_profile("character.sabai-sompoo").is_empty()
	DirAccess.remove_absolute(profile_abs)

	var ok := stranger_ok and partner_ok and best_ok and sample_compat_ok and invalid_id_ok and persistence_ok and merge_order_ok and reset_ok
	print("[EFFECT-CHARACTER-PROFILE] stranger=%s partner=%s best=%s invalid_id=%s persistence=%s merge=%s reset=%s ok=%s" % [
		str(stranger_ok).to_lower(),
		str(partner_ok).to_lower(),
		str(best_ok).to_lower(),
		str(invalid_id_ok).to_lower(),
		str(persistence_ok).to_lower(),
		str(merge_order_ok).to_lower(),
		str(reset_ok).to_lower(),
		str(ok).to_lower(),
	])
	quit(0 if ok else 1)
