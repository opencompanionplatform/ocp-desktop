extends SceneTree

const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const EffectControllerScript = preload("res://scripts/runtime_v3/controllers/effect_controller.gd")

class FakeContext:
	extends Node
	var settings := {"progression_aura_enabled": true, "reduce_motion": false}
	var character := {"id": "character.bible"}

class FakeProgression:
	extends Node
	var rank := "partner"
	func canonical_projection() -> Dictionary:
		return {
			"revision": 7,
			"levelCap": 200,
			"companions": [{
				"companionId": "companion.bible",
				"characterId": "character.bible",
				"relationship": {
					"level": 12,
					"xp": 100,
					"bondRank": rank,
					"currentLevelXp": 0,
					"nextLevelXp": 200,
					"progressPermille": 500,
				},
				"skills": [],
			}],
		}

class FakeEffectPackService:
	extends Node
	var aura_enabled := true

	func resolve_slot(slot_name: String, _include_disabled: bool = false, _character_id: String = "") -> Dictionary:
		if slot_name == "bodyAura":
			if not aura_enabled:
				return {}
			return {
				"packageId": "effect.starter-neon",
				"version": "1.0.0",
				"path": "user://effect-starter",
				"config": {
					"renderer": "procedural-rings-v1",
					"preset": "halo",
					"tint": "#C084FC",
					"intensity": 90,
					"speedPermille": 720,
				},
			}
		if slot_name == "levelUpBurst":
			return {
				"packageId": "effect.starter-neon",
				"version": "1.0.0",
				"path": "user://effect-starter",
				"config": {
					"renderer": "procedural-rings-v1",
					"preset": "burst",
					"anchor": "character-feet-bottom",
					"scaleMode": "character-height",
					"scale": 1.05,
					"offsetX": 0,
					"offsetY": 0,
					"tint": "#FACC15",
					"intensity": 100,
					"speedPermille": 1000,
				},
			}
		return {}


class FakeServices:
	extends Node
	var cloud_progression_service: Node
	var effect_pack_service: Node

class FakeMachine:
	extends Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var context := FakeContext.new()
	var bus := EventBusScript.new()
	var progression := FakeProgression.new()
	var services := FakeServices.new()
	var effect_pack := FakeEffectPackService.new()
	services.cloud_progression_service = progression
	services.effect_pack_service = effect_pack
	var machine := FakeMachine.new()
	var host := Control.new()
	host.size = Vector2(384, 384)
	var sprite := AnimatedSprite2D.new()
	sprite.position = Vector2(192, 210)
	var controller := EffectControllerScript.new()
	for node in [context, bus, progression, effect_pack, services, machine, host, sprite, controller]:
		root.add_child(node)

	controller.configure(context, bus, services, machine)
	controller.bind_effect_layer(host, sprite)
	controller.start()
	await process_frame
	controller._refresh_relationship_aura()

	var aura := controller.relationship_aura
	var aura_layer := host.get_node_or_null("BackBodyEffects")
	var built_ok := is_instance_valid(aura) \
		and aura.get_parent() == aura_layer \
		and aura.get_child_count() == 2 \
		and controller.relationship_aura_rank == "partner"
	var aura_position := (aura as Node2D).position if built_ok else Vector2.ZERO
	var position_ok := built_ok \
		and aura_position.x >= 124.0 and aura_position.x <= host.size.x - 124.0 \
		and aura_position.y >= 128.0 and aura_position.y <= host.size.y - 128.0

	bus.publish(&"progression.celebration_shown", {"characterId": "character.bible", "toLevel": 12})
	await process_frame
	var pulse_ok := is_instance_valid(controller.relationship_aura)

	# Regression: the Effect Pack slot checkbox must be authoritative. Before
	# this fix an empty bodyAura resolution fell through to the legacy procedural
	# fallback, so Aura could never actually be switched off.
	effect_pack.aura_enabled = false
	bus.publish(&"effect_pack.changed", {"reason": "slot-enabled"})
	await process_frame
	var disabled_ok := not is_instance_valid(controller.relationship_aura)

	effect_pack.aura_enabled = true
	progression.rank = "best-companion"
	bus.publish(&"cloud.progression.updated", progression.canonical_projection())
	await process_frame
	var rank_refresh_ok := is_instance_valid(controller.relationship_aura) and controller.relationship_aura_rank == "best-companion"

	controller._play_equipped_level_up_burst()
	var burst := controller.level_up_burst
	var burst_position := (burst as Node2D).position if is_instance_valid(burst) else Vector2.ZERO
	var expected_feet_y := controller._character_visual_rect().end.y
	var burst_ground_ok := is_instance_valid(burst) \
		and burst.get_child_count() == 13 \
		and absf(burst_position.x - controller._character_visual_rect().get_center().x) <= 0.5 \
		and absf(burst_position.y - expected_feet_y) <= 0.5

	var ok := built_ok and position_ok and pulse_ok and disabled_ok and rank_refresh_ok and burst_ground_ok
	print("[PROGRESSION-EFFECTS] aura=%s position=%s pulse=%s disabled=%s rank_refresh=%s burst_ground=%s" % [
		str(built_ok).to_lower(),
		str(position_ok).to_lower(),
		str(pulse_ok).to_lower(),
		str(disabled_ok).to_lower(),
		str(rank_refresh_ok).to_lower(),
		str(burst_ground_ok).to_lower(),
	])
	controller.stop()
	quit(0 if ok else 1)
