extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const StateMachineScript = preload("res://scripts/runtime_v3/core/runtime_state_machine.gd")
const ControllerScript = preload("res://scripts/runtime_v3/controllers/proactive_local_llm_companion_controller.gd")


class FakeAIService:
	extends Node
	var configured := true

	func provider_status() -> Dictionary:
		return {"provider_id": "ollama", "configured": configured}


class FakeServices:
	extends Node
	var ai_service := FakeAIService.new()


var events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var services := FakeServices.new()
	var state_machine := StateMachineScript.new()
	var controller := ControllerScript.new()
	for node in [context, bus, services, state_machine, controller]:
		holder.add_child(node)
	services.add_child(services.ai_service)
	context.update_settings({
		"llm_companion_mode_enabled": true,
		"ai_provider_id": "ollama",
		"language": "en",
	})
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	controller.configure(context, bus, services, state_machine)
	controller.start()
	controller._last_activity_ms = 0
	controller._last_proactive_ms = -ControllerScript.IDLE_COOLDOWN_MS

	var first_allowed: bool = controller.try_request(ControllerScript.IDLE_COOLDOWN_MS)
	var duplicate_suppressed: bool = not controller.try_request(ControllerScript.IDLE_COOLDOWN_MS + 1)
	var first_payload := _first_payload(&"ai.prompt_requested")
	var privacy_ok := str(first_payload.get("source", "")) == "proactive-local-llm-companion" \
		and bool(first_payload.get("proactive", false)) \
		and not str(first_payload.get("prompt", "")).to_lower().contains("clipboard") \
		and not str(first_payload.get("prompt", "")).to_lower().contains("screen")

	bus.publish(&"chat.response_failed", {"message_id": str(first_payload.get("message_id", "")), "error": "test"})
	controller._last_activity_ms = ControllerScript.IDLE_COOLDOWN_MS
	var next_cycle_allowed: bool = controller.try_request(ControllerScript.IDLE_COOLDOWN_MS * 2)
	context.update_settings({"ai_provider_id": "openai-compatible"})
	controller._request_in_flight = false
	controller._last_activity_ms = 0
	var cloud_blocked: bool = not controller.try_request(ControllerScript.IDLE_COOLDOWN_MS * 3)
	context.update_settings({"ai_provider_id": "ollama", "llm_companion_mode_enabled": false})
	var disabled_blocked: bool = not controller.try_request(ControllerScript.IDLE_COOLDOWN_MS * 4)

	var ok := first_allowed and duplicate_suppressed and privacy_ok and next_cycle_allowed and cloud_blocked and disabled_blocked
	print("[ADR-0045] first=", first_allowed, " duplicate=", duplicate_suppressed, " privacy=", privacy_ok, " next=", next_cycle_allowed, " cloud=", cloud_blocked, " disabled=", disabled_blocked, " ok=", ok)
	controller.stop()
	holder.free()
	quit(0 if ok else 1)


func _first_payload(topic: StringName) -> Dictionary:
	for event in events:
		if event.get("topic") == topic:
			return event.get("payload", {})
	return {}
