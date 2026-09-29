extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")

class FakeBridge:
	extends Node
	signal ai_response_received(message_id: String, text: String, provider_id: String, model: String)
	signal ai_response_failed(message_id: String, error: String, provider_id: String)
	var last_system_prompt := ""

	func provider_credential_present(provider_id: String) -> bool:
		return provider_id == "openai-compatible"

	func request_cloud_ai(message_id: String, _prompt: String, system_prompt: String, provider_id: String, _base_url: String, model: String, _timeout_seconds: int) -> bool:
		if not system_prompt.is_empty():
			last_system_prompt = system_prompt
		call_deferred("_reply", message_id, provider_id, model)
		return true

	func _reply(message_id: String, provider_id: String, model: String) -> void:
		ai_response_received.emit(message_id, "service cloud reply", provider_id, model)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var service := AIServiceScript.new()
	var bridge := FakeBridge.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	holder.add_child(bridge)
	context.update_settings({
		"language": "th",
		"ai_provider_id": "openai-compatible",
		"ai_base_url": "https://example.test/v1",
		"ai_model": "cloud-model",
		"ai_timeout_seconds": 45,
	})
	context.update_character({"voice_profile": {"gender": "female", "age": "adult", "thaiSpeechStyle": "feminine"}})
	var events: Array[Dictionary] = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	service.configure(context, bus)
	service.bind_bridge(bridge)
	service.start()
	var status: Dictionary = service.provider_status()
	service.request({"message_id": "msg-service-cloud", "prompt": "hello"})
	await process_frame
	await process_frame
	service.test_connection()
	await process_frame
	await process_frame
	var received := false
	var connection_tested := false
	for entry in events:
		if entry.get("topic") == &"ai.response_received" and str((entry.get("payload", {}) as Dictionary).get("text", "")) == "service cloud reply":
			received = true
		elif entry.get("topic") == &"ai.connection_test_completed" and bool((entry.get("payload", {}) as Dictionary).get("ok", false)):
			connection_tested = true
	var ok: bool = status.get("provider_id", "") == "openai-compatible" \
		and bool(status.get("configured", false)) \
		and bridge.last_system_prompt.contains("Never use ผม or ครับ") \
		and received \
		and connection_tested
	print("[AI-SERVICE-CLOUD] provider=", status.get("provider_id", ""), " configured=", status.get("configured", false), " received=", received, " live_test=", connection_tested, " ok=", ok)
	service.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
