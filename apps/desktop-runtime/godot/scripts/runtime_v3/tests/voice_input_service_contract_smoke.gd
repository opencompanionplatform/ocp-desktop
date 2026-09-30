extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const VoiceInputServiceScript = preload("res://scripts/runtime_v3/services/voice_input_service.gd")


class FakeBridge:
	extends Node
	signal asr_ready(session_id: String, provider_id: String, model_id: String, sample_rate: int)
	signal asr_interim(session_id: String, text: String)
	signal asr_final(session_id: String, text: String)
	signal asr_turn_complete(session_id: String)
	signal asr_interrupted(session_id: String)
	signal asr_error(session_id: String, reason_code: String)
	signal asr_closed(session_id: String)

	var vad_codes: Array[int] = [0, 1, 2, 3]
	var starts: Array[Dictionary] = []
	var audio: Array[Dictionary] = []
	var ends: Array[String] = []
	var echo_guard_changes: Array[bool] = []
	var reset_count := 0

	func voice_vad_reset() -> void:
		reset_count += 1

	func voice_vad_set_echo_guard(enabled: bool) -> void:
		echo_guard_changes.append(enabled)

	func voice_vad_process_pcm16(_pcm: PackedByteArray) -> int:
		if vad_codes.is_empty():
			return 0
		return vad_codes.pop_front()

	func request_asr_start(session_id: String, language_codes: PackedStringArray) -> bool:
		starts.append({"session_id": session_id, "languages": Array(language_codes)})
		return true

	func request_asr_audio(session_id: String, pcm: PackedByteArray, sample_rate: int) -> bool:
		audio.append({"session_id": session_id, "bytes": pcm.size(), "sample_rate": sample_rate})
		return true

	func request_asr_end(session_id: String) -> bool:
		ends.append(session_id)
		return true


var events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var service := VoiceInputServiceScript.new()
	var bridge := FakeBridge.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	holder.add_child(bridge)
	context.update_settings({"language": "th"})
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	service.configure(context, bus)
	service.start()
	service.bind_bridge(bridge)
	bus.publish(&"tts.started", {"message_id": "msg-echo"})
	bus.publish(&"tts.finished", {"message_id": "msg-echo"})

	var pcm := PackedByteArray([0, 0, 1, 0, 2, 0, 1, 0])
	service._handle_pcm16_frame(pcm) # silence -> pre-roll only
	service._handle_pcm16_frame(pcm) # speech start -> ASR start + pre-roll flush
	service._handle_pcm16_frame(pcm) # active -> audio
	service._handle_pcm16_frame(pcm) # speech end -> tail + ASR end

	var session_id := str(bridge.starts[0].get("session_id", "")) if not bridge.starts.is_empty() else ""
	bridge.asr_ready.emit(session_id, "gemini-live", "gemini-3.5-transcribe-live", 16000)
	bridge.asr_interim.emit(session_id, "สวัส")
	bridge.asr_final.emit(session_id, "สวัสดีครับ")
	# Gemini Live Transcription may omit turnComplete after the finalized input
	# transcription. Final must therefore complete the utterance on its own.
	bridge.asr_final.emit(session_id, "สวัสดีครับ")
	bridge.asr_turn_complete.emit(session_id)

	var start_ok: bool = bridge.starts.size() == 1 \
		and not session_id.is_empty() \
		and bridge.starts[0].get("languages", []) == ["th-TH", "en-US"]
	var audio_ok := bridge.audio.size() == 4 \
		and bridge.audio.all(func(entry: Dictionary) -> bool:
			return str(entry.get("session_id", "")) == session_id \
				and int(entry.get("sample_rate", 0)) == 16000 \
				and int(entry.get("bytes", 0)) == pcm.size())
	var end_ok := bridge.ends == [session_id] and service.active_session_id.is_empty()
	var barge_in_ok := _topic_count(&"voice.user_speech_started") == 1
	var interim_ok: bool = _topic_payload(&"voice.transcript_interim").get("text", "") == "สวัส"
	var final_ok: bool = _topic_payload(&"voice.transcript_final").get("text", "") == "สวัสดีครับ"
	var prompt := _topic_payload(&"ai.prompt_requested")
	var prompt_ok := _topic_count(&"ai.prompt_requested") == 1 \
		and str(prompt.get("prompt", "")) == "สวัสดีครับ" \
		and str(prompt.get("source", "")) == "voice-asr" \
		and str(prompt.get("voice_session_id", "")) == session_id
	var ready_ok: bool = _topic_payload(&"voice.asr_ready").get("model_id", "") == "gemini-3.5-transcribe-live"
	var echo_guard_ok := bridge.echo_guard_changes == [false, true, false]
	var ok: bool = start_ok and audio_ok and end_ok and barge_in_ok and interim_ok and final_ok and prompt_ok and ready_ok and echo_guard_ok
	print("[VOICE-INPUT] start=", start_ok, " audio=", audio_ok, " end=", end_ok, " barge_in=", barge_in_ok, " interim=", interim_ok, " final=", final_ok, " prompt=", prompt_ok, " ready=", ready_ok, " echo_guard=", echo_guard_ok, " ok=", ok)
	service.stop()
	holder.free()
	quit(0 if ok else 1)


func _topic_count(topic: StringName) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") == topic:
			count += 1
	return count


func _topic_payload(topic: StringName) -> Dictionary:
	for entry in events:
		if entry.get("topic") == topic:
			return entry.get("payload", {})
	return {}
