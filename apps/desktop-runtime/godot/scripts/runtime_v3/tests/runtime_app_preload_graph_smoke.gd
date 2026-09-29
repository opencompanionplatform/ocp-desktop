extends SceneTree

const PATHS := [
	"res://scripts/runtime_v3/services/tts_service.gd",
	"res://scripts/runtime_v3/services/credential_service.gd",
	"res://scripts/runtime_v3/services/cloud_session_service.gd",
	"res://scripts/runtime_v3/services/cloud_auth_service.gd",
	"res://scripts/runtime_v3/services/cloud_device_service.gd",
	"res://scripts/runtime_v3/services/cloud_library_service.gd",
	"res://scripts/runtime_v3/services/cloud_download_service.gd",
	"res://scripts/runtime_v3/services/cloud_deep_link_service.gd",
	"res://scripts/runtime_v3/services/progression_queue_service.gd",
	"res://scripts/runtime_v3/services/cloud_progression_service.gd",
	"res://scripts/runtime_v3/services/localization_service.gd",
	"res://scripts/runtime_v3/services/startup_registration_service.gd",
	"res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd",
	"res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd",
]

func _initialize() -> void:
	for path in PATHS:
		print("[PRELOAD-PROBE] before ", path)
		var resource := load(path)
		print("[PRELOAD-PROBE] after ", path, " ok=", resource != null)
		if resource == null:
			quit(1)
			return
	print("[PRELOAD-PROBE] before runtime_app.gd")
	var runtime_script := load("res://scripts/runtime_v3/runtime_app.gd")
	print("[PRELOAD-PROBE] after runtime_app.gd ok=", runtime_script != null)
	quit(0 if runtime_script != null else 1)
