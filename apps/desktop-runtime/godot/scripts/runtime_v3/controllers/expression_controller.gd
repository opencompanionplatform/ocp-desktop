extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ExpressionController

# Character-package `expressions` are authored full expression frames, not a
# guaranteed face-only layer. V1 therefore renders them as a *resting visual
# replacement* only while the body is stationary/idle. Physics, one-shot body
# animation and speech keep body authority and can never be covered by a stale
# full-character expression frame.

var body_sprite: AnimatedSprite2D
var expression_sprite: AnimatedSprite2D
var current_emotion := "neutral"
var active_expression := ""
var movement_state := "stationary"
var speech_active := false
var _pending_emotion_instance := ""
var _body_visibility_before_expression := true
var _expression_visible := false


func bind_sprite(target: AnimatedSprite2D) -> void:
	body_sprite = target
	if is_instance_valid(expression_sprite):
		expression_sprite.queue_free()
	expression_sprite = AnimatedSprite2D.new()
	expression_sprite.name = "ExpressionSurface"
	expression_sprite.centered = body_sprite.centered
	expression_sprite.z_index = body_sprite.z_index + 1
	expression_sprite.visible = false
	var parent := body_sprite.get_parent()
	if parent != null:
		parent.add_child(expression_sprite)
	set_process(true)


func start() -> void:
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.subscribe(&"emotion.changed", Callable(self, "_on_emotion_changed"))
	event_bus.subscribe(&"tts.started", Callable(self, "_on_tts_started"))
	event_bus.subscribe(&"tts.finished", Callable(self, "_on_tts_terminal"))
	event_bus.subscribe(&"tts.failed", Callable(self, "_on_tts_terminal"))
	event_bus.subscribe(&"tts.interrupted", Callable(self, "_on_tts_terminal"))
	event_bus.subscribe(&"animation.finished", Callable(self, "_on_animation_finished"))
	event_bus.subscribe(&"character.presentation_state", Callable(self, "_on_physics_state"))
	event_bus.subscribe(&"character.physics_moved", Callable(self, "_on_physics_state"))
	event_bus.subscribe(&"character.disappear_requested", Callable(self, "_on_character_disappear"))


func stop() -> void:
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.unsubscribe(&"emotion.changed", Callable(self, "_on_emotion_changed"))
	event_bus.unsubscribe(&"tts.started", Callable(self, "_on_tts_started"))
	event_bus.unsubscribe(&"tts.finished", Callable(self, "_on_tts_terminal"))
	event_bus.unsubscribe(&"tts.failed", Callable(self, "_on_tts_terminal"))
	event_bus.unsubscribe(&"tts.interrupted", Callable(self, "_on_tts_terminal"))
	event_bus.unsubscribe(&"animation.finished", Callable(self, "_on_animation_finished"))
	event_bus.unsubscribe(&"character.presentation_state", Callable(self, "_on_physics_state"))
	event_bus.unsubscribe(&"character.physics_moved", Callable(self, "_on_physics_state"))
	event_bus.unsubscribe(&"character.disappear_requested", Callable(self, "_on_character_disappear"))
	_clear_expression()
	set_process(false)


func _process(_delta: float) -> void:
	if not _expression_visible or not is_instance_valid(body_sprite) or not is_instance_valid(expression_sprite):
		return
	_sync_expression_transform()


func _on_character_loaded(_payload: Dictionary) -> void:
	current_emotion = "neutral"
	movement_state = "stationary"
	speech_active = false
	_pending_emotion_instance = ""
	_clear_expression()
	call_deferred("_maybe_restore_expression", "character-load")


