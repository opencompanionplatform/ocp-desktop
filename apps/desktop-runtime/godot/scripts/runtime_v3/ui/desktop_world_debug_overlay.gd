extends Control
class_name RuntimeV3DesktopWorldDebugOverlay
## Visual inspection layer for the Rust-owned Desktop World.
##
## F9 toggles the overlay. Drawing is read-only and uses the latest DTO cache
## from RuntimeV3WorldDebugService.

@export var show_monitors: bool = true
@export var show_windows: bool = true
@export var show_surfaces: bool = true
@export var show_cursor: bool = true
@export var show_taskbar: bool = true

var world_service: RuntimeV3WorldDebugService = null
var selected_surface_id: String = ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_unhandled_key_input(true)
	set_process(true)


func bind_service(service: RuntimeV3WorldDebugService) -> void:
	world_service = service
	if not world_service.world_changed.is_connected(queue_redraw):
		world_service.world_changed.connect(queue_redraw)
	queue_redraw()


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey \
	and event.pressed \
	and not event.echo \
	and event.keycode == KEY_F9:
		visible = not visible
		queue_redraw()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	if world_service == null:
		_draw_status("Desktop World service unavailable")
		return

	var state := world_service.snapshot()
	var desktop_rect := _rect_from_value(
		state.get("virtualDesktopBounds", {})
	)

	if desktop_rect.size.x <= 0.0 or desktop_rect.size.y <= 0.0:
		_draw_status(
			"Desktop World waiting for monitor-layout event\n"
			+ "F9: toggle overlay"
		)
		return

	if show_monitors:
		for monitor in state.get("monitors", []):
			if monitor is Dictionary:
				_draw_monitor(monitor, desktop_rect)

	if show_windows:
		for window_id in state.get("windows", {}).keys():
			var window: Dictionary = state["windows"][window_id]
			_draw_window(str(window_id), window, desktop_rect)

	if show_surfaces:
		for surface_id in state.get("surfaces", {}).keys():
			var surface: Dictionary = state["surfaces"][surface_id]
			_draw_surface(str(surface_id), surface, desktop_rect)

	if show_taskbar:
		var taskbar: Dictionary = state.get("taskbar", {})
		if not taskbar.is_empty():
			var taskbar_rect := _rect_from_value(
				taskbar.get("bounds", {})
			)
			draw_rect(
				_to_overlay_rect(taskbar_rect, desktop_rect),
				Color(0.85, 0.25, 0.95, 0.55),
				true
			)

	if show_cursor:
		var cursor: Dictionary = state.get("cursor", {})
		if not cursor.is_empty():
			var point := _point_from_value(cursor.get("position", {}))
			var local_point := _to_overlay_point(point, desktop_rect)
			draw_circle(local_point, 6.0, Color(1.0, 0.25, 0.25, 0.95))
			draw_line(
				local_point - Vector2(10.0, 0.0),
				local_point + Vector2(10.0, 0.0),
				Color.WHITE,
				1.0
			)
			draw_line(
				local_point - Vector2(0.0, 10.0),
				local_point + Vector2(0.0, 10.0),
				Color.WHITE,
				1.0
			)

	_draw_status(_status_text(state))


func _draw_monitor(monitor: Dictionary, desktop_rect: Rect2) -> void:
	var bounds := _rect_from_value(monitor.get("bounds", {}))
	var work_area := _rect_from_value(monitor.get("workArea", {}))
	var local_bounds := _to_overlay_rect(bounds, desktop_rect)
	var local_work := _to_overlay_rect(work_area, desktop_rect)

	draw_rect(local_bounds, Color(0.1, 0.7, 1.0, 0.18), true)
	draw_rect(local_bounds, Color(0.1, 0.8, 1.0, 0.95), false, 2.0)
	draw_rect(local_work, Color(0.2, 1.0, 0.55, 0.8), false, 1.0)
	draw_string(
		ThemeDB.fallback_font,
		local_bounds.position + Vector2(6.0, 18.0),
		str(monitor.get("name", "Monitor")),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		14,
		Color.WHITE
	)


