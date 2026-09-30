extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ChatSessionOrchestrator

const SentenceChunkerScript = preload("res://scripts/runtime_v3/services/sentence_chunker.gd")
const MAX_TTS_MESSAGE_CHARACTERS := 600
const TTS_STABLE_PAUSE_SECONDS := 0.45

## Owns one chat response lifecycle from user prompt through visible response,
## desktop bubble, optional TTS and animation state. Provider-specific work stays
## behind AIService; presentation consumers only observe stable session events.

var _sequence := 0
var _active_message_id := ""
var _stream_text_by_message: Dictionary = {}
var _bubble_chunkers: Dictionary = {}
var _tts_chunkers: Dictionary = {}
var _tts_chunk_index: Dictionary = {}
var _tts_dispatched_chars: Dictionary = {}
var _tts_pending_chunks: Dictionary = {}
var _tts_response_complete: Dictionary = {}
var _tts_dispatch_pending: Dictionary = {}
var _tts_pause_generation: Dictionary = {}
var _tts_speaking_latched: Dictionary = {}


func start() -> void:
	event_bus.subscribe(&"ai.prompt_requested", Callable(self, "_on_prompt_requested"))
	event_bus.subscribe(&"ai.stream_started", Callable(self, "_on_stream_started"))
	event_bus.subscribe(&"ai.stream_delta", Callable(self, "_on_stream_delta"))
	event_bus.subscribe(&"ai.response_received", Callable(self, "_on_response_received"))
	event_bus.subscribe(&"ai.response_failed", Callable(self, "_on_response_failed"))
	event_bus.subscribe(&"tts.started", Callable(self, "_on_tts_started"))
	event_bus.subscribe(&"tts.finished", Callable(self, "_on_tts_finished"))
	event_bus.subscribe(&"tts.failed", Callable(self, "_on_tts_failed"))
	event_bus.subscribe(&"tts.interrupted", Callable(self, "_on_tts_interrupted"))


func stop() -> void:
	event_bus.unsubscribe(&"ai.prompt_requested", Callable(self, "_on_prompt_requested"))
	event_bus.unsubscribe(&"ai.stream_started", Callable(self, "_on_stream_started"))
	event_bus.unsubscribe(&"ai.stream_delta", Callable(self, "_on_stream_delta"))
	event_bus.unsubscribe(&"ai.response_received", Callable(self, "_on_response_received"))
	event_bus.unsubscribe(&"ai.response_failed", Callable(self, "_on_response_failed"))
	event_bus.unsubscribe(&"tts.started", Callable(self, "_on_tts_started"))
	event_bus.unsubscribe(&"tts.finished", Callable(self, "_on_tts_finished"))
	event_bus.unsubscribe(&"tts.failed", Callable(self, "_on_tts_failed"))
	event_bus.unsubscribe(&"tts.interrupted", Callable(self, "_on_tts_interrupted"))
	_stream_text_by_message.clear()
	_bubble_chunkers.clear()
	_tts_chunkers.clear()
	_tts_chunk_index.clear()
	_tts_dispatched_chars.clear()
	_tts_pending_chunks.clear()
	_tts_response_complete.clear()
	_tts_dispatch_pending.clear()
	_tts_pause_generation.clear()
	_tts_speaking_latched.clear()


func _on_prompt_requested(payload: Dictionary) -> void:
	var prompt := str(payload.get("prompt", "")).strip_edges()
	if prompt.is_empty():
		return

	var request := payload.duplicate(true)
	var message_id := str(request.get("message_id", ""))
	if message_id.is_empty():
		message_id = _next_message_id()
		request["message_id"] = message_id
	_active_message_id = message_id
	_stream_text_by_message[message_id] = ""
	_bubble_chunkers[message_id] = SentenceChunkerScript.new()
	_tts_chunkers[message_id] = SentenceChunkerScript.new()
	_tts_chunk_index[message_id] = 0
	_tts_dispatched_chars[message_id] = 0
	_tts_pending_chunks[message_id] = 0
	_tts_response_complete[message_id] = false
	_tts_pause_generation[message_id] = 0
	_tts_speaking_latched[message_id] = false

	event_bus.publish(&"chat.response_started", {
		"message_id": message_id,
		"prompt": prompt,
	})
	event_bus.publish(&"ai.thinking_started", {"message_id": message_id})
	event_bus.publish(&"animation.requested", {
		"name": "think",
		"message_id": message_id,
	})

	if is_instance_valid(services) and is_instance_valid(services.ai_service) and services.ai_service.has_method("request"):
		services.ai_service.call("request", request)
		return

	_on_response_failed({
		"message_id": message_id,
		"error": "AI service unavailable",
		"request": request,
	})


