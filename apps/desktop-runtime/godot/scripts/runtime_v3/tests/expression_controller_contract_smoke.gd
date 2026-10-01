extends SceneTree

const ControllerScript = preload("res://scripts/runtime_v3/controllers/expression_controller.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")


class FakeContext:
	extends Node
	var character: Dictionary = {
		"expressions": {
			"happy": {"sprite": "body", "frames": [1]},
		},
	}
	var package: Dictionary = {
		"entry": {
			"sprites": [
				{"id": "body", "path": "assets/body.png", "frameSize": [16, 16]},
			],
			"animations": {
				"idle": {"sprite": "body", "frames": [0], "fps": 1.0, "loop": true},
				"walk_left": {"sprite": "body", "frames": [0], "fps": 6.0, "loop": true},
			},
		},
	}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node2D.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := EventBusScript.new()
	var controller := ControllerScript.new()
	var services := Node.new()
	var state_machine := Node.new()
	var body := AnimatedSprite2D.new()
	for node in [context, bus, controller, services, state_machine, body]:
		holder.add_child(node)

	var image := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	image.fill_rect(Rect2i(0, 0, 16, 16), Color(0.2, 0.4, 1.0, 1.0))
	image.fill_rect(Rect2i(16, 0, 16, 16), Color(1.0, 0.4, 0.2, 1.0))
	var sheet := ImageTexture.create_from_image(image)
	var idle_texture := AtlasTexture.new()
	idle_texture.atlas = sheet
	idle_texture.region = Rect2(0, 0, 16, 16)
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	for animation_name in [&"idle", &"walk_left"]:
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, true)
		frames.add_frame(animation_name, idle_texture)
	body.sprite_frames = frames
	body.play(&"idle")

	controller.configure(context, bus, services, state_machine)
	controller.bind_sprite(body)
	var expression_events: Array[Dictionary] = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary) -> void:
		if topic == &"expression.changed":
			expression_events.append(payload.duplicate(true)))
	controller.start()

	bus.publish(&"emotion.changed", {"companionId": "default", "emotion": "happy"})
	await process_frame
	var happy_texture := controller.expression_sprite.sprite_frames.get_frame_texture(&"expression", 0) as AtlasTexture
	var happy_ok := controller.expression_sprite.visible \
		and not body.visible \
		and controller.active_expression == "happy" \
		and happy_texture != null \
		and int(happy_texture.region.position.x) == 16 \
		and body.animation == &"idle"

	bus.publish(&"tts.started", {"companion_id": "default", "message_id": "m-1"})
	var speech_body_authority := controller.speech_active \
		and not controller.expression_sprite.visible \
		and body.visible \
		and controller.active_expression.is_empty()

	body.flip_h = true
	bus.publish(&"tts.finished", {"companion_id": "default", "message_id": "m-1"})
	await process_frame
	controller._process(0.0)
	var restored_texture := controller.expression_sprite.sprite_frames.get_frame_texture(&"expression", 0) as AtlasTexture
	var restored_ok := not controller.speech_active \
		and controller.expression_sprite.visible \
		and not body.visible \
		and controller.expression_sprite.flip_h \
		and controller.active_expression == "happy" \
		and restored_texture != null \
		and int(restored_texture.region.position.x) == 16

	bus.publish(&"character.physics_moved", {
		"companionId": "default",
		"movementState": "walking",
		"surfaceKind": "desktop_floor",
	})
	body.play(&"walk_left")
	var movement_body_authority := not controller.expression_sprite.visible \
		and body.visible \
		and controller.active_expression.is_empty()

	body.play(&"idle")
	bus.publish(&"character.physics_moved", {
		"companionId": "default",
		"movementState": "stationary",
		"surfaceKind": "desktop_floor",
	})
	await process_frame
	var stationary_restore := controller.expression_sprite.visible \
		and not body.visible \
		and controller.active_expression == "happy"

	bus.publish(&"emotion.changed", {"companionId": "default", "emotion": "sad"})
	await process_frame
	var fallback_event: Dictionary = expression_events[-1] if not expression_events.is_empty() else {}
	var fallback_ok := not controller.expression_sprite.visible \
		and body.visible \
		and controller.active_expression.is_empty() \
		and bool(fallback_event.get("fallback", false))

	var ok := happy_ok and speech_body_authority and restored_ok and movement_body_authority and stationary_restore and fallback_ok
	print("[EMBODIMENT-EXPRESSION] happy=", happy_ok,
		" speech_body=", speech_body_authority,
		" restore=", restored_ok,
		" movement_body=", movement_body_authority,
		" stationary_restore=", stationary_restore,
		" fallback=", fallback_ok,
		" ok=", ok)
	controller.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
