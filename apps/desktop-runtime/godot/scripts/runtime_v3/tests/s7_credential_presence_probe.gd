extends SceneTree

func _initialize() -> void:
	var bridge := OcpRuntimeBridge.new()
	root.add_child(bridge)
	var method_ok := bridge.has_method("load_cloud_refresh_token")
	var present := false
	if method_ok:
		var result: Variant = bridge.call("load_cloud_refresh_token")
		if result is Dictionary:
			present = bool((result as Dictionary).get("ok", false)) and not str((result as Dictionary).get("refresh_token", "")).is_empty()
	print("[S7-CREDENTIAL] method=%s present=%s" % [str(method_ok).to_lower(), str(present).to_lower()])
	bridge.free()
	quit(0 if method_ok else 1)
