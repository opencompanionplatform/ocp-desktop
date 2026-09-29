extends Node

var _handoff_path := ""
var _token := ""
var _started_at := 0
var _detachment_requested := false
var _exit_requested := false


func _ready() -> void:
	_handoff_path = OS.get_environment("OCP_NATIVE_HOST_HANDOFF_PATH")
	_token = OS.get_environment("OCP_NATIVE_HOST_TOKEN")
	_started_at = Time.get_ticks_msec()
	print("[G10 Godot] native embed smoke begin")
	if _handoff_path.is_empty() or _token.is_empty():
		push_error("[G10 Godot] handoff path or token is missing")
		get_tree().quit(51)
		return

	var hwnd := int(DisplayServer.window_get_native_handle(
		DisplayServer.WINDOW_HANDLE,
		get_window().get_window_id()
	))
	if hwnd == 0:
		push_error("[G10 Godot] native HWND unavailable")
		get_tree().quit(52)
		return

	_write_status({
		"status": "godot-ready",
		"token": _token,
		"godot_hwnd": hwnd,
		"physics_committed": false,
	})
	print("[G10 Godot] godot-ready hwnd=%s physics_committed=false" % str(hwnd))


func _process(_delta: float) -> void:
	var payload := _read_handoff()
	if payload.is_empty() or str(payload.get("token", "")) != _token:
		_check_timeout()
		return

	var status := str(payload.get("status", ""))
	if status == "embedded" and not _detachment_requested:
		print("[G10 Godot] native-embedded physics_committed=false")
		_detachment_requested = true
		_write_status({
			"status": "detach-request",
			"token": _token,
			"physics_committed": false,
		})
	elif status == "detached":
		if not _exit_requested:
			print("[G10 Godot] native-detached physics_committed=false")
			_exit_requested = true
			_write_status({
				"status": "godot-exit-ready",
				"token": _token,
				"physics_committed": false,
			})
	elif status == "host-closed" and _exit_requested:
		print("[G10 Godot] native Godot embed smoke passed")
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
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _write_status(payload: Dictionary) -> void:
	var temporary_path := _handoff_path + ".godot.tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()
		DirAccess.remove_absolute(_handoff_path)
		DirAccess.rename_absolute(temporary_path, _handoff_path)


func _check_timeout() -> void:
	if Time.get_ticks_msec() - _started_at > 30_000:
		push_error("[G10 Godot] native embed timeout")
		get_tree().quit(53)
