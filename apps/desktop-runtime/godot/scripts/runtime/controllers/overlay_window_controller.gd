extends Node
class_name OverlayWindowController

signal viewport_changed(logical_size: Vector2, physical_size: Vector2i)
signal mode_changed(debug_mode: bool)

@export var logical_scale: float = 2.0
@export var debug_window_size := Vector2i(1280, 800)
@export var debug_mode: bool = true

var window: Window
var _last_physical_size := Vector2i.ZERO

func bind(target_window: Window = null) -> void:
    window = target_window if target_window != null else get_window()
    apply_mode(debug_mode)

func apply_mode(use_debug_mode: bool) -> void:
    if window == null:
        window = get_window()
    debug_mode = use_debug_mode
    if debug_mode:
        _apply_debug_window()
    else:
        _apply_overlay_window()
    mode_changed.emit(debug_mode)
    _emit_viewport_changed()

func toggle_mode() -> void:
    apply_mode(not debug_mode)

func sync_to_current_screen() -> void:
    if window == null:
        return
    var screen: int = DisplayServer.window_get_current_screen(window.get_window_id())
    var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
    if not debug_mode:
        window.position = usable.position
        window.size = usable.size
    _emit_viewport_changed()

func get_logical_viewport_size() -> Vector2:
    if window == null:
        return Vector2.ZERO
    var safe_scale: float = maxf(logical_scale, 1.0)
    return Vector2(window.size) / safe_scale

func physical_to_logical(value: Vector2) -> Vector2:
    return value / maxf(logical_scale, 1.0)

func logical_to_physical(value: Vector2) -> Vector2:
    return value * maxf(logical_scale, 1.0)

func _apply_debug_window() -> void:
    window.borderless = false
    window.transparent = false
    window.always_on_top = false
    window.unresizable = false
    window.size = debug_window_size
    window.position = Vector2i(80, 80)
    window.mouse_passthrough_polygon = PackedVector2Array()

func _apply_overlay_window() -> void:
    window.borderless = true
    window.transparent = true
    window.always_on_top = true
    window.unresizable = true
    sync_to_current_screen()

func _emit_viewport_changed() -> void:
    if window == null or window.size == _last_physical_size:
        return
    _last_physical_size = window.size
    viewport_changed.emit(get_logical_viewport_size(), window.size)
