extends Node
## G12.3 one-companion native host contract smoke.
##
## This is intentionally an isolated test scene. It exercises the real
## RuntimeV3NativePresentationCoordinator, RuntimeV3BridgeAdapter, and
## OcpRuntimeBridge lifecycle without enabling native presentation in the
## production RuntimeApp.

const DEFAULT_COMPANION := "default"
const CLIENT_SIZE := Vector2i(256, 256)
const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const CoordinatorScript = preload("res://scripts/runtime_v3/services/native_presentation_coordinator.gd")
const BridgeAdapterScript = preload("res://scripts/runtime_v3/services/runtime_bridge_adapter.gd")

var _handoff_path := ""
var _token := ""
var _started_at := 0
var _attached := false
var _exit_ready := false
var _coordinator: Node
var _bridge: Node


func _ready() -> void:
	_handoff_path = OS.get_environment("OCP_NATIVE_HOST_HANDOFF_PATH")
	_token = OS.get_environment("OCP_NATIVE_HOST_TOKEN")
	_started_at = Time.get_ticks_msec()
	print("[G12.3 Godot] native Runtime host contract smoke begin")
	if _handoff_path.is_empty() or _token.is_empty():
		_fail("handoff path or token is missing", 61)
		return

	_bridge = get_node("OcpRuntimeBridge")
	var context: Node = get_node("RuntimeContext")
	var event_bus: Node = get_node("RuntimeEventBus")
	context.set_script(ContextScript)
	event_bus.set_script(EventBusScript)

	_coordinator = Node.new()
	_coordinator.set_script(CoordinatorScript)
	add_child(_coordinator)
	_coordinator.configure(context, event_bus)
	_coordinator.start()
	var adapter: Node = Node.new()
	adapter.set_script(BridgeAdapterScript)
	add_child(adapter)
	adapter.configure(context, event_bus)
	adapter.bind_bridge(_bridge)
	adapter.start()
	context.update_runtime_config({
		"native_presentation_enabled": true,
		"presentation_requested_mode": "native-companion",
	})

	if not _coordinator.request(DEFAULT_COMPANION, _token):
		_fail("coordinator rejected native request", 62)
		return
	if _coordinator.state_name() != "requested":
		_fail("coordinator did not enter requested state", 63)
		return

	var hwnd := int(DisplayServer.window_get_native_handle(
		DisplayServer.WINDOW_HANDLE,
		get_window().get_window_id()
	))
	if hwnd == 0:
		_fail("Godot HWND unavailable", 64)
		return
	_write_status({
		"status": "godot-ready",
		"token": _token,
		"godot_hwnd": hwnd,
		"companion_id": DEFAULT_COMPANION,
		"physics_committed": false,
	})
	print("[G12.3 Godot] requested companion=default physics_committed=false")


func _process(_delta: float) -> void:
	var payload := _read_handoff()
	if payload.is_empty() or str(payload.get("token", "")) != _token:
		_check_timeout()
		return

	var status := str(payload.get("status", ""))
	if status == "embedded" and not _attached:
		if _coordinator.state_name() != "requested":
			_fail("embedded arrived before requested state", 65)
			return
		if not bool(_bridge.call("attach_render_surface", DEFAULT_COMPANION, _token)):
			_fail("bridge rejected attach_render_surface", 66)
			return
		if _coordinator.state_name() != "ready":
			_fail("coordinator did not enter ready state", 67)
			return
		# The native host owns the actual HWND embed. The bridge reports
		# readiness; this explicit acknowledgement represents the host-side
		# attach completion in the frozen ADR-0017 lifecycle contract.
		if not _coordinator.accept_attached(DEFAULT_COMPANION):
			_fail("coordinator rejected host attach acknowledgement", 67)
			return
		if not bool(_bridge.call("set_render_client_size", CLIENT_SIZE.x, CLIENT_SIZE.y)):
			_fail("bridge rejected set_render_client_size", 68)
			return
		if _coordinator.state_name() != "attached" or _coordinator.host_size != CLIENT_SIZE:
			_fail("coordinator did not enter attached/resized state", 69)
			return
		_attached = true
		print("[G12.3 Godot] attached companion=default client_size=(256,256) physics_committed=false")
		_write_status({
			"status": "detach-request",
			"token": _token,
			"companion_id": DEFAULT_COMPANION,
			"physics_committed": false,
		})
	elif status == "detached" and _attached and not _exit_ready:
		if not bool(_bridge.call("detach_render_surface", DEFAULT_COMPANION)):
			_fail("bridge rejected detach_render_surface", 70)
			return
		if _coordinator.state_name() != "detached":
			_fail("coordinator did not enter detached state", 71)
			return
		_exit_ready = true
		print("[G12.3 Godot] detached companion=default physics_committed=false")
		_write_status({
			"status": "godot-exit-ready",
			"token": _token,
			"companion_id": DEFAULT_COMPANION,
			"physics_committed": false,
		})
	elif status == "host-closed" and _exit_ready:
		print("[G12.3 Godot] native Runtime host contract smoke passed")
		get_tree().quit(0)
	else:
		_check_timeout()


func _read_handoff() -> Dictionary:
	if not FileAccess.file_exists(_handoff_path):
		return {}
	var file := FileAccess.open(_handoff_path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _write_status(payload: Dictionary) -> void:
	var temporary_path := _handoff_path + ".g12.tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()
		DirAccess.remove_absolute(_handoff_path)
		DirAccess.rename_absolute(temporary_path, _handoff_path)


func _check_timeout() -> void:
	if Time.get_ticks_msec() - _started_at > 30_000:
		_fail("native Runtime host contract timeout", 72)


func _fail(reason: String, code: int) -> void:
	push_error("[G12.3 Godot] " + reason)
	get_tree().quit(code)
