extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3OfflinePresenceController

const LocalBehaviorCatalogScript = preload("res://scripts/runtime_v3/core/local_behavior_catalog.gd")

# Local-only, deterministic companion activity. This controller deliberately
# emits presentation requests only: it never moves the character, opens a
# network connection, or invokes a provider/LLM.

const SCHEDULE_INTERVAL_SECONDS := 18.0
const USER_ACTION_HOLD_SECONDS := 18.0
const SIT_AFTER_SECONDS := 90.0
const SLEEP_AFTER_SECONDS := 180.0
const SAFE_ANIMATIONS := LocalBehaviorCatalogScript.AMBIENT_ROTATION
const LOCAL_BUBBLES_EN := [
	"I am here if you need me.",
	"Taking a quiet moment.",
	"Ready when you are.",
	"Keeping you company offline.",
]
const LOCAL_BUBBLES_TH := [
	"ฉันอยู่ตรงนี้ถ้าคุณต้องการนะ",
	"พักเงียบ ๆ สักครู่นะ",
	"พร้อมเมื่อคุณพร้อมนะ",
	"อยู่เป็นเพื่อนคุณแบบออฟไลน์นะ",
]

var elapsed_seconds := 0.0
var user_action_hold_seconds := 0.0
var sequence := 0
var dragging := false
var lifecycle_active := false
var voice_requests_active := 0
var presence_was_enabled := true
var stationary_seconds := 0.0
var sitting := false
var sleeping := false
var wake_pending := false
var last_movement_state := "stationary"
var last_surface_kind := "desktop_floor"


func start() -> void:
	if event_bus == null:
		return
	presence_was_enabled = _is_enabled()
	if context != null and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)
	event_bus.subscribe(&"character.drag_started", _on_drag_started)
	event_bus.subscribe(&"character.drag_finished", _on_drag_finished)
	event_bus.subscribe(&"character.appear_requested", _on_lifecycle_requested)
	event_bus.subscribe(&"character.disappear_requested", _on_lifecycle_requested)
	event_bus.subscribe(&"animation.finished", _on_animation_finished)
	event_bus.subscribe(&"animation.requested", _on_animation_requested)
	event_bus.subscribe(&"character.presentation_state", _on_physics_moved)
	event_bus.subscribe(&"character.physics_moved", _on_physics_moved)
	event_bus.subscribe(&"emotion.changed", _on_emotion_changed)
	event_bus.subscribe(&"tts.requested", _on_tts_requested)
	event_bus.subscribe(&"tts.finished", _on_tts_terminal)
	event_bus.subscribe(&"tts.failed", _on_tts_terminal)
	set_process(true)


func stop() -> void:
	set_process(false)
	if context != null and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)
	if event_bus == null:
		return
	event_bus.unsubscribe(&"character.drag_started", _on_drag_started)
	event_bus.unsubscribe(&"character.drag_finished", _on_drag_finished)
	event_bus.unsubscribe(&"character.appear_requested", _on_lifecycle_requested)
	event_bus.unsubscribe(&"character.disappear_requested", _on_lifecycle_requested)
	event_bus.unsubscribe(&"animation.finished", _on_animation_finished)
	event_bus.unsubscribe(&"animation.requested", _on_animation_requested)
	event_bus.unsubscribe(&"character.presentation_state", _on_physics_moved)
	event_bus.unsubscribe(&"character.physics_moved", _on_physics_moved)
	event_bus.unsubscribe(&"emotion.changed", _on_emotion_changed)
	event_bus.unsubscribe(&"tts.requested", _on_tts_requested)
	event_bus.unsubscribe(&"tts.finished", _on_tts_terminal)
	event_bus.unsubscribe(&"tts.failed", _on_tts_terminal)
	voice_requests_active = 0


