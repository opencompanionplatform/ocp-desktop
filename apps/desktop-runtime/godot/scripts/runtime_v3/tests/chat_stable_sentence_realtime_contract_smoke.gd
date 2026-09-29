extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const OrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")


class DeferredAI:
	extends Node
	var request_payload: Dictionary = {}
	func request(payload: Dictionary) -> void:
		request_payload = payload.duplicate(true)


var tts_requests: Array[Dictionary] = []
var bubbles: Array[Dictionary] = []
var events: Array[Dictionary] = []


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
	bus.event_published.connect(func(topic: StringName, payload: Dictionary): events.append({"topic": topic, "payload": payload.duplicate(true)}))
	bus.subscribe(&"tts.requested", func(payload: Dictionary): tts_requests.append(payload.duplicate(true)))
	bus.subscribe(&"bubble.requested", func(payload: Dictionary): bubbles.append(payload.duplicate(true)))
	orchestrator.configure(context, bus, services, null)
	orchestrator.start()

	bus.publish(&"ai.prompt_requested", {"message_id": "realtime-1", "prompt": "ทดสอบ"})
	bus.publish(&"ai.stream_started", {"message_id": "realtime-1", "provider_id": "fake"})
	bus.publish(&"ai.stream_delta", {
		"message_id": "realtime-1",
		"provider_id": "fake",
		"delta": "สวัสดีครับ. กำลังตอบต่อ",
		"text": "สวัสดีครับ. กำลังตอบต่อ",
	})
	await process_frame
	var before_final := tts_requests.size() == 1 \
		and str(tts_requests[0].get("text", "")) == "สวัสดีครับ." \
		and int(tts_requests[0].get("chunk_index", -1)) == 0 \
		and not bool(tts_requests[0].get("final", true)) \
		and bubbles.size() == 1 \
		and str(bubbles[0].get("text", "")) == "สวัสดีครับ."

	# A repeated accumulated provider snapshot must not replay the committed
	# sentence through either speech or Bubble.
	bus.publish(&"ai.stream_delta", {
		"message_id": "realtime-1",
		"provider_id": "fake",
		"delta": "",
		"text": "สวัสดีครับ. กำลังตอบต่อ",
	})
	await process_frame
	var duplicate_suppressed := tts_requests.size() == 1 and bubbles.size() == 1

	bus.publish(&"ai.response_received", {
		"message_id": "realtime-1",
		"provider_id": "fake",
		"text": "สวัสดีครับ. กำลังตอบต่อ 😊",
	})
	await process_frame
	var final_tail := tts_requests.size() == 2 \
		and str(tts_requests[1].get("text", "")) == "กำลังตอบต่อ 😊" \
		and int(tts_requests[1].get("chunk_index", -1)) == 1 \
		and bool(tts_requests[1].get("final", false)) \
		and bubbles.size() == 2 \
		and str(bubbles[1].get("text", "")) == "กำลังตอบต่อ 😊"

	for request in tts_requests.duplicate(true):
		bus.publish(&"tts.started", request)
		bus.publish(&"tts.finished", request)
	var one_final_idle := _animation_count("idle") == 1
	var ok := before_final and duplicate_suppressed and final_tail and one_final_idle
	print("[CHAT-STABLE-REALTIME] before_final=", before_final, " dedup=", duplicate_suppressed, " final_tail=", final_tail, " one_idle=", one_final_idle)
	orchestrator.stop()
	holder.free()
	quit(0 if ok else 1)


func _animation_count(name: String) -> int:
	var count := 0
	for event in events:
		if event.get("topic") == &"animation.requested" and str(event.get("payload", {}).get("name", "")) == name:
			count += 1
	return count
