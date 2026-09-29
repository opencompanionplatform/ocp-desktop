extends SceneTree

const ControllerScript = preload("res://scripts/runtime_v3/controllers/offline_presence_controller.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const LocalBehaviorCatalogScript = preload("res://scripts/runtime_v3/core/local_behavior_catalog.gd")


class FakeContext:
	extends Node
	signal context_changed(section: StringName)
	var settings: Dictionary = {"offline_presence_enabled": true}
	var runtime_config: Dictionary = {"chat_presentation_active": false, "chat_focus_active": false}
	var window: Dictionary = {"hidden_to_tray": false}
	var character: Dictionary = {
		"animations": PackedStringArray(LocalBehaviorCatalogScript.CHARACTER3_ANIMATIONS),
	}

	func set_presence_enabled(enabled: bool) -> void:
		settings["offline_presence_enabled"] = enabled
		context_changed.emit(&"settings")

	func update_settings(values: Dictionary) -> void:
		for key in values.keys():
			settings[key] = values[key]
		context_changed.emit(&"settings")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var bus := EventBusScript.new()
	var context := FakeContext.new()
	var controller := ControllerScript.new()
	var services := Node.new()
	var state_machine := Node.new()
	holder.add_child(bus)
	holder.add_child(context)
	holder.add_child(controller)
	holder.add_child(services)
	holder.add_child(state_machine)
	controller.configure(context, bus, services, state_machine)
	var received: Array = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		received.append({"topic": topic, "payload": payload.duplicate(true)})
	)
	controller.start()

	context.update_settings({"language": "th"})
	var thai_bubbles: Array = controller._local_bubbles_for_current_language()
	context.update_settings({"language": "en"})
	var english_bubbles: Array = controller._local_bubbles_for_current_language()
	var language_bubbles_ok := str(thai_bubbles[0]).contains("ฉันอยู่ตรงนี้") \
		and str(english_bubbles[0]) == "I am here if you need me."

	var first_emitted: bool = controller._emit_scheduled_action()
	var deterministic_order: bool = received.size() == 2 \
		and received[0].topic == &"animation.requested" \
		and str(received[0].payload.get("name", "")) == "think" \
		and received[1].topic == &"bubble.requested" \
		and str(received[0].payload.get("source", "")) == "offline-presence"

	received.clear()
	bus.publish(&"character.drag_started", {"source": "smoke"})
	var drag_event_count := received.size()
	var drag_suppressed: bool = not controller._emit_scheduled_action() and received.size() == drag_event_count
	bus.publish(&"character.drag_finished", {"source": "smoke"})
	context.window["hidden_to_tray"] = true
	var hidden_suppressed: bool = not controller._emit_scheduled_action()
	context.window["hidden_to_tray"] = false
	context.runtime_config["chat_presentation_active"] = true
	var chat_active_suppressed: bool = not controller._emit_scheduled_action()
	context.runtime_config["chat_presentation_active"] = false
	context.runtime_config["chat_focus_active"] = true
	var legacy_chat_focus_suppressed: bool = not controller._emit_scheduled_action()
	context.runtime_config["chat_focus_active"] = false
	bus.publish(&"character.appear_requested", {"source": "smoke"})
	var lifecycle_suppressed: bool = not controller._emit_scheduled_action()
	bus.publish(&"animation.finished", {"name": "appear", "source": "smoke"})
	bus.publish(&"tts.requested", {"message_id": "voice-1", "text": "hello", "source": "smoke"})
	var voice_suppressed: bool = not controller._emit_scheduled_action() and controller.voice_requests_active == 1
	bus.publish(&"tts.finished", {"message_id": "voice-1", "source": "smoke"})
	var voice_released: bool = controller.voice_requests_active == 0
	received.clear()
	context.set_presence_enabled(false)
	var disabled_idle: bool = received.size() == 1 \
		and received[0].topic == &"animation.requested" \
		and str(received[0].payload.get("name", "")) == "idle" \
		and str(received[0].payload.get("reason", "")) == "disabled"
	var disabled_suppressed: bool = not controller._emit_scheduled_action()
	context.set_presence_enabled(true)
	bus.publish(&"animation.requested", {"name": "wave", "source": "native-menu"})
	var user_action_event_count := received.size()
	var user_action_suppressed: bool = not controller._emit_scheduled_action()
	user_action_suppressed = user_action_suppressed and received.size() == user_action_event_count

	controller.user_action_hold_seconds = 0.0
	received.clear()
	bus.publish(&"character.physics_moved", {
		"companionId": "default",
		"movementState": "climbing",
		"surfaceKind": "monitor_edge",
	})
	var physics_suppressed := not controller._emit_scheduled_action()
	var before_moving_emotion := received.size()
	bus.publish(&"emotion.changed", {"companionId": "default", "emotion": "angry"})
	var moving_emotion_suppressed := received.size() == before_moving_emotion + 1 # only the emotion.changed event itself

	bus.publish(&"character.physics_moved", {
		"companionId": "default",
		"movementState": "stationary",
		"surfaceKind": "desktop_floor",
	})
	controller.user_action_hold_seconds = 0.0
	received.clear()
	bus.publish(&"emotion.changed", {"companionId": "default", "emotion": "angry", "emotionInstance": "smoke-angry"})
	var angry_reaction := received.any(func(event: Dictionary) -> bool:
		return event.topic == &"animation.requested" \
			and str(event.payload.get("name", "")) == "angry" \
			and str(event.payload.get("source", "")) == "local-reaction"
	)

	controller.user_action_hold_seconds = 0.0
	controller.stationary_seconds = controller.SIT_AFTER_SECONDS
	received.clear()
	controller._process(0.1)
	var sit_triggered := controller.sitting and not controller.sleeping and received.any(func(event: Dictionary) -> bool:
		return event.topic == &"animation.requested" \
			and str(event.payload.get("name", "")) == "sit" \
			and str(event.payload.get("reason", "")) == "surface-idle"
	)
	controller.user_action_hold_seconds = 0.0
	controller.stationary_seconds = controller.SLEEP_AFTER_SECONDS
	received.clear()
	controller._process(0.1)
	var sleep_triggered := not controller.sitting and controller.sleeping and received.any(func(event: Dictionary) -> bool:
		return event.topic == &"animation.requested" \
			and str(event.payload.get("name", "")) == "sleep" \
			and str(event.payload.get("reason", "")) == "surface-idle-timeout"
	)
	bus.publish(&"character.drag_started", {"source": "wake-smoke"})
	bus.publish(&"character.drag_finished", {"source": "wake-smoke"})
	# Wake should happen immediately after the user returns; the normal user
	# action hold may still be active and must not delay wake.
	received.clear()
	controller._process(0.1)
	var wake_triggered := not controller.sitting and not controller.sleeping and not controller.wake_pending and received.any(func(event: Dictionary) -> bool:
		return event.topic == &"animation.requested" \
			and str(event.payload.get("name", "")) == "wake" \
			and str(event.payload.get("reason", "")) == "user-return"
	)

	var mapped_names := LocalBehaviorCatalogScript.mapped_animation_names()
	var mapping_complete := mapped_names.size() == LocalBehaviorCatalogScript.CHARACTER3_ANIMATIONS.size()
	for animation_name in LocalBehaviorCatalogScript.CHARACTER3_ANIMATIONS:
		mapping_complete = mapping_complete and LocalBehaviorCatalogScript.owner_for(str(animation_name)) != "unmapped"

	var ok := first_emitted and deterministic_order and language_bubbles_ok \
		and drag_suppressed and hidden_suppressed \
		and chat_active_suppressed and legacy_chat_focus_suppressed \
		and lifecycle_suppressed and voice_suppressed and voice_released \
		and disabled_idle and disabled_suppressed and user_action_suppressed \
		and physics_suppressed and moving_emotion_suppressed and angry_reaction \
		and sit_triggered and sleep_triggered and wake_triggered and mapping_complete
	print("[G14.1] deterministic_order=", deterministic_order, " physics_suppressed=", physics_suppressed, " reaction=", angry_reaction, " surface_idle=", sit_triggered and sleep_triggered and wake_triggered, " mapping_23=", mapping_complete, " suppressed=", ok)
	controller.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
