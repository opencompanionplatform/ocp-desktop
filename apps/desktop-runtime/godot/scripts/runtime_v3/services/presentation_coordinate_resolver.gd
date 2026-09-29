extends RefCounted
class_name RuntimeV3PresentationCoordinateResolver
## RC27.4 presentation-coordinate authority.
##
## Input is always canonical Windows desktop-logical coordinates.
## Output is always local coordinates for the current Godot presentation
## viewport. Debug-window mode projects one logical monitor into the current
## viewport. Overlay mode delegates to RuntimeV3CoordinateMapper's virtual
## overlay canvas.

var coordinate_mapper: RefCounted
var active_debug_screen: int = -1
var active_overlay_screen: int = -1
var active_overlay_descriptor: Dictionary = {}
var debug_enabled: bool = false
var debug_interval_ms: int = 250
var _last_log_ms_by_phase: Dictionary = {}


func configure(mapper: RefCounted) -> void:
	coordinate_mapper = mapper
	debug_enabled = _env_flag("OCP_COORDINATE_DEBUG") or _env_flag("OCP_VISUAL_DEBUG")


func set_overlay_screen(descriptor: Dictionary) -> bool:
	if descriptor.is_empty():
		return false
	var screen_index: int = int(descriptor.get("screen", -1))
	var logical: Rect2 = descriptor.get("logical", Rect2())
	var physical: Rect2 = descriptor.get("physical", Rect2())
	if screen_index < 0 or logical.size == Vector2.ZERO or physical.size == Vector2.ZERO:
		return false
	var changed: bool = screen_index != active_overlay_screen
	active_overlay_screen = screen_index
	active_overlay_descriptor = descriptor.duplicate(true)
	return changed


func clear_overlay_screen() -> void:
	active_overlay_screen = -1
	active_overlay_descriptor.clear()


func desktop_point_to_local(
	desktop_point: Vector2,
	viewport_size: Vector2,
	overlay_enabled: bool
) -> Vector2:
	_ensure_mapper()
	if coordinate_mapper == null:
		return desktop_point
	if overlay_enabled:
		if not active_overlay_descriptor.is_empty():
			var logical: Rect2 = active_overlay_descriptor.get("logical", Rect2())
			var normalized := Vector2(
				_ratio(desktop_point.x - logical.position.x, logical.size.x),
				_ratio(desktop_point.y - logical.position.y, logical.size.y)
			)
			return normalized * _safe_viewport(viewport_size)
		return coordinate_mapper.call("desktop_to_overlay", desktop_point)

	var item: Dictionary = coordinate_mapper.call("screen_for_desktop_point", desktop_point)
	if item.is_empty():
		return desktop_point
	active_debug_screen = int(item.get("screen", 0))
	var logical: Rect2 = item.get("logical", Rect2())
	var normalized := Vector2(
		_ratio(desktop_point.x - logical.position.x, logical.size.x),
		_ratio(desktop_point.y - logical.position.y, logical.size.y)
	)
	var local := normalized * _safe_viewport(viewport_size)
	_log("desktop-to-debug-viewport", {
		"desktop": desktop_point,
		"local": local,
		"screen": active_debug_screen,
		"logical": logical,
		"viewport_size": viewport_size,
	})
	return local


