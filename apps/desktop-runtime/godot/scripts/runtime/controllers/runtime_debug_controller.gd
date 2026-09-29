extends Node
class_name RuntimeDebugController

signal debug_message(text: String)

@export var start_in_debug_mode: bool = true
@export var enable_click_through_in_overlay: bool = true

var companion: Node
var animations: Node
var hover_menu: Node
var overlay: Node
var click_through: Node
var menu_control: Control
var companion_hit_control: Control

func configure(
    companion_controller: Node,
    animation_controller: Node,
    hover_controller: Node,
    overlay_controller: Node,
    click_controller: Node,
    menu: Control,
    companion_hit: Control = null
) -> void:
    companion = companion_controller
    animations = animation_controller
    hover_menu = hover_controller
    overlay = overlay_controller
    click_through = click_controller
    menu_control = menu
    companion_hit_control = companion_hit

    overlay.bind()
    overlay.apply_mode(start_in_debug_mode)
    hover_menu.bind(menu_control, companion_hit_control)

    if not overlay.viewport_changed.is_connected(_on_viewport_changed):
        overlay.viewport_changed.connect(_on_viewport_changed)
    if not hover_menu.menu_opened.is_connected(_refresh_click_through):
        hover_menu.menu_opened.connect(_refresh_click_through)
    if not hover_menu.menu_closed.is_connected(_refresh_click_through):
        hover_menu.menu_closed.connect(_refresh_click_through)
    if companion != null:
        if not companion.moved.is_connected(_on_companion_moved):
            companion.moved.connect(_on_companion_moved)
        if not companion.visibility_changed.is_connected(_refresh_click_through):
            companion.visibility_changed.connect(_refresh_click_through)

    _refresh_click_through()
    debug_message.emit("Runtime controllers configured")

func set_debug_mode(value: bool) -> void:
    overlay.apply_mode(value)
    click_through.set_enabled(not value and enable_click_through_in_overlay)
    _refresh_click_through()

func toggle_debug_mode() -> void:
    set_debug_mode(not overlay.debug_mode)

func play_animation(name: StringName) -> void:
    if animations != null:
        animations.play(name, true)

func show_companion() -> void:
    if companion != null:
        companion.show_companion()

func hide_companion() -> void:
    if companion != null:
        companion.hide_companion()

func _on_viewport_changed(logical_size: Vector2, physical_size: Vector2i) -> void:
    debug_message.emit("Viewport logical=%s physical=%s" % [logical_size, physical_size])
    if companion != null:
        companion.place_bottom_right(logical_size)
    _refresh_click_through()

func _on_companion_moved(_position: Vector2) -> void:
    # Explicit event update; no per-frame passthrough writes.
    _refresh_click_through()

func _refresh_click_through(_unused = null) -> void:
    if click_through == null or overlay == null:
        return
    click_through.physical_scale = overlay.logical_scale
    click_through.set_enabled(not overlay.debug_mode and enable_click_through_in_overlay)
    var rects: Array[Rect2] = []
    if companion != null and companion.sprite != null and companion.sprite.visible:
        rects.append(companion.get_interaction_rect())
    if menu_control != null and menu_control.visible:
        rects.append(menu_control.get_global_rect())
    click_through.set_interactive_rects(rects)
