extends SceneTree

func _initialize() -> void:
	var root := OS.get_environment("APPDATA").path_join("Godot/app_userdata/OCP Desktop Runtime/packages/characters/character.sabai-sompoo/1.0.0")
	var result: Variant = ClassDB.class_call_static(&"OcpRuntimeBridge", &"verify_installed_cloud_character", root)
	if result is Dictionary:
		var row := result as Dictionary
		print("[S7-ACTIVE-VERIFY] ok=", bool(row.get("ok", false)), " managed=", bool(row.get("managed", false)), " error=", str(row.get("error", "")))
		quit(0 if bool(row.get("ok", false)) else 1)
		return
	print("[S7-ACTIVE-VERIFY] invalid-result")
	quit(2)