func _process(delta: float) -> void:
	if user_action_hold_seconds > 0.0:
		user_action_hold_seconds = maxf(0.0, user_action_hold_seconds - delta)
	if not _is_allowed():
		elapsed_seconds = 0.0
		return

	stationary_seconds += delta
	# Wake is a direct response to renewed user activity. Do not wait for the
	# normal 18-second presentation hold or the character feels asleep even
	# after the user has already returned.
	if wake_pending:
		if _request_presence_animation("wake", "user-return"):
			wake_pending = false
			sitting = false
			sleeping = false
			stationary_seconds = 0.0
			elapsed_seconds = 0.0
			return

	# Surface idle lifecycle: remain active for a while, sit after a shorter
	# idle period, then sleep only after a longer uninterrupted idle period.
	if not sitting and not sleeping and stationary_seconds >= SIT_AFTER_SECONDS and user_action_hold_seconds <= 0.0:
		if _request_presence_animation("sit", "surface-idle"):
			sitting = true
			elapsed_seconds = 0.0
			return
	if not sleeping and stationary_seconds >= SLEEP_AFTER_SECONDS and user_action_hold_seconds <= 0.0:
		if _request_presence_animation("sleep", "surface-idle-timeout"):
			sitting = false
			sleeping = true
			elapsed_seconds = 0.0
			return
	if sitting or sleeping:
		return

	elapsed_seconds += delta
	if elapsed_seconds < SCHEDULE_INTERVAL_SECONDS:
		return
	elapsed_seconds = 0.0
	_emit_scheduled_action()


func _emit_scheduled_action() -> bool:
	if not _is_allowed() or user_action_hold_seconds > 0.0:
		return false
	var available := _available_safe_animations()
	if available.is_empty():
		return false
	var animation_name := available[sequence % available.size()]
	event_bus.publish(&"animation.requested", {
		"name": animation_name,
		"source": "offline-presence",
		"sequence": sequence,
	})
	if sequence % 2 == 0:
		var local_bubbles := _local_bubbles_for_current_language()
		event_bus.publish(&"bubble.requested", {
			"text": local_bubbles[(sequence / 2) % local_bubbles.size()],
			"duration": 3.5,
			"source": "offline-presence",
			"sequence": sequence,
		})
	print("[OfflinePresence] scheduled animation=%s sequence=%d" % [animation_name, sequence])
	sequence += 1
	return true


func _local_bubbles_for_current_language() -> Array:
	var locale := "en"
	if context != null:
		locale = str(context.settings.get("language", "en")).strip_edges().to_lower()
	return LOCAL_BUBBLES_TH if locale.begins_with("th") else LOCAL_BUBBLES_EN


func _is_allowed() -> bool:
	if not _is_enabled() or dragging or lifecycle_active or voice_requests_active > 0:
		return false
	if context == null:
		return false
	# Ambient/local idle behavior never owns locomotion. Physics is the only
	# authority while walking, jumping, climbing, hanging, or falling.
	if last_movement_state != "stationary" or last_surface_kind != "desktop_floor":
		return false
	# Desktop Chat owns the companion presentation while its window is active.
	# Offline Presence must not inject local presentation during that interval;
	# it may resume only after Chat presentation releases ownership.
	var runtime_config: Dictionary = context.runtime_config if context.get("runtime_config") is Dictionary else {}
	if bool(runtime_config.get("chat_presentation_active", false)) or bool(runtime_config.get("chat_focus_active", false)):
		return false
	return not bool(context.window.get("hidden_to_tray", false))


func _is_enabled() -> bool:
	return context != null and bool(context.settings.get("offline_presence_enabled", true))


func _available_safe_animations() -> PackedStringArray:
	var available := PackedStringArray()
	if context == null:
		return available
	var advertised: Variant = context.character.get("animations", PackedStringArray())
	if not advertised is PackedStringArray:
		return available
	for animation_name in SAFE_ANIMATIONS:
		if advertised.has(animation_name):
			available.append(animation_name)
	return available


func _has_animation(animation_name: String) -> bool:
	if context == null:
		return false
	var advertised: Variant = context.character.get("animations", PackedStringArray())
	return advertised is PackedStringArray and advertised.has(animation_name)


func _request_presence_animation(animation_name: String, reason: String) -> bool:
	if not _has_animation(animation_name):
		return false
	event_bus.publish(&"animation.requested", {
		"name": animation_name,
		"source": "offline-presence",
		"reason": reason,
	})
	print("[OfflinePresence] behavior=%s reason=%s owner=%s" % [
		animation_name,
		reason,
		LocalBehaviorCatalogScript.owner_for(animation_name),
	])
	return true


