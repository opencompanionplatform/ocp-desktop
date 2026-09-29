extends RefCounted
class_name RuntimeV3CoordinateMapper
## RC26 mixed-DPI multi-monitor coordinate mapper.
##
## Canonical side: Windows desktop logical pixels, primary-monitor origin.
## Godot side: normalized physical-pixel virtual canvas used by the overlay.
##
## An exact map can be supplied through OCP_MONITOR_MAP_JSON:
## [
##   {"screen":0,"logical":[0,0,1920,1080],"physical":[3840,0,2880,1824]},
##   ...
## ]
##
## Without that variable, RC26 derives a best-effort per-monitor map from
## DisplayServer screen positions, sizes, scales, and primary-screen identity.

var screens: Array[Dictionary] = []
var primary_screen: int = 0
var physical_origin: Vector2 = Vector2.ZERO
var debug_enabled: bool = false
var debug_interval_ms: int = 500
var _last_log_ms_by_phase: Dictionary = {}


func refresh() -> void:
	debug_enabled = _env_flag("OCP_COORDINATE_DEBUG") or _env_flag("OCP_VISUAL_DEBUG")
	screens.clear()
	primary_screen = DisplayServer.get_primary_screen()

	if _load_explicit_map():
		_finalize()
		return

	var count: int = DisplayServer.get_screen_count()
	if count <= 0:
		return

	var primary_position := Vector2(DisplayServer.screen_get_position(primary_screen))
	var primary_scale := effective_windows_scale(
		DisplayServer.screen_get_scale(primary_screen),
		DisplayServer.screen_get_dpi(primary_screen)
	)

	for index in range(count):
		var physical_rect := Rect2(
			Vector2(DisplayServer.screen_get_position(index)),
			Vector2(DisplayServer.screen_get_size(index))
		)
		var reported_scale := DisplayServer.screen_get_scale(index)
		var dpi := DisplayServer.screen_get_dpi(index)
		var scale := effective_windows_scale(reported_scale, dpi)
		var logical_rect := derive_logical_rect(
			physical_rect,
			primary_position,
			primary_scale,
			scale
		)

		screens.append({
			"screen": index,
			"scale": scale,
			"reported_scale": reported_scale,
			"dpi": dpi,
			"logical": logical_rect,
			"physical": physical_rect,
		})

	_finalize()


func effective_windows_scale(reported_scale: float, dpi: int) -> float:
	# On Windows ARM64/Godot compatibility mode, screen_get_scale() may report
	# 1.0 even when Windows desktop coordinates are DPI-virtualized at 200%.
	# DPI is therefore the authoritative fallback. Never reduce a valid
	# reported scale; choose the larger signal.
	var scale_from_dpi := maxf(float(dpi) / 96.0, 1.0)
	return maxf(maxf(reported_scale, scale_from_dpi), 0.001)


func derive_logical_rect(
	physical_rect: Rect2,
	primary_physical_position: Vector2,
	primary_scale: float,
	monitor_scale: float
) -> Rect2:
	# Windows canonical desktop coordinates are primary-monitor logical pixels.
	# Monitor displacement uses the primary scale, while each monitor's extent
	# uses its own DPI scale. This matches Desktop World floor bounds.
	var logical_position := (
		physical_rect.position - primary_physical_position
	) / maxf(primary_scale, 0.001)
	var logical_size := physical_rect.size / maxf(monitor_scale, 0.001)
	return Rect2(logical_position, logical_size)


func desktop_to_overlay(point: Vector2) -> Vector2:
	if screens.is_empty():
		return point

	var item := _screen_for_logical_point(point)
	var logical: Rect2 = item.logical
	var physical: Rect2 = item.physical
	var normalized := Vector2(
		_safe_ratio(point.x - logical.position.x, logical.size.x),
		_safe_ratio(point.y - logical.position.y, logical.size.y)
	)
	var result := physical.position - physical_origin + normalized * physical.size
	_log("desktop-to-overlay", {
		"desktop": point,
		"overlay": result,
		"screen": item.screen,
		"logical": logical,
		"physical": physical,
	})
	return result


func overlay_to_desktop(point: Vector2) -> Vector2:
	if screens.is_empty():
		return point

	var absolute_physical := point + physical_origin
	var item := _screen_for_physical_point(absolute_physical)
	var logical: Rect2 = item.logical
	var physical: Rect2 = item.physical
	var normalized := Vector2(
		_safe_ratio(absolute_physical.x - physical.position.x, physical.size.x),
		_safe_ratio(absolute_physical.y - physical.position.y, physical.size.y)
	)
	var result := logical.position + normalized * logical.size
	_log("overlay-to-desktop", {
		"overlay": point,
		"desktop": result,
		"screen": item.screen,
		"logical": logical,
		"physical": physical,
	})
	return result


