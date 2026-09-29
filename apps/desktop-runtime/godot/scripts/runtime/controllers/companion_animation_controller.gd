extends Node
class_name CompanionAnimationController

signal animation_changed(name: StringName)
signal animation_missing(name: StringName)

@export var default_animation: StringName = &"idle_neutral"
@export var fallback_animation: StringName = &"idle"

var sprite: AnimatedSprite2D

func bind(target: AnimatedSprite2D) -> void:
    sprite = target
    if sprite == null:
        push_warning("CompanionAnimationController: target sprite is null")
        return
    play_default()

func has_animation(name: StringName) -> bool:
    return sprite != null \
        and sprite.sprite_frames != null \
        and sprite.sprite_frames.has_animation(name)

func play(name: StringName, restart: bool = false) -> bool:
    if not has_animation(name):
        animation_missing.emit(name)
        return false
    if restart or sprite.animation != name or not sprite.is_playing():
        sprite.play(name)
        animation_changed.emit(name)
    return true

func play_default() -> void:
    if play(default_animation):
        return
    if play(fallback_animation):
        return
    if sprite != null and sprite.sprite_frames != null:
        var names: PackedStringArray = sprite.sprite_frames.get_animation_names()
        if not names.is_empty():
            play(StringName(names[0]))

func stop() -> void:
    if sprite != null:
        sprite.stop()

func set_speed(scale_value: float) -> void:
    if sprite != null:
        sprite.speed_scale = maxf(scale_value, 0.0)
