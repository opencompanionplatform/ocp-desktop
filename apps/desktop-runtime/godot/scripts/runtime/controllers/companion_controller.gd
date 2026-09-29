extends Node
class_name CompanionController

signal moved(position: Vector2)
signal visibility_changed(is_visible: bool)
signal drag_started
signal drag_finished

@export var screen_margin := Vector2(24.0, 24.0)
@export var walk_speed: float = 260.0
@export var clamp_to_viewport: bool = true

var sprite: AnimatedSprite2D
var animation_controller: Node
var _dragging := false
var _drag_offset := Vector2.ZERO
var _walk_target := Vector2.ZERO
var _walking := false

func bind(target: AnimatedSprite2D, animations: Node = null) -> void:
    sprite = target
    animation_controller = animations
    if animation_controller != null:
        animation_controller.bind(sprite)
    set_process(true)

func _process(delta: float) -> void:
    if sprite == null:
        return
    if _dragging:
        sprite.global_position = _clamp_position(sprite.get_global_mouse_position() - _drag_offset)
        moved.emit(sprite.global_position)
        return
    if _walking:
        var next_position: Vector2 = sprite.global_position.move_toward(_walk_target, walk_speed * delta)
        sprite.global_position = _clamp_position(next_position)
        moved.emit(sprite.global_position)
        if sprite.global_position.distance_to(_walk_target) <= 1.0:
            _walking = false
            if animation_controller != null:
                animation_controller.play_default()

func show_companion() -> void:
    if sprite == null:
        return
    sprite.visible = true
    visibility_changed.emit(true)

func hide_companion() -> void:
    if sprite == null:
        return
    sprite.visible = false
    visibility_changed.emit(false)

func place_bottom_right(viewport_size: Vector2) -> void:
    if sprite == null:
        return
    var half_size: Vector2 = _visual_half_size()
    sprite.position = Vector2(
        viewport_size.x - screen_margin.x - half_size.x,
        viewport_size.y - screen_margin.y - half_size.y
    )
    sprite.position = _clamp_position(sprite.position)
    moved.emit(sprite.position)

func walk_to(target: Vector2, animation: StringName = &"walk") -> void:
    if sprite == null:
        return
    _walk_target = _clamp_position(target)
    _walking = true
    if animation_controller != null:
        animation_controller.play(animation)

func walk_left(distance: float = 220.0) -> void:
    if sprite != null:
        walk_to(sprite.global_position + Vector2(-distance, 0.0))

func walk_right(distance: float = 220.0) -> void:
    if sprite != null:
        walk_to(sprite.global_position + Vector2(distance, 0.0))

func center(viewport_size: Vector2) -> void:
    walk_to(viewport_size * 0.5)

func begin_drag(mouse_position: Vector2) -> void:
    if sprite == null:
        return
    _dragging = true
    _walking = false
    _drag_offset = mouse_position - sprite.global_position
    drag_started.emit()

func end_drag() -> void:
    if not _dragging:
        return
    _dragging = false
    drag_finished.emit()
    if animation_controller != null:
        animation_controller.play_default()

func get_interaction_rect(padding: float = 12.0) -> Rect2:
    if sprite == null:
        return Rect2()
    var half_size: Vector2 = _visual_half_size()
    return Rect2(sprite.global_position - half_size, half_size * 2.0).grow(padding)

func _visual_half_size() -> Vector2:
    if sprite == null or sprite.sprite_frames == null:
        return Vector2(64.0, 64.0)
    var texture: Texture2D = sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame)
    if texture == null:
        return Vector2(64.0, 64.0)
    return texture.get_size() * sprite.scale.abs() * 0.5

func _clamp_position(value: Vector2) -> Vector2:
    if not clamp_to_viewport or sprite == null or sprite.get_viewport() == null:
        return value
    var viewport_size: Vector2 = sprite.get_viewport_rect().size
    var half_size: Vector2 = _visual_half_size()
    return Vector2(
        clampf(value.x, screen_margin.x + half_size.x, viewport_size.x - screen_margin.x - half_size.x),
        clampf(value.y, screen_margin.y + half_size.y, viewport_size.y - screen_margin.y - half_size.y)
    )
