extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const EmbodimentControllerScript = preload("res://scripts/runtime_v3/controllers/embodiment_controller.gd")

var events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var controller := EmbodimentControllerScript.new()
	var services := Node.new()
	var machine := Node.new()
	for node in [context, bus, controller, services, machine]:
		holder.add_child(node)

	context.update_character({"soul_profile": {"traits": {"energy": 0.9}}})
	bus.event_published.connect(func(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	controller.configure(context, bus, services, machine)
	controller.start()

	var initial: Dictionary = controller.snapshot()
	var initial_ok: bool = str(initial.get("mode", "")) == "idle" \
		and float(initial.get("arousal", 0.0)) > 0.5 \
		and float(initial.get("ambientIntervalScale", 0.0)) < 1.0

	bus.publish(&"ai.thinking_started", {"message_id": "emb-1"})
	var thinking_ok := controller.body_mode == "thinking"
	bus.publish(&"tts.started", {"message_id": "emb-1"})
	var speaking_ok := controller.body_mode == "speaking"

	bus.publish(&"character.physics_moved", {
		"companionId": "default",
		"movementState": "walking",
		"surfaceKind": "desktop_floor",
	})
	var movement_owns_body := controller.body_mode == "moving"
	bus.publish(&"character.drag_started", {"source": "smoke"})
	var interaction_owns_body := controller.body_mode == "interacting"
	bus.publish(&"character.drag_finished", {"source": "smoke"})
	var movement_restored := controller.body_mode == "moving"

	bus.publish(&"character.physics_moved", {
		"companionId": "default",
		"movementState": "stationary",
		"surfaceKind": "desktop_floor",
	})
	var speaking_restored := controller.body_mode == "speaking"
	bus.publish(&"tts.finished", {"message_id": "emb-1"})
	var thinking_restored := controller.body_mode == "thinking"
	bus.publish(&"ai.thinking_finished", {"message_id": "emb-1"})
	var idle_restored := controller.body_mode == "idle"

	var idle_arousal := controller.arousal
	bus.publish(&"emotion.changed", {
		"companionId": "default",
		"emotion": "angry",
		"emotionInstance": "emb-emotion-1",
	})
	var emotion_ok := controller.body_mode == "reacting" \
		and controller.emotion == "angry" \
		and controller.arousal > idle_arousal \
		and controller.motion_scale > 1.0
	controller._expire_reaction(controller._reaction_generation)
	var reaction_settled := controller.body_mode == "idle"

	var high_energy_arousal := controller.arousal
	context.update_character({"soul_profile": {"traits": {"energy": 0.1}}})
	var soul_scaling_ok := controller.arousal < high_energy_arousal \
		and controller.ambient_interval_scale > 0.9

	var embodiment_events := events.filter(func(entry: Dictionary) -> bool:
		return entry.get("topic") == &"embodiment.state_changed")
	var revisions_ok := embodiment_events.size() >= 8
	var previous_revision := 0
	for entry in embodiment_events:
		var payload: Dictionary = entry.get("payload", {})
		var current_revision := int(payload.get("revision", 0))
		revisions_ok = revisions_ok and current_revision > previous_revision \
			and str(payload.get("source", "")) == "embodiment-v1"
		previous_revision = current_revision
	var no_duplicate_animation_authority := not events.any(func(entry: Dictionary) -> bool:
		return entry.get("topic") == &"animation.requested")

	var ok: bool = initial_ok \
		and thinking_ok \
		and speaking_ok \
		and movement_owns_body \
		and interaction_owns_body \
		and movement_restored \
		and speaking_restored \
		and thinking_restored \
		and idle_restored \
		and emotion_ok \
		and reaction_settled \
		and soul_scaling_ok \
		and revisions_ok \
		and no_duplicate_animation_authority
	print("[EMBODIMENT-V1] initial=", initial_ok,
		" thinking=", thinking_ok,
		" speaking=", speaking_ok,
		" moving=", movement_owns_body,
		" interacting=", interaction_owns_body,
		" emotion=", emotion_ok,
		" soul=", soul_scaling_ok,
		" authority=", no_duplicate_animation_authority,
		" ok=", ok)

	controller.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
