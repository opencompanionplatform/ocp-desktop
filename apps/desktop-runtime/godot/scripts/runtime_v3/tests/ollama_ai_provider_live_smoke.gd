extends SceneTree

## Manual live smoke for the exact RuntimeV3 Ollama adapter.
## Requires a running local Ollama server. Set OCP_TEST_OLLAMA_MODEL to choose
## an installed model; defaults to qwen3.5:latest. Not intended for CI.

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const ProviderScript = preload("res://scripts/runtime_v3/services/ollama_ai_provider_adapter.gd")

var _test_result: Dictionary = {}
var _response_result: Dictionary = {}
var _response_error: Dictionary = {}
var _stream_text := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var provider := ProviderScript.new()
	holder.add_child(context)
	holder.add_child(provider)
	var test_model := OS.get_environment("OCP_TEST_OLLAMA_MODEL").strip_edges()
	if test_model.is_empty():
		test_model = "qwen3.5:latest"
	context.update_settings({
		"ai_provider_id": "ollama",
		"ai_base_url": "http://127.0.0.1:11434",
		"ai_model": test_model,
		"ai_timeout_seconds": 45,
		"ai_context_tokens": 8192,
	})
	provider.configure(context)
	provider.connection_tested.connect(func(payload: Dictionary) -> void:
		_test_result = payload.duplicate(true))
	provider.stream_delta.connect(_on_stream_delta)
	provider.response_completed.connect(func(payload: Dictionary) -> void:
		_response_result = payload.duplicate(true))
	provider.response_failed.connect(func(payload: Dictionary) -> void:
		_response_error = payload.duplicate(true))

	provider.test_connection()
	await _wait_for_result(30_000, func() -> bool: return not _test_result.is_empty())
	if not bool(_test_result.get("ok", false)):
		print("[OLLAMA-LIVE] connection=false message=", _test_result.get("message", "timeout"))
		holder.free()
		quit(1)
		return

	provider.request({
		"message_id": "ollama-live-smoke",
		"prompt": "ตอบเป็นภาษาไทยสั้นๆ ว่า Ollama พร้อมใช้งาน",
	})
	await _wait_for_result(45_000, func() -> bool:
		return not _response_result.is_empty() or not _response_error.is_empty())
	var reply := _stream_text.strip_edges()
	if reply.is_empty():
		reply = str(_response_result.get("text", "")).strip_edges()
	var ok := not reply.is_empty() and _response_error.is_empty()
	print(
		"[OLLAMA-LIVE] connection=", bool(_test_result.get("ok", false)),
		" ctx=", int(_test_result.get("context_tokens", 0)),
		" reply=", reply,
		" error=", str(_response_error.get("error", "")),
		" ok=", ok
	)
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _on_stream_delta(payload: Dictionary) -> void:
	_stream_text += str(payload.get("delta", ""))


func _wait_for_result(timeout_ms: int, predicate: Callable) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return
		await create_timer(0.05).timeout
