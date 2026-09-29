extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3HoverController

var host: Control
var menu: Control

var dragging: bool = false
var suppressed_until_exit: bool = false
var pointer_inside: bool = false
var hide_generation: int = 0

var menu_gap: float = 12.0
var screen_margin: float = 16.0
var bridge_padding: float = 10.0
var hide_delay_seconds: float = 0.35


func bind(character_host: Control, target_menu: Control) -> void:
	host = character_host
	menu = target_menu
	if is_instance_valid(menu):
		menu.visible = false


func start() -> void:
	event_bus.subscribe(&"character.drag_started", Callable(self, "_on_drag_started"))
	event_bus.subscribe(&"character.drag_finished", Callable(self, "_on_drag_finished"))
	event_bus.subscribe(&"character.position_changed", Callable(self, "_on_character_position_changed"))
	event_bus.subscribe(&"monitor.topology_changed", Callable(self, "_on_geometry_changed"))
	event_bus.subscribe(&"window.restored", Callable(self, "_on_geometry_changed"))


func stop() -> void:
	event_bus.unsubscribe(&"character.drag_started", Callable(self, "_on_drag_started"))
	event_bus.unsubscribe(&"character.drag_finished", Callable(self, "_on_drag_finished"))
	event_bus.unsubscribe(&"character.position_changed", Callable(self, "_on_character_position_changed"))
	event_bus.unsubscribe(&"monitor.topology_changed", Callable(self, "_on_geometry_changed"))
	event_bus.unsubscribe(&"window.restored", Callable(self, "_on_geometry_changed"))


func _process(_delta: float) -> void:
	if not is_instance_valid(host) or not is_instance_valid(menu):
		return
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		# The native host owns the hit-test surface in G12.5. The overlay menu is
		# too large for the 256x256 render client and would cover the character.
		if menu.visible:
			menu.visible = false
			event_bus.publish(&"click_through.refresh_requested", {})
		return

	var mouse_position: Vector2 = host.get_viewport().get_mouse_position()
	var host_rect: Rect2 = _character_interaction_rect()
	var menu_rect: Rect2 = menu.get_global_rect().grow(bridge_padding)
	var bridge_rect: Rect2 = _bridge_rect(host_rect, menu_rect)

	var inside: bool = host_rect.has_point(mouse_position) \
		or (menu.visible and menu_rect.has_point(mouse_position)) \
		or (menu.visible and bridge_rect.has_point(mouse_position))

	if not inside:
		suppressed_until_exit = false

	if inside and not pointer_inside and not dragging and not suppressed_until_exit:
		_show_menu()
	elif not inside and pointer_inside and not dragging:
		_schedule_hide()

	pointer_inside = inside


func _show_menu() -> void:
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	hide_generation += 1
	_layout_menu()
	if not menu.visible:
		menu.visible = true
		event_bus.publish(&"click_through.refresh_requested", {})


func _schedule_hide() -> void:
	hide_generation += 1
	var generation: int = hide_generation
	await get_tree().create_timer(hide_delay_seconds).timeout

	if generation != hide_generation or dragging:
		return

	var mouse_position: Vector2 = host.get_viewport().get_mouse_position()
	var host_rect: Rect2 = _character_interaction_rect()
	var menu_rect: Rect2 = menu.get_global_rect().grow(bridge_padding)
	var bridge_rect: Rect2 = _bridge_rect(host_rect, menu_rect)

	if not host_rect.has_point(mouse_position) \
	and not menu_rect.has_point(mouse_position) \
	and not bridge_rect.has_point(mouse_position):
		menu.visible = false
		event_bus.publish(&"click_through.refresh_requested", {})


func _layout_menu() -> void:
	var viewport_size: Vector2 = host.get_viewport_rect().size
	var character_rect: Rect2 = _character_interaction_rect()
	var menu_size: Vector2 = menu.size

	# Prefer the left side so the menu does not cover the character.
	var target := Vector2(
		character_rect.position.x - menu_size.x - menu_gap,
		character_rect.position.y + (character_rect.size.y - menu_size.y) * 0.5
	)

	# If there is not enough room on the left, use the right side.
	if target.x < screen_margin:
		target.x = character_rect.end.x + menu_gap

	target.x = clampf(
		target.x,
		screen_margin,
		maxf(screen_margin, viewport_size.x - menu_size.x - screen_margin)
	)
	target.y = clampf(
		target.y,
		screen_margin,
		maxf(screen_margin, viewport_size.y - menu_size.y - screen_margin)
	)

	menu.position = target


func _character_interaction_rect() -> Rect2:
	# During V3 migration, use the visible host rectangle for reliable dragging
	# and hover. The package hitbox remains available in RuntimeContext for the
	# later exact-alpha/input-mask implementation.
	return Rect2(host.position, host.size).grow(8.0)


func _bridge_rect(character_rect: Rect2, menu_rect: Rect2) -> Rect2:
	var left: float = minf(character_rect.end.x, menu_rect.end.x)
	var right: float = maxf(character_rect.position.x, menu_rect.position.x)
	var top: float = maxf(character_rect.position.y, menu_rect.position.y)
	var bottom: float = minf(character_rect.end.y, menu_rect.end.y)

	if right >= left:
		# Horizontal bridge between menu and character.
		var bridge_top: float = top
		var bridge_bottom: float = bottom
		if bridge_bottom <= bridge_top:
			var center_y: float = (character_rect.get_center().y + menu_rect.get_center().y) * 0.5
			bridge_top = center_y - 24.0
			bridge_bottom = center_y + 24.0
		return Rect2(
			Vector2(left - bridge_padding, bridge_top - bridge_padding),
			Vector2((right - left) + bridge_padding * 2.0, (bridge_bottom - bridge_top) + bridge_padding * 2.0)
		)

	return character_rect.merge(menu_rect)


func _on_drag_started(_payload: Dictionary) -> void:
	dragging = true
	suppressed_until_exit = true
	hide_generation += 1
	if is_instance_valid(menu):
		menu.visible = false
	event_bus.publish(&"click_through.refresh_requested", {})


func _on_drag_finished(_payload: Dictionary) -> void:
	dragging = false


func _on_character_position_changed(_payload: Dictionary) -> void:
	if is_instance_valid(menu) and menu.visible:
		_layout_menu()


func _on_geometry_changed(_payload: Dictionary) -> void:
	if is_instance_valid(menu) and menu.visible:
		_layout_menu()
