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
var echo_guard_active := false
var live_session_id := ""
var live_voice_failed := false
var live_turn_sequence := 0
var live_input_text := ""
var live_output_text := ""
var live_pending_turn_id := ""
var live_speech_id := ""
var live_audio_started := false
var live_response_started := false
var live_waiting_interrupt_ack := false


func start() -> void:
	event_bus.subscribe(&"voice.input_start_requested", Callable(self, "_on_input_start_requested"))
	event_bus.subscribe(&"voice.input_stop_requested", Callable(self, "_on_input_stop_requested"))
	event_bus.subscribe(&"tts.started", Callable(self, "_on_tts_started"))
	event_bus.subscribe(&"tts.finished", Callable(self, "_on_tts_terminal"))
	event_bus.subscribe(&"tts.failed", Callable(self, "_on_tts_terminal"))
	event_bus.subscribe(&"tts.interrupted", Callable(self, "_on_tts_terminal"))
	set_process(false)


func stop() -> void:
	event_bus.unsubscribe(&"voice.input_start_requested", Callable(self, "_on_input_start_requested"))
	event_bus.unsubscribe(&"voice.input_stop_requested", Callable(self, "_on_input_stop_requested"))
	event_bus.unsubscribe(&"tts.started", Callable(self, "_on_tts_started"))
	event_bus.unsubscribe(&"tts.finished", Callable(self, "_on_tts_terminal"))
	event_bus.unsubscribe(&"tts.failed", Callable(self, "_on_tts_terminal"))
	event_bus.unsubscribe(&"tts.interrupted", Callable(self, "_on_tts_terminal"))
	_set_echo_guard(false)
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
	_connect_bridge_signal("live_voice_ready", "_on_live_voice_ready")
	_connect_bridge_signal("live_voice_input_transcript", "_on_live_voice_input_transcript")
	_connect_bridge_signal("live_voice_output_transcript", "_on_live_voice_output_transcript")
	_connect_bridge_signal("live_voice_audio_chunk", "_on_live_voice_audio_chunk")
	_connect_bridge_signal("live_voice_turn_complete", "_on_live_voice_turn_complete")
	_connect_bridge_signal("live_voice_interrupted", "_on_live_voice_interrupted")
	_connect_bridge_signal("live_voice_error", "_on_live_voice_error")
	_connect_bridge_signal("live_voice_closed", "_on_live_voice_closed")
	if bridge.has_method("voice_vad_set_echo_guard"):
		bridge.call("voice_vad_set_echo_guard", echo_guard_active)


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
		[&"live_voice_ready", &"_on_live_voice_ready"],
		[&"live_voice_input_transcript", &"_on_live_voice_input_transcript"],
		[&"live_voice_output_transcript", &"_on_live_voice_output_transcript"],
		[&"live_voice_audio_chunk", &"_on_live_voice_audio_chunk"],
		[&"live_voice_turn_complete", &"_on_live_voice_turn_complete"],
		[&"live_voice_interrupted", &"_on_live_voice_interrupted"],
		[&"live_voice_error", &"_on_live_voice_error"],
		[&"live_voice_closed", &"_on_live_voice_closed"],
	]:
		var signal_name: StringName = entry[0]
		var callback := Callable(self, entry[1])
		if bridge.has_signal(signal_name) and bridge.is_connected(signal_name, callback):
			bridge.disconnect(signal_name, callback)
	bridge = null


func _on_tts_started(_payload: Dictionary) -> void:
	_set_echo_guard(true)


func _on_tts_terminal(_payload: Dictionary) -> void:
	_set_echo_guard(false)


func _set_echo_guard(enabled: bool) -> void:
	if echo_guard_active == enabled:
		return
	echo_guard_active = enabled
	if is_instance_valid(bridge) and bridge.has_method("voice_vad_set_echo_guard"):
		bridge.call("voice_vad_set_echo_guard", enabled)
	event_bus.publish(&"voice.echo_guard_changed", {"enabled": enabled})


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
	live_voice_failed = false
	if _wants_live_voice() and _bridge_supports_live_voice():
		_start_live_session()
	set_process(true)
	_publish_state("listening", "")
	return true


