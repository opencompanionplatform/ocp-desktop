extends SceneTree

const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ProgressionServiceScript = preload("res://scripts/runtime_v3/services/cloud_progression_service.gd")
const CelebrationScript = preload("res://scripts/runtime_v3/controllers/progression_celebration_controller.gd")

class FakeContext:
	extends Node
	var settings := {"reduce_motion": false, "progression_level_up_enabled": true}

class FakeServices:
	extends Node

class FakeMachine:
	extends Node

var _published: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _capture(topic: StringName, payload: Dictionary) -> void:
	_published.append({"topic": String(topic), "payload": payload.duplicate(true)})


func _run() -> void:
	var context := FakeContext.new()
	var bus := EventBusScript.new()
	var services := FakeServices.new()
	var machine := FakeMachine.new()
	var progression := ProgressionServiceScript.new()
	var celebration := CelebrationScript.new()
	var host := Control.new()
	host.size = Vector2(384, 384)
	var sprite := AnimatedSprite2D.new()
	sprite.position = Vector2(192, 205)
	for node in [context, bus, services, machine, progression, celebration, host, sprite]:
		root.add_child(node)

	bus.event_published.connect(_capture)
	progression.configure(context, bus)
	celebration.configure(context, bus, services, machine)
	celebration.bind_character(host, sprite)
	celebration.start()

	var companion_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d21"
	var initial := {
		"revision": 1,
		"levelCap": 200,
		"companions": [{
			"companionId": companion_id,
			"characterId": "character.bible",
			"relationship": {
				"level": 1,
				"xp": 45_000_000,
				"bondRank": "stranger",
				"currentLevelXp": 0,
				"nextLevelXp": 50_000_000,
				"progressPermille": 900,
			},
			"skills": [],
		}],
	}
	var leveled := initial.duplicate(true)
	leveled["revision"] = 2
	leveled["companions"] = [{
		"companionId": companion_id,
		"characterId": "character.bible",
		"relationship": {
			"level": 2,
			"xp": 55_000_000,
			"bondRank": "stranger",
			"currentLevelXp": 50_000_000,
			"nextLevelXp": 120_000_000,
			"progressPermille": 71,
		},
		"skills": [],
	}]

	progression.call("_apply_canonical_projection", initial, "test-seed", false)
	progression.call("_apply_canonical_projection", leveled, "test-sync", true)
	await process_frame

	var level_event: Dictionary = {}
	for item in _published:
		if str(item.get("topic", "")) == "progression.level_up":
			level_event = item.get("payload", {})
			break
	var event_ok := int(level_event.get("fromLevel", 0)) == 1 \
		and int(level_event.get("toLevel", 0)) == 2 \
		and str(level_event.get("characterId", "")) == "character.bible" \
		and str(level_event.get("source", "")) == "test-sync"

	var panel := celebration.get_node_or_null("ProgressionCelebrationLayer/ProgressionCelebrationRoot/ProgressionToast")
	var title := celebration.get_node_or_null("ProgressionCelebrationLayer/ProgressionCelebrationRoot/ProgressionToast/LevelUpStack/LevelUpTitle")
	# VBoxContainer keeps the generated default name in Godot. If future UI naming
	# changes, verify the visible panel plus the dedicated celebration event.
	var overlay_ok := is_instance_valid(panel) and bool(panel.visible)
	var floating_badge := host.get_node_or_null("FloatingLevelUpBadge")
	var floating_ok := is_instance_valid(floating_badge) and bool((floating_badge as Control).visible)
	var celebration_signal := false
	for item in _published:
		if str(item.get("topic", "")) == "progression.celebration_shown":
			celebration_signal = true
			break

	_published.clear()
	context.settings["reduce_motion"] = true
	bus.publish(&"progression.level_up", {
		"companionId": companion_id,
		"characterId": "character.bible",
		"fromLevel": 2,
		"toLevel": 3,
		"bondRank": "stranger",
	})
	await process_frame
	var fallback_ok := false
	for item in _published:
		if str(item.get("topic", "")) == "notification.requested":
			var payload: Dictionary = item.get("payload", {})
			fallback_ok = str(payload.get("source", "")) == "progression-fallback"
			if fallback_ok:
				break

	var ok := event_ok and overlay_ok and floating_ok and celebration_signal and fallback_ok
	print("[PROGRESSION-LEVEL-UP] event=%s overlay=%s floating=%s celebration=%s reduced_motion_fallback=%s title_node=%s" % [
		str(event_ok).to_lower(),
		str(overlay_ok).to_lower(),
		str(floating_ok).to_lower(),
		str(celebration_signal).to_lower(),
		str(fallback_ok).to_lower(),
		str(is_instance_valid(title)).to_lower(),
	])
	celebration.stop()
	quit(0 if ok else 1)
