extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")


class FakeAIService:
	extends Node
	var bus: Node

	func request(payload: Dictionary) -> void:
		var message_id := str(payload.get("message_id", ""))
		var text := "First sentence. Second sentence."
		bus.publish(&"ai.stream_started", {
			"message_id": message_id,
			"provider_id": "fake",
			"request": payload,
		})
		bus.publish(&"ai.stream_delta", {
			"message_id": message_id,
			"provider_id": "fake",
			"delta": text,
			"text": text,
			"request": payload,
		})
		bus.publish(&"ai.response_received", {
			"message_id": message_id,
			"provider_id": "fake",
			"text": text,
			"request": payload,
		})


var events: Array[Dictionary] = []
var tts_requests: Array[Dictionary] = []
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
	context.update_settings({
		"tts_enabled": true,
		"chat_voice_mode": "auto-speak",
	})
	context.update_runtime_config({"chat_presentation_active": true})
	ai.bus = bus
	services.register_service(&"ai", ai)
	bus.event_published.connect(_record_event)
	bus.subscribe(&"tts.requested", Callable(self, "_capture_tts"))
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-auto-speak",
		"prompt": "say two sentences",
	})
	await process_frame

	var text_before_voice := _topic_before(&"chat.assistant_message_received", &"tts.requested")
	var segmented_queue := tts_requests.size() == 2 \
		and str(tts_requests[0].get("message_id", "")) == "msg-auto-speak" \
		and str(tts_requests[0].get("text", "")) == "First sentence." \
		and int(tts_requests[0].get("chunk_index", -1)) == 0 \
		and not bool(tts_requests[0].get("final", true)) \
		and str(tts_requests[0].get("source", "")) == "chat-session-stable" \
		and str(tts_requests[1].get("text", "")) == "Second sentence." \
		and int(tts_requests[1].get("chunk_index", -1)) == 1 \
		and bool(tts_requests[1].get("final", false)) \
		and str(tts_requests[1].get("source", "")) == "chat-session-stable"
	var no_idle_before_voice := _animation_count("idle") == 0
	for index in range(tts_requests.size()):
		var request: Dictionary = tts_requests[index]
		bus.publish(&"tts.started", request.merged({"speech_id": "speech-auto-%d" % index}, true))
		bus.publish(&"tts.finished", request.merged({"speech_id": "speech-auto-%d" % index}, true))
	var lifecycle_ok := _animation_count("speak") == 1 and _animation_count("idle") == 1 and _animation_count("think") == 1
	var ok := text_before_voice and segmented_queue and no_idle_before_voice and lifecycle_ok
	print("[CHAT-AUTO-SPEAK] segmented=", segmented_queue, " text_first=", text_before_voice, " no_early_idle=", no_idle_before_voice, " lifecycle=", lifecycle_ok, " ok=", ok)
	orchestrator.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _record_event(topic: StringName, payload: Dictionary) -> void:
	events.append({"topic": topic, "payload": payload.duplicate(true)})


func _capture_tts(payload: Dictionary) -> void:
	tts_requests.append(payload.duplicate(true))


func _topic_before(first: StringName, second: StringName) -> bool:
	var first_index := -1
	var second_index := -1
	for index in range(events.size()):
		var topic = events[index].get("topic")
		if topic == first and first_index < 0:
			first_index = index
		if topic == second and second_index < 0:
			second_index = index
	return first_index >= 0 and second_index >= 0 and first_index < second_index


func _animation_count(name: String) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") != &"animation.requested":
			continue
		var payload: Dictionary = entry.get("payload", {})
		if str(payload.get("name", "")) == name:
			count += 1
	return count
