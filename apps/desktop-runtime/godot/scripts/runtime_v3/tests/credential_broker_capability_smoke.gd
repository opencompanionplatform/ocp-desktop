extends SceneTree


func _initialize() -> void:
	var bridge := OcpRuntimeBridge.new()
	get_root().add_child(bridge)
	var first: PackedStringArray = bridge.call("start_credential_broker", "a".repeat(64)) if bridge.has_method("start_credential_broker") else PackedStringArray()
	var second: PackedStringArray = bridge.call("start_credential_broker", "b".repeat(64)) if bridge.has_method("start_credential_broker") else PackedStringArray()
	var pipe_ok := first.size() == 2 \
		and first[0].begins_with("--ocp-credential-pipe=ocp-credential-") \
		and first[0].length() == "--ocp-credential-pipe=ocp-credential-".length() + 32
	var capability_ok := first.size() == 2 \
		and first[1].begins_with("--ocp-credential-capability=") \
		and first[1].length() == "--ocp-credential-capability=".length() + 64
	var session_stable := first == second
	var ok := pipe_ok and capability_ok and session_stable
	print("[G16.13B-BROKER] method=", bridge.has_method("start_credential_broker"), " pipe=", pipe_ok, " capability=", capability_ok, " session_stable=", session_stable, " ok=", ok)
	bridge.free()
	quit(0 if ok else 1)
