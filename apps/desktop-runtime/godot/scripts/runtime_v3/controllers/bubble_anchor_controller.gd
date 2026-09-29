class_name RuntimeV3BubbleAnchorController
extends Node
## Positions the Bubble Box from the actual character origin and bubbleAnchor.
##
## Expected context values:
##   character_position: companion Node2D global position
##   bubble_anchor: Vector2 from character.json
##   character_scale: companion scale
##
## The controller can also show an anchor marker and hitbox rectangle in debug.

@export var bubble_gap: float = 12.0
@export var keep_inside_viewport: bool = true
@export var debug_marker_radius: float = 7.0

var _bubble: Control = null
var _companion: Node2D = null
var _debug_layer: Control = null

var _bubble_anchor: Vector2 = Vector2.ZERO
var _hitbox: Rect2 = Rect2()
var _debug_enabled: bool = false


func configure(
	companion: Node2D,
	bubble: Control,
	debug_layer: Control = null
) -> void:
	_companion = companion
	_bubble = bubble
	_debug_layer = debug_layer


func apply_character_config(character_config: Dictionary) -> void:
	_bubble_anchor = _read_vector2(
		character_config.get("bubbleAnchor", {}),
		Vector2(0.0, -220.0)
	)

	_hitbox = _read_rect2(
		character_config.get("hitbox", {}),
		Rect2(-128.0, -220.0, 256.0, 256.0)
	)

	update_bubble_position()
	_queue_debug_redraw()


func update_bubble_position() -> void:
	if _bubble == null or _companion == null:
		return

	var scaled_anchor := Vector2(
		_bubble_anchor.x * _companion.scale.x,
		_bubble_anchor.y * _companion.scale.y
	)

	var anchor_global: Vector2 = _companion.global_position + scaled_anchor
	var bubble_size: Vector2 = _bubble.size

	# Center Bubble Box above the anchor.
	var target_position := Vector2(
		anchor_global.x - bubble_size.x * 0.5,
		anchor_global.y - bubble_size.y - bubble_gap
	)

	if keep_inside_viewport:
		target_position = _clamp_to_viewport(
			target_position,
			bubble_size
		)

	_bubble.global_position = target_position


func set_debug_enabled(enabled: bool) -> void:
	_debug_enabled = enabled

	if _debug_layer != null:
		_debug_layer.visible = enabled

	_queue_debug_redraw()


func get_anchor_global_position() -> Vector2:
	if _companion == null:
		return Vector2.ZERO

	return _companion.global_position + Vector2(
		_bubble_anchor.x * _companion.scale.x,
		_bubble_anchor.y * _companion.scale.y
	)


func get_hitbox_global_rect() -> Rect2:
	if _companion == null or not is_instance_valid(_companion) or not _companion.is_inside_tree():
		return Rect2()

	var scale_value := _companion.scale
	var scaled_position := Vector2(
		_hitbox.position.x * scale_value.x,
		_hitbox.position.y * scale_value.y
	)
	var scaled_size := Vector2(
		_hitbox.size.x * absf(scale_value.x),
		_hitbox.size.y * absf(scale_value.y)
	)

	return Rect2(
		_companion.global_position + scaled_position,
		scaled_size
	)


func _process(_delta: float) -> void:
	if _bubble != null and _bubble.visible:
		update_bubble_position()

	if _debug_enabled:
		_queue_debug_redraw()


func _clamp_to_viewport(
	position_value: Vector2,
	control_size: Vector2
) -> Vector2:
	var viewport_rect: Rect2 = get_viewport().get_visible_rect()
	var maximum := viewport_rect.end - control_size

	return Vector2(
		clampf(position_value.x, viewport_rect.position.x, maximum.x),
		clampf(position_value.y, viewport_rect.position.y, maximum.y)
	)


func _queue_debug_redraw() -> void:
	if _debug_layer != null and _debug_layer.has_method("queue_redraw"):
		_debug_layer.queue_redraw()


func _read_vector2(
	value: Variant,
	fallback: Vector2
) -> Vector2:
	if value is Vector2:
		return value

	if value is Dictionary:
		return Vector2(
			float(value.get("x", fallback.x)),
			float(value.get("y", fallback.y))
		)

	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))

	return fallback


func _read_rect2(
	value: Variant,
	fallback: Rect2
) -> Rect2:
	if value is Rect2:
		return value

	if value is Dictionary:
		return Rect2(
			float(value.get("x", fallback.position.x)),
			float(value.get("y", fallback.position.y)),
			float(value.get("width", fallback.size.x)),
			float(value.get("height", fallback.size.y))
		)

	return fallback
