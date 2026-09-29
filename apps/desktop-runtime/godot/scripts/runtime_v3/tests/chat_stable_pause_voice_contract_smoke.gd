extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")


class DeferredAI:
	extends Node
	func request(_payload: Dictionary) -> void:
		pass


var tts_requests: Array[Dictionary] = []
var bubbles: Array[Dictionary] = []
var idle_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var services := ServicesScript.new()
	var ai := DeferredAI.new()
	var orchestrator := OrchestratorScript.new()
	for node in [context, bus, services, ai, orchestrator]:
		holder.add_child(node)
	context.update_settings({"tts_enabled": true})
	services.register_service(&"ai", ai)
	bus.subscribe(&"tts.requested", func(payload: Dictionary): tts_requests.append(payload.duplicate(true)))
	bus.subscribe(&"bubble.requested", func(payload: Dictionary): bubbles.append(payload.duplicate(true)))
	bus.subscribe(&"animation.requested", func(payload: Dictionary):
		if str(payload.get("name", "")) == "idle": idle_count += 1)
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	var thai_phrase := "สวัสดีครับ วันนี้มีอะไรให้ผมช่วยไหมครับ"
	bus.publish(&"ai.prompt_requested", {"message_id": "pause-1", "prompt": "ทดสอบ"})
	bus.publish(&"ai.stream_started", {"message_id": "pause-1", "provider_id": "fake"})
	bus.publish(&"ai.stream_delta", {"message_id": "pause-1", "provider_id": "fake", "delta": thai_phrase, "text": thai_phrase})
	await create_timer(OrchestratorScript.TTS_STABLE_PAUSE_SECONDS + 0.15).timeout
	var early_voice := tts_requests.size() == 1 \
		and str(tts_requests[0].get("text", "")) == thai_phrase \
		and int(tts_requests[0].get("chunk_index", -1)) == 0 \
		and bubbles.is_empty()
	bus.publish(&"ai.response_received", {"message_id": "pause-1", "provider_id": "fake", "text": thai_phrase})
	await process_frame
	var no_duplicate := tts_requests.size() == 1 and bubbles.size() == 1
	bus.publish(&"tts.started", tts_requests[0])
	bus.publish(&"tts.finished", tts_requests[0])
	var one_idle := idle_count == 1
	var ok := early_voice and no_duplicate and one_idle
	print("[CHAT-STABLE-PAUSE] early=", early_voice, " dedup=", no_duplicate, " idle=", one_idle, " requests=", tts_requests.size())
	orchestrator.stop()
	holder.free()
	quit(0 if ok else 1)
