extends SceneTree

const ControllerScript = preload("res://scripts/runtime_v3/controllers/sound_controller.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")


class FakeContext:
	extends Node
	var settings: Dictionary = {"sfx_enabled": true}
	var package: Dictionary = {"installed_path": "user://missing-character-sfx"}
	var character: Dictionary = {
		"audio_profile": {
			"clips": [{
				"id": "sfx_happy",
				"path": "assets/audio/happy.wav",
				"loop": false,
				"gainDb": -3.0,
				"fadeInSeconds": 0.02,
				"fadeOutSeconds": 0.1,
			}],
			"bindings": {
				"happy": {"clip": "sfx_happy", "start": "animation-start"},
			}
		}
	}

	func update_settings(values: Dictionary) -> void:
		settings.merge(values, true)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var bus := EventBusScript.new()
	var context := FakeContext.new()
	var controller := ControllerScript.new()
	var player := AudioStreamPlayer.new()
	var services := Node.new()
	var machine := Node.new()
	for node in [bus, context, controller, player, services, machine]:
		holder.add_child(node)
	controller.configure(context, bus, services, machine)
	controller.bind_player(player)
	controller.start()

	var received: Array = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		received.append({"topic": topic, "payload": payload.duplicate(true)})
	)
	var binding_ok: bool = str(controller._audio_binding("happy").get("clip", "")) == "sfx_happy"
	var clip_ok: bool = str(controller._audio_clip("sfx_happy").get("path", "")) == "assets/audio/happy.wav"

	bus.publish(&"animation.started", {"name": "happy"})
	var missing_count := received.filter(func(item): return item.topic == &"sound.missing").size()
	var missing_asset_reported: bool = missing_count == 1

	bus.publish(&"sound.sfx_toggle_requested", {})
	var disabled_ok: bool = bool(context.settings.get("sfx_enabled", true)) == false
	bus.publish(&"animation.started", {"name": "happy"})
	var disabled_missing_count := received.filter(func(item): return item.topic == &"sound.missing").size()
	var disabled_suppresses_playback: bool = disabled_missing_count == missing_count

	var master_bus := AudioServer.get_bus_index("Master")
	var initial_mute := AudioServer.is_bus_mute(master_bus) if master_bus >= 0 else false
	bus.publish(&"sound.master_toggle_requested", {})
	var master_toggle_ok := master_bus >= 0 and AudioServer.is_bus_mute(master_bus) != initial_mute
	if master_bus >= 0:
		AudioServer.set_bus_mute(master_bus, initial_mute)

	var ok: bool = binding_ok and clip_ok and missing_asset_reported and disabled_ok \
		and disabled_suppresses_playback and master_toggle_ok
	print("[CharacterSFX] binding=", binding_ok, " missing=", missing_asset_reported, " sfx_toggle=", disabled_ok, " master=", master_toggle_ok)
	controller.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
