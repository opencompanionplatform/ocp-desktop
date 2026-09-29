extends SceneTree


func _initialize() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/runtime_v3/runtime_app.gd")
	var load_index := source.find("services.settings_service.load_settings()")
	var reload_index := source.find("services.ai_service.reload_provider()", load_index)
	var test_index := source.find("services.ai_service.test_connection()", reload_index)
	var ok := load_index >= 0 and reload_index > load_index and test_index > reload_index
	print("[G16.20-STARTUP-AI] load=", load_index, " reload=", reload_index, " test=", test_index, " ok=", ok)
	quit(0 if ok else 1)
