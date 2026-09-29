extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")

var events: Array[Dictionary] = []
var tts_requests: Array[Dictionary] = []
var assistant_text := ""
var failure_text := ""
var bus: Node
var chat_done := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var model := OS.get_environment("OCP_TEST_OLLAMA_MODEL").strip_edges()
	if model.is_empty():
		print("[CHAT-OLLAMA-TTS-LIVE] skipped: OCP_TEST_OLLAMA_MODEL is not set")
		quit(0)
		return
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	bus = EventBusScript.new()
	var services := ServicesScript.new()
	var ai := AIServiceScript.new()
	var orchestrator := OrchestratorScript.new()
	for node in [context, bus, services, ai, orchestrator]:
		holder.add_child(node)
	context.update_settings({
		"ai_provider_id": "ollama",
		"ai_base_url": "http://127.0.0.1:11434",
		"ai_model": model,
		"ai_timeout_seconds": 60,
		"tts_enabled": true,
	})
	bus.event_published.connect(_record_event)
	bus.subscribe(&"chat.assistant_message_received", Callable(self, "_on_message"))
	bus.subscribe(&"chat.response_failed", Callable(self, "_on_failed"))
	bus.subscribe(&"tts.requested", Callable(self, "_fake_tts"))
	ai.configure(context, bus)
	ai.start()
	services.register_service(&"ai", ai)
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	bus.publish(&"ai.prompt_requested", {
		"message_id": "chat-ollama-tts-live",
		"prompt": "Reply with one short friendly sentence in Thai.",
	})
	for _step in range(600):
		if chat_done and _animation_count("idle") > 0:
			break
		await create_timer(0.1).timeout
	var message_ids_ok := true
	for request in tts_requests:
		message_ids_ok = message_ids_ok and str(request.get("message_id", "")) == "chat-ollama-tts-live"
	var ok := chat_done \
		and failure_text.is_empty() \
		and not assistant_text.is_empty() \
		and not tts_requests.is_empty() \
		and _animation_count("speak") >= 1 \
		and _animation_count("idle") == 1 \
		and message_ids_ok
	print("[CHAT-OLLAMA-TTS-LIVE] model=", model, " chat=", chat_done, " tts_chunks=", tts_requests.size(), " speak=", _animation_count("speak"), " idle=", _animation_count("idle"), " ok=", ok, " text=", assistant_text.left(120), " error=", failure_text)
	orchestrator.stop()
	ai.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _record_event(topic: StringName, payload: Dictionary) -> void:
	events.append({"topic": topic, "payload": payload.duplicate(true)})


func _fake_tts(payload: Dictionary) -> void:
	tts_requests.append(payload.duplicate(true))
	var copy := payload.duplicate(true)
	bus.publish(&"tts.started", copy)
	bus.publish(&"tts.finished", copy)


func _on_message(payload: Dictionary) -> void:
	assistant_text = str(payload.get("text", "")).strip_edges()
	chat_done = true


func _on_failed(payload: Dictionary) -> void:
	failure_text = str(payload.get("error", "unknown chat error"))
	chat_done = true


func _animation_count(name: String) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") != &"animation.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("name", "")) == name:
			count += 1
	return count
