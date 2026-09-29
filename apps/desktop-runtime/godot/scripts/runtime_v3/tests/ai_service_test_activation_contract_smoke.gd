extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")

class FakeBridge:
	extends Node
	signal ai_response_received(message_id: String, text: String, provider_id: String, model: String)
	signal ai_response_failed(message_id: String, error: String, provider_id: String)

	func provider_credential_present(provider_id: String) -> bool:
		return provider_id == "openai-compatible"

	func request_cloud_ai(message_id: String, _prompt: String, _system_prompt: String, provider_id: String, _base_url: String, model: String, _timeout_seconds: int) -> bool:
		call_deferred("_reply", message_id, provider_id, model)
		return true

	func _reply(message_id: String, provider_id: String, model: String) -> void:
		ai_response_received.emit(message_id, "OK", provider_id, model)


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
	context.update_settings({"ai_provider_id": "offline"})
	service.configure(context, bus)
	service.bind_bridge(bridge)
	service.start()

	var events: Array[Dictionary] = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)}))

	var overrides := {
		"ai_provider_id": "openai-compatible",
		"ai_base_url": "https://example.test/v1",
		"ai_model": "activation-model",
		"ai_timeout_seconds": 45,
	}
	service.test_connection(overrides)
	await process_frame
	await process_frame
	await process_frame

	var status: Dictionary = service.provider_status()
	var activated: bool = status.get("provider_id", "") == "openai-compatible" \
		and bool(status.get("configured", false)) \
		and context.settings.get("ai_provider_id", "") == "openai-compatible" \
		and context.settings.get("ai_model", "") == "activation-model"
	var connection_ok := false
	var activation_event := false
	for entry in events:
		if entry.get("topic") == &"ai.connection_test_completed" and bool((entry.get("payload", {}) as Dictionary).get("ok", false)):
			connection_ok = true
		if entry.get("topic") == &"ai.provider_test_activated":
			activation_event = true
	var ok: bool = activated and connection_ok and activation_event
	print("[AI-SERVICE-TEST-ACTIVATION] connection=", connection_ok, " activated=", activated, " activation_event=", activation_event, " ok=", ok)
	service.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