func contains_desktop_point(point: Vector2, margin: float = 0.0) -> bool:
	if screens.is_empty():
		refresh()
	for item in screens:
		var logical: Rect2 = item.get("logical", Rect2())
		if logical.grow(maxf(margin, 0.0)).has_point(point):
			return true
	return false


func clamp_desktop_point(point: Vector2) -> Vector2:
	if screens.is_empty():
		refresh()
	if screens.is_empty():
		return point
	if contains_desktop_point(point):
		return point

	var nearest := point
	var nearest_distance := INF
	for item in screens:
		var logical: Rect2 = item.get("logical", Rect2())
		var candidate := Vector2(
			clampf(point.x, logical.position.x, logical.end.x),
			clampf(point.y, logical.position.y, logical.end.y)
		)
		var distance := point.distance_squared_to(candidate)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = candidate
	return nearest


func screen_for_desktop_point(point: Vector2) -> Dictionary:
	if screens.is_empty():
		refresh()
	if screens.is_empty():
		return {}
	return _screen_for_logical_point(point).duplicate(true)


func screen_for_overlay_point(point: Vector2) -> Dictionary:
	if screens.is_empty():
		refresh()
	if screens.is_empty():
		return {}
	return _screen_for_physical_point(point + physical_origin).duplicate(true)


func screen_by_index(screen_index: int) -> Dictionary:
	if screens.is_empty():
		refresh()
	for item in screens:
		if int(item.get("screen", -1)) == screen_index:
			return item.duplicate(true)
	return {}


func primary_screen_descriptor() -> Dictionary:
	var item := screen_by_index(primary_screen)
	if not item.is_empty():
		return item
	if screens.is_empty():
		return {}
	return screens[0].duplicate(true)


func describe() -> Dictionary:
	return {
		"primary_screen": primary_screen,
		"physical_origin": physical_origin,
		"screens": screens.duplicate(true),
	}


func _load_explicit_map() -> bool:
	var raw := OS.get_environment("OCP_MONITOR_MAP_JSON").strip_edges()
	if raw.is_empty():
		return false

	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Array):
		push_warning("[coordinate-map] OCP_MONITOR_MAP_JSON must be a JSON array")
		return false

	for value in parsed:
		if not (value is Dictionary):
			continue
		var logical_values: Array = value.get("logical", [])
		var physical_values: Array = value.get("physical", [])
		if logical_values.size() != 4 or physical_values.size() != 4:
			continue
		screens.append({
			"screen": int(value.get("screen", screens.size())),
			"scale": float(value.get("scale", 1.0)),
			"logical": Rect2(
				float(logical_values[0]), float(logical_values[1]),
				float(logical_values[2]), float(logical_values[3])
			),
			"physical": Rect2(
				float(physical_values[0]), float(physical_values[1]),
				float(physical_values[2]), float(physical_values[3])
			),
		})

	return not screens.is_empty()


func _finalize() -> void:
	if screens.is_empty():
		return

	physical_origin = Vector2(INF, INF)
	for item in screens:
		var rect: Rect2 = item.physical
		physical_origin.x = minf(physical_origin.x, rect.position.x)
		physical_origin.y = minf(physical_origin.y, rect.position.y)

	_log("refresh", describe())


func _screen_for_logical_point(point: Vector2) -> Dictionary:
	for item in screens:
		var rect: Rect2 = item.logical
		if rect.has_point(point):
			return item
	return _nearest(point, true)


func _screen_for_physical_point(point: Vector2) -> Dictionary:
	for item in screens:
		var rect: Rect2 = item.physical
		if rect.has_point(point):
			return item
	return _nearest(point, false)


func _nearest(point: Vector2, logical_space: bool) -> Dictionary:
	var best: Dictionary = screens[0]
	var best_distance := INF
	for item in screens:
		var rect: Rect2 = item.logical if logical_space else item.physical
		var closest := Vector2(
			clampf(point.x, rect.position.x, rect.end.x),
			clampf(point.y, rect.position.y, rect.end.y)
		)
		var distance := point.distance_squared_to(closest)
		if distance < best_distance:
			best_distance = distance
			best = item
	return best


func _safe_ratio(value: float, extent: float) -> float:
	return clampf(value / maxf(extent, 0.001), 0.0, 1.0)


func _log(phase: String, data: Dictionary) -> void:
	if not debug_enabled:
		return
	var now_ms: int = Time.get_ticks_msec()
	var previous_ms: int = int(_last_log_ms_by_phase.get(phase, -debug_interval_ms))
	if now_ms - previous_ms < debug_interval_ms:
		return
	_last_log_ms_by_phase[phase] = now_ms
	print("[coordinate-map] phase=", phase, " data=", JSON.stringify(data))


func _env_flag(name: String) -> bool:
	return OS.get_environment(name).strip_edges().to_lower() in [
		"1", "true", "yes", "on"
	]
