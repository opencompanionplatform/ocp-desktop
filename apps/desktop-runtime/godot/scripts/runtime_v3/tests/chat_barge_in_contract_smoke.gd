extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")


class FakeAIService:
	extends Node
	var requested: Array[String] = []
	var cancelled: Array[String] = []

	func request(payload: Dictionary) -> void:
		requested.append(str(payload.get("message_id", "")))

	func cancel(message_id: String) -> void:
		cancelled.append(message_id)


var events: Array[Dictionary] = []
var bus: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	bus = EventBusScript.new()
	var services := ServicesScript.new()
	var ai := FakeAIService.new()
	var orchestrator := OrchestratorScript.new()
	for node in [context, bus, services, ai, orchestrator]:
		holder.add_child(node)
	services.register_service(&"ai", ai)
	bus.event_published.connect(_record_event)
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-old",
		"prompt": "old question",
	})
	# Simulate an established spoken response so the new turn must stop both AI
	# generation and speech lifecycle without flashing IDLE before the new THINK.
	orchestrator._tts_pending_chunks["msg-old"] = 2
	orchestrator._tts_speaking_latched["msg-old"] = true
	orchestrator._tts_response_complete["msg-old"] = false
	var before_second := events.size()

	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-new",
		"prompt": "new question",
	})

	var second_events := events.slice(before_second)
	var cancel_payload := _first_payload(second_events, &"tts.cancel_requested")
	var interrupted_payload := _first_payload(second_events, &"chat.response_interrupted")
	var old_state_clean := not orchestrator._tts_pending_chunks.has("msg-old") \
		and not orchestrator._tts_speaking_latched.has("msg-old") \
		and not orchestrator._tts_response_complete.has("msg-old") \
		and not orchestrator._stream_text_by_message.has("msg-old")
	var no_idle_flash := _animation_count(second_events, "idle") == 0
	var new_think_once := _animation_count_for_message(second_events, "think", "msg-new") == 1
	var ok := ai.requested == ["msg-old", "msg-new"] \
		and ai.cancelled == ["msg-old"] \
		and str(cancel_payload.get("message_id", "")) == "msg-old" \
		and str(cancel_payload.get("reason", "")) == "new-user-turn" \
		and str(interrupted_payload.get("message_id", "")) == "msg-old" \
		and str(interrupted_payload.get("next_message_id", "")) == "msg-new" \
		and orchestrator._active_message_id == "msg-new" \
		and old_state_clean \
		and no_idle_flash \
		and new_think_once
	print("[CHAT-BARGE-IN] ai_cancel=", ai.cancelled, " tts_cancel=", cancel_payload, " old_clean=", old_state_clean, " no_idle_flash=", no_idle_flash, " new_think=", new_think_once, " ok=", ok)

	orchestrator.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _record_event(topic: StringName, payload: Dictionary) -> void:
	events.append({"topic": topic, "payload": payload.duplicate(true)})


func _first_payload(source: Array, topic: StringName) -> Dictionary:
	for entry_value in source:
		var entry: Dictionary = entry_value
		if entry.get("topic") == topic:
			return (entry.get("payload", {}) as Dictionary).duplicate(true)
	return {}


func _animation_count(source: Array, name: String) -> int:
	var count := 0
	for entry_value in source:
		var entry: Dictionary = entry_value
		if entry.get("topic") != &"animation.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("name", "")) == name:
			count += 1
	return count


func _animation_count_for_message(source: Array, name: String, message_id: String) -> int:
	var count := 0
	for entry_value in source:
		var entry: Dictionary = entry_value
		if entry.get("topic") != &"animation.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("name", "")) == name and str(payload.get("message_id", "")) == message_id:
			count += 1
	return count
