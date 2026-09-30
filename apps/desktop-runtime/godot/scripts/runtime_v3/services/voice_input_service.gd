extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3VoiceInputService

const BUS_NAME := "OCP Voice Input"
const TARGET_SAMPLE_RATE := 16000
const FRAME_MS := 20
const PRE_ROLL_FRAMES := 4
const MAX_CAPTURE_FRAMES_PER_TICK := 4

var bridge: Node
var capture_effect: AudioEffectCapture
var microphone_player: AudioStreamPlayer
var capture_active := false
var resample_phase := 0
var session_sequence := 0
var active_session_id := ""
var pre_roll: Array[PackedByteArray] = []
var transcript_parts: Dictionary = {}
var turn_complete_seen: Dictionary = {}
var completed_sessions: Dictionary = {}


func start() -> void:
	event_bus.subscribe(&"voice.input_start_requested", Callable(self, "_on_input_start_requested"))
	event_bus.subscribe(&"voice.input_stop_requested", Callable(self, "_on_input_stop_requested"))
	set_process(false)


func stop() -> void:
	event_bus.unsubscribe(&"voice.input_start_requested", Callable(self, "_on_input_start_requested"))
	event_bus.unsubscribe(&"voice.input_stop_requested", Callable(self, "_on_input_stop_requested"))
	_stop_capture("service-stop")
	_disconnect_bridge()


func bind_bridge(target: Node) -> void:
	if bridge == target:
		return
	_disconnect_bridge()
	bridge = target
	if not is_instance_valid(bridge):
		return
	_connect_bridge_signal("asr_ready", "_on_asr_ready")
	_connect_bridge_signal("asr_interim", "_on_asr_interim")
	_connect_bridge_signal("asr_final", "_on_asr_final")
	_connect_bridge_signal("asr_turn_complete", "_on_asr_turn_complete")
	_connect_bridge_signal("asr_interrupted", "_on_asr_interrupted")
	_connect_bridge_signal("asr_error", "_on_asr_error")
	_connect_bridge_signal("asr_closed", "_on_asr_closed")


func _connect_bridge_signal(signal_name: StringName, method_name: StringName) -> void:
	if bridge.has_signal(signal_name):
		var callback := Callable(self, method_name)
		if not bridge.is_connected(signal_name, callback):
			bridge.connect(signal_name, callback)


func _disconnect_bridge() -> void:
	if not is_instance_valid(bridge):
		bridge = null
		return
	for entry in [
		[&"asr_ready", &"_on_asr_ready"],
		[&"asr_interim", &"_on_asr_interim"],
		[&"asr_final", &"_on_asr_final"],
		[&"asr_turn_complete", &"_on_asr_turn_complete"],
		[&"asr_interrupted", &"_on_asr_interrupted"],
		[&"asr_error", &"_on_asr_error"],
		[&"asr_closed", &"_on_asr_closed"],
	]:
		var signal_name: StringName = entry[0]
		var callback := Callable(self, entry[1])
		if bridge.has_signal(signal_name) and bridge.is_connected(signal_name, callback):
			bridge.disconnect(signal_name, callback)
	bridge = null


func _on_input_start_requested(_payload: Dictionary) -> void:
	_start_capture()


func _on_input_stop_requested(_payload: Dictionary) -> void:
	_stop_capture("user-stop")


func _start_capture() -> bool:
	if capture_active:
		return true
	if not _bridge_supports_voice_input():
		_publish_state("unavailable", "Runtime voice bridge is unavailable")
		return false

	var bus_index := AudioServer.get_bus_index(BUS_NAME)
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, BUS_NAME)
	AudioServer.set_bus_mute(bus_index, true)
	for index in range(AudioServer.get_bus_effect_count(bus_index) - 1, -1, -1):
		AudioServer.remove_bus_effect(bus_index, index)

	capture_effect = AudioEffectCapture.new()
	capture_effect.buffer_length = 0.25
	AudioServer.add_bus_effect(bus_index, capture_effect, 0)
	capture_effect.clear_buffer()

	microphone_player = AudioStreamPlayer.new()
	microphone_player.name = "VoiceInputMicrophone"
	microphone_player.bus = BUS_NAME
	microphone_player.stream = AudioStreamMicrophone.new()
	add_child(microphone_player)
	microphone_player.play()

	bridge.call("voice_vad_reset")
	pre_roll.clear()
	resample_phase = 0
	capture_active = true
	set_process(true)
	_publish_state("listening", "")
	return true


