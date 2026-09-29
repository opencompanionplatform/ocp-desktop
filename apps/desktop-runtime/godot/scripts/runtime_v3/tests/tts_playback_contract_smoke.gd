extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const TTSServiceScript = preload("res://scripts/runtime_v3/services/tts_service.gd")

class FakeBridge:
	extends Node
	signal speech_started(companion_id: String, speech_id: String, text: String)
	signal speech_requested(companion_id: String, speech_id: String, text: String, subtitle: bool, audio_path: String)
	signal speech_finished(speech_id: String, companion_id: String, outcome: String)
	var reports: Array[Dictionary] = []

	func request_tts(_message_id: String, _chunk_index: int, text: String, _voice: String, _provider_id: String, _model_id: String, _final_chunk: bool) -> bool:
		call_deferred("_complete_without_audio", text)
		return true

	func _complete_without_audio(text: String) -> void:
		speech_started.emit("default", "speech-contract", text)
		speech_requested.emit("default", "speech-contract", text, false, "")

	func report_speech_finished(speech_id: String, companion_id: String, outcome: String) -> void:
		reports.append({"speech_id": speech_id, "companion_id": companion_id, "outcome": outcome})
		speech_finished.emit(speech_id, companion_id, outcome)

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
	service.configure(context, bus)
	service.start()
	service.bind_bridge(bridge)

	bus.publish(&"tts.requested", {
		"message_id": "message-contract",
		"chunk_index": 0,
		"text": "hello",
		"final": true,
	})
	await process_frame
	await process_frame
	var ok: bool = bridge.reports.size() == 1 \
		and bridge.reports[0].get("speech_id") == "speech-contract" \
		and bridge.reports[0].get("outcome") == "tts-unavailable"
	print("[TTS-PLAYBACK-CONTRACT] reports=", bridge.reports.size(), " outcome=", bridge.reports[0].get("outcome", "") if bridge.reports.size() > 0 else "", " ok=", ok)
	service.stop()
	holder.free()
	quit(0 if ok else 1)
