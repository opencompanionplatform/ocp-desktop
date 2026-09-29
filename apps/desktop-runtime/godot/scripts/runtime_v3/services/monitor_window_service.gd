extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3MonitorWindowService
## Phase 6 foundation for native per-monitor windows.
##
## Current production mode remains the single virtual-desktop overlay.
## This service owns monitor-window descriptors and future Window instances,
## keeping native window lifecycle out of controllers.

var descriptors: Dictionary = {}
var windows: Dictionary = {}
var active_screen_index: int = -1


func rebuild_descriptors() -> Dictionary:
	var count: int = DisplayServer.get_screen_count()
	var next_descriptors: Dictionary = {}

	for index in range(count):
		var rect: Rect2i = DisplayServer.screen_get_usable_rect(index)
		var scale: float = DisplayServer.screen_get_scale(index)
		if scale <= 0.0:
			scale = 1.0

		next_descriptors[index] = {
			"screen_index": index,
			"desktop_rect": rect,
			"scale": scale,
			"dpi": DisplayServer.screen_get_dpi(index),
			"window_name": "MonitorWindow%d" % index,
		}

	descriptors = next_descriptors
	return descriptors.duplicate(true)


func create_monitor_windows() -> void:
	# Intentionally opt-in. Creating native windows is deferred until the
	# Window content-host migration is complete.
	if not bool(context.runtime_config.get("per_monitor_windows_enabled", false)):
		return

	for screen_index in descriptors.keys():
		if windows.has(screen_index):
			continue

		var descriptor: Dictionary = descriptors[screen_index]
		var monitor_window := _build_monitor_window(descriptor, false)
		add_child(monitor_window)
		windows[screen_index] = monitor_window


func create_window_for_screen(
	screen_index: int,
	initially_visible: bool = false
) -> Window:
	if not bool(context.runtime_config.get("per_monitor_windows_enabled", false)):
		return null

	var descriptor: Dictionary = descriptor_for_screen(screen_index)
	if descriptor.is_empty():
		return null

	var current := window_for_screen(screen_index)
	if is_instance_valid(current) and windows.size() == 1:
		active_screen_index = screen_index
		return current

	destroy_monitor_windows()
	var monitor_window := _build_monitor_window(descriptor, initially_visible)
	add_child(monitor_window)
	windows[screen_index] = monitor_window
	active_screen_index = screen_index
	return monitor_window


func destroy_monitor_windows() -> void:
	for value in windows.values():
		var monitor_window: Window = value
		if is_instance_valid(monitor_window):
			monitor_window.queue_free()
	windows.clear()
	active_screen_index = -1


func window_for_screen(screen_index: int) -> Window:
	return windows.get(screen_index)


func descriptor_for_screen(screen_index: int) -> Dictionary:
	return descriptors.get(screen_index, {})


func primary_screen_index() -> int:
	var primary := DisplayServer.get_primary_screen()
	if descriptors.has(primary):
		return primary
	if descriptors.is_empty():
		return -1
	return int(descriptors.keys()[0])


func active_window() -> Window:
	return window_for_screen(active_screen_index)


func _build_monitor_window(
	descriptor: Dictionary,
	initially_visible: bool
) -> Window:
	var desktop_rect: Rect2i = descriptor.get("desktop_rect", Rect2i())
	var monitor_window := Window.new()
	monitor_window.name = str(descriptor.get("window_name", "MonitorWindow"))
	monitor_window.visible = initially_visible
	monitor_window.borderless = true
	monitor_window.transparent = true
	monitor_window.always_on_top = true
	monitor_window.unresizable = true
	monitor_window.exclusive = false
	monitor_window.transient = false
	monitor_window.position = desktop_rect.position
	monitor_window.size = desktop_rect.size
	monitor_window.content_scale_size = desktop_rect.size
	return monitor_window
