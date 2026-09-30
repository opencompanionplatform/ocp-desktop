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
	context.update_settings({"tts_enabled": true})
	ai.bus = bus
	services.register_service(&"ai", ai)
	bus.event_published.connect(_record_event)
	bus.subscribe(&"tts.requested", Callable(self, "_capture_tts"))
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	bus.publish(&"ai.prompt_requested", {
		"message_id": "msg-multi-tts",
		"prompt": "say two sentences",
	})
	# TTS is intentionally deferred so Chat delivery cannot be blocked by
	# synthesis dispatch. Let the idle queue run before asserting TTS state.
	await process_frame
	var chat_final_before_tts := _topic_before(&"chat.assistant_message_received", &"tts.requested")
	var queued_ok := tts_requests.size() == 2 \
		and str(tts_requests[0].get("text", "")) == "First sentence." \
		and str(tts_requests[1].get("text", "")) == "Second sentence." \
		and int(tts_requests[0].get("chunk_index", -1)) == 0 \
		and int(tts_requests[1].get("chunk_index", -1)) == 1 \
		and _animation_count("idle") == 0 and chat_final_before_tts
	for index in range(tts_requests.size()):
		var request: Dictionary = tts_requests[index].duplicate(true)
		bus.publish(&"tts.started", request)
		if index == tts_requests.size() - 1:
			request["outcome"] = "interrupted"
			bus.publish(&"tts.interrupted", request)
		else:
			bus.publish(&"tts.finished", request)
	var no_mid_idle := _animation_count("idle") == 1
	var no_mid_think := _animation_count("think") == 1
	var final_idle_once := _animation_count("idle") == 1
	var speak_count := _animation_count("speak")
	var message_ids_ok := true
	for request in tts_requests:
		message_ids_ok = message_ids_ok and str(request.get("message_id", "")) == "msg-multi-tts"
	var ok := queued_ok and no_mid_idle and no_mid_think and final_idle_once and speak_count == 1 and message_ids_ok
	print("[CHAT-TTS-LIFECYCLE] chunks=", tts_requests.size(), " no_mid_idle=", no_mid_idle, " no_mid_think=", no_mid_think, " final_idle_once=", final_idle_once, " speak_count=", speak_count, " ok=", ok)
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
