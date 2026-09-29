extends RefCounted
## Rust owns Store trust; this layer only gates presentation on its result.

static func verify(path: String) -> Dictionary:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return {"ok": false, "error": "Preview requires a verified snapshot from Runtime's main thread"}
	if not ClassDB.class_has_method(&"OcpRuntimeBridge", &"verify_installed_cloud_character"):
		return {"ok": false, "error": "Runtime package verifier unavailable; rebuild Runtime"}
	var result: Variant = ClassDB.class_call_static(
		&"OcpRuntimeBridge", &"verify_installed_cloud_character", ProjectSettings.globalize_path(path)
	)
	return result if result is Dictionary else {"ok": false, "error": "Invalid verification result"}