func _on_stream_started(payload: Dictionary) -> void:
	var request: Dictionary = payload.get("request", {}) if payload.get("request", {}) is Dictionary else {}
	var message_id := str(payload.get("message_id", request.get("message_id", _active_message_id)))
	if message_id.is_empty():
		return
	_stream_text_by_message[message_id] = ""
	event_bus.publish(&"chat.assistant_stream_started", {
		"message_id": message_id,
		"provider_id": str(payload.get("provider_id", "")),
		"request": request,
	})


func _on_stream_delta(payload: Dictionary) -> void:
	var request: Dictionary = payload.get("request", {}) if payload.get("request", {}) is Dictionary else {}
	var message_id := str(payload.get("message_id", request.get("message_id", _active_message_id)))
	if message_id.is_empty():
		return
	var delta := str(payload.get("delta", ""))
	var full_text := str(payload.get("text", ""))
	if full_text.is_empty():
		full_text = str(_stream_text_by_message.get(message_id, "")) + delta
	_stream_text_by_message[message_id] = full_text

	event_bus.publish(&"chat.assistant_stream_delta", {
		"message_id": message_id,
		"delta": delta,
		"text": full_text,
		"provider_id": str(payload.get("provider_id", "")),
		"request": request,
	})

	# Raw deltas remain presentation-only. Runtime's stateful chunkers emit only
	# stable sentence/phrase boundaries, so neither Bubble nor TTS can regress to
	# the old one-token/emoji-only replacement defect.
	_emit_ready_bubble_chunks(message_id, full_text, false)
	if _tts_enabled():
		# Quality-first Auto Speak uses complete WAV segments rather than raw PCM
		# chunks. Dispatch stable text early so the first short WAV can synthesize
		# before the assistant reply has fully finished, while later WAVs prefetch.
		_queue_tts_dispatch(message_id, full_text, false)
		_schedule_stable_pause_dispatch(message_id, full_text)


func _on_response_received(payload: Dictionary) -> void:
	var request: Dictionary = payload.get("request", {}) if payload.get("request", {}) is Dictionary else {}
	var message_id := str(payload.get("message_id", request.get("message_id", _active_message_id)))
	var text := str(payload.get("text", "")).strip_edges()
	if text.is_empty():
		text = str(_stream_text_by_message.get(message_id, "")).strip_edges()
	if text.is_empty():
		_on_response_failed({
			"message_id": message_id,
			"error": "AI provider returned an empty response",
			"request": request,
		})
		return

	event_bus.publish(&"ai.thinking_finished", {"message_id": message_id})
	event_bus.publish(&"chat.assistant_message_received", {
		"message_id": message_id,
		"text": text,
		"request": request,
		"streamed": _stream_text_by_message.has(message_id),
	})
	_emit_ready_bubble_chunks(message_id, text, true)
	_stream_text_by_message.erase(message_id)

	if _tts_enabled():
		# Finalize the same stable-segment queue used during streaming. TTSService
		# overlaps synthesis of later whole-WAV segments with current playback,
		# preserving quality while reducing first-audio latency.
		_queue_tts_dispatch(message_id, text, true)
	_tts_pause_generation.erase(message_id)
	_tts_response_complete[message_id] = true
	_finish_tts_message_if_ready(message_id)