func _stop_capture(reason: String) -> void:
	if not active_session_id.is_empty() and is_instance_valid(bridge) and bridge.has_method("request_asr_end"):
		bridge.call("request_asr_end", active_session_id)
	active_session_id = ""
	pre_roll.clear()
	if is_instance_valid(bridge) and bridge.has_method("voice_vad_reset"):
		bridge.call("voice_vad_reset")
	set_process(false)
	capture_active = false
	if is_instance_valid(microphone_player):
		microphone_player.stop()
		microphone_player.queue_free()
	microphone_player = null
	capture_effect = null
	var bus_index := AudioServer.get_bus_index(BUS_NAME)
	if bus_index >= 0:
		AudioServer.remove_bus(bus_index)
	_publish_state("stopped", reason)


func _process(_delta: float) -> void:
	if not capture_active or capture_effect == null:
		return
	var source_rate := maxi(1, int(round(AudioServer.get_mix_rate())))
	var source_frame_samples := maxi(1, int(round(float(source_rate) * float(FRAME_MS) / 1000.0)))
	var processed := 0
	while capture_effect.get_frames_available() >= source_frame_samples and processed < MAX_CAPTURE_FRAMES_PER_TICK:
		var frames: PackedVector2Array = capture_effect.get_buffer(source_frame_samples)
		if frames.is_empty():
			break
		var pcm := _resample_to_pcm16(frames, source_rate)
		if not pcm.is_empty():
			_handle_pcm16_frame(pcm)
		processed += 1


func _resample_to_pcm16(frames: PackedVector2Array, source_rate: int) -> PackedByteArray:
	var pcm := PackedByteArray()
	if source_rate <= 0:
		return pcm
	for frame in frames:
		resample_phase += TARGET_SAMPLE_RATE
		if resample_phase < source_rate:
			continue
		resample_phase -= source_rate
		var mono := clampf((float(frame.x) + float(frame.y)) * 0.5, -1.0, 1.0)
		var sample := clampi(roundi(mono * 32767.0), -32768, 32767)
		pcm.append(sample & 0xff)
		pcm.append((sample >> 8) & 0xff)
	return pcm


func _handle_pcm16_frame(pcm: PackedByteArray) -> void:
	if not _bridge_supports_voice_input() or pcm.is_empty():
		return
	pre_roll.append(pcm.duplicate())
	while pre_roll.size() > PRE_ROLL_FRAMES:
		pre_roll.pop_front()

	var vad_code := int(bridge.call("voice_vad_process_pcm16", pcm))
	match vad_code:
		1:
			_start_speech_turn()
		2:
			if not active_session_id.is_empty():
				bridge.call("request_asr_audio", active_session_id, pcm, TARGET_SAMPLE_RATE)
		3:
			if not active_session_id.is_empty():
				bridge.call("request_asr_audio", active_session_id, pcm, TARGET_SAMPLE_RATE)
				bridge.call("request_asr_end", active_session_id)
				active_session_id = ""
		-1:
			_publish_state("error", "Invalid microphone PCM frame")


func _start_speech_turn() -> void:
	session_sequence += 1
	var session_id := "voice-%d-%d" % [Time.get_ticks_msec(), session_sequence]
	var languages := PackedStringArray(_language_hints())
	if not bool(bridge.call("request_asr_start", session_id, languages)):
		_publish_state("error", "ASR session was not accepted")
		bridge.call("voice_vad_reset")
		pre_roll.clear()
		return

	active_session_id = session_id
	transcript_parts[session_id] = []
	event_bus.publish(&"voice.user_speech_started", {"session_id": session_id})
	for buffered in pre_roll:
		bridge.call("request_asr_audio", session_id, buffered, TARGET_SAMPLE_RATE)
	pre_roll.clear()
	_publish_state("speaking", "")


