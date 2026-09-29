extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3MultiMonitorController

var poll_elapsed: float = 0.0


func start() -> void:
	refresh()


func _process(delta: float) -> void:
	poll_elapsed += delta
	if poll_elapsed >= 1.0:
		poll_elapsed = 0.0
		refresh()


func refresh() -> void:
	var count: int = DisplayServer.get_screen_count()
	if count <= 0:
		return

	var rects: Array = []
	var scales: Array = []
	var dpis: Array = []
	var virtual_rect: Rect2i = DisplayServer.screen_get_usable_rect(0)

	for index in range(count):
		var rect: Rect2i = DisplayServer.screen_get_usable_rect(index)
		if index > 0:
			virtual_rect = virtual_rect.merge(rect)
		rects.append(rect)
		var scale: float = DisplayServer.screen_get_scale(index)
		scales.append(scale if scale > 0.0 else 1.0)
		dpis.append(DisplayServer.screen_get_dpi(index))

	var canvas_scale: float = _choose_canvas_scale(scales)
	var local_rects: Array = []
	for rect_value in rects:
		var rect: Rect2i = rect_value
		local_rects.append(Rect2(
			(Vector2(rect.position) - Vector2(virtual_rect.position)) / canvas_scale,
			Vector2(rect.size) / canvas_scale
		))

	var changed: bool = virtual_rect != context.monitor.get("virtual_rect", Rect2i()) \
		or rects != context.monitor.get("rects", [])

	context.update_monitor({
		"count": count,
		"virtual_rect": virtual_rect,
		"rects": rects,
		"local_rects": local_rects,
		"scales": scales,
		"dpis": dpis,
	})
	context.update_window({"canvas_scale": canvas_scale})

	if changed:
		event_bus.publish(&"monitor.topology_changed", context.monitor)


func _choose_canvas_scale(scales: Array) -> float:
	var maximum_scale: float = 1.0
	for value in scales:
		maximum_scale = maxf(maximum_scale, float(value))
	return maximum_scale
