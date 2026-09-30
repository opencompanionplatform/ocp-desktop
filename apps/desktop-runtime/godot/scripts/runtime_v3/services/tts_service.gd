extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3TTSService

## Serializes ChatSessionOrchestrator TTS chunks through the Rust bridge and the
## kernel voice router. Only one clip is allowed in flight so sentence chunks do
## not overlap. The existing companion playback path remains the audio authority;
## this service translates its bridge lifecycle into stable tts.* runtime events.

var bridge: Node
var _queue: Array[Dictionary] = []
# `_inflight` is the chunk currently being synthesized by Kernel. Once Kernel
# emits speech_started, synthesis is complete and we can immediately submit the
# next chunk while the current audio is still playing.
var _inflight: Dictionary = {}
# `_playback` is the one clip allowed to play at a time. `_ready` contains clips
# already synthesized and waiting for the previous clip to finish.
var _playback: Dictionary = {}
var _ready: Array[Dictionary] = []
var _players: Dictionary = {}
# Gemini streaming uses one real-time AudioStreamGenerator per speech. The
# kernel sends L16 PCM deltas; we keep a small pending queue when the generator
# buffer is temporarily full so we never block the main thread.
var _stream_players: Dictionary = {}
var _stream_pending: Dictionary = {}
var _stream_state: Dictionary = {}
var _stream_playbacks: Dictionary = {}
var _stream_pcm_bytes: Dictionary = {}
var _stream_sample_rates: Dictionary = {}
var _stream_pending_finish: Dictionary = {}
var _stream_pending_chunks: Dictionary = {}
# Keep the generator paused until a small amount of PCM is queued. Starting an
# AudioStreamGenerator on an empty buffer can immediately underrun on Windows,
# especially when the first Gemini SSE delta arrives on the next frame.
# WASAPI is already proven reliable with AudioStreamPlayer + AudioStreamWAV in
# this runtime. Keep Gemini's low time-to-first-audio, but emit short in-memory
# WAV segments instead of AudioStreamGenerator, which is currently silent on the
# production Windows path even though PCM reaches the bridge correctly.
const STREAM_SEGMENT_MS := 160 # legacy WAV fallback only
const STREAM_GENERATOR_PREBUFFER_SECONDS := 0.20
const STREAM_GENERATOR_BUFFER_SECONDS := 1.0
# Keep provider PCM at unity gain. Per-network-chunk normalization and the
# later +24 dB fixed boost both risk clipping/distortion. Volume belongs to the
# normal mixer/output controls; the TTS transport must preserve Gemini PCM.
const STREAM_OUTPUT_GAIN_DB := 0.0
var _stream_audio_started: Dictionary = {}
var _stream_audio_chunks: Dictionary = {}
var _stream_audio_peak: Dictionary = {}
var _stream_wav_buffers: Dictionary = {}
var _stream_wav_queue: Dictionary = {}
var _stream_wav_finished: Dictionary = {}
var _route_reasons: Dictionary = {}
# Voice Realtime V2 interruption guards. Message/chunk keys cover synthesis that
# was cancelled before a speech id existed; speech ids cover late PCM/completion
# after local playback has already been interrupted.
var _cancelled_chunks: Dictionary = {}
var _cancelled_speech_ids: Dictionary = {}
# Low-overhead Voice Realtime V2 latency telemetry. We retain only timestamps
# and correlation ids; no prompt text, audio bytes, or provider credentials are
# stored. One small record exists per in-flight/prefetched speech and is erased
# on completion/cancellation.
var _voice_latency_requests: Dictionary = {}
var _voice_latency_speech: Dictionary = {}
# Gemini 3.8 Live audio bypasses Kernel's normal TTS request/correlation path
# but reuses the same AudioStreamGenerator playback lifecycle.
var _live_speech_ids: Dictionary = {}


func start() -> void:
	event_bus.subscribe(&"tts.requested", Callable(self, "_on_tts_requested"))
	event_bus.subscribe(&"tts.cancel_requested", Callable(self, "_on_tts_cancel_requested"))
	event_bus.subscribe(&"voice.live_audio_started", Callable(self, "_on_live_audio_started"))
	event_bus.subscribe(&"voice.live_audio_chunk", Callable(self, "_on_live_audio_chunk"))
	event_bus.subscribe(&"voice.live_audio_finished", Callable(self, "_on_live_audio_finished"))
	set_process(true)


func stop() -> void:
	event_bus.unsubscribe(&"tts.requested", Callable(self, "_on_tts_requested"))
	event_bus.unsubscribe(&"tts.cancel_requested", Callable(self, "_on_tts_cancel_requested"))
	event_bus.unsubscribe(&"voice.live_audio_started", Callable(self, "_on_live_audio_started"))
	event_bus.unsubscribe(&"voice.live_audio_chunk", Callable(self, "_on_live_audio_chunk"))
	event_bus.unsubscribe(&"voice.live_audio_finished", Callable(self, "_on_live_audio_finished"))
	# Drop generator playback references before detaching their streams. This is
	# important on WASAPI/Dummy alike: an AudioStreamGeneratorPlayback can remain
	# referenced by the player until `stream` is explicitly cleared.
	_stream_playbacks.clear()
	for player_value in _players.values():
		var player := player_value as AudioStreamPlayer
		if is_instance_valid(player):
			player.stop()
			player.stream = null
			# `stop()` is a shutdown/teardown path, so release the player now instead
			# of leaving AudioStreamGeneratorPlayback alive until the deferred queue.
			player.free()
	_players.clear()
	_stream_pcm_bytes.clear()
	_stream_sample_rates.clear()
	_stream_pending_finish.clear()
	_stream_pending_chunks.clear()
	_stream_audio_started.clear()
	_stream_audio_chunks.clear()
	_stream_audio_peak.clear()
	_stream_wav_buffers.clear()
	_stream_wav_queue.clear()
	_stream_wav_finished.clear()
	_route_reasons.clear()
	_cancelled_chunks.clear()
	_cancelled_speech_ids.clear()
	_voice_latency_requests.clear()
	_voice_latency_speech.clear()
	_live_speech_ids.clear()
	set_process(false)
	_disconnect_bridge()
	_queue.clear()
	_inflight.clear()
	_playback.clear()
	_ready.clear()


func bind_bridge(target: Node) -> void:
	if bridge == target:
		return
	_disconnect_bridge()
	bridge = target
	if not is_instance_valid(bridge):
		return
	if bridge.has_signal("speech_started_v2"):
		bridge.connect("speech_started_v2", Callable(self, "_on_bridge_speech_started_v2"))
	elif bridge.has_signal("speech_started"):
		bridge.connect("speech_started", Callable(self, "_on_bridge_speech_started"))
	if bridge.has_signal("speech_stream_started_v2"):
		bridge.connect("speech_stream_started_v2", Callable(self, "_on_bridge_speech_stream_started_v2"))
	elif bridge.has_signal("speech_stream_started"):
		bridge.connect("speech_stream_started", Callable(self, "_on_bridge_speech_stream_started"))
	if bridge.has_signal("speech_audio_chunk"):
		bridge.connect("speech_audio_chunk", Callable(self, "_on_bridge_speech_audio_chunk"))
	if bridge.has_signal("speech_stream_finished"):
		bridge.connect("speech_stream_finished", Callable(self, "_on_bridge_speech_stream_finished"))
	if bridge.has_signal("speech_requested"):
		bridge.connect("speech_requested", Callable(self, "_on_bridge_speech_requested"))
	if bridge.has_signal("speech_route_diagnostic"):
		bridge.connect("speech_route_diagnostic", Callable(self, "_on_bridge_speech_route_diagnostic"))
	if bridge.has_signal("speech_finished"):
		bridge.connect("speech_finished", Callable(self, "_on_bridge_speech_finished"))
	_pump()