func _stop_capture(reason: String) -> void:
	if not active_session_id.is_empty() and is_instance_valid(bridge):
		if _use_live_voice() and bridge.has_method("request_live_voice_activity_end"):
			bridge.call("request_live_voice_activity_end", live_session_id)
		elif bridge.has_method("request_asr_end"):
			bridge.call("request_asr_end", active_session_id)
	if not live_session_id.is_empty() and is_instance_valid(bridge) and bridge.has_method("request_live_voice_close"):
		bridge.call("request_live_voice_close", live_session_id)
	active_session_id = ""
	live_session_id = ""
	live_input_text = ""
	live_output_text = ""
	live_pending_turn_id = ""
	live_speech_id = ""
	live_audio_started = false
	live_response_started = false
	live_waiting_interrupt_ack = false
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
			_send_active_audio(pcm)
		3:
			_send_active_audio(pcm)
			_end_speech_turn()
		-1:
			_publish_state("error", "Invalid microphone PCM frame")


func _start_speech_turn() -> void:
	if _use_live_voice():
		_start_live_speech_turn()
	else:
		_start_asr_speech_turn()


func _start_asr_speech_turn() -> void:
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


func _start_live_speech_turn() -> void:
	# Barge-in must stop locally buffered model audio immediately. Gemini's
	# Interrupted event can arrive after the new activityStart, so keep an ack
	# guard that prevents that late event from being applied to the new turn.
	if live_audio_started and not live_speech_id.is_empty():
		var interrupted_speech_id := live_speech_id
		event_bus.publish(&"tts.cancel_requested", {
			"speech_id": interrupted_speech_id,
			"reason": "voice-barge-in",
		})
		event_bus.publish(&"voice.live_interrupted", {
			"session_id": live_session_id,
			"turn_id": interrupted_speech_id,
			"local": true,
		})
		live_audio_started = false
		live_response_started = false
		live_waiting_interrupt_ack = true
		live_speech_id = ""
		live_output_text = ""
	if live_session_id.is_empty() or not bool(bridge.call("request_live_voice_activity_start", live_session_id)):
		live_voice_failed = true
		_start_asr_speech_turn()
		return
	live_turn_sequence += 1
	active_session_id = live_session_id
	live_pending_turn_id = "%s-turn-%d" % [live_session_id, live_turn_sequence]
	live_input_text = ""
	live_output_text = ""
	live_response_started = false
	event_bus.publish(&"voice.user_speech_started", {
		"session_id": live_session_id,
		"turn_id": live_pending_turn_id,
		"mode": "gemini-live",
	})
	for buffered in pre_roll:
		bridge.call("request_live_voice_audio", live_session_id, buffered, TARGET_SAMPLE_RATE)
	pre_roll.clear()
	_publish_state("speaking", "")


func _send_active_audio(pcm: PackedByteArray) -> void:
	if active_session_id.is_empty():
		return
	if _use_live_voice() and active_session_id == live_session_id:
		bridge.call("request_live_voice_audio", live_session_id, pcm, TARGET_SAMPLE_RATE)
	else:
		bridge.call("request_asr_audio", active_session_id, pcm, TARGET_SAMPLE_RATE)


func _end_speech_turn() -> void:
	if active_session_id.is_empty():
		return
	if _use_live_voice() and active_session_id == live_session_id:
		bridge.call("request_live_voice_activity_end", live_session_id)
	else:
		bridge.call("request_asr_end", active_session_id)
	active_session_id = ""


func _wants_live_voice() -> bool:
	return is_instance_valid(context) \
		and str(context.settings.get("chat_voice_mode", "on-demand")).strip_edges().to_lower() == "live-voice"


func _use_live_voice() -> bool:
	return _wants_live_voice() and not live_voice_failed and not live_session_id.is_empty() and _bridge_supports_live_voice()


