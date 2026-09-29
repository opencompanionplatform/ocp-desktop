extends Node

var _handoff_path := ""
var _token := ""
var _started_at := 0


func _ready() -> void:
	_handoff_path = OS.get_environment("OCP_NATIVE_HOST_HANDOFF_PATH")
	_token = OS.get_environment("OCP_NATIVE_HOST_TOKEN")
	_started_at = Time.get_ticks_msec()
	print("[G9 Godot] native-host handoff smoke begin")
	if _handoff_path.is_empty() or _token.is_empty():
		push_error("[G9 Godot] handoff path or token is missing")
		get_tree().quit(41)


func _process(_delta: float) -> void:
	if _handoff_path.is_empty():
		return
	if FileAccess.file_exists(_handoff_path):
		var file := FileAccess.open(_handoff_path, FileAccess.READ)
		var parsed = JSON.parse_string(file.get_as_text()) if file else null
		if parsed is Dictionary \
		and str(parsed.get("status", "")) == "ready" \
		and str(parsed.get("token", "")) == _token \
		and int(parsed.get("hwnd", 0)) != 0 \
		and int(parsed.get("dpi", 0)) > 0:
			print(
				"[G9 Godot] native-host-consumed hwnd=%s dpi=%s physics_committed=false"
				% [str(parsed.get("hwnd")), str(parsed.get("dpi"))]
			)
			var consumed := {
				"status": "consumed",
				"token": _token,
				"physics_committed": false,
			}
			var output := FileAccess.open(_handoff_path, FileAccess.WRITE)
			output.store_string(JSON.stringify(consumed))
			print("[G9 Godot] native-host handoff smoke passed")
			get_tree().quit(0)
			return
	if Time.get_ticks_msec() - _started_at > 30_000:
		push_error("[G9 Godot] native-host handoff timeout")
		get_tree().quit(42)
