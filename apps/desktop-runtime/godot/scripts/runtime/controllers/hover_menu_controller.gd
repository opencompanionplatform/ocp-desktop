extends Node
class_name HoverMenuController

signal menu_opened
signal menu_closed

@export var hide_delay_seconds: float = 0.55
@export var bridge_padding: float = 28.0

var menu: Control
var companion_hovered := false
var menu_hovered := false
var pinned_open := false
var _hide_generation := 0

func bind(menu_control: Control, companion_hit_control: Control = null) -> void:
    menu = menu_control
    if menu == null:
        push_warning("HoverMenuController: menu is null")
        return
    menu.mouse_filter = Control.MOUSE_FILTER_STOP
    if not menu.mouse_entered.is_connected(_on_menu_entered):
        menu.mouse_entered.connect(_on_menu_entered)
    if not menu.mouse_exited.is_connected(_on_menu_exited):
        menu.mouse_exited.connect(_on_menu_exited)
    if companion_hit_control != null:
        companion_hit_control.mouse_filter = Control.MOUSE_FILTER_STOP
        if not companion_hit_control.mouse_entered.is_connected(_on_companion_entered):
            companion_hit_control.mouse_entered.connect(_on_companion_entered)
        if not companion_hit_control.mouse_exited.is_connected(_on_companion_exited):
            companion_hit_control.mouse_exited.connect(_on_companion_exited)
    menu.hide()

func notify_companion_hover(is_hovered: bool) -> void:
    companion_hovered = is_hovered
    if is_hovered:
        show_menu()
    else:
        _schedule_hide()

func show_menu() -> void:
    if menu == null:
        return
    _hide_generation += 1
    if not menu.visible:
        menu.show()
        menu_opened.emit()

func hide_menu_immediately() -> void:
    if menu == null or pinned_open:
        return
    _hide_generation += 1
    if menu.visible:
        menu.hide()
        menu_closed.emit()

func set_pinned(value: bool) -> void:
    pinned_open = value
    if pinned_open:
        show_menu()
    else:
        _schedule_hide()

func get_combined_hover_rect(companion_rect: Rect2) -> Rect2:
    if menu == null or not menu.visible:
        return companion_rect
    return companion_rect.merge(menu.get_global_rect()).grow(bridge_padding)

func _on_companion_entered() -> void:
    notify_companion_hover(true)

func _on_companion_exited() -> void:
    notify_companion_hover(false)

func _on_menu_entered() -> void:
    menu_hovered = true
    show_menu()

func _on_menu_exited() -> void:
    menu_hovered = false
    _schedule_hide()

func _schedule_hide() -> void:
    _hide_generation += 1
    var generation: int = _hide_generation
    await get_tree().create_timer(hide_delay_seconds).timeout
    if generation != _hide_generation:
        return
    if pinned_open or companion_hovered or menu_hovered:
        return
    hide_menu_immediately()
