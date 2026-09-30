extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const TTSServiceScript = preload("res://scripts/runtime_v3/services/tts_service.gd")

var events: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var service := TTSServiceScript.new()
	for node in [context, bus, service]:
		holder.add_child(node)
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	service.configure(context, bus)
	service.start()

	var speech_id := "live-session-turn-1"
	# Keep a synthetic playback slot occupied so the live request is queued rather
	# than opening a real AudioStreamGenerator on Godot's Dummy device. Generator
	# PCM behavior is already covered by tts_stream_pcm_gain_contract_smoke.gd;
	# this contract proves the new Live→TTS correlation path without device leaks.
	service._playback = {"speech_id": "blocker", "streaming": true}
	service._on_live_audio_started({
		"turn_id": speech_id,
		"speech_id": speech_id,
		"sample_rate": 24000,
	})
	var queued_ok := service._live_speech_ids.has(speech_id) \
		and service._ready.size() == 1 \
		and str(service._ready[0].get("speech_id", "")) == speech_id \
		and bool(service._ready[0].get("streaming", false))

	# Promote the queued request without starting a device player, then verify PCM
	# is retained until the real generator becomes available.
	service._playback = service._ready.pop_front()
	var pcm := PackedByteArray([1, 0, 2, 0, 3, 0, 4, 0])
	service._on_live_audio_chunk({"speech_id": speech_id, "audio": pcm})
	var chunk_ok := service._stream_pending_chunks.has(speech_id) \
		and (service._stream_pending_chunks[speech_id] as Array).size() == 1

	service._on_live_audio_finished({"speech_id": speech_id, "outcome": "finished"})
	var finish_queued_ok := service._stream_pending_finish.has(speech_id)
	service._report_speech_finished(speech_id, "default", "finished")
	var finished_ok := not service._live_speech_ids.has(speech_id) \
		and service._playback.is_empty() \
		and _topic_count(&"tts.finished") == 1 \
		and _topic_count(&"tts.failed") == 0

	var cancel_id := "live-session-turn-cancel"
	service._playback = {"speech_id": "blocker-2", "streaming": true}
	service._on_live_audio_started({"turn_id": cancel_id, "speech_id": cancel_id, "sample_rate": 24000})
	service._playback = service._ready.pop_front()
	service._on_tts_cancel_requested({"speech_id": cancel_id, "reason": "voice-barge-in"})
	var cancel_ok := not service._live_speech_ids.has(cancel_id) \
		and not service._cancelled_speech_ids.has(cancel_id) \
		and service._playback.is_empty() \
		and _topic_count(&"tts.interrupted") == 1

	var ok := queued_ok and chunk_ok and finish_queued_ok and finished_ok and cancel_ok
	print("[VOICE-LIVE-TTS] queued=", queued_ok, " chunk=", chunk_ok, " finish_queued=", finish_queued_ok, " finished=", finished_ok, " cancel=", cancel_ok, " ok=", ok)

	service.stop()
	holder.free()
	quit(0 if ok else 1)


func _topic_count(topic: StringName) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") == topic:
			count += 1
	return count
