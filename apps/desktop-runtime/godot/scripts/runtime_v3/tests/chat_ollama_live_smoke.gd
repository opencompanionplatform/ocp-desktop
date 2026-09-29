extends SceneTree

class FakeContext:
	extends Node
	var settings: Dictionary = {}

var done := false
var chat_ok := false
var assistant_text := ""
var failure_text := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var model := OS.get_environment("OCP_TEST_OLLAMA_MODEL").strip_edges()
	if model.is_empty():
		print("[CHAT-OLLAMA-LIVE] skipped: OCP_TEST_OLLAMA_MODEL is not set")
		quit(0)
		return
	var context := FakeContext.new()
	context.settings = {
		"ai_provider_id": "ollama",
		"ai_base_url": "http://127.0.0.1:11434",
		"ai_model": model,
		"ai_timeout_seconds": 30,
		"tts_enabled": false,
	}
	var bus: Node = load("res://scripts/runtime_v3/core/runtime_event_bus.gd").new()
	var services: Node = load("res://scripts/runtime_v3/core/runtime_services.gd").new()
	var ai: Node = load("res://scripts/runtime_v3/services/ai_service.gd").new()
	var orchestrator: Node = load("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd").new()
	get_root().add_child(context)
	get_root().add_child(bus)
	get_root().add_child(services)
	get_root().add_child(ai)
	get_root().add_child(orchestrator)
	services.set("ai_service", ai)
	ai.call("configure", context, bus)
	orchestrator.call("configure", context, bus, services, null)
	bus.call("subscribe", &"chat.assistant_message_received", Callable(self, "_on_message"))
	bus.call("subscribe", &"chat.response_failed", Callable(self, "_on_failed"))
	ai.call("start")
	orchestrator.call("start")
	bus.call("publish", &"ai.prompt_requested", {
		"message_id": "chat-ollama-live",
		"prompt": "Reply with one short friendly sentence.",
	})
	for _step in range(300):
		if done:
			break
		await create_timer(0.1).timeout
	if not done:
		failure_text = "timeout waiting for chat response"
	print("[CHAT-OLLAMA-LIVE] model=", model, " ok=", chat_ok, " text=", assistant_text.left(120), " error=", failure_text)
	orchestrator.call("stop")
	ai.call("stop")
	for node in [orchestrator, ai, services, bus, context]:
		if is_instance_valid(node):
			node.queue_free()
	quit(0 if chat_ok else 1)


func _on_message(payload: Dictionary) -> void:
	assistant_text = str(payload.get("text", "")).strip_edges()
	chat_ok = not assistant_text.is_empty()
	done = true


func _on_failed(payload: Dictionary) -> void:
	failure_text = str(payload.get("error", "unknown chat error"))
	done = true