func _language_hints() -> Array[String]:
	var language := str(context.settings.get("language", "en")).strip_edges().to_lower() if is_instance_valid(context) else "en"
	if language.begins_with("th"):
		return ["th-TH", "en-US"]
	return ["en-US", "th-TH"]


func _bridge_supports_voice_input() -> bool:
	return is_instance_valid(bridge) \
		and bridge.has_method("voice_vad_reset") \
		and bridge.has_method("voice_vad_process_pcm16") \
		and bridge.has_method("request_asr_start") \
		and bridge.has_method("request_asr_audio") \
		and bridge.has_method("request_asr_end")


func _on_asr_ready(session_id: String, provider_id: String, model_id: String, sample_rate: int) -> void:
	event_bus.publish(&"voice.asr_ready", {
		"session_id": session_id,
		"provider_id": provider_id,
		"model_id": model_id,
		"sample_rate": sample_rate,
	})


func _on_asr_interim(session_id: String, text: String) -> void:
	var clean := text.strip_edges()
	if clean.is_empty():
		return
	event_bus.publish(&"voice.transcript_interim", {"session_id": session_id, "text": clean})


func _on_asr_final(session_id: String, text: String) -> void:
	if completed_sessions.has(session_id):
		return
	var clean := text.strip_edges()
	if clean.is_empty():
		return
	var parts: Array = transcript_parts.get(session_id, [])
	if parts.is_empty() or str(parts[parts.size() - 1]) != clean:
		parts.append(clean)
	transcript_parts[session_id] = parts
	# Gemini Live Transcription's inputTranscription is the finalized utterance.
	# Do not wait for turnComplete: transcription-only sessions may omit it, and
	# server message ordering is not guaranteed. Completion is idempotent below.
	_complete_transcript(session_id)


func _on_asr_turn_complete(session_id: String) -> void:
	if completed_sessions.has(session_id):
		return
	turn_complete_seen[session_id] = true
	# If a final transcript raced ahead of/behind this event, complete only when
	# usable text exists. A later Final will call the same idempotent helper.
	if transcript_parts.has(session_id):
		_complete_transcript(session_id)


func _complete_transcript(session_id: String) -> void:
	if completed_sessions.has(session_id):
		return
	var parts: Array = transcript_parts.get(session_id, [])
	var clean_parts: Array[String] = []
	for part in parts:
		var text := str(part).strip_edges()
		if not text.is_empty():
			clean_parts.append(text)
	var transcript := " ".join(clean_parts).strip_edges()
	if transcript.is_empty():
		return
	transcript_parts.erase(session_id)
	turn_complete_seen.erase(session_id)
	completed_sessions[session_id] = true
	while completed_sessions.size() > 32:
		completed_sessions.erase(completed_sessions.keys()[0])
	event_bus.publish(&"voice.transcript_final", {"session_id": session_id, "text": transcript})
	event_bus.publish(&"ai.prompt_requested", {
		"prompt": transcript,
		"source": "voice-asr",
		"voice_session_id": session_id,
	})
	_publish_state("listening", "")


func _on_asr_interrupted(session_id: String) -> void:
	event_bus.publish(&"voice.asr_interrupted", {"session_id": session_id})


func _on_asr_error(session_id: String, reason_code: String) -> void:
	transcript_parts.erase(session_id)
	if active_session_id == session_id:
		active_session_id = ""
	if is_instance_valid(bridge) and bridge.has_method("voice_vad_reset"):
		bridge.call("voice_vad_reset")
	_publish_state("error", reason_code)


func _on_asr_closed(session_id: String) -> void:
	if active_session_id == session_id:
		active_session_id = ""
	event_bus.publish(&"voice.asr_closed", {"session_id": session_id})


func _publish_state(state: String, reason: String) -> void:
	event_bus.publish(&"voice.input_state_changed", {
		"state": state,
		"reason": reason,
		"capture_active": capture_active,
	})