func _disconnect_bridge() -> void:
	if not is_instance_valid(bridge):
		bridge = null
		return
	if bridge.has_signal("speech_started_v2") and bridge.is_connected("speech_started_v2", Callable(self, "_on_bridge_speech_started_v2")):
		bridge.disconnect("speech_started_v2", Callable(self, "_on_bridge_speech_started_v2"))
	if bridge.has_signal("speech_started") and bridge.is_connected("speech_started", Callable(self, "_on_bridge_speech_started")):
		bridge.disconnect("speech_started", Callable(self, "_on_bridge_speech_started"))
	if bridge.has_signal("speech_stream_started_v2") and bridge.is_connected("speech_stream_started_v2", Callable(self, "_on_bridge_speech_stream_started_v2")):
		bridge.disconnect("speech_stream_started_v2", Callable(self, "_on_bridge_speech_stream_started_v2"))
	if bridge.has_signal("speech_stream_started") and bridge.is_connected("speech_stream_started", Callable(self, "_on_bridge_speech_stream_started")):
		bridge.disconnect("speech_stream_started", Callable(self, "_on_bridge_speech_stream_started"))
	if bridge.has_signal("speech_audio_chunk") and bridge.is_connected("speech_audio_chunk", Callable(self, "_on_bridge_speech_audio_chunk")):
		bridge.disconnect("speech_audio_chunk", Callable(self, "_on_bridge_speech_audio_chunk"))
	if bridge.has_signal("speech_stream_finished") and bridge.is_connected("speech_stream_finished", Callable(self, "_on_bridge_speech_stream_finished")):
		bridge.disconnect("speech_stream_finished", Callable(self, "_on_bridge_speech_stream_finished"))
	if bridge.has_signal("speech_requested") and bridge.is_connected("speech_requested", Callable(self, "_on_bridge_speech_requested")):
		bridge.disconnect("speech_requested", Callable(self, "_on_bridge_speech_requested"))
	if bridge.has_signal("speech_route_diagnostic") and bridge.is_connected("speech_route_diagnostic", Callable(self, "_on_bridge_speech_route_diagnostic")):
		bridge.disconnect("speech_route_diagnostic", Callable(self, "_on_bridge_speech_route_diagnostic"))
	if bridge.has_signal("speech_finished") and bridge.is_connected("speech_finished", Callable(self, "_on_bridge_speech_finished")):
		bridge.disconnect("speech_finished", Callable(self, "_on_bridge_speech_finished"))
	bridge = null


func _on_live_audio_started(payload: Dictionary) -> void:
	var speech_id := str(payload.get("speech_id", "")).strip_edges()
	if speech_id.is_empty() or _live_speech_ids.has(speech_id):
		return
	var sample_rate := int(payload.get("sample_rate", 24000))
	if sample_rate != 24000:
		return
	var request := {
		"message_id": str(payload.get("turn_id", speech_id)),
		"chunk_index": 0,
		"final": true,
		"speech_id": speech_id,
		"companion_id": "default",
		"text": "",
		"streaming": true,
		"sample_rate": sample_rate,
		"channels": 1,
		"sample_width": 2,
	}
	_live_speech_ids[speech_id] = true
	_accept_stream_speech_started(request, "default", speech_id, "", sample_rate, 1, 2)


func _on_live_audio_chunk(payload: Dictionary) -> void:
	var speech_id := str(payload.get("speech_id", "")).strip_edges()
	var audio_value: Variant = payload.get("audio", PackedByteArray())
	if speech_id.is_empty() or not _live_speech_ids.has(speech_id) or not (audio_value is PackedByteArray):
		return
	_on_bridge_speech_audio_chunk(speech_id, audio_value as PackedByteArray)


func _on_live_audio_finished(payload: Dictionary) -> void:
	var speech_id := str(payload.get("speech_id", "")).strip_edges()
	if speech_id.is_empty() or not _live_speech_ids.has(speech_id):
		return
	_on_bridge_speech_stream_finished(speech_id, "default", str(payload.get("outcome", "finished")))


func _on_tts_requested(payload: Dictionary) -> void:
	var text := str(payload.get("text", "")).strip_edges()
	if text.is_empty():
		return
	var request := payload.duplicate(true)
	request["text"] = text
	_publish_direct_tts_bubble(request)
	_queue.append(request)
	_pump()


func _tts_chunk_key(message_id: String, chunk_index: int) -> String:
	return "%s:%d" % [message_id, chunk_index]


func _request_matches_cancel(request: Dictionary, message_id: String, speech_id: String) -> bool:
	if not speech_id.is_empty() and str(request.get("speech_id", "")) == speech_id:
		return true
	return not message_id.is_empty() and str(request.get("message_id", "")) == message_id


func _publish_interrupted(request: Dictionary, reason: String) -> void:
	event_bus.publish(&"tts.interrupted", {
		"message_id": str(request.get("message_id", "")),
		"chunk_index": int(request.get("chunk_index", 0)),
		"final": bool(request.get("final", false)),
		"speech_id": str(request.get("speech_id", "")),
		"companion_id": str(request.get("companion_id", "default")),
		"outcome": "interrupted",
		"reason": reason,
	})


func _cleanup_speech_state(speech_id: String) -> void:
	if speech_id.is_empty():
		return
	var player := _players.get(speech_id) as AudioStreamPlayer
	_players.erase(speech_id)
	if is_instance_valid(player):
		player.stop()
		player.stream = null
		player.queue_free()
	_stream_playbacks.erase(speech_id)
	_stream_pcm_bytes.erase(speech_id)
	_stream_sample_rates.erase(speech_id)
	_stream_pending_finish.erase(speech_id)
	_stream_pending_chunks.erase(speech_id)
	_stream_audio_started.erase(speech_id)
	_stream_audio_chunks.erase(speech_id)
	_stream_audio_peak.erase(speech_id)
	_stream_wav_buffers.erase(speech_id)
	_stream_wav_queue.erase(speech_id)
	_stream_wav_finished.erase(speech_id)
	_stream_wav_finished.erase(speech_id + ":companion")
	_stream_wav_finished.erase(speech_id + ":outcome")
	_route_reasons.erase(speech_id)
	_voice_latency_speech.erase(speech_id)


func _advance_playback_after_cancel() -> void:
	if not _playback.is_empty() or _ready.is_empty():
		return
	_playback = _ready.pop_front()
	if bool(_playback.get("streaming", false)):
		_start_stream_playback(_playback)
	elif not str(_playback.get("audio_path", "")).is_empty():
		_start_playback(_playback)