func _can_present_reaction() -> bool:
	if dragging or lifecycle_active or voice_requests_active > 0 or context == null:
		return false
	if last_movement_state != "stationary" or last_surface_kind != "desktop_floor":
		return false
	var runtime_config: Dictionary = context.runtime_config if context.get("runtime_config") is Dictionary else {}
	if bool(runtime_config.get("chat_presentation_active", false)) or bool(runtime_config.get("chat_focus_active", false)):
		return false
	return not bool(context.window.get("hidden_to_tray", false))


func _on_physics_moved(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default":
		return
	var state := str(payload.get("movementState", payload.get("state", last_movement_state)))
	var surface := str(payload.get("surfaceKind", last_surface_kind))
	if not state.is_empty():
		last_movement_state = state
	if not surface.is_empty():
		last_surface_kind = surface
	if last_movement_state != "stationary" or last_surface_kind != "desktop_floor":
		elapsed_seconds = 0.0
		stationary_seconds = 0.0
		sitting = false
		if sleeping:
			sleeping = false
			wake_pending = false


func _on_emotion_changed(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default" or not _can_present_reaction():
		return
	var emotion := str(payload.get("emotion", "neutral")).strip_edges().to_lower()
	var animation_name := str(LocalBehaviorCatalogScript.animation_for_emotion(emotion))
	if not _has_animation(animation_name):
		return
	sitting = false
	sleeping = false
	wake_pending = false
	stationary_seconds = 0.0
	elapsed_seconds = 0.0
	event_bus.publish(&"animation.requested", {
		"name": animation_name,
		"source": "local-reaction",
		"emotion": emotion,
		"emotionInstance": str(payload.get("emotionInstance", "")),
	})
	print("[OfflinePresence] reaction emotion=%s animation=%s" % [emotion, animation_name])


func _on_drag_started(_payload: Dictionary) -> void:
	dragging = true
	elapsed_seconds = 0.0
	stationary_seconds = 0.0
	sitting = false
	if sleeping:
		sleeping = false
		wake_pending = true


func _on_drag_finished(_payload: Dictionary) -> void:
	dragging = false
	elapsed_seconds = 0.0


func _on_lifecycle_requested(_payload: Dictionary) -> void:
	lifecycle_active = true
	elapsed_seconds = 0.0


func _on_animation_finished(payload: Dictionary) -> void:
	var animation_name := str(payload.get("name", ""))
	if animation_name in ["appear", "disappear"]:
		lifecycle_active = false


func _on_animation_requested(payload: Dictionary) -> void:
	var source := str(payload.get("source", ""))
	if source != "offline-presence":
		user_action_hold_seconds = USER_ACTION_HOLD_SECONDS
		stationary_seconds = 0.0
		sitting = false
		if sleeping:
			sleeping = false
			wake_pending = source not in ["physics", "physics-transition", "local-reaction"]


func _on_tts_requested(payload: Dictionary) -> void:
	if str(payload.get("text", "")).strip_edges().is_empty():
		return
	voice_requests_active += 1
	elapsed_seconds = 0.0


func _on_tts_terminal(_payload: Dictionary) -> void:
	voice_requests_active = maxi(0, voice_requests_active - 1)
	if voice_requests_active == 0:
		# Give the just-finished speech a full quiet interval before autonomous
		# presence can replace the visible pose.
		user_action_hold_seconds = USER_ACTION_HOLD_SECONDS
	elapsed_seconds = 0.0


func _on_context_changed(section: StringName) -> void:
	if section != &"settings":
		return
	var enabled := _is_enabled()
	if presence_was_enabled and not enabled:
		_settle_to_idle()
	presence_was_enabled = enabled


func _settle_to_idle() -> void:
	elapsed_seconds = 0.0
	user_action_hold_seconds = 0.0
	stationary_seconds = 0.0
	sitting = false
	sleeping = false
	wake_pending = false
	if dragging or lifecycle_active or context == null:
		return
	if bool(context.window.get("hidden_to_tray", false)):
		return
	if not _available_safe_animations().has("idle"):
		return
	event_bus.publish(&"animation.requested", {
		"name": "idle",
		"source": "offline-presence",
		"reason": "disabled",
	})
	print("[OfflinePresence] disabled -> idle")