func _draw_window(
	window_id: String,
	window: Dictionary,
	desktop_rect: Rect2
) -> void:
	if not bool(window.get("visible", true)):
		return

	var bounds := _rect_from_value(window.get("bounds", {}))
	var local_rect := _to_overlay_rect(bounds, desktop_rect)
	var active := bool(window.get("active", false))
	var minimized := bool(window.get("minimized", false))
	var outline := (
		Color(1.0, 0.75, 0.1, 0.95)
		if active
		else Color(0.75, 0.8, 0.9, 0.7)
	)
	if minimized:
		outline = Color(0.5, 0.5, 0.5, 0.65)

	draw_rect(local_rect, Color(outline, 0.08), true)
	draw_rect(local_rect, outline, false, 2.5 if active else 1.0)

	var label := str(window.get(
		"titleClassification",
		window.get("applicationId", window_id.left(8))
	))
	draw_string(
		ThemeDB.fallback_font,
		local_rect.position + Vector2(4.0, 14.0),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		maxf(20.0, local_rect.size.x - 8.0),
		11,
		outline
	)


func _draw_surface(
	surface_id: String,
	surface: Dictionary,
	desktop_rect: Rect2
) -> void:
	var geometry := _rect_from_value(
		surface.get("geometry", surface.get("bounds", {}))
	)
	if geometry.size.x <= 0.0 and geometry.size.y <= 0.0:
		return

	var local_rect := _to_overlay_rect(geometry, desktop_rect)
	var selected := surface_id == selected_surface_id
	var color := (
		Color(1.0, 0.2, 0.8, 1.0)
		if selected
		else Color(0.2, 1.0, 0.65, 0.75)
	)
	draw_rect(local_rect, color, false, 2.0 if selected else 1.0)


func _draw_status(text: String) -> void:
	var panel := Rect2(Vector2(12.0, 12.0), Vector2(430.0, 132.0))
	draw_rect(panel, Color(0.02, 0.025, 0.035, 0.88), true)
	draw_rect(panel, Color(0.25, 0.8, 1.0, 0.85), false, 1.0)
	var lines := text.split("\n")
	var y := 32.0
	for line in lines:
		draw_string(
			ThemeDB.fallback_font,
			Vector2(24.0, y),
			line,
			HORIZONTAL_ALIGNMENT_LEFT,
			400.0,
			13,
			Color.WHITE
		)
		y += 18.0


func _status_text(state: Dictionary) -> String:
	return (
		"Desktop World Debug [F9]\n"
		+ "state=%s connected=%s revision=%d\n"
		% [
			state.get("runtimeState", "unknown"),
			state.get("connected", false),
			state.get("revision", 0),
		]
		+ "monitors=%d windows=%d surfaces=%d\n"
		% [
			state.get("monitors", []).size(),
			state.get("windows", {}).size(),
			state.get("surfaces", {}).size(),
		]
		+ "last=%s"
		% state.get("lastEventType", "")
	)


func _to_overlay_point(point: Vector2, desktop_rect: Rect2) -> Vector2:
	var size := get_viewport_rect().size
	return Vector2(
		(point.x - desktop_rect.position.x)
			* size.x / desktop_rect.size.x,
		(point.y - desktop_rect.position.y)
			* size.y / desktop_rect.size.y
	)


func _to_overlay_rect(rect: Rect2, desktop_rect: Rect2) -> Rect2:
	return Rect2(
		_to_overlay_point(rect.position, desktop_rect),
		Vector2(
			rect.size.x * get_viewport_rect().size.x
				/ desktop_rect.size.x,
			rect.size.y * get_viewport_rect().size.y
				/ desktop_rect.size.y
		)
	)


func _rect_from_value(value: Variant) -> Rect2:
	if not value is Dictionary:
		return Rect2()
	var data: Dictionary = value
	if data.has("0"):
		data = data.get("0", {})
	var origin := _point_from_value(data.get("origin", {}))
	var size := _size_from_value(data.get("size", {}))
	return Rect2(origin, size)


func _point_from_value(value: Variant) -> Vector2:
	if not value is Dictionary:
		return Vector2.ZERO
	return Vector2(
		float(value.get("x", 0.0)),
		float(value.get("y", 0.0))
	)


func _size_from_value(value: Variant) -> Vector2:
	if not value is Dictionary:
		return Vector2.ZERO
	return Vector2(
		float(value.get("width", 0.0)),
		float(value.get("height", 0.0))
	)