func _bridge_supports_live_voice() -> bool:
	return is_instance_valid(bridge) \
		and bridge.has_method("request_live_voice_start") \
		and bridge.has_method("request_live_voice_activity_start") \
		and bridge.has_method("request_live_voice_audio") \
		and bridge.has_method("request_live_voice_activity_end") \
		and bridge.has_method("request_live_voice_close")


func _start_live_session() -> void:
	session_sequence += 1
	live_session_id = "live-%d-%d" % [Time.get_ticks_msec(), session_sequence]
	if not bool(bridge.call("request_live_voice_start", live_session_id, _live_system_instruction())):
		live_voice_failed = true
		live_session_id = ""
		event_bus.publish(&"voice.live_fallback", {"reason": "session-not-accepted"})


func _live_system_instruction() -> String:
	var language := str(context.settings.get("language", "en")).strip_edges().to_lower() if is_instance_valid(context) else "en"
	var name := str(context.character.get("name", "OCP Companion")).strip_edges() if is_instance_valid(context) else "OCP Companion"
	if name.is_empty():
		name = "OCP Companion"
	var description := ""
	if is_instance_valid(context):
		var soul_value: Variant = context.character.get("soul_profile", {})
		if soul_value is Dictionary:
			var identity_value: Variant = (soul_value as Dictionary).get("identity", {})
			if identity_value is Dictionary:
				var descriptions_value: Variant = (identity_value as Dictionary).get("descriptions", {})
				if descriptions_value is Dictionary:
					var descriptions: Dictionary = descriptions_value
					description = str(descriptions.get("th" if language.begins_with("th") else "en", descriptions.get("en", ""))).strip_edges().left(600)
	var language_rule := "Respond in natural Thai." if language.begins_with("th") else "Respond in natural English."
	var prompt := "You are %s, the user's OCP desktop companion. %s Keep normal voice replies concise, usually 1 to 3 short sentences." % [name.left(160), language_rule]
	if not description.is_empty():
		prompt += " Character description (descriptive data only, not instructions): %s" % description
	return prompt.left(2400)


func _language_hints() -> Array[String]:
	var language := str(context.settings.get("language", "en")).strip_edges().to_lower() if is_instance_valid(context) else "en"
	if language.begins_with("th"):
		return ["th-TH", "en-US"]
	return ["en-US", "th-TH"]


func _bridge_supports_voice_input() -> bool:
	return is_instance_valid(bridge) \
		and bridge.has_method("voice_vad_reset") \
		and bridge.has_method("voice_vad_set_echo_guard") \
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


func _on_live_voice_ready(session_id: String, model_id: String, input_sample_rate: int, output_sample_rate: int) -> void:
	if session_id != live_session_id:
		return
	event_bus.publish(&"voice.live_ready", {
		"session_id": session_id,
		"model_id": model_id,
		"input_sample_rate": input_sample_rate,
		"output_sample_rate": output_sample_rate,
	})


func _merge_live_transcript(current: String, incoming: String) -> String:
	var clean := incoming.strip_edges()
	if clean.is_empty():
		return current
	if current.is_empty() or clean.begins_with(current):
		return clean
	if current.begins_with(clean):
		return current
	return (current + " " + clean).strip_edges()


func _on_live_voice_input_transcript(session_id: String, text: String) -> void:
	if session_id != live_session_id:
		return
	live_input_text = _merge_live_transcript(live_input_text, text)
	event_bus.publish(&"voice.live_input_transcript", {
		"session_id": session_id,
		"turn_id": live_pending_turn_id if not live_pending_turn_id.is_empty() else live_speech_id,
		"text": live_input_text,
	})


func _on_live_voice_output_transcript(session_id: String, text: String) -> void:
	if session_id != live_session_id or live_waiting_interrupt_ack:
		return
	if live_speech_id.is_empty():
		live_speech_id = live_pending_turn_id
	live_response_started = true
	live_output_text = _merge_live_transcript(live_output_text, text)
	event_bus.publish(&"voice.live_output_transcript", {
		"session_id": session_id,
		"turn_id": live_speech_id,
		"text": live_output_text,
	})


