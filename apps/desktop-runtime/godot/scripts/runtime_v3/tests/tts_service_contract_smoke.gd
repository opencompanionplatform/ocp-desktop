extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const TTSServiceScript = preload("res://scripts/runtime_v3/services/tts_service.gd")

class FakeBridge:
	extends Node
	signal speech_started(companion_id: String, speech_id: String, text: String)
	signal speech_requested(companion_id: String, speech_id: String, text: String, subtitle: bool, audio_path: String)
	signal speech_finished(speech_id: String, companion_id: String, outcome: String)
	signal speech_route_diagnostic(speech_id: String, reason_code: String)
	var requests: Array[Dictionary] = []
	var sequence := 0

	func request_tts(message_id: String, chunk_index: int, text: String, voice: String, provider_id: String, model_id: String, final_chunk: bool) -> bool:
		sequence += 1
		var speech_id := "speech-%d" % sequence
		requests.append({
			"message_id": message_id,
			"chunk_index": chunk_index,
			"text": text,
			"voice": voice,
			"provider_id": provider_id,
			"model_id": model_id,
			"final": final_chunk,
			"speech_id": speech_id,
		})
		call_deferred("_complete", speech_id, text)
		return true

	func _complete(speech_id: String, text: String) -> void:
		speech_started.emit("default", speech_id, text)
		# Keep the first clip open long enough to prove the second chunk is
		# synthesized/prefetched while playback of chunk 0 is still active.
		if speech_id != "speech-1":
			call_deferred("_finish", speech_id)

	func _finish(speech_id: String) -> void:
		speech_finished.emit(speech_id, "default", "finished")

	func report_speech_finished(speech_id: String, companion_id: String, outcome: String) -> void:
		speech_finished.emit(speech_id, companion_id, outcome)

var events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var service := TTSServiceScript.new()
	var bridge := FakeBridge.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	holder.add_child(bridge)
	context.update_settings({
		"tts_enabled": true,
		# Regression: a legacy concrete persona must not override Character mode.
		"tts_voice": "Enceladus",
		"tts_voice_mode": "character",
		"tts_provider_id": "auto",
		"tts_model": "gemini-2.5-flash-preview-tts",
	})
	context.update_character({
		"voice_profile": {"gender": "female", "age": "adult", "thaiSpeechStyle": "feminine"},
	})
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	service.configure(context, bus)
	service.start()
	service.bind_bridge(bridge)

	bus.publish(&"tts.requested", {
		"message_id": "msg-1",
		"chunk_index": 0,
		"text": "first sentence",
		"final": false,
		"source": "electron-control-center-test",
	})
	bus.publish(&"tts.requested", {
		"message_id": "msg-1",
		"chunk_index": 1,
		"text": "second sentence",
		"final": true,
		"source": "chat-session-stream",
	})
	await process_frame
	await process_frame
	await process_frame

	var prefetched := bridge.requests.size() == 2 \
		and int(bridge.requests[0].get("chunk_index", -1)) == 0 \
		and int(bridge.requests[1].get("chunk_index", -1)) == 1 \
		and str(bridge.requests[0].get("voice", "")) == "profile:female:adult" \
		and str(bridge.requests[0].get("provider_id", "")) == "auto" \
		and str(bridge.requests[0].get("model_id", "")) == "gemini-2.5-flash-preview-tts"
	# Finish chunk 0 only after chunk 1 has already been synthesized/accepted.
	bridge._finish("speech-1")
	await process_frame
	await process_frame
	var finishes := _topic_count(&"tts.finished")
	var direct_bubbles := _topic_count(&"bubble.requested") == 1 \
		and _bubble_text_for("msg-1") == "first sentence"
	var ok := prefetched and direct_bubbles
	print("[TTS-SERVICE] prefetched=", prefetched, " finishes=", finishes, " direct_bubbles=", direct_bubbles, " ok=", ok)
	service.stop()
	holder.free()
	quit(0 if ok else 1)


func _topic_count(topic: StringName) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") == topic:
			count += 1
	return count


func _bubble_text_for(message_id: String) -> String:
	var result := ""
	for entry in events:
		if entry.get("topic") == &"bubble.requested":
			var payload: Dictionary = entry.get("payload", {})
			if str(payload.get("message_id", "")) == message_id:
				result = str(payload.get("text", ""))
	return result
