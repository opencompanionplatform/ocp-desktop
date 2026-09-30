extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")

var done := false
var assistant_text := ""
var failure_text := ""
var started_ms := 0
var first_delta_ms := -1
var total_ms := -1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var model := OS.get_environment("OCP_TEST_OLLAMA_MODEL").strip_edges()
	if model.is_empty():
		model = "qwen2.5-coder:1.5b"
	var prompt := OS.get_environment("OCP_TEST_CHAT_PROMPT").strip_edges()
	if prompt.is_empty():
		prompt = "สวัสดีค่ะ ตอบกลับเป็นภาษาไทยสั้น ๆ หนึ่งประโยคแบบเป็นธรรมชาติ"

	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var services := ServicesScript.new()
	var ai := AIServiceScript.new()
	var orchestrator := OrchestratorScript.new()
	for node in [context, bus, services, ai, orchestrator]:
		holder.add_child(node)

	context.update_settings({
		"language": "th",
		"ai_provider_id": "ollama",
		"ai_base_url": "http://127.0.0.1:11434",
		"ai_model": model,
		"ai_timeout_seconds": 60,
		"tts_enabled": false,
	})
	bus.subscribe(&"ai.stream_delta", Callable(self, "_on_stream_delta"))
	bus.subscribe(&"chat.assistant_message_received", Callable(self, "_on_message"))
	bus.subscribe(&"chat.response_failed", Callable(self, "_on_failed"))
	ai.configure(context, bus)
	ai.start()
	services.register_service(&"ai", ai)
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	started_ms = Time.get_ticks_msec()
	bus.publish(&"ai.prompt_requested", {
		"message_id": "voice-turn-live",
		"prompt": prompt,
		"source": "voice-turn-live",
	})
	for _step in range(600):
		if done:
			break
		await create_timer(0.1).timeout
	if not done:
		failure_text = "timeout waiting for chat response"
		total_ms = Time.get_ticks_msec() - started_ms

	var response_b64 := Marshalls.raw_to_base64(assistant_text.to_utf8_buffer())
	var ok := done and failure_text.is_empty() and not assistant_text.is_empty() and first_delta_ms >= 0 and total_ms >= first_delta_ms
	print("[VOICE-TURN-LLM] ok=%s model=%s first_delta_ms=%d total_ms=%d response_b64=%s error=%s" % [
		str(ok).to_lower(),
		model,
		first_delta_ms,
		total_ms,
		response_b64,
		failure_text.replace(" ", "_"),
	])

	orchestrator.stop()
	ai.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _on_stream_delta(payload: Dictionary) -> void:
	if first_delta_ms >= 0 or str(payload.get("message_id", "")) != "voice-turn-live":
		return
	if str(payload.get("delta", "")).is_empty():
		return
	first_delta_ms = Time.get_ticks_msec() - started_ms


func _on_message(payload: Dictionary) -> void:
	if str(payload.get("message_id", "")) != "voice-turn-live":
		return
	assistant_text = str(payload.get("text", "")).strip_edges()
	total_ms = Time.get_ticks_msec() - started_ms
	done = true


func _on_failed(payload: Dictionary) -> void:
	if str(payload.get("message_id", "")) != "voice-turn-live":
		return
	failure_text = str(payload.get("error", "unknown chat error"))
	total_ms = Time.get_ticks_msec() - started_ms
	done = true