func local_point_to_desktop(
	local_point: Vector2,
	viewport_size: Vector2,
	overlay_enabled: bool
) -> Vector2:
	_ensure_mapper()
	if coordinate_mapper == null:
		return local_point
	if overlay_enabled:
		if not active_overlay_descriptor.is_empty():
			var logical: Rect2 = active_overlay_descriptor.get("logical", Rect2())
			var safe_viewport := _safe_viewport(viewport_size)
			var normalized := Vector2(
				_ratio(local_point.x, safe_viewport.x),
				_ratio(local_point.y, safe_viewport.y)
			)
			return logical.position + normalized * logical.size
		return coordinate_mapper.call("overlay_to_desktop", local_point)

	var item: Dictionary = coordinate_mapper.call("screen_by_index", active_debug_screen)
	if item.is_empty():
		item = coordinate_mapper.call("primary_screen_descriptor")
	if item.is_empty():
		return local_point
	var logical: Rect2 = item.get("logical", Rect2())
	var safe_viewport := _safe_viewport(viewport_size)
	var normalized := Vector2(
		_ratio(local_point.x, safe_viewport.x),
		_ratio(local_point.y, safe_viewport.y)
	)
	var desktop := logical.position + normalized * logical.size
	_log("debug-viewport-to-desktop", {
		"local": local_point,
		"desktop": desktop,
		"screen": int(item.get("screen", 0)),
		"logical": logical,
		"viewport_size": viewport_size,
	})
	return desktop


func overlay_canvas_contains_host(
	host_position: Vector2,
	host_size: Vector2,
	overlay_canvas_size: Vector2
) -> bool:
	if overlay_canvas_size.x <= 0.0 or overlay_canvas_size.y <= 0.0:
		return false
	return Rect2(Vector2.ZERO, overlay_canvas_size).intersects(
		Rect2(host_position, host_size),
		true
	)


func desktop_feet_to_host_position(
	desktop_feet: Vector2,
	host_size: Vector2,
	viewport_size: Vector2,
	overlay_enabled: bool
) -> Vector2:
	if not overlay_enabled and _env_flag("OCP_NATIVE_PRODUCTION_ENABLED"):
		# The native HWND, not the embedded Godot child, owns desktop placement.
		return Vector2.ZERO
	var local_feet := desktop_point_to_local(
		desktop_feet,
		viewport_size,
		overlay_enabled
	)
	var target := local_feet - Vector2(host_size.x * 0.5, host_size.y)
	if not overlay_enabled:
		target = _clamp_host(target, host_size, viewport_size)
	return target


func host_position_to_desktop_feet(
	host_position: Vector2,
	host_size: Vector2,
	viewport_size: Vector2,
	overlay_enabled: bool
) -> Vector2:
	if not overlay_enabled and _env_flag("OCP_NATIVE_PRODUCTION_ENABLED"):
		return Vector2.ZERO
	var local_feet := host_position + Vector2(host_size.x * 0.5, host_size.y)
	return local_point_to_desktop(local_feet, viewport_size, overlay_enabled)


func _ensure_mapper() -> void:
	if coordinate_mapper == null:
		return
	var screens: Array = coordinate_mapper.get("screens")
	if screens.is_empty():
		coordinate_mapper.call("refresh")


func _clamp_host(target: Vector2, host_size: Vector2, viewport_size: Vector2) -> Vector2:
	var maximum := Vector2(
		maxf(0.0, viewport_size.x - host_size.x),
		maxf(0.0, viewport_size.y - host_size.y)
	)
	return Vector2(
		clampf(target.x, 0.0, maximum.x),
		clampf(target.y, 0.0, maximum.y)
	)


func _safe_viewport(viewport_size: Vector2) -> Vector2:
	return Vector2(maxf(viewport_size.x, 1.0), maxf(viewport_size.y, 1.0))


func _ratio(value: float, extent: float) -> float:
	return clampf(value / maxf(extent, 0.001), 0.0, 1.0)


func _log(phase: String, data: Dictionary) -> void:
	if not debug_enabled:
		return
	var now_ms: int = Time.get_ticks_msec()
	var previous_ms: int = int(_last_log_ms_by_phase.get(phase, -debug_interval_ms))
	if now_ms - previous_ms < debug_interval_ms:
		return
	_last_log_ms_by_phase[phase] = now_ms
	print("[presentation-coordinate] phase=", phase, " data=", JSON.stringify(data))


func _env_flag(name: String) -> bool:
	return OS.get_environment(name).strip_edges().to_lower() in [
		"1", "true", "yes", "on"
	]
