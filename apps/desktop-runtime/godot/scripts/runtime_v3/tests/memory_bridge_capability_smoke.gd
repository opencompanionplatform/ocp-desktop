extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var bridge := ClassDB.instantiate("OcpRuntimeBridge") as Node
	var ok := is_instance_valid(bridge) \
		and bridge.has_method("request_memory_recent") \
		and bridge.has_method("request_memory_relevant") \
		and bridge.has_method("request_memory_turn_write") \
		and bridge.has_signal("memory_recent_received") \
		and bridge.has_signal("memory_recent_failed") \
		and bridge.has_signal("memory_relevant_received") \
		and bridge.has_signal("memory_relevant_failed") \
		and bridge.has_signal("memory_turn_written") \
		and bridge.has_signal("memory_turn_write_failed")
	print("[MEMORY-V2-BRIDGE] recent=", bridge.has_method("request_memory_recent") if is_instance_valid(bridge) else false,
		" relevant=", bridge.has_method("request_memory_relevant") if is_instance_valid(bridge) else false,
		" write=", bridge.has_method("request_memory_turn_write") if is_instance_valid(bridge) else false,
		" recent_signal=", bridge.has_signal("memory_recent_received") if is_instance_valid(bridge) else false,
		" relevant_signal=", bridge.has_signal("memory_relevant_received") if is_instance_valid(bridge) else false,
		" write_signal=", bridge.has_signal("memory_turn_written") if is_instance_valid(bridge) else false,
		" ok=", ok)
	if is_instance_valid(bridge):
		bridge.free()
	quit(0 if ok else 1)
