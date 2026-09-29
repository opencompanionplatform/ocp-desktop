extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var bridge := ClassDB.instantiate("OcpRuntimeBridge") as Node
	var ok := is_instance_valid(bridge) \
		and bridge.has_method("request_tts") \
		and bridge.has_signal("speech_started") \
		and bridge.has_signal("speech_finished") \
		and bridge.has_signal("speech_requested")
	print("[TTS-BRIDGE] request_tts=", bridge.has_method("request_tts") if is_instance_valid(bridge) else false,
		" started=", bridge.has_signal("speech_started") if is_instance_valid(bridge) else false,
		" finished=", bridge.has_signal("speech_finished") if is_instance_valid(bridge) else false)
	if is_instance_valid(bridge):
		bridge.free()
	quit(0 if ok else 1)
