extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const StateMachineScript = preload("res://scripts/runtime_v3/core/runtime_state_machine.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")

var events: Array[Dictionary] = []
var test_bus: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	test_bus = bus
	var services := ServicesScript.new()
	var state_machine := StateMachineScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(services)
	holder.add_child(state_machine)
	bus.event_published.connect(_record_event)

	var ai_service := AIServiceScript.new()
	holder.add_child(ai_service)
	ai_service.configure(context, bus)
	ai_service.start()
	services.register_service(&"ai", ai_service)

	var orchestrator := OrchestratorScript.new()
	holder.add_child(orchestrator)
	orchestrator.configure(context, bus, services, state_machine)
	orchestrator.start()

	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-smoke-1",
		"prompt": "hello",
	})
	var base_ok := _has_topic(&"ai.provider_status_changed") \
		and _topic_before(&"ai.thinking_started", &"ai.stream_started") \
		and _topic_before(&"ai.stream_started", &"ai.stream_delta") \
		and _topic_before(&"ai.stream_delta", &"ai.response_received") \
		and _topic_before(&"ai.response_received", &"chat.assistant_message_received") \
		and _has_topic(&"chat.assistant_stream_started") \
		and _has_topic(&"chat.assistant_stream_delta") \
		and _has_topic(&"bubble.requested") \
		and not _has_streaming_bubble("msg-smoke-1") \
		and _has_final_bubble("msg-smoke-1") \
		and _final_bubble_duration_ms("msg-smoke-1") in [8000, 12000] \
		and _has_animation("think") \
		and _has_animation("idle") \
		and not _has_animation("speak") \
		and _message_id_for(&"chat.assistant_message_received") == "msg-smoke-1" \
		and _message_id_for(&"chat.assistant_stream_delta") == "msg-smoke-1"

	events.clear()
	bus.publish(&"ai.stream_started", {
		"message_id": "msg-delta-only",
		"provider_id": "ollama",
		"request": {"message_id": "msg-delta-only"},
	})
	for delta in ["สวัสดี", "ครับ", " 😊"]:
		bus.publish(&"ai.stream_delta", {
			"message_id": "msg-delta-only",
			"provider_id": "ollama",
			"delta": delta,
			"request": {"message_id": "msg-delta-only"},
		})
	bus.publish(&"ai.response_received", {
		"message_id": "msg-delta-only",
		"provider_id": "ollama",
		"text": "",
		"request": {"message_id": "msg-delta-only"},
	})
	var delta_accumulation_ok := \
		_text_for(&"chat.assistant_message_received", "msg-delta-only") == "สวัสดีครับ 😊" \
		and _text_for(&"bubble.requested", "msg-delta-only") == "สวัสดีครับ 😊" \
		and _final_bubble_duration_ms("msg-delta-only") == 12000

	events.clear()
	context.update_settings({"tts_enabled": true})
	bus.subscribe(&"tts.requested", Callable(self, "_fake_tts"))
	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-smoke-2",
		"prompt": "speak",
	})
	# Streaming TTS is intentionally deferred so synthesis cannot block the Chat
	# response dispatch. Observe the next frame before asserting its lifecycle.
	await process_frame
	var tts_request_count := _topic_count(&"tts.requested")
	var tts_ok := tts_request_count >= 1 \
		and _has_topic(&"tts.started") \
		and _has_topic(&"tts.finished") \
		and _has_animation("speak") \
		and _topic_count(&"tts.started") == tts_request_count \
		and _topic_count(&"tts.finished") == tts_request_count \
		# Whole-WAV chunks are one logical utterance: SPEAK latches once across
		# all prefetched segments instead of restarting at each sentence boundary.
		and _animation_count("speak") == 1 \
		and _animation_count("idle") == 1 \
		# Stable whole-WAV segments may begin synthesis before the final assistant
		# message event; the visible response must still be emitted in the lifecycle.
		and _has_topic(&"chat.assistant_message_received") \
		and _topic_before(&"tts.started", &"tts.finished") \
		and _message_id_for(&"tts.requested") == "msg-smoke-2"

	events.clear()
	context.update_runtime_config({"chat_presentation_active": true})
	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-chat-text-first",
		"prompt": "do not auto speak",
	})
	await process_frame
	var chat_text_first_ok := _has_topic(&"chat.assistant_message_received") \
		and _topic_count(&"tts.requested") == 0 \
		and not _has_animation("speak")

	events.clear()
	bus.publish(&"tts.started", {
		"message_id": "read_aloud-foreign",
		"source": "read-aloud",
	})
	bus.publish(&"tts.failed", {
		"message_id": "read_aloud-foreign",
		"reason_code": "local-voice-not-installed",
	})
	var foreign_read_aloud_guard_ok := _animation_count("speak") == 0 \
		and _animation_count("think") == 0 \
		and _animation_count("idle") == 0

	var ok := base_ok and delta_accumulation_ok and tts_ok and chat_text_first_ok and foreign_read_aloud_guard_ok
	print("[CHAT-P2] orchestrator base=", base_ok, " delta_accumulation=", delta_accumulation_ok, " native_tts=", tts_ok, " chat_text_first=", chat_text_first_ok, " foreign_read_aloud_guard=", foreign_read_aloud_guard_ok, " events=", events.size())
	orchestrator.stop()
	ai_service.stop()
	holder.free()
	quit(0 if ok else 1)


func _record_event(topic: StringName, payload: Dictionary) -> void:
	events.append({"topic": topic, "payload": payload.duplicate(true)})


func _fake_tts(payload: Dictionary) -> void:
	if not is_instance_valid(test_bus):
		return
	var copy := payload.duplicate(true)
	test_bus.publish(&"tts.started", copy)
	test_bus.publish(&"tts.finished", copy)


func _has_topic(topic: StringName) -> bool:
	return _topic_index(topic) >= 0


func _topic_index(topic: StringName) -> int:
	for index in range(events.size()):
		if events[index].get("topic") == topic:
			return index
	return -1


func _topic_before(first: StringName, second: StringName) -> bool:
	var first_index := _topic_index(first)
	var second_index := _topic_index(second)
	return first_index >= 0 and second_index >= 0 and first_index < second_index


func _topic_count(topic: StringName) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") == topic:
			count += 1
	return count


func _has_animation(name: String) -> bool:
	for entry in events:
		if entry.get("topic") == &"animation.requested" and str(entry.get("payload", {}).get("name", "")) == name:
			return true
	return false


func _animation_count(name: String) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") == &"animation.requested" and str(entry.get("payload", {}).get("name", "")) == name:
			count += 1
	return count


func _has_streaming_bubble(message_id: String) -> bool:
	for entry in events:
		if entry.get("topic") != &"bubble.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("message_id", "")) == message_id and bool(payload.get("streaming", false)):
			return true
	return false


func _has_final_bubble(message_id: String) -> bool:
	for entry in events:
		if entry.get("topic") != &"bubble.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("message_id", "")) == message_id and not bool(payload.get("streaming", false)):
			return true
	return false


func _final_bubble_duration_ms(message_id: String) -> int:
	for entry in events:
		if entry.get("topic") != &"bubble.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("message_id", "")) == message_id and not bool(payload.get("streaming", false)):
			return int(payload.get("durationMs", 0))
	return 0


func _message_id_for(topic: StringName) -> String:
	for entry in events:
		if entry.get("topic") == topic:
			return str(entry.get("payload", {}).get("message_id", ""))
	return ""


func _text_for(topic: StringName, message_id: String) -> String:
	for entry in events:
		if entry.get("topic") != topic:
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("message_id", "")) == message_id:
			return str(payload.get("text", ""))
	return ""
