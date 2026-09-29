extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ClickThroughController

var window: Window
var character_host: Control
var hover_menu: Control
var quick_panel: Control
var picker: Control
var bubble: Control
var notification: Control
var last_polygon: PackedVector2Array = PackedVector2Array()
var character_ready: bool = false
var drag_capture_active: bool = false


func bind(
	target_window: Window,
	host: Control,
	hover: Control,
	quick: Control,
	character_picker: Control,
	bubble_panel: Control,
	notification_panel: Control = null
) -> void:
	window = target_window
	character_host = host
	hover_menu = hover
	quick_panel = quick
	picker = character_picker
	bubble = bubble_panel
	notification = notification_panel


func start() -> void:
	event_bus.subscribe(&"click_through.refresh_requested", Callable(self, "_on_refresh_requested"))
	event_bus.subscribe(&"character.position_changed", Callable(self, "_on_refresh_requested"))
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.subscribe(&"character.load_failed", Callable(self, "_on_character_load_failed"))
	event_bus.subscribe(&"monitor.topology_changed", Callable(self, "_on_refresh_requested"))
	event_bus.subscribe(&"window.restored", Callable(self, "_on_refresh_requested"))
	event_bus.subscribe(
		&"click_through.drag_capture_started",
		Callable(self, "_on_drag_capture_started")
	)
	event_bus.subscribe(
		&"click_through.drag_capture_finished",
		Callable(self, "_on_drag_capture_finished")
	)


func stop() -> void:
	event_bus.unsubscribe(&"click_through.refresh_requested", Callable(self, "_on_refresh_requested"))
	event_bus.unsubscribe(&"character.position_changed", Callable(self, "_on_refresh_requested"))
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.unsubscribe(&"character.load_failed", Callable(self, "_on_character_load_failed"))
	event_bus.unsubscribe(&"monitor.topology_changed", Callable(self, "_on_refresh_requested"))
	event_bus.unsubscribe(&"window.restored", Callable(self, "_on_refresh_requested"))
	event_bus.unsubscribe(
		&"click_through.drag_capture_started",
		Callable(self, "_on_drag_capture_started")
	)
	event_bus.unsubscribe(
		&"click_through.drag_capture_finished",
		Callable(self, "_on_drag_capture_finished")
	)


func _on_character_loaded(_payload: Dictionary) -> void:
	character_ready = true
	call_deferred("refresh")


func _on_character_load_failed(_payload: Dictionary) -> void:
	character_ready = false
	_apply_polygon(PackedVector2Array())


func _on_drag_capture_started(_payload: Dictionary) -> void:
	drag_capture_active = true
	# Empty passthrough polygon means the overlay receives the full drag gesture.
	# It is restored immediately after the canonical release transaction.
	_apply_polygon(PackedVector2Array())


func _on_drag_capture_finished(_payload: Dictionary) -> void:
	drag_capture_active = false
	call_deferred("refresh")


func _on_refresh_requested(_payload: Dictionary) -> void:
	if drag_capture_active:
		return
	refresh()


func refresh() -> void:
	if not is_instance_valid(window):
		return

	var overlay_enabled: bool = bool(context.runtime_config.get("overlay_enabled", false))
	var passthrough_enabled: bool = bool(context.runtime_config.get("click_through_enabled", true))
	var modal_open: bool = bool(context.runtime_config.get("native_dialog_open", false))

	if drag_capture_active:
		_apply_polygon(PackedVector2Array())
		return

	# Empty polygon disables passthrough and avoids rendering/input clipping while
	# startup or a native modal dialog is being prepared.
	if not overlay_enabled or not passthrough_enabled or not character_ready or modal_open:
		_apply_polygon(PackedVector2Array())
		return

	var points := PackedVector2Array()
	_append_rect_points(points, Rect2(character_host.position, character_host.size).grow(18.0))

	# Never include a hidden menu at its scene-default position. This was the
	# source of the startup polygon stretching across the desktop.
	if hover_menu.visible:
		_append_rect_points(points, hover_menu.get_global_rect().grow(18.0))

	if quick_panel.visible:
		_append_rect_points(points, quick_panel.get_global_rect().grow(10.0))
	# A top-level Character Manager owns its own input region and must never
	# expand the companion surface's passthrough polygon.
	if is_instance_valid(picker) and picker.visible and picker.get_window() == window:
		_append_rect_points(points, picker.get_global_rect().grow(10.0))
	if bubble.visible:
		_append_rect_points(points, bubble.get_global_rect().grow(10.0))
	if is_instance_valid(notification) and notification.visible:
		_append_rect_points(points, notification.get_global_rect().grow(10.0))

	var safe_polygon: PackedVector2Array = Geometry2D.convex_hull(points)
	_apply_polygon(safe_polygon)


func _append_rect_points(points: PackedVector2Array, rect: Rect2) -> void:
	points.append(rect.position)
	points.append(Vector2(rect.end.x, rect.position.y))
	points.append(rect.end)
	points.append(Vector2(rect.position.x, rect.end.y))


func _apply_polygon(points: PackedVector2Array) -> void:
	if _same(points, last_polygon):
		return
	window.mouse_passthrough_polygon = points
	last_polygon = points.duplicate()


func _same(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size():
		return false
	for index in range(a.size()):
		if not a[index].is_equal_approx(b[index]):
			return false
	return true