func _on_response_failed(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", _active_message_id))
	var error_text := str(payload.get("error", "AI response failed"))
	_stream_text_by_message.erase(message_id)
	_bubble_chunkers.erase(message_id)
	_tts_chunkers.erase(message_id)
	_tts_chunk_index.erase(message_id)
	_tts_dispatched_chars.erase(message_id)
	_tts_dispatch_pending.erase(message_id)
	_tts_pause_generation.erase(message_id)
	_tts_speaking_latched.erase(message_id)
	event_bus.publish(&"ai.thinking_finished", {"message_id": message_id})
	event_bus.publish(&"chat.response_failed", {
		"message_id": message_id,
		"error": error_text,
	})
	_tts_response_complete[message_id] = true
	_finish_tts_message_if_ready(message_id)


func _emit_final_reply_tts(message_id: String, text: String) -> void:
	var speech_text := _sanitize_speech_text(text).left(MAX_TTS_MESSAGE_CHARACTERS).strip_edges()
	if speech_text.is_empty() or not _has_speakable_content(speech_text):
		return
	# Reserve before publish: a deterministic/local backend may synchronously
	# finish from inside EventBus.publish().
	_tts_pending_chunks[message_id] = int(_tts_pending_chunks.get(message_id, 0)) + 1
	_tts_dispatched_chars[message_id] = speech_text.length()
	_tts_chunk_index[message_id] = 1
	event_bus.publish(&"tts.requested", {
		"message_id": message_id,
		"chunk_index": 0,
		"text": speech_text,
		"final": true,
		"source": "chat-auto-speak",
	})


func _queue_tts_dispatch(message_id: String, full_text: String, final: bool) -> void:
	if message_id.is_empty() or full_text.is_empty():
		return
	var already_pending := _tts_dispatch_pending.has(message_id)
	var previous: Dictionary = _tts_dispatch_pending.get(message_id, {})
	_tts_dispatch_pending[message_id] = {
		"full_text": full_text,
		"final": final or bool(previous.get("final", false)),
	}
	if not already_pending:
		call_deferred("_emit_ready_tts_chunks_deferred", message_id)


func _emit_ready_tts_chunks_deferred(message_id: String) -> void:
	var pending: Dictionary = _tts_dispatch_pending.get(message_id, {})
	if pending.is_empty():
		return
	_tts_dispatch_pending.erase(message_id)
	var final := bool(pending.get("final", false))
	_emit_ready_tts_chunks(message_id, str(pending.get("full_text", "")), final)
	if final:
		_finish_tts_message_if_ready(message_id)


func _emit_ready_tts_chunks(message_id: String, full_text: String, final: bool, stable_pause: bool = false) -> void:
	if message_id.is_empty() or full_text.is_empty():
		return
	var chunker: RefCounted = _tts_chunkers.get(message_id)
	if chunker == null:
		chunker = SentenceChunkerScript.new()
		_tts_chunkers[message_id] = chunker
	var chunks: Array[String] = chunker.take_ready(full_text, final, stable_pause)
	if chunks.is_empty():
		return
	var requests: Array[Dictionary] = []
	for chunk_position in range(chunks.size()):
		var dispatched_chars := int(_tts_dispatched_chars.get(message_id, 0))
		var remaining_budget := MAX_TTS_MESSAGE_CHARACTERS - dispatched_chars
		if remaining_budget <= 0:
			break
		var speech_text := _sanitize_speech_text(chunks[chunk_position])
		if speech_text.length() > remaining_budget:
			speech_text = speech_text.left(remaining_budget).strip_edges()
		if speech_text.is_empty() or not _has_speakable_content(speech_text):
			continue
		var index := int(_tts_chunk_index.get(message_id, 0))
		_tts_chunk_index[message_id] = index + 1
		_tts_dispatched_chars[message_id] = dispatched_chars + speech_text.length()
		requests.append({
			"message_id": message_id,
			"chunk_index": index,
			"text": speech_text,
			"final": false,
			"source": "chat-session-stable",
		})
	if requests.is_empty():
		return
	# Reserve the complete batch before publishing. A fast fallback/test backend
	# may synchronously finish the first request from inside publish(); without
	# this reservation the lifecycle could emit IDLE before later chunks exist.
	_tts_pending_chunks[message_id] = int(_tts_pending_chunks.get(message_id, 0)) + requests.size()
	if final:
		requests[requests.size() - 1]["final"] = true
	for request in requests:
		event_bus.publish(&"tts.requested", request)


func _schedule_stable_pause_dispatch(message_id: String, full_text: String) -> void:
	var generation := int(_tts_pause_generation.get(message_id, 0)) + 1
	_tts_pause_generation[message_id] = generation
	_flush_tts_after_stable_pause(message_id, full_text, generation)


func _flush_tts_after_stable_pause(message_id: String, full_text: String, generation: int) -> void:
	await get_tree().create_timer(TTS_STABLE_PAUSE_SECONDS).timeout
	if int(_tts_pause_generation.get(message_id, -1)) != generation:
		return
	if bool(_tts_response_complete.get(message_id, false)):
		return
	_emit_ready_tts_chunks(message_id, full_text, false, true)


func _emit_ready_bubble_chunks(message_id: String, full_text: String, final: bool) -> void:
	if message_id.is_empty() or full_text.is_empty():
		return
	var chunker: RefCounted = _bubble_chunkers.get(message_id)
	if chunker == null:
		chunker = SentenceChunkerScript.new()
		_bubble_chunkers[message_id] = chunker
	var chunks: Array[String] = chunker.take_ready(full_text, final)
	for chunk_position in range(chunks.size()):
		var bubble_text := chunks[chunk_position].strip_edges()
		if bubble_text.is_empty():
			continue
		var final_tail := final and chunk_position == chunks.size() - 1
		event_bus.publish(&"bubble.requested", {
			"message_id": message_id,
			"text": bubble_text,
			"duration": 12.0 if final_tail else 8.0,
			"durationMs": 12000 if final_tail else 8000,
			"streaming": false,
			"source": "chat-session-stable",
		})
	if final:
		_bubble_chunkers.erase(message_id)


func _sanitize_speech_text(value: String) -> String:
	var speech_text := value.strip_edges()
	for marker in ["**", "__", "```", "`", "###", "##", "# "]:
		speech_text = speech_text.replace(marker, "")
	return speech_text.strip_edges()


func _has_speakable_content(value: String) -> bool:
	for offset in range(value.length()):
		var code := value.unicode_at(offset)
		if (code >= 48 and code <= 57) \
		or (code >= 65 and code <= 90) \
		or (code >= 97 and code <= 122) \
		or (code >= 0x0E01 and code <= 0x0E5B) \
		or (code >= 0x00C0 and code < 0x1F000):
			return true
	return false


func _on_tts_started(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	# Read Aloud and voice tests are owned by their callers. They share the
	# Runtime TTS event bus, but must never mutate the automatic chat-session
	# animation lifecycle (ADR-0053/G16.26A).
	if not _owns_tts_message(message_id):
		return
	# Whole-WAV segments are one logical utterance. Start SPEAK once and keep it
	# latched across all prefetched segments instead of restarting the animation
	# at every sentence boundary.
	if bool(_tts_speaking_latched.get(message_id, false)):
		return
	_tts_speaking_latched[message_id] = true
	event_bus.publish(&"animation.requested", {
		"name": "speak",
		"message_id": message_id,
		"source": "chat-tts",
	})


func _on_tts_finished(payload: Dictionary) -> void:
	_complete_tts_chunk(payload)


func _on_tts_failed(payload: Dictionary) -> void:
	_complete_tts_chunk(payload)


func _on_tts_interrupted(payload: Dictionary) -> void:
	_complete_tts_chunk(payload)


func _complete_tts_chunk(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	if not _owns_tts_message(message_id):
		return
	var pending := maxi(0, int(_tts_pending_chunks.get(message_id, 0)) - 1)
	_tts_pending_chunks[message_id] = pending
	# Voice Realtime V2 treats all stable TTS chunks for one assistant response
	# as one utterance. Once SPEAK begins it stays latched across provider/token
	# gaps and prefetched chunk boundaries; only final response completion may
	# transition back to IDLE. This removes visible SPEAK->THINK oscillation and
	# keeps lipsync/animation ownership aligned with the logical utterance.
	_finish_tts_message_if_ready(message_id)


func _owns_tts_message(message_id: String) -> bool:
	return not message_id.is_empty() and _tts_pending_chunks.has(message_id)


func _finish_tts_message_if_ready(message_id: String) -> void:
	if message_id.is_empty() or not bool(_tts_response_complete.get(message_id, false)):
		return
	# A deferred TTS dispatch still owns the handoff. Never transition to IDLE
	# before that handoff has actually queued its chunks.
	if _tts_dispatch_pending.has(message_id):
		return
	if int(_tts_pending_chunks.get(message_id, 0)) > 0:
		return
	event_bus.publish(&"animation.requested", {
		"name": "idle",
		"message_id": message_id,
	})
	_tts_pending_chunks.erase(message_id)
	_tts_response_complete.erase(message_id)
	_tts_chunkers.erase(message_id)
	_tts_chunk_index.erase(message_id)
	_tts_dispatched_chars.erase(message_id)
	_tts_pause_generation.erase(message_id)
	_tts_speaking_latched.erase(message_id)
	if _active_message_id == message_id:
		_active_message_id = ""


func _chat_voice_mode() -> String:
	if not is_instance_valid(context):
		return "on-demand"
	var mode := str(context.settings.get("chat_voice_mode", "on-demand")).strip_edges().to_lower()
	return mode if mode in ["off", "on-demand", "auto-speak", "live-voice"] else "on-demand"


func _final_reply_tts_enabled() -> bool:
	return is_instance_valid(context) \
		and bool(context.runtime_config.get("chat_presentation_active", false)) \
		and _chat_voice_mode() == "auto-speak"


func _tts_enabled() -> bool:
	if not is_instance_valid(context) or not bool(context.settings.get("tts_enabled", false)):
		return false
	var chat_mode := _chat_voice_mode()
	if chat_mode in ["off", "live-voice"]:
		return false
	# Desktop Chat defaults to explicit Read Aloud. Auto Speak opts into the
	# quality-first stable WAV queue; native companion presentation uses the same
	# sentence/phrase boundary logic so synthesis can overlap current playback.
	if bool(context.runtime_config.get("chat_presentation_active", false)):
		return chat_mode == "auto-speak"
	return true


func _next_message_id() -> String:
	_sequence += 1
	return "msg_%d_%d" % [Time.get_ticks_msec(), _sequence]