func _on_emotion_changed(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default":
		return
	current_emotion = str(payload.get("emotion", "neutral")).strip_edges().to_lower()
	if current_emotion.is_empty():
		current_emotion = "neutral"
	_pending_emotion_instance = str(payload.get("emotionInstance", ""))
	if movement_state != "stationary":
		_report_pending_emotion("movement-authority", true)
		return
	# Let reaction/body animation subscribers run first. A package one-shot owns
	# presentation until it finishes; only then do we restore the expression.
	call_deferred("_maybe_restore_expression", "emotion")


func _on_tts_started(payload: Dictionary) -> void:
	if str(payload.get("companion_id", payload.get("companionId", "default"))) != "default":
		return
	speech_active = true
	_clear_expression()
	event_bus.publish(&"expression.changed", {
		"companion_id": "default",
		"expression": "",
		"emotion": current_emotion,
		"source": "speech-body-authority",
		"speaking": true,
		"fallback": true,
	})


func _on_tts_terminal(payload: Dictionary) -> void:
	if str(payload.get("companion_id", payload.get("companionId", "default"))) != "default":
		return
	speech_active = false
	call_deferred("_maybe_restore_expression", "speech-terminal")


func _on_animation_finished(_payload: Dictionary) -> void:
	call_deferred("_maybe_restore_expression", "animation-finished")


func _on_physics_state(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default":
		return
	var next_state := str(payload.get("movementState", payload.get("state", movement_state))).strip_edges().to_lower()
	if next_state.is_empty():
		return
	var was_stationary := movement_state == "stationary"
	movement_state = next_state
	if movement_state != "stationary":
		_clear_expression()
		if not _pending_emotion_instance.is_empty():
			_report_pending_emotion("movement-authority", true)
	elif not was_stationary:
		call_deferred("_maybe_restore_expression", "movement-stopped")


func _on_character_disappear(_payload: Dictionary) -> void:
	_clear_expression()


func _maybe_restore_expression(source: String) -> void:
	if speech_active or movement_state != "stationary" or not _body_is_expression_safe():
		return
	var expression_name := _preferred_expression([current_emotion, "neutral"])
	var rendered := _show_expression(expression_name)
	event_bus.publish(&"expression.changed", {
		"companion_id": "default",
		"expression": expression_name if rendered else "",
		"emotion": current_emotion,
		"source": source,
		"speaking": false,
		"fallback": not rendered,
	})
	if not _pending_emotion_instance.is_empty():
		_report_pending_emotion(expression_name if rendered else "body-animation-fallback", not rendered)


func _body_is_expression_safe() -> bool:
	if not is_instance_valid(body_sprite) or body_sprite.sprite_frames == null:
		return false
	var animation_name := str(body_sprite.animation).strip_edges().to_lower()
	if animation_name.is_empty() or animation_name.begins_with("idle"):
		return true
	if not body_sprite.is_playing():
		return true
	return false


func _expressions() -> Dictionary:
	if context == null:
		return {}
	var value: Variant = context.character.get("expressions", {})
	return value if value is Dictionary else {}


func _preferred_expression(candidates: Array[String]) -> String:
	var expressions := _expressions()
	for candidate in candidates:
		var normalized := candidate.strip_edges().to_lower()
		if not normalized.is_empty() and expressions.has(normalized):
			return normalized
	return ""


func _show_expression(expression_name: String) -> bool:
	if expression_name.is_empty() or not is_instance_valid(body_sprite) or not is_instance_valid(expression_sprite):
		_clear_expression()
		return false
	var expression_value: Variant = _expressions().get(expression_name, {})
	if not (expression_value is Dictionary):
		_clear_expression()
		return false
	var expression: Dictionary = expression_value
	var sheet := _loaded_sheet_for_expression(expression)
	if sheet.is_empty():
		_clear_expression()
		return false
	var frame_indices_value: Variant = expression.get("frames", [])
	var frame_indices: Array = frame_indices_value if frame_indices_value is Array else []
	if frame_indices.is_empty():
		_clear_expression()
		return false

	var frame_width := int(sheet.get("frame_width", 0))
	var frame_height := int(sheet.get("frame_height", 0))
	var texture: Texture2D = sheet.get("texture")
	if texture == null or frame_width <= 0 or frame_height <= 0:
		_clear_expression()
		return false
	var columns := maxi(1, texture.get_width() / frame_width)
	var rows := maxi(1, texture.get_height() / frame_height)
	var max_frame := columns * rows
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	frames.add_animation(&"expression")
	frames.set_animation_loop(&"expression", frame_indices.size() > 1)
	frames.set_animation_speed(&"expression", 2.0 if frame_indices.size() > 1 else 1.0)
	for raw_index in frame_indices:
		var frame_index := int(raw_index)
		if frame_index < 0 or frame_index >= max_frame:
			continue
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2(
			(frame_index % columns) * frame_width,
			(frame_index / columns) * frame_height,
			frame_width,
			frame_height
		)
		frames.add_frame(&"expression", atlas)
	if frames.get_frame_count(&"expression") <= 0:
		_clear_expression()
		return false

	if not _expression_visible:
		_body_visibility_before_expression = body_sprite.visible
	body_sprite.visible = false
	expression_sprite.sprite_frames = frames
	_sync_expression_transform()
	expression_sprite.visible = true
	expression_sprite.play(&"expression")
	_expression_visible = true
	active_expression = expression_name
	return true


func _loaded_sheet_for_expression(expression: Dictionary) -> Dictionary:
	var entry_value: Variant = context.package.get("entry", {}) if context != null else {}
	if not (entry_value is Dictionary) or body_sprite.sprite_frames == null:
		return {}
	var entry: Dictionary = entry_value
	var sprites_value: Variant = entry.get("sprites", [])
	var sprites: Array = sprites_value if sprites_value is Array else []
	if sprites.is_empty():
		return {}
	var default_sprite_id := ""
	for sprite_value in sprites:
		if sprite_value is Dictionary:
			default_sprite_id = str((sprite_value as Dictionary).get("id", ""))
			if not default_sprite_id.is_empty():
				break
	var sprite_id := str(expression.get("sprite", default_sprite_id)).strip_edges()
	if sprite_id.is_empty():
		sprite_id = default_sprite_id
	var sprite_definition := _sprite_definition(sprites, sprite_id)
	if sprite_definition.is_empty():
		return {}
	var frame_size_value: Variant = sprite_definition.get("frameSize", [])
	if not (frame_size_value is Array) or (frame_size_value as Array).size() < 2:
		return {}
	var frame_width := int((frame_size_value as Array)[0])
	var frame_height := int((frame_size_value as Array)[1])
	if frame_width <= 0 or frame_height <= 0:
		return {}

	var animations_value: Variant = entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	for animation_name in body_sprite.sprite_frames.get_animation_names():
		var clip_value: Variant = animations.get(str(animation_name), {})
		if not (clip_value is Dictionary):
			continue
		var clip: Dictionary = clip_value
		var clip_sprite_id := str(clip.get("sprite", default_sprite_id)).strip_edges()
		if clip_sprite_id.is_empty():
			clip_sprite_id = default_sprite_id
		if clip_sprite_id != sprite_id or body_sprite.sprite_frames.get_frame_count(animation_name) <= 0:
			continue
		var frame_texture := body_sprite.sprite_frames.get_frame_texture(animation_name, 0)
		if frame_texture is AtlasTexture:
			var atlas_texture := frame_texture as AtlasTexture
			if atlas_texture.atlas != null:
				return {"texture": atlas_texture.atlas, "frame_width": frame_width, "frame_height": frame_height}
	return {}


func _sprite_definition(sprites: Array, sprite_id: String) -> Dictionary:
	for sprite_value in sprites:
		if sprite_value is Dictionary and str((sprite_value as Dictionary).get("id", "")) == sprite_id:
			return (sprite_value as Dictionary).duplicate(true)
	return {}


func _sync_expression_transform() -> void:
	if not is_instance_valid(body_sprite) or not is_instance_valid(expression_sprite):
		return
	expression_sprite.position = body_sprite.position
	expression_sprite.rotation = body_sprite.rotation
	expression_sprite.scale = body_sprite.scale
	expression_sprite.flip_h = body_sprite.flip_h
	expression_sprite.flip_v = body_sprite.flip_v
	expression_sprite.offset = body_sprite.offset
	expression_sprite.modulate = body_sprite.modulate


func _clear_expression() -> void:
	active_expression = ""
	if _expression_visible and is_instance_valid(body_sprite):
		body_sprite.visible = _body_visibility_before_expression
	_expression_visible = false
	if is_instance_valid(expression_sprite):
		expression_sprite.stop()
		expression_sprite.visible = false


func _report_pending_emotion(expression_set: String, fallback: bool) -> void:
	if _pending_emotion_instance.is_empty():
		return
	var emotion_instance := _pending_emotion_instance
	_pending_emotion_instance = ""
	if services == null or not is_instance_valid(services.bridge_adapter):
		return
	var bridge: Node = services.bridge_adapter.bridge
	if not is_instance_valid(bridge) or not bridge.has_method("report_emotion_presented"):
		return
	bridge.call_deferred(
		"report_emotion_presented",
		emotion_instance,
		"default",
		current_emotion,
		expression_set,
		fallback
	)
