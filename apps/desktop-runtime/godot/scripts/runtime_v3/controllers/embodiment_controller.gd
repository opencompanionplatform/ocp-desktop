extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3EmbodimentController

# Embodiment V1 is a local coordination layer. It derives one bounded body
# state from facts the Runtime already owns; it never moves Physics directly,
# calls an AI provider, or requests duplicate animations.

const REACTION_HOLD_SECONDS := 2.5
const DEFAULT_AROUSAL := 0.35

var body_mode := "idle"
var emotion := "neutral"
var arousal := DEFAULT_AROUSAL
var motion_scale := 1.0
var ambient_interval_scale := 1.0
var movement_state := "stationary"
var surface_kind := "desktop_floor"
var thinking := false
var speaking := false
var dragging := false
var reaction_active := false
var revision := 0
var _reaction_generation := 0


func start() -> void:
	if event_bus == null:
		return
	event_bus.subscribe(&"ai.thinking_started", _on_thinking_started)
	event_bus.subscribe(&"ai.thinking_finished", _on_thinking_finished)
	event_bus.subscribe(&"tts.started", _on_tts_started)
	event_bus.subscribe(&"tts.finished", _on_tts_terminal)
	event_bus.subscribe(&"tts.failed", _on_tts_terminal)
	event_bus.subscribe(&"tts.interrupted", _on_tts_terminal)
	event_bus.subscribe(&"emotion.changed", _on_emotion_changed)
	event_bus.subscribe(&"character.drag_started", _on_drag_started)
	event_bus.subscribe(&"character.drag_finished", _on_drag_finished)
	event_bus.subscribe(&"character.presentation_state", _on_physics_state)
	event_bus.subscribe(&"character.physics_moved", _on_physics_state)
	if context != null and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)
	_recompute("start", true)


func stop() -> void:
	if context != null and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)
	if event_bus == null:
		return
	event_bus.unsubscribe(&"ai.thinking_started", _on_thinking_started)
	event_bus.unsubscribe(&"ai.thinking_finished", _on_thinking_finished)
	event_bus.unsubscribe(&"tts.started", _on_tts_started)
	event_bus.unsubscribe(&"tts.finished", _on_tts_terminal)
	event_bus.unsubscribe(&"tts.failed", _on_tts_terminal)
	event_bus.unsubscribe(&"tts.interrupted", _on_tts_terminal)
	event_bus.unsubscribe(&"emotion.changed", _on_emotion_changed)
	event_bus.unsubscribe(&"character.drag_started", _on_drag_started)
	event_bus.unsubscribe(&"character.drag_finished", _on_drag_finished)
	event_bus.unsubscribe(&"character.presentation_state", _on_physics_state)
	event_bus.unsubscribe(&"character.physics_moved", _on_physics_state)


func snapshot() -> Dictionary:
	return {
		"mode": body_mode,
		"emotion": emotion,
		"arousal": arousal,
		"motionScale": motion_scale,
		"ambientIntervalScale": ambient_interval_scale,
		"movementState": movement_state,
		"surfaceKind": surface_kind,
		"revision": revision,
	}


func _on_thinking_started(_payload: Dictionary) -> void:
	thinking = true
	_recompute("thinking-started")


func _on_thinking_finished(_payload: Dictionary) -> void:
	thinking = false
	_recompute("thinking-finished")


func _on_tts_started(_payload: Dictionary) -> void:
	speaking = true
	_recompute("speech-started")


func _on_tts_terminal(_payload: Dictionary) -> void:
	speaking = false
	_recompute("speech-finished")


func _on_drag_started(_payload: Dictionary) -> void:
	dragging = true
	_recompute("drag-started")


func _on_drag_finished(_payload: Dictionary) -> void:
	dragging = false
	_recompute("drag-finished")


func _on_physics_state(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default":
		return
	var next_movement := str(payload.get("movementState", payload.get("state", movement_state))).strip_edges().to_lower()
	var next_surface := str(payload.get("surfaceKind", surface_kind)).strip_edges().to_lower()
	if not next_movement.is_empty():
		movement_state = next_movement
	if not next_surface.is_empty():
		surface_kind = next_surface
	_recompute("physics-state")


func _on_emotion_changed(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default":
		return
	var next_emotion := str(payload.get("emotion", "neutral")).strip_edges().to_lower()
	emotion = next_emotion if not next_emotion.is_empty() else "neutral"
	reaction_active = emotion != "neutral"
	_reaction_generation += 1
	var generation := _reaction_generation
	_recompute("emotion-changed")
	if reaction_active and is_inside_tree():
		get_tree().create_timer(REACTION_HOLD_SECONDS).timeout.connect(
			func() -> void: _expire_reaction(generation),
			CONNECT_ONE_SHOT
		)


func _expire_reaction(generation: int) -> void:
	if generation != _reaction_generation:
		return
	reaction_active = false
	_recompute("emotion-settled")


func _on_context_changed(section: StringName) -> void:
	if section == &"character":
		_recompute("soul-updated", true)


func _recompute(reason: String, force: bool = false) -> void:
	var next_mode := _derive_mode()
	var next_arousal := _derive_arousal()
	var next_motion_scale := clampf(0.85 + next_arousal * 0.30, 0.85, 1.15)
	var next_ambient_scale := clampf(1.25 - next_arousal * 0.50, 0.75, 1.25)
	var changed := next_mode != body_mode \
		or not is_equal_approx(next_arousal, arousal) \
		or not is_equal_approx(next_motion_scale, motion_scale) \
		or not is_equal_approx(next_ambient_scale, ambient_interval_scale)
	body_mode = next_mode
	arousal = next_arousal
	motion_scale = next_motion_scale
	ambient_interval_scale = next_ambient_scale
	if not changed and not force:
		return
	revision += 1
	var payload := snapshot()
	payload["reason"] = reason
	payload["source"] = "embodiment-v1"
	event_bus.publish(&"embodiment.state_changed", payload)


func _derive_mode() -> String:
	if dragging:
		return "interacting"
	match movement_state:
		"climbing":
			return "climbing"
		"hanging":
			return "hanging"
		"airborne-falling", "falling", "airborne":
			return "airborne"
		"walking", "moving":
			return "moving"
	if speaking:
		return "speaking"
	if thinking:
		return "thinking"
	if reaction_active:
		return "reacting"
	return "idle"


func _derive_arousal() -> float:
	var emotion_arousal := DEFAULT_AROUSAL
	match emotion:
		"happy":
			emotion_arousal = 0.65
		"sad":
			emotion_arousal = 0.25
		"angry":
			emotion_arousal = 0.85
		"surprised":
			emotion_arousal = 0.90
		_:
			emotion_arousal = DEFAULT_AROUSAL
	var soul_energy := 0.5
	if context != null:
		var soul_value: Variant = context.character.get("soul_profile", {})
		if soul_value is Dictionary:
			var traits_value: Variant = (soul_value as Dictionary).get("traits", {})
			if traits_value is Dictionary:
				soul_energy = clampf(float((traits_value as Dictionary).get("energy", 0.5)), 0.0, 1.0)
	return clampf(emotion_arousal * 0.60 + soul_energy * 0.40, 0.0, 1.0)
