extends SceneTree

const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")

class FakeEffectPackService:
	extends Node

	func snapshot() -> Dictionary:
		return {
			"installed": [],
			"loadout": {"bodyAura": {"packageId": "effect.video-neon", "version": "1.0.0"}},
			"enabled": {"bodyAura": true, "groundRune": true, "levelUpBurst": true},
			"resolved": {"bodyAura": {"packageId": "effect.video-neon", "version": "1.0.0", "name": "Video Neon FX Pack", "slot": "bodyAura", "config": {"scale": 0.9}}},
			"previewRank": "",
		}

	func resolve_slot(slot_name: String, _include_disabled: bool = false, character_id: String = "") -> Dictionary:
		if slot_name != "bodyAura":
			return {}
		return {
			"packageId": "effect.video-neon",
			"version": "1.0.0",
			"name": "Video Neon FX Pack",
			"slot": slot_name,
			"path": "user://private/path",
			"config": {"scale": 1.18, "_characterProfile": character_id},
		}


class FakeServices:
	extends Node
	var effect_pack_service: Node


func _initialize() -> void:
	var raw := {
		"installed": [{
			"packageId": "effect.video-neon",
			"version": "1.0.0",
			"name": "Video Neon FX Pack",
			"slots": ["bodyAura", "groundRune", "levelUpBurst"],
			"progression": {},
		}],
		"loadout": {
			"bodyAura": {"packageId": "effect.video-neon", "version": "1.0.0"},
		},
		"enabled": {"bodyAura": true, "groundRune": true, "levelUpBurst": true},
		"resolved": {
			"bodyAura": {
				"packageId": "effect.video-neon",
				"version": "1.0.0",
				"name": "Video Neon FX Pack",
				"path": "user://packages/effects/effect.video-neon/1.0.0",
				"slot": "bodyAura",
				"config": {"renderer": "sprite-sheet-2d", "scale": 1.15},
			},
		},
		"previewRank": "",
	}
	var projected: Dictionary = AdapterScript._project_effect_pack_snapshot(raw)
	var resolved: Dictionary = projected.get("resolved", {})
	var aura: Dictionary = resolved.get("bodyAura", {})
	var projection_ok: bool = projected.has("previewRank") \
		and projected.size() == 5 \
		and aura.size() == 5 \
		and not aura.has("path") \
		and aura.get("packageId", "") == "effect.video-neon" \
		and (aura.get("config", {}) as Dictionary).get("scale", 0.0) == 1.15

	var fake_effect := FakeEffectPackService.new()
	var fake_services := FakeServices.new()
	fake_services.effect_pack_service = fake_effect
	root.add_child(fake_effect)
	root.add_child(fake_services)
	var adapter := AdapterScript.new()
	root.add_child(adapter)
	adapter.services = fake_services
	adapter.preview_state = adapter._idle_preview_state()
	adapter.preview_state["packageId"] = "character.sabai-sompoo"
	var preview_snapshot := adapter._effect_pack_snapshot()
	var preview_aura := ((preview_snapshot.get("resolved", {}) as Dictionary).get("bodyAura", {}) as Dictionary)
	var preview_config := preview_aura.get("config", {}) as Dictionary
	var preview_character_ok := is_equal_approx(float(preview_config.get("scale", 0.0)), 1.18) \
		and str(preview_config.get("_characterProfile", "")) == "character.sabai-sompoo" \
		and not preview_aura.has("path")
	var ok := projection_ok and preview_character_ok
	print("[DESKTOP-SHELL-EFFECT-PROJECTION] path_stripped=%s schema_keys=%s preview_character=%s" % [
		str(not aura.has("path")).to_lower(),
		str(projected.size() == 5).to_lower(),
		str(preview_character_ok).to_lower(),
	])
	quit(0 if ok else 1)