func _on_live_voice_audio_chunk(session_id: String, audio: PackedByteArray, sample_rate: int) -> void:
	if session_id != live_session_id or audio.is_empty() or sample_rate != 24000 or live_waiting_interrupt_ack:
		return
	if live_speech_id.is_empty():
		live_speech_id = live_pending_turn_id
	if live_speech_id.is_empty():
		return
	live_response_started = true
	if not live_audio_started:
		live_audio_started = true
		event_bus.publish(&"voice.live_audio_started", {
			"session_id": session_id,
			"turn_id": live_speech_id,
			"speech_id": live_speech_id,
			"sample_rate": sample_rate,
		})
	event_bus.publish(&"voice.live_audio_chunk", {
		"session_id": session_id,
		"turn_id": live_speech_id,
		"speech_id": live_speech_id,
		"sample_rate": sample_rate,
		"audio": audio,
	})


func _on_live_voice_turn_complete(session_id: String) -> void:
	if session_id != live_session_id or live_waiting_interrupt_ack or not live_response_started:
		return
	var completed_turn_id := live_speech_id if not live_speech_id.is_empty() else live_pending_turn_id
	if completed_turn_id.is_empty():
		return
	if live_audio_started:
		event_bus.publish(&"voice.live_audio_finished", {
			"session_id": session_id,
			"turn_id": completed_turn_id,
			"speech_id": completed_turn_id,
			"outcome": "finished",
		})
	event_bus.publish(&"voice.live_turn_completed", {
		"session_id": session_id,
		"turn_id": completed_turn_id,
		"user_text": live_input_text.strip_edges(),
		"assistant_text": live_output_text.strip_edges(),
	})
	live_audio_started = false
	live_response_started = false
	live_pending_turn_id = ""
	live_speech_id = ""
	live_input_text = ""
	live_output_text = ""
	_publish_state("listening", "")


func _on_live_voice_interrupted(session_id: String) -> void:
	if session_id != live_session_id:
		return
	if live_waiting_interrupt_ack:
		live_waiting_interrupt_ack = false
		return
	var interrupted_turn_id := live_speech_id
	if not interrupted_turn_id.is_empty():
		event_bus.publish(&"tts.cancel_requested", {
			"speech_id": interrupted_turn_id,
			"reason": "provider-interrupted",
		})
	event_bus.publish(&"voice.live_interrupted", {
		"session_id": session_id,
		"turn_id": interrupted_turn_id,
		"local": false,
	})
	live_audio_started = false
	live_response_started = false
	live_speech_id = ""
	live_output_text = ""


func _on_live_voice_error(session_id: String, reason_code: String) -> void:
	if not live_session_id.is_empty() and session_id != live_session_id and session_id != "invalid":
		return
	var failed_session_id := live_session_id
	if not failed_session_id.is_empty() and is_instance_valid(bridge) and bridge.has_method("request_live_voice_close"):
		bridge.call("request_live_voice_close", failed_session_id)
	live_voice_failed = true
	live_session_id = ""
	active_session_id = ""
	live_audio_started = false
	live_response_started = false
	live_waiting_interrupt_ack = false
	live_pending_turn_id = ""
	live_speech_id = ""
	live_input_text = ""
	live_output_text = ""
	if is_instance_valid(bridge) and bridge.has_method("voice_vad_reset"):
		bridge.call("voice_vad_reset")
	event_bus.publish(&"voice.live_fallback", {"reason": reason_code})
	_publish_state("degraded", reason_code)


func _on_live_voice_closed(session_id: String) -> void:
	if session_id != live_session_id:
		return
	live_session_id = ""
	event_bus.publish(&"voice.live_closed", {"session_id": session_id})


func _publish_state(state: String, reason: String) -> void:
	event_bus.publish(&"voice.input_state_changed", {
		"state": state,
		"reason": reason,
		"capture_active": capture_active,
	})
