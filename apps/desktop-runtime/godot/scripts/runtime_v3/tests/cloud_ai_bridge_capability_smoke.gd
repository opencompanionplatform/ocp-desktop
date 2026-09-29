extends SceneTree

func _initialize() -> void:
	var bridge := OcpRuntimeBridge.new()
	get_root().add_child(bridge)
	var ok := is_instance_valid(bridge) \
		and bridge.has_method("request_cloud_ai") \
		and bridge.has_signal("ai_response_received") \
		and bridge.has_signal("ai_response_failed") \
		and bridge.has_method("store_provider_credential") \
		and bridge.has_method("provider_credential_present")
	print("[CLOUD-AI-BRIDGE] request=", bridge.has_method("request_cloud_ai") if is_instance_valid(bridge) else false,
		" received=", bridge.has_signal("ai_response_received") if is_instance_valid(bridge) else false,
		" failed=", bridge.has_signal("ai_response_failed") if is_instance_valid(bridge) else false,
		" secure_store=", bridge.has_method("store_provider_credential") if is_instance_valid(bridge) else false)
	bridge.free()
	quit(0 if ok else 1)
