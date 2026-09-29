extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3WorldDebugService
## Read-only projection of Rust Desktop World events for debug rendering.
##
## This is not another World Model. Rust remains authoritative. The service
## only keeps the latest sanitized descriptors received over the runtime bridge.

signal world_changed
signal connection_state_changed(connected: bool)

var world_id: String = ""
var revision: int = 0
var previous_revision: int = 0
var change_count: int = 0
var runtime_state: String = "unknown"
var connected: bool = false
var last_event_type: String = ""
var last_error: String = ""

var virtual_desktop_bounds: Dictionary = {}
var monitors: Array[Dictionary] = []
var windows: Dictionary = {}
var surfaces: Dictionary = {}
var cursor: Dictionary = {}
var taskbar: Dictionary = {}
var capabilities: Dictionary = {}


func start() -> void:
	pass


func clear() -> void:
	world_id = ""
	revision = 0
	previous_revision = 0
	change_count = 0
	runtime_state = "unknown"
	last_event_type = ""
	last_error = ""
	virtual_desktop_bounds.clear()
	monitors.clear()
	windows.clear()
	surfaces.clear()
	cursor.clear()
	taskbar.clear()
	capabilities.clear()
	world_changed.emit()


func set_connection_state(value: bool) -> void:
	if connected == value:
		return
	connected = value
	connection_state_changed.emit(connected)
	world_changed.emit()


func consume_event(event_type: String, payload: Dictionary) -> void:
	last_event_type = event_type
	_update_common(payload)

	match event_type:
		"ocp.runtime.desktop-world-started":
			runtime_state = str(payload.get("state", "running"))
		"ocp.runtime.desktop-world-degraded":
			runtime_state = "degraded"
			last_error = str(payload.get("message", ""))
		"ocp.runtime.desktop-world-stopped":
			runtime_state = "stopped"

		"ocp.world.monitor-layout-changed":
			virtual_desktop_bounds = _dictionary(payload.get(
				"virtualDesktopBounds", {}
			))
			monitors = _dictionary_array(payload.get("monitors", []))

		"ocp.world.window-added", \
		"ocp.world.window-moved", \
		"ocp.world.window-resized", \
		"ocp.world.window-activated", \
		"ocp.world.window-deactivated", \
		"ocp.world.window-minimized", \
		"ocp.world.window-restored", \
		"ocp.world.window-visibility-changed", \
		"ocp.world.window-metadata-changed":
			_upsert_window(payload)

		"ocp.world.window-removed":
			var removed_window_id := str(payload.get("windowId", ""))
			windows.erase(removed_window_id)

		"ocp.surface.created", "ocp.surface.updated":
			_upsert_surface(payload)

		"ocp.surface.removed":
			var removed_surface_id := str(payload.get("surfaceId", ""))
			surfaces.erase(removed_surface_id)

		"ocp.world.cursor-changed":
			cursor = _dictionary(payload.get("cursor", {}))

		"ocp.world.taskbar-changed":
			taskbar = _dictionary(payload.get("taskbarOrDock", {}))

		"ocp.world.capabilities-changed":
			capabilities = _dictionary(payload.get("capabilities", {}))

	world_changed.emit()


func snapshot() -> Dictionary:
	return {
		"worldId": world_id,
		"revision": revision,
		"previousRevision": previous_revision,
		"changeCount": change_count,
		"runtimeState": runtime_state,
		"connected": connected,
		"lastEventType": last_event_type,
		"lastError": last_error,
		"virtualDesktopBounds": virtual_desktop_bounds.duplicate(true),
		"monitors": monitors.duplicate(true),
		"windows": windows.duplicate(true),
		"surfaces": surfaces.duplicate(true),
		"cursor": cursor.duplicate(true),
		"taskbar": taskbar.duplicate(true),
		"capabilities": capabilities.duplicate(true),
	}


func _update_common(payload: Dictionary) -> void:
	if payload.has("worldId"):
		world_id = str(payload.get("worldId", ""))
	if payload.has("revision"):
		revision = int(payload.get("revision", revision))
	if payload.has("previousRevision"):
		previous_revision = int(payload.get(
			"previousRevision", previous_revision
		))
	if payload.has("changeCount"):
		change_count = int(payload.get("changeCount", change_count))


func _upsert_window(payload: Dictionary) -> void:
	var window_id := str(payload.get("windowId", ""))
	var descriptor := _dictionary(payload.get("window", {}))
	if window_id.is_empty() or descriptor.is_empty():
		return
	windows[window_id] = descriptor


func _upsert_surface(payload: Dictionary) -> void:
	var surface_id := str(payload.get("surfaceId", ""))
	var descriptor := _dictionary(payload.get("surface", {}))
	if surface_id.is_empty() or descriptor.is_empty():
		return
	surfaces[surface_id] = descriptor


func _dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


func _dictionary_array(value: Variant) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				result.append(item)
	return result