func _on_tts_cancel_requested(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", "")).strip_edges()
	var speech_id := str(payload.get("speech_id", "")).strip_edges()
	if message_id.is_empty() and speech_id.is_empty():
		return
	var reason := str(payload.get("reason", "user-interrupt")).strip_edges()
	if reason.is_empty():
		reason = "user-interrupt"

	var kept_queue: Array[Dictionary] = []
	for request in _queue:
		if _request_matches_cancel(request, message_id, speech_id):
			_publish_interrupted(request, reason)
		else:
			kept_queue.append(request)
	_queue = kept_queue

	if not _inflight.is_empty() and _request_matches_cancel(_inflight, message_id, speech_id):
		var cancelled := _inflight.duplicate(true)
		var cancelled_key := _tts_chunk_key(str(cancelled.get("message_id", "")), int(cancelled.get("chunk_index", 0)))
		_cancelled_chunks[cancelled_key] = true
		_voice_latency_requests.erase(cancelled_key)
		_inflight.clear()
		_publish_interrupted(cancelled, reason)

	var kept_ready: Array[Dictionary] = []
	for request in _ready:
		if _request_matches_cancel(request, message_id, speech_id):
			var ready_speech_id := str(request.get("speech_id", ""))
			if not ready_speech_id.is_empty():
				var ready_was_live := _live_speech_ids.has(ready_speech_id)
				if not ready_was_live:
					_cancelled_speech_ids[ready_speech_id] = true
				_live_speech_ids.erase(ready_speech_id)
				_cleanup_speech_state(ready_speech_id)
			_publish_interrupted(request, reason)
		else:
			kept_ready.append(request)
	_ready = kept_ready

	if not _playback.is_empty() and _request_matches_cancel(_playback, message_id, speech_id):
		var active := _playback.duplicate(true)
		var active_speech_id := str(active.get("speech_id", ""))
		if not active_speech_id.is_empty():
			var active_was_live := _live_speech_ids.has(active_speech_id)
			if not active_was_live:
				_cancelled_speech_ids[active_speech_id] = true
			_live_speech_ids.erase(active_speech_id)
			_cleanup_speech_state(active_speech_id)
		_playback.clear()
		_publish_interrupted(active, reason)
		_advance_playback_after_cancel()

	_pump()


func _publish_direct_tts_bubble(request: Dictionary) -> void:
	# ChatSessionOrchestrator owns Chat bubbles, including rolling stream
	# updates. Direct callers such as Electron Voice Test used to bypass that
	# path, leaving speech with no visible text. Publish one bounded bubble for
	# those callers without duplicating the Chat-owned lifecycle.
	var source := str(request.get("source", ""))
	if source.begins_with("chat-session") or source == "ai-voice-test":
		return
	event_bus.publish(&"bubble.requested", {
		"message_id": str(request.get("message_id", "")),
		"text": str(request.get("text", "")),
		"duration": 8.0,
		"durationMs": 8000,
		"streaming": false,
		"source": "tts-service-direct",
	})


func _resolve_voice_setting(request: Dictionary) -> String:
	var explicit_voice := str(request.get("voice", "")).strip_edges()
	if not explicit_voice.is_empty() and explicit_voice.to_lower() != "auto":
		return explicit_voice

	var voice_mode := "character"
	if is_instance_valid(context):
		voice_mode = str(context.settings.get("tts_voice_mode", "character")).strip_edges().to_lower()
	if voice_mode == "character":
		# Character/3 voice metadata owns automatic character speech. Ignore stale
		# provider-specific personas saved by older builds while this mode is active.
		var profile: Dictionary = context.character.get("voice_profile", {}) if is_instance_valid(context) else {}
		var gender := str(profile.get("gender", profile.get("presentation", "neutral"))).strip_edges().to_lower()
		if gender not in ["female", "male", "neutral"]:
			gender = "neutral"
		return _profile_token({"gender": gender, "age": profile.get("age", "adult")})

	var configured_voice := "auto"
	if is_instance_valid(context):
		configured_voice = str(context.settings.get("tts_voice", "auto")).strip_edges()
	if not configured_voice.is_empty() and configured_voice.to_lower() != "auto":
		return configured_voice
	return _profile_token({
		"gender": context.settings.get("tts_voice_gender", "neutral") if is_instance_valid(context) else "neutral",
		"age": context.settings.get("tts_voice_age", "adult") if is_instance_valid(context) else "adult",
	})


func _profile_token(profile: Dictionary) -> String:
	var gender := str(profile.get("gender", "neutral")).strip_edges().to_lower()
	var age := str(profile.get("age", "adult")).strip_edges().to_lower()
	if gender not in ["female", "male", "neutral"]:
		gender = "neutral"
	if age not in ["child", "adult"]:
		age = "adult"
	return "profile:%s:%s" % [gender, age]


func _resolve_delivery_mode(request: Dictionary) -> String:
	var requested := str(request.get("delivery_mode", "")).strip_edges().to_lower()
	if requested in ["quality", "whole", "whole-clip", "wav"]:
		return "quality"
	if requested in ["streaming", "realtime", "low-latency"]:
		return "streaming"
	if is_instance_valid(context):
		var configured := str(context.settings.get("tts_delivery_mode", "streaming")).strip_edges().to_lower()
		if configured in ["quality", "whole", "whole-clip", "wav"]:
			return "quality"
	# Voice Realtime V2 defaults to stream-first. The bridge/kernel still falls
	# back to the existing whole-clip router when streaming cannot start.
	return "streaming"


func _voice_latency_register_speech(message_id: String, chunk_index: int, speech_id: String, delivery_mode: String, milestone: String) -> void:
	if speech_id.is_empty():
		return
	var key := _tts_chunk_key(message_id, chunk_index)
	var request_value: Variant = _voice_latency_requests.get(key, {})
	if not (request_value is Dictionary):
		return
	var record: Dictionary = (request_value as Dictionary).duplicate(true)
	if record.is_empty():
		return
	_voice_latency_requests.erase(key)
	record["speech_id"] = speech_id
	record["delivery_mode"] = delivery_mode
	var now := Time.get_ticks_msec()
	if milestone == "stream-start":
		record["stream_started_ms"] = now
	else:
		record["synthesis_ready_ms"] = now
	_voice_latency_speech[speech_id] = record
	_voice_latency_publish(speech_id, milestone)


func _voice_latency_mark(speech_id: String, milestone: String) -> void:
	var value: Variant = _voice_latency_speech.get(speech_id, {})
	if not (value is Dictionary):
		return
	var record: Dictionary = value
	var field := ""
	match milestone:
		"first-pcm": field = "first_pcm_ms"
		"audio-start": field = "audio_started_ms"
		"finished": field = "finished_ms"
		"interrupted": field = "finished_ms"
		_: return
	if record.has(field):
		return
	record[field] = Time.get_ticks_msec()
	_voice_latency_speech[speech_id] = record
	_voice_latency_publish(speech_id, milestone)
	if milestone in ["finished", "interrupted"]:
		_voice_latency_speech.erase(speech_id)


func _voice_latency_publish(speech_id: String, milestone: String) -> void:
	if event_bus == null:
		return
	var value: Variant = _voice_latency_speech.get(speech_id, {})
	if not (value is Dictionary):
		return
	var record: Dictionary = value
	var requested_ms := int(record.get("requested_ms", 0))
	if requested_ms <= 0:
		return
	var elapsed := func(field: String) -> float:
		var tick := int(record.get(field, 0))
		return float(maxi(0, tick - requested_ms)) if tick > 0 else 0.0
	event_bus.publish(&"tts.latency_measured", {
		"messageId": str(record.get("message_id", "")),
		"chunkIndex": int(record.get("chunk_index", 0)),
		"speechId": speech_id,
		"deliveryMode": str(record.get("delivery_mode", "")),
		"milestone": milestone,
		"requestToStreamStartMs": elapsed.call("stream_started_ms"),
		"requestToSynthesisReadyMs": elapsed.call("synthesis_ready_ms"),
		"requestToFirstPcmMs": elapsed.call("first_pcm_ms"),
		"requestToAudioStartMs": elapsed.call("audio_started_ms"),
		"totalMs": elapsed.call("finished_ms"),
	})


func _pump() -> void:
	# Keep one synthesis request in flight. As soon as it becomes a playable
	# clip, `_on_bridge_speech_started` calls `_pump()` again, so generation of
	# the next sentence overlaps the current audio playback.
	if not _inflight.is_empty() or _queue.is_empty():
		return
	if not is_instance_valid(bridge) or not bridge.has_method("request_tts"):
		_fail_next("Runtime speech bridge is unavailable")
		return

	_inflight = _queue.pop_front()
	var delivery_mode := _resolve_delivery_mode(_inflight)
	var latency_key := _tts_chunk_key(str(_inflight.get("message_id", "")), int(_inflight.get("chunk_index", 0)))
	_voice_latency_requests[latency_key] = {
		"requested_ms": Time.get_ticks_msec(),
		"delivery_mode": delivery_mode,
		"message_id": str(_inflight.get("message_id", "")),
		"chunk_index": int(_inflight.get("chunk_index", 0)),
	}
	var request_method := "request_tts"
	if delivery_mode == "streaming" and bridge.has_method("request_tts_streaming"):
		request_method = "request_tts_streaming"
	var accepted := bool(bridge.call(
		request_method,
		str(_inflight.get("message_id", "")),
		int(_inflight.get("chunk_index", 0)),
		str(_inflight.get("text", "")),
		_resolve_voice_setting(_inflight),
		str(_inflight.get("provider_id", context.settings.get("tts_provider_id", "auto") if is_instance_valid(context) else "auto")),
		str(_inflight.get("model_id", context.settings.get("tts_model", "gemini-3.1-flash-tts-preview") if is_instance_valid(context) else "gemini-3.1-flash-tts-preview")),
		bool(_inflight.get("final", false))
	))
	_inflight["delivery_mode"] = delivery_mode
	_inflight["bridge_method"] = request_method
	if not accepted:
		var failed := _inflight.duplicate(true)
		_voice_latency_requests.erase(latency_key)
		_inflight.clear()
		event_bus.publish(&"tts.failed", {
			"message_id": str(failed.get("message_id", "")),
			"chunk_index": int(failed.get("chunk_index", 0)),
			"final": bool(failed.get("final", false)),
			"error": "Kernel TTS request was not accepted",
		})
		call_deferred("_pump")


func _fail_next(error_text: String) -> void:
	if _queue.is_empty():
		return
	var failed: Dictionary = _queue.pop_front() as Dictionary
	event_bus.publish(&"tts.failed", {
		"message_id": str(failed.get("message_id", "")),
		"chunk_index": int(failed.get("chunk_index", 0)),
		"final": bool(failed.get("final", false)),
		"error": error_text,
	})


func _on_bridge_speech_started_v2(companion_id: String, speech_id: String, message_id: String, chunk_index: int, final_chunk: bool, text: String) -> void:
	var cancel_key := _tts_chunk_key(message_id, chunk_index)
	if _cancelled_chunks.has(cancel_key):
		_cancelled_chunks.erase(cancel_key)
		_cancelled_speech_ids[speech_id] = true
		return
	_voice_latency_register_speech(message_id, chunk_index, speech_id, "quality", "synthesis-ready")
	if _inflight.is_empty():
		return
	if str(_inflight.get("message_id", "")) != message_id or int(_inflight.get("chunk_index", -1)) != chunk_index:
		return
	var request := _inflight.duplicate(true)
	_inflight.clear()
	request["final"] = final_chunk
	_accept_whole_speech_started(request, companion_id, speech_id, text)


func _on_bridge_speech_started(companion_id: String, speech_id: String, text: String) -> void:
	if _inflight.is_empty():
		return
	# Legacy bridge correlation matched by display-safe text. Voice Realtime V2
	# uses speech_started_v2 above and retains this only for older bridge builds.
	if text.strip_edges() != str(_inflight.get("text", "")).strip_edges():
		return
	var request := _inflight.duplicate(true)
	_inflight.clear()
	_accept_whole_speech_started(request, companion_id, speech_id, text)


func _accept_whole_speech_started(request: Dictionary, companion_id: String, speech_id: String, text: String) -> void:
	request["speech_id"] = speech_id
	request["companion_id"] = companion_id
	request["text"] = text
	request["audio_path"] = ""
	if _playback.is_empty():
		_playback = request
	else:
		_ready.append(request)
	# The current chunk has finished synthesis. Start synthesizing the next chunk
	# immediately; playback remains strictly serialized by `_playback`.
	_pump()


func _on_bridge_speech_stream_started_v2(companion_id: String, speech_id: String, message_id: String, chunk_index: int, final_chunk: bool, text: String, sample_rate: int, channels: int, sample_width: int) -> void:
	var cancel_key := _tts_chunk_key(message_id, chunk_index)
	if _cancelled_chunks.has(cancel_key):
		_cancelled_chunks.erase(cancel_key)
		_cancelled_speech_ids[speech_id] = true
		return
	_voice_latency_register_speech(message_id, chunk_index, speech_id, "streaming", "stream-start")
	var request: Dictionary = {}
	if not _inflight.is_empty() \
		and str(_inflight.get("message_id", "")) == message_id \
		and int(_inflight.get("chunk_index", -1)) == chunk_index:
		request = _inflight.duplicate(true)
		_inflight.clear()
		request["final"] = final_chunk
		_pump()
	elif not _playback.is_empty() and str(_playback.get("speech_id", "")) == speech_id:
		request = _playback.duplicate(true)
	else:
		return
	_accept_stream_speech_started(request, companion_id, speech_id, text, sample_rate, channels, sample_width)


func _on_bridge_speech_stream_started(companion_id: String, speech_id: String, text: String, sample_rate: int, channels: int, sample_width: int) -> void:
	# Legacy bridge fallback: correlate by text only. V2 uses message/chunk ids.
	var request: Dictionary = {}
	if not _inflight.is_empty() and text.strip_edges() == str(_inflight.get("text", "")).strip_edges():
		request = _inflight.duplicate(true)
		_inflight.clear()
		_pump()
	elif not _playback.is_empty() and str(_playback.get("speech_id", "")) == speech_id:
		request = _playback.duplicate(true)
	else:
		return
	_accept_stream_speech_started(request, companion_id, speech_id, text, sample_rate, channels, sample_width)


func _accept_stream_speech_started(request: Dictionary, companion_id: String, speech_id: String, text: String, sample_rate: int, channels: int, sample_width: int) -> void:
	request["speech_id"] = speech_id
	request["companion_id"] = companion_id
	request["text"] = text
	request["streaming"] = true
	request["sample_rate"] = sample_rate
	request["channels"] = channels
	request["sample_width"] = sample_width

	# Streaming synthesis may finish before the previous sentence has finished
	# playing. Never replace the active playback slot: queue the new stream and
	# start it only when the current stream reports completion.
	if _playback.is_empty():
		_playback = request
		_start_stream_playback(_playback)
	else:
		_ready.append(request)


func _start_stream_playback(request: Dictionary) -> void:
	# Continuous generator playback avoids a main-thread player handoff every
	# 160 ms. Those tiny WAV joins were audible as stutter even when Gemini had
	# already buffered many chunks. Keep the WAV backend below as a compatibility
	# fallback, but use one generator for the complete speech in production.
	_start_stream_generator_playback(request)


func _start_stream_wav_playback(request: Dictionary) -> void:
	var speech_id := str(request.get("speech_id", ""))
	if speech_id.is_empty():
		return
	_stream_wav_buffers[speech_id] = PackedByteArray()
	_stream_wav_queue[speech_id] = []
	_stream_wav_finished[speech_id] = false
	_stream_audio_started[speech_id] = false
	_stream_audio_chunks[speech_id] = 0
	_stream_audio_peak[speech_id] = 0.0
	event_bus.publish(&"tts.started", {
		"message_id": str(request.get("message_id", "")),
		"chunk_index": int(request.get("chunk_index", 0)),
		"final": bool(request.get("final", false)),
		"speech_id": speech_id,
		"companion_id": str(request.get("companion_id", "default")),
		"text": str(request.get("text", "")),
	})
	print("[TTS-STREAM] backend=wav-segments speech=", speech_id, " segment_ms=", STREAM_SEGMENT_MS, " driver=", AudioServer.get_driver_name())


func _start_stream_generator_playback(request: Dictionary) -> void:
	var speech_id := str(request.get("speech_id", ""))
	if speech_id.is_empty() or _stream_playbacks.has(speech_id):
		return
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = float(request.get("sample_rate", 24000))
	# Keep enough PCM headroom for Windows/WASAPI scheduling jitter. We still
	# start after a small prebuffer, so this does not add a full-second latency.
	generator.buffer_length = STREAM_GENERATOR_BUFFER_SECONDS
	var player := AudioStreamPlayer.new()
	player.name = "TTSSpeechStream_%s" % speech_id.replace("-", "_")
	player.bus = "Master"
	player.volume_db = STREAM_OUTPUT_GAIN_DB
	add_child(player)
	player.stream = generator
	player.play()
	# Prime the generator while paused. This avoids an immediate empty-buffer
	# underrun before the first 40 ms Gemini PCM delta reaches the main thread.
	player.stream_paused = true
	var playback := player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		player.stop()
		player.queue_free()
		return
	_players[speech_id] = player
	_stream_playbacks[speech_id] = playback
	_stream_pcm_bytes[speech_id] = 0
	_stream_sample_rates[speech_id] = int(request.get("sample_rate", 24000))
	_stream_audio_started[speech_id] = false
	_stream_audio_chunks[speech_id] = 0
	_stream_audio_peak[speech_id] = 0.0
	_flush_stream_pending_chunks(speech_id)
	# If the provider finished while this speech was queued behind another one,
	# let `_process()` compute the remaining audible buffer after all prefetched
	# PCM has been drained into the generator. Using total synthesized duration
	# here would add a second copy of playback time and create a pause between
	# sentence chunks.
	event_bus.publish(&"tts.started", {
		"message_id": str(request.get("message_id", "")),
		"chunk_index": int(request.get("chunk_index", 0)),
		"final": bool(request.get("final", false)),
		"speech_id": speech_id,
		"companion_id": str(request.get("companion_id", "default")),
		"text": str(request.get("text", "")),
	})
	print("[TTS-STREAM] speech=", speech_id, " driver=", AudioServer.get_driver_name(), " rate=", generator.mix_rate)


func _on_bridge_speech_audio_chunk(speech_id: String, audio: PackedByteArray) -> void:
	if _cancelled_speech_ids.has(speech_id):
		return
	_voice_latency_mark(speech_id, "first-pcm")
	# Continuous generator playback is primary. Keep recognizing the legacy WAV
	# buffer as well so an older/fallback playback object can still consume its
	# deltas. Retain chunks only before either backend has been initialized.
	if not _stream_playbacks.has(speech_id) and not _stream_wav_buffers.has(speech_id):
		if not _stream_pending_chunks.has(speech_id):
			_stream_pending_chunks[speech_id] = []
		(_stream_pending_chunks[speech_id] as Array).append(audio)
		return
	_push_stream_audio(speech_id, audio)


func _push_stream_audio(speech_id: String, audio: PackedByteArray) -> void:
	_push_stream_generator_audio(speech_id, audio)


func _push_stream_wav_audio(speech_id: String, audio: PackedByteArray) -> void:
	if audio.is_empty():
		return
	if not _stream_wav_buffers.has(speech_id):
		_stream_wav_buffers[speech_id] = PackedByteArray()
	if audio.size() % 2 != 0:
		audio = audio.slice(0, audio.size() - 1)
	if audio.is_empty():
		return
	var normalization := normalize_stream_pcm_for_playback(audio)
	var normalized_audio: Variant = normalization.get("audio", audio)
	if normalized_audio is PackedByteArray:
		audio = normalized_audio
	var peak := float(normalization.get("output_peak", 0.0))
	var source_peak := float(normalization.get("source_peak", peak))
	var gain := float(normalization.get("gain", 1.0))
	_stream_audio_chunks[speech_id] = int(_stream_audio_chunks.get(speech_id, 0)) + 1
	_stream_audio_peak[speech_id] = maxf(float(_stream_audio_peak.get(speech_id, 0.0)), peak)
	var buffer: PackedByteArray = _stream_wav_buffers[speech_id]
	buffer.append_array(audio)
	_stream_wav_buffers[speech_id] = buffer
	var target_bytes := int(round(24000.0 * 2.0 * float(STREAM_SEGMENT_MS) / 1000.0))
	while int((_stream_wav_buffers[speech_id] as PackedByteArray).size()) >= target_bytes:
		var current: PackedByteArray = _stream_wav_buffers[speech_id]
		var segment := current.slice(0, target_bytes)
		_stream_wav_buffers[speech_id] = current.slice(target_bytes)
		(_stream_wav_queue[speech_id] as Array).append(segment)
		_start_next_stream_wav_segment(speech_id)
	if int(_stream_audio_chunks.get(speech_id, 0)) <= 2:
		print("[TTS-STREAM] pcm speech=", speech_id, " bytes=", audio.size(), " source_peak=", source_peak, " gain=", gain, " output_peak=", peak, " queued_segments=", (_stream_wav_queue[speech_id] as Array).size())


func normalize_stream_pcm_for_playback(audio: PackedByteArray) -> Dictionary:
	# Compatibility helper retained for tests/callers, but deliberately does not
	# alter Gemini PCM anymore. Gain belongs to the continuous AudioStreamPlayer,
	# not to independently-sized network chunks.
	if audio.size() < 2:
		return {"audio": audio, "source_peak": 0.0, "output_peak": 0.0, "gain": 1.0}
	var usable_bytes := audio.size() - (audio.size() % 2)
	var source_peak := 0.0
	for index in range(usable_bytes / 2):
		source_peak = maxf(source_peak, absf(float(audio.decode_s16(index * 2)) / 32768.0))
	return {"audio": audio, "source_peak": source_peak, "output_peak": source_peak, "gain": 1.0}


func _start_next_stream_wav_segment(speech_id: String) -> void:
	if not _players.has(speech_id):
		var queue: Array = _stream_wav_queue.get(speech_id, [])
		if queue.is_empty():
			return
		var pcm: PackedByteArray = queue.pop_front()
		_stream_wav_queue[speech_id] = queue
		var stream := AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate = 24000
		stream.stereo = false
		stream.data = pcm
		var player := AudioStreamPlayer.new()
		player.name = "TTSSpeechStreamWav_%s" % speech_id.replace("-", "_")
		player.bus = "Master"
		player.volume_db = STREAM_OUTPUT_GAIN_DB
		add_child(player)
		player.stream = stream
		_players[speech_id] = player
		player.finished.connect(Callable(self, "_on_stream_wav_segment_finished").bind(speech_id))
		player.play()
		_stream_audio_started[speech_id] = true
		print("[TTS-STREAM] segment-start speech=", speech_id, " length=", stream.get_length(), " playing=", player.playing, " remaining=", queue.size())


func _on_stream_wav_segment_finished(speech_id: String) -> void:
	var player := _players.get(speech_id) as AudioStreamPlayer
	_players.erase(speech_id)
	if is_instance_valid(player):
		player.queue_free()
	_start_next_stream_wav_segment(speech_id)
	var buffer: PackedByteArray = _stream_wav_buffers.get(speech_id, PackedByteArray())
	var queue: Array = _stream_wav_queue.get(speech_id, [])
	if bool(_stream_wav_finished.get(speech_id, false)) and buffer.is_empty() and queue.is_empty() and not _players.has(speech_id):
		var companion_id := str(_stream_wav_finished.get(speech_id + ":companion", "default"))
		var outcome := str(_stream_wav_finished.get(speech_id + ":outcome", "finished"))
		_stream_wav_finished.erase(speech_id)
		_stream_wav_finished.erase(speech_id + ":companion")
		_stream_wav_finished.erase(speech_id + ":outcome")
		_stream_wav_buffers.erase(speech_id)
		_stream_wav_queue.erase(speech_id)
		_stream_audio_started.erase(speech_id)
		_stream_audio_chunks.erase(speech_id)
		_stream_audio_peak.erase(speech_id)
		_report_speech_finished(speech_id, companion_id, outcome)


func _push_stream_generator_audio(speech_id: String, audio: PackedByteArray) -> void:
	if audio.is_empty():
		return
	var playback := _stream_playbacks.get(speech_id) as AudioStreamGeneratorPlayback
	if playback == null:
		if not _stream_pending_chunks.has(speech_id):
			_stream_pending_chunks[speech_id] = []
		(_stream_pending_chunks[speech_id] as Array).append(audio)
		return

	# Gemini TTS streaming is signed 16-bit little-endian mono PCM at 24 kHz.
	# Never drop a chunk when the generator races with the audio mixer: even if
	# `push_buffer()` rejects a frame block after `get_frames_available()` said it
	# was writable, retain the entire block and retry on the next process tick.
	# The previous implementation could lose a whole chunk on that race, which
	# presents exactly as "streaming is fast, but there is no sound".
	if audio.size() < 2:
		return
	if audio.size() % 2 != 0:
		push_warning("[TTS-STREAM] odd PCM byte count=%d speech=%s; dropping final byte" % [audio.size(), speech_id])
		audio = audio.slice(0, audio.size() - 1)
	var normalization := normalize_stream_pcm_for_playback(audio)
	var normalized_audio: Variant = normalization.get("audio", audio)
	if normalized_audio is PackedByteArray:
		audio = normalized_audio
	var source_peak := float(normalization.get("source_peak", 0.0))
	var applied_gain := float(normalization.get("gain", 1.0))
	var frame_count := audio.size() / 2
	if frame_count <= 0:
		return
	var available := playback.get_frames_available()
	if available <= 0:
		if not _stream_pending_chunks.has(speech_id):
			_stream_pending_chunks[speech_id] = []
		(_stream_pending_chunks[speech_id] as Array).append(audio)
		return

	var frames_to_push: int = min(frame_count, available)
	var frames := PackedVector2Array()
	frames.resize(frames_to_push)
	var peak := 0.0
	for index in range(frames_to_push):
		var sample: int = audio.decode_s16(index * 2)
		var value: float = float(sample) / 32768.0
		peak = maxf(peak, absf(value))
		frames[index] = Vector2(value, value)

	if not playback.push_buffer(frames):
		# The mixer may have consumed/reconfigured the available space between
		# `get_frames_available()` and `push_buffer()`. Preserve all audio rather
		# than silently discarding it.
		if not _stream_pending_chunks.has(speech_id):
			_stream_pending_chunks[speech_id] = []
		(_stream_pending_chunks[speech_id] as Array).push_front(audio)
		return

	_stream_pcm_bytes[speech_id] = int(_stream_pcm_bytes.get(speech_id, 0)) + frames.size() * 2
	_stream_audio_chunks[speech_id] = int(_stream_audio_chunks.get(speech_id, 0)) + 1
	_stream_audio_peak[speech_id] = maxf(float(_stream_audio_peak.get(speech_id, 0.0)), peak)
	if int(_stream_audio_chunks[speech_id]) <= 2:
		print("[TTS-STREAM] pcm speech=", speech_id, " bytes=", audio.size(), " pushed_frames=", frames.size(), " source_peak=", source_peak, " gain=", applied_gain, " output_peak=", peak, " available=", playback.get_frames_available())
	_maybe_start_stream_audio(speech_id)
	if frames_to_push < frame_count:
		var remaining := PackedByteArray()
		remaining.resize((frame_count - frames_to_push) * 2)
		for index in range(frames_to_push, frame_count):
			remaining[(index - frames_to_push) * 2] = audio[index * 2]
			remaining[(index - frames_to_push) * 2 + 1] = audio[index * 2 + 1]
		if not _stream_pending_chunks.has(speech_id):
			_stream_pending_chunks[speech_id] = []
		(_stream_pending_chunks[speech_id] as Array).push_front(remaining)


func _maybe_start_stream_audio(speech_id: String) -> void:
	if bool(_stream_audio_started.get(speech_id, false)):
		return
	var player := _players.get(speech_id) as AudioStreamPlayer
	if not is_instance_valid(player):
		return
	# Keep a modest continuous PCM cushion before unpausing WASAPI. The previous
	# 80 ms threshold was vulnerable to normal cloud jitter; 200 ms is still
	# interactive but substantially reduces generator underruns.
	var rate: int = max(1, int(_stream_sample_rates.get(speech_id, 24000)))
	var prebuffer_bytes := int(float(rate) * 2.0 * STREAM_GENERATOR_PREBUFFER_SECONDS)
	if int(_stream_pcm_bytes.get(speech_id, 0)) < prebuffer_bytes:
		return
	player.stream_paused = false
	_stream_audio_started[speech_id] = true
	_voice_latency_mark(speech_id, "audio-start")
	var master_bus := AudioServer.get_bus_index("Master")
	var master_muted := master_bus >= 0 and AudioServer.is_bus_mute(master_bus)
	var master_db := AudioServer.get_bus_volume_db(master_bus) if master_bus >= 0 else 0.0
	print("[TTS-STREAM] audio-start speech=", speech_id, " buffered_ms=", int(float(_stream_pcm_bytes.get(speech_id, 0)) / 2.0 / float(rate) * 1000.0), " playing=", player.playing, " paused=", player.stream_paused, " bus=Master mute=", master_muted, " db=", master_db, " chunks=", _stream_audio_chunks.get(speech_id, 0), " peak=", _stream_audio_peak.get(speech_id, 0.0))


func _flush_stream_pending_chunks(speech_id: String) -> void:
	var pending: Array = _stream_pending_chunks.get(speech_id, [])
	_stream_pending_chunks.erase(speech_id)
	for audio in pending:
		_push_stream_audio(speech_id, audio as PackedByteArray)


func _on_bridge_speech_stream_finished(speech_id: String, companion_id: String, outcome: String) -> void:
	if _cancelled_speech_ids.has(speech_id):
		_cleanup_speech_state(speech_id)
		_cancelled_speech_ids.erase(speech_id)
		return
	if _stream_wav_buffers.has(speech_id):
		var tail: PackedByteArray = _stream_wav_buffers.get(speech_id, PackedByteArray())
		if not tail.is_empty():
			if tail.size() % 2 != 0:
				tail = tail.slice(0, tail.size() - 1)
			if not tail.is_empty():
				(_stream_wav_queue[speech_id] as Array).append(tail)
			_stream_wav_buffers[speech_id] = PackedByteArray()
		_stream_wav_finished[speech_id] = true
		_stream_wav_finished[speech_id + ":companion"] = companion_id
		_stream_wav_finished[speech_id + ":outcome"] = outcome
		_start_next_stream_wav_segment(speech_id)
		# A reply shorter than one segment can finish before a player is created.
		if not _players.has(speech_id) and (_stream_wav_queue.get(speech_id, []) as Array).is_empty():
			_stream_wav_finished.erase(speech_id)
			_stream_wav_finished.erase(speech_id + ":companion")
			_stream_wav_finished.erase(speech_id + ":outcome")
			_stream_wav_buffers.erase(speech_id)
			_stream_wav_queue.erase(speech_id)
			_stream_audio_started.erase(speech_id)
			_stream_audio_chunks.erase(speech_id)
			_stream_audio_peak.erase(speech_id)
			_report_speech_finished(speech_id, companion_id, outcome)
		return
	# Continuous AudioStreamGenerator is the production path. Very short replies
	# can finish before the normal prebuffer threshold; release the paused player
	# here so the buffered tail is still audible instead of being discarded.
	if not bool(_stream_audio_started.get(speech_id, false)):
		var player := _players.get(speech_id) as AudioStreamPlayer
		if is_instance_valid(player) and int(_stream_pcm_bytes.get(speech_id, 0)) > 0:
			player.stream_paused = false
			_stream_audio_started[speech_id] = true
	# The stream may finish while this chunk is still prefetched behind another
	# speech. Keep the completion fact until its generator becomes the active
	# playback slot.
	# Do not compute the finish deadline until every network delta has been
	# pushed into the generator. Otherwise a full generator buffer would make us
	# report completion while queued PCM is still waiting to play.
	_stream_pending_finish[speech_id] = {
		"companion_id": companion_id,
		"outcome": outcome,
	}


func _process(_delta: float) -> void:
	# Drain queued PCM as the generator buffer opens up. This prevents a fast SSE
	# stream from dropping audio when a network delta is larger than the current
	# generator capacity.
	for speech_id in _stream_pending_chunks.keys():
		_flush_stream_pending_chunks(str(speech_id))

	if _stream_pending_finish.is_empty():
		return
	var now := Time.get_ticks_msec()
	for speech_id in _stream_pending_finish.keys():
		var pending: Dictionary = _stream_pending_finish[speech_id]
		if _stream_pending_chunks.has(speech_id) and not (_stream_pending_chunks[speech_id] as Array).is_empty():
			continue
		if not pending.has("deadline_ms"):
			var rate: int = max(1, int(_stream_sample_rates.get(speech_id, 24000)))
			var playback := _stream_playbacks.get(speech_id) as AudioStreamGeneratorPlayback
			var remaining_ms := 0
			if playback != null:
				var capacity_frames := int(float(rate) * STREAM_GENERATOR_BUFFER_SECONDS)
				var queued_frames := maxi(0, capacity_frames - playback.get_frames_available())
				remaining_ms = int(float(queued_frames) / float(rate) * 1000.0)
			else:
				var bytes: int = int(_stream_pcm_bytes.get(speech_id, 0))
				remaining_ms = int(float(bytes) / 2.0 / float(rate) * 1000.0)
			pending["deadline_ms"] = now + remaining_ms + 120
			_stream_pending_finish[speech_id] = pending
			continue
		if now < int(pending.get("deadline_ms", now)):
			continue
		_stream_pending_finish.erase(speech_id)
		var companion_id: String = str(pending.get("companion_id", "default"))
		var outcome: String = str(pending.get("outcome", "finished"))
		var player := _players.get(speech_id) as AudioStreamPlayer
		_players.erase(speech_id)
		_stream_playbacks.erase(speech_id)
		_stream_pcm_bytes.erase(speech_id)
		_stream_sample_rates.erase(speech_id)
		_stream_pending_chunks.erase(speech_id)
		_stream_audio_started.erase(speech_id)
		_stream_audio_chunks.erase(speech_id)
		_stream_audio_peak.erase(speech_id)
		if is_instance_valid(player):
			player.stop()
			player.queue_free()
		_report_speech_finished(speech_id, companion_id, outcome)
		if not _playback.is_empty() and str(_playback.get("speech_id", "")) == speech_id:
			_playback.clear()
			if not _ready.is_empty():
				_playback = _ready.pop_front()
				if bool(_playback.get("streaming", false)):
					_start_stream_playback(_playback)
				else:
					_start_playback(_playback)


func _on_bridge_speech_requested(companion_id: String, speech_id: String, text: String, subtitle: bool, audio_path: String) -> void:
	if _cancelled_speech_ids.has(speech_id):
		return
	# `speech_started` arrives before `speech_requested`; attach the resulting
	# file to either the currently playable chunk or the prefetched ready queue.
	var target: Dictionary = {}
	var target_index := -1
	if not _playback.is_empty() and str(_playback.get("speech_id", "")) == speech_id:
		target = _playback
	else:
		for index in range(_ready.size()):
			if str(_ready[index].get("speech_id", "")) == speech_id:
				target_index = index
				target = _ready[index]
				break
	if target.is_empty():
		# Whole-clip synthesis can legitimately complete before the separate
		# `speech_started` signal is observed by this service. Recover directly
		# from the serialized in-flight request so a valid `speech_requested`
		# carrying `audio_path` can never be dropped silently.
		var inflight_text := str(_inflight.get("text", "")).strip_edges()
		if not _inflight.is_empty() and text.strip_edges() == inflight_text:
			target = _inflight.duplicate(true)
			_inflight.clear()
			target["speech_id"] = speech_id
			target["companion_id"] = companion_id
			target["text"] = text
			target["audio_path"] = ""
			if _playback.is_empty():
				_playback = target
			else:
				target_index = _ready.size()
				_ready.append(target)
			print("[TTS-PLAYBACK] recovered whole-clip speech without prior speech_started speech=", speech_id)
			_pump()
		else:
			# `speech_requested` is the authoritative whole-clip delivery signal from
			# the trusted Runtime bridge. Even when lifecycle correlation was lost,
			# preserve playback instead of discarding a valid synthesized WAV.
			target = {
				"speech_id": speech_id,
				"companion_id": companion_id,
				"text": text,
				"audio_path": "",
				"message_id": "",
				"chunk_index": 0,
				"final": true,
				"streaming": false,
			}
			if _playback.is_empty():
				_playback = target
			else:
				target_index = _ready.size()
				_ready.append(target)
			print("[TTS-PLAYBACK] recovered standalone whole-clip speech=", speech_id, " text_chars=", text.length())
	target["route_reason"] = str(_route_reasons.get(speech_id, ""))

	if target_index >= 0:
		target["audio_path"] = audio_path
		_ready[target_index] = target
	else:
		_playback["audio_path"] = audio_path
		target = _playback

	if bool(target.get("streaming", false)):
		return

	if target_index >= 0:
		# Current playback is still busy; this synthesized clip is prefetched.
		return

	_start_playback(target)


func _on_bridge_speech_route_diagnostic(speech_id: String, reason_code: String) -> void:
	if reason_code in ["provider-credential-required", "local-voice-not-installed", "dns-unreachable", "provider-auth-failed", "provider-quota-exceeded", "provider-rate-limited", "tts-unavailable"]:
		_route_reasons[speech_id] = reason_code


func _start_playback(request: Dictionary) -> void:
	var speech_id := str(request.get("speech_id", ""))
	var companion_id := str(request.get("companion_id", "default"))
	var text := str(request.get("text", ""))
	var audio_path := str(request.get("audio_path", ""))
	if speech_id.is_empty():
		return

	if audio_path.is_empty():
		print("[TTS-PLAYBACK] speech=", speech_id, " audio=false outcome=tts-unavailable")
		_report_speech_finished(speech_id, companion_id, "tts-unavailable")
		return
	if not FileAccess.file_exists(audio_path):
		push_warning("[TTS-PLAYBACK] speech clip missing: " + audio_path)
		_report_speech_finished(speech_id, companion_id, "tts-unavailable")
		return

	var stream := AudioStreamWAV.load_from_file(audio_path)
	if stream == null:
		stream = AudioStreamWAV.load_from_buffer(FileAccess.get_file_as_bytes(audio_path))
	if stream == null:
		push_warning("[TTS-PLAYBACK] speech clip failed to load: " + audio_path)
		_report_speech_finished(speech_id, companion_id, "tts-unavailable")
		return

	var player := AudioStreamPlayer.new()
	player.name = "TTSSpeech_%s" % speech_id.replace("-", "_")
	add_child(player)
	player.stream = stream
	_players[speech_id] = player
	player.finished.connect(Callable(self, "_on_player_finished").bind(speech_id, companion_id))
	player.play()
	_voice_latency_mark(speech_id, "audio-start")
	event_bus.publish(&"tts.started", {
		"message_id": str(request.get("message_id", "")),
		"chunk_index": int(request.get("chunk_index", 0)),
		"final": bool(request.get("final", false)),
		"speech_id": speech_id,
		"companion_id": companion_id,
		"text": text,
	})
	print(
		"[TTS-PLAYBACK] speech=%s audio=true driver=%s length=%.3f playing=%s path=%s"
		% [speech_id, AudioServer.get_driver_name(), stream.get_length(), player.playing, audio_path]
	)


func _on_player_finished(speech_id: String, companion_id: String) -> void:
	var player := _players.get(speech_id) as AudioStreamPlayer
	_players.erase(speech_id)
	if is_instance_valid(player):
		player.queue_free()
	print("[TTS-PLAYBACK] speech=", speech_id, " outcome=finished")
	_report_speech_finished(speech_id, companion_id, "finished")


func _report_speech_finished(speech_id: String, companion_id: String, outcome: String) -> void:
	if _live_speech_ids.has(speech_id):
		_live_speech_ids.erase(speech_id)
		_on_bridge_speech_finished(speech_id, companion_id, outcome)
		return
	if is_instance_valid(bridge) and bridge.has_method("report_speech_finished"):
		bridge.call("report_speech_finished", speech_id, companion_id, outcome)
	else:
		push_warning("[TTS-PLAYBACK] bridge cannot report speech completion")


func _on_bridge_speech_finished(speech_id: String, companion_id: String, outcome: String) -> void:
	if _cancelled_speech_ids.has(speech_id):
		_cleanup_speech_state(speech_id)
		_cancelled_speech_ids.erase(speech_id)
		return
	if _playback.is_empty() or speech_id != str(_playback.get("speech_id", "")):
		return
	_voice_latency_mark(speech_id, "finished")
	var finished_request := _playback.duplicate(true)
	var success := outcome == "finished"
	if success:
		event_bus.publish(&"tts.finished", {
			"message_id": str(finished_request.get("message_id", "")),
			"chunk_index": int(finished_request.get("chunk_index", 0)),
			"final": bool(finished_request.get("final", false)),
			"speech_id": speech_id,
			"companion_id": companion_id,
			"outcome": outcome,
		})
	else:
		event_bus.publish(&"tts.failed", {
			"message_id": str(finished_request.get("message_id", "")),
			"chunk_index": int(finished_request.get("chunk_index", 0)),
			"final": bool(finished_request.get("final", false)),
			"speech_id": speech_id,
			"companion_id": companion_id,
			"outcome": outcome,
			"reason_code": str(finished_request.get("route_reason", "tts-unavailable" if outcome == "tts-unavailable" else "playback-failed")),
			"error": "Speech playback did not complete: %s" % outcome,
		})
	_route_reasons.erase(speech_id)
	_playback.clear()
	if not _ready.is_empty():
		_playback = _ready.pop_front()
		if bool(_playback.get("streaming", false)):
			_start_stream_playback(_playback)
		elif not str(_playback.get("audio_path", "")).is_empty():
			_start_playback(_playback)
	_pump()


