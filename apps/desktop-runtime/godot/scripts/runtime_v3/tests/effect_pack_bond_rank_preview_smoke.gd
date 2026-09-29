extends SceneTree

const EffectPackServiceScript = preload("res://scripts/runtime_v3/services/effect_pack_service.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var service = EffectPackServiceScript.new()
	root.add_child(service)

	var entry := {
		"progression": {
			"mode": "bond-rank",
			"variants": [
				{
					"id": "stranger",
					"minLevel": 1,
					"minBondRank": "stranger",
					"slotOverrides": {"bodyAura": {"tint": "#22D3EE", "intensity": 72}},
				},
				{
					"id": "partner",
					"minLevel": 1,
					"minBondRank": "partner",
					"slotOverrides": {"bodyAura": {"tint": "#C084FC", "intensity": 94}},
				},
				{
					"id": "best-companion",
					"minLevel": 1,
					"minBondRank": "best-companion",
					"slotOverrides": {"bodyAura": {"tint": "#FACC15", "intensity": 100}},
				},
			],
		},
	}

	var partner_ok := service.set_preview_rank("partner")
	var partner_slot := {"tint": "#FFFFFF", "intensity": 50}
	service._apply_progression_variant("bodyAura", entry, partner_slot, "", service.preview_rank())
	partner_ok = partner_ok 		and str(partner_slot.get("tint", "")) == "#C084FC" 		and int(partner_slot.get("intensity", 0)) == 94 		and str(partner_slot.get("_variantId", "")) == "partner"

	var best_ok := service.set_preview_rank("best-companion")
	var best_slot := {"tint": "#FFFFFF", "intensity": 50}
	service._apply_progression_variant("bodyAura", entry, best_slot, "", service.preview_rank())
	best_ok = best_ok 		and str(best_slot.get("tint", "")) == "#FACC15" 		and int(best_slot.get("intensity", 0)) == 100 		and str(best_slot.get("_variantId", "")) == "best-companion"

	var canonical_slot := {"tint": "#FFFFFF", "intensity": 50}
	service._apply_progression_variant("bodyAura", entry, canonical_slot)
	var canonical_isolated := str(canonical_slot.get("tint", "")) == "#22D3EE" and str(canonical_slot.get("_variantId", "")) == "stranger"

	var reset_ok := service.set_preview_rank("") and service.preview_rank().is_empty()
	var invalid_ok := not service.set_preview_rank("legendary")

	var ok := partner_ok and best_ok and canonical_isolated and reset_ok and invalid_ok
	print("[EFFECT-RANK-PREVIEW] partner=%s best=%s canonical_isolated=%s reset=%s invalid_rejected=%s" % [
		str(partner_ok).to_lower(),
		str(best_ok).to_lower(),
		str(canonical_isolated).to_lower(),
		str(reset_ok).to_lower(),
		str(invalid_ok).to_lower(),
	])
	quit(0 if ok else 1)
