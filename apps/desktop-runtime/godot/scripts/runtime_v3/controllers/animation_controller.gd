extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3AnimationController

var sprite: AnimatedSprite2D
var ai_thinking := false
# Presentation animations requested by Offline Presence (think/speak) must not
# be overwritten by canonical physics animation events while they are playing.
var presentation_lock := false
var presentation_animation: StringName = &""
var presentation_source := ""
var presentation_interruptible := true
var presentation_priority := 0

func bind_sprite(target: AnimatedSprite2D) -> void:
	sprite = target
	if is_instance_valid(sprite):
		var callback := Callable(self, "_on_animation_finished")
		if not sprite.animation_finished.is_connected(callback):
			sprite.animation_finished.connect(callback)

func start() -> void:
	event_bus.subscribe(&"animation.requested", Callable(self, "_on_animation_requested"))
	event_bus.subscribe(&"ai.thinking_started", Callable(self, "_on_ai_thinking_started"))
	event_bus.subscribe(&"ai.thinking_finished", Callable(self, "_on_ai_thinking_finished"))

func stop() -> void:
	event_bus.unsubscribe(&"animation.requested", Callable(self, "_on_animation_requested"))
	event_bus.unsubscribe(&"ai.thinking_started", Callable(self, "_on_ai_thinking_started"))
	event_bus.unsubscribe(&"ai.thinking_finished", Callable(self, "_on_ai_thinking_finished"))
	ai_thinking = false
	presentation_lock = false
	presentation_animation = &""
	presentation_source = ""
	presentation_interruptible = true
	presentation_priority = 0

func _on_ai_thinking_started(_payload: Dictionary = {}) -> void:
	ai_thinking = true
	_play_animation(&"think", "ai-thinking")

func _on_ai_thinking_finished(_payload: Dictionary = {}) -> void:
	ai_thinking = false
	if is_instance_valid(sprite) and sprite.animation == &"think":
		_play_animation(&"idle", "ai-thinking-finished")

func _action_priority_rank(value: String) -> int:
	match value:
		"ambient": return 10
		"presentation": return 20
		"reaction": return 30
		"lifecycle": return 40
		_: return 20


func _clear_presentation_owner() -> void:
	presentation_lock = false
	presentation_animation = &""
	presentation_source = ""
	presentation_interruptible = true
	presentation_priority = 0


func _on_animation_requested(payload: Dictionary) -> void:
	var name: StringName = StringName(payload.get("name", "idle"))
	var source := str(payload.get("source", "event"))
	var incoming_priority := _action_priority_rank(str(payload.get("priority", "presentation")))
	# Custom actions may protect themselves from other presentation requests, but
	# canonical Physics always remains authoritative and can interrupt them.
	if presentation_lock \
	and presentation_source == "character-action" \
	and source not in ["physics", "physics-transition"] \
	and name != presentation_animation:
		if not presentation_interruptible:
			return
		if source == "character-action" and incoming_priority < presentation_priority:
			return
	# Offline Presence clips may be authored as looping animations. When the
	# scheduler replaces one of those clips (for example think -> happy -> idle),
	# AnimatedSprite2D does not emit animation_finished for the interrupted loop.
	# Clear the old ownership explicitly so later canonical Physics animations
	# are not rejected forever while the sprite remains visually idle.
	if presentation_lock \
	and source not in ["physics", "physics-transition"] \
	and name != presentation_animation:
		_clear_presentation_owner()
	# A canonical body that is already moving is the source of truth for the
	# visible pose. Physics therefore always clears presentation ownership.
	if presentation_lock and source in ["physics", "physics-transition"]:
		if ai_thinking:
			return
		_clear_presentation_owner()
	if ai_thinking and name != &"think" and name != &"speak":
		return
	if source in ["offline-presence", "local-reaction", "character-action"]:
		presentation_lock = true
		presentation_animation = name
		presentation_source = source
		presentation_interruptible = bool(payload.get("interruptible", true)) if source == "character-action" else true
		presentation_priority = incoming_priority if source == "character-action" else 0
	_play_animation(name, source)

func _play_animation(name: StringName, source: String = "event") -> void:
	if not is_instance_valid(sprite):
		event_bus.publish(&"animation.missing", {"name": name, "source": source})
		return
	if sprite.sprite_frames == null:
		event_bus.publish(&"animation.missing", {"name": name, "source": source})
		return
	var character_service: Variant = services.get("character_service") if is_instance_valid(services) else null
	if not sprite.sprite_frames.has_animation(name) \
	and character_service != null \
	and character_service.has_method("ensure_animation_loaded"):
		character_service.call("ensure_animation_loaded", name, sprite.sprite_frames)
	if not sprite.sprite_frames.has_animation(name):
		event_bus.publish(&"animation.missing", {"name": name, "source": source})
		return
	sprite.play(name)
	if character_service != null and character_service.has_method("trim_animation_cache"):
		character_service.call("trim_animation_cache", sprite.sprite_frames, name)
	_apply_visual_profile(name)
	print(
		"[AnimationPlayback] started=%s source=%s frames=%d loop=%s" % [
			name,
			source,
			sprite.sprite_frames.get_frame_count(name),
			sprite.sprite_frames.get_animation_loop(name),
		]
	)
	event_bus.publish(&"animation.started", {"name": name, "source": source})

func _apply_visual_profile(name: StringName) -> void:
	if not is_instance_valid(sprite):
		return
	# Native presentation scale is owned exclusively by CharacterController.
	# It fits the canonical idle alpha bounds to the native canvas, applies DPI
	# compensation and the user's presentation-size preset, then repositions the
	# visual bounds on every animation.started event. Reapplying a legacy
	# base/profile scale here fights that fitted value and makes the companion
	# jump back to a different size whenever an animation changes.
	if context != null and bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	var profiles: Dictionary = context.character.get("visual_profiles", {})
	var profile: Dictionary = profiles.get(str(name), {})
	var base_scale := float(context.character.get("scale", 0.6))
	var profile_scale := clampf(float(profile.get("scale", 1.0)), 0.25, 2.0)
	sprite.scale = Vector2.ONE * base_scale * profile_scale

func _on_animation_finished() -> void:
	if not is_instance_valid(sprite):
		return
	var finished: StringName = sprite.animation
	event_bus.publish(&"animation.finished", {"name": finished})
	if presentation_lock and finished == presentation_animation:
		_clear_presentation_owner()
		# Physics was intentionally suppressed during the presentation clip.
		# Return to a stable visual pose without allowing a stale physics event to
		# immediately overwrite the presentation animation.
		if not ai_thinking:
			_play_animation(&"idle", "presentation-finished")
