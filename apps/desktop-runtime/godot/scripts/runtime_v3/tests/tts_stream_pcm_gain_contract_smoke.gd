extends SceneTree

const TTSServiceScript = preload("res://scripts/runtime_v3/services/tts_service.gd")


class FakeBus extends Node:
	func publish(_topic: StringName, _payload: Dictionary) -> void:
		pass

	func unsubscribe(_topic: StringName, _callback: Callable) -> void:
		pass


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var service := TTSServiceScript.new()
	var bus := FakeBus.new()
	get_root().add_child(bus)
	get_root().add_child(service)
	service.event_bus = bus
	var quiet := _pcm([128, -128, 96, -96])
	var quiet_result := service.normalize_stream_pcm_for_playback(quiet)
	var loud := _pcm([16384, -16384])
	var loud_result := service.normalize_stream_pcm_for_playback(loud)
	var silence := _pcm([0, 0])
	var silence_result := service.normalize_stream_pcm_for_playback(silence)
	# PCM that arrives before the continuous generator is initialized must be
	# retained intact and drained when playback starts; never drop early cloud
	# deltas while the active speech slot is changing.
	var speech_id := "stream-routing-contract"
	service._on_bridge_speech_audio_chunk(speech_id, quiet)
	var pending: Array = service._stream_pending_chunks.get(speech_id, [])
	var quiet_ok: bool = float(quiet_result.get("source_peak", 0.0)) > 0.0 \
		and is_equal_approx(float(quiet_result.get("gain", 0.0)), 1.0) \
		and quiet_result.get("audio", PackedByteArray()) == quiet \
		and is_equal_approx(float(quiet_result.get("output_peak", 0.0)), float(quiet_result.get("source_peak", -1.0)))
	var loud_ok: bool = is_equal_approx(float(loud_result.get("gain", 0.0)), 1.0) \
		and loud_result.get("audio", PackedByteArray()) == loud \
		and is_equal_approx(float(loud_result.get("output_peak", 0.0)), 0.5)
	var silence_ok: bool = is_equal_approx(float(silence_result.get("gain", 0.0)), 1.0) \
		and is_equal_approx(float(silence_result.get("output_peak", 1.0)), 0.0)
	var routing_ok: bool = pending.size() == 1 \
		and pending[0] is PackedByteArray \
		and (pending[0] as PackedByteArray) == quiet
	# The gain regression does not create a real AudioStreamGenerator here:
	# Godot's headless Dummy driver retains its playback object until engine exit.
	# Generator lifecycle is covered by the TTS service contracts; this contract
	# owns the distortion invariant: provider PCM stays untouched and mixer gain
	# stays at unity (0 dB).
	var output_gain_ok: bool = is_equal_approx(float(service.STREAM_OUTPUT_GAIN_DB), 0.0)
	var ok: bool = quiet_ok and loud_ok and silence_ok and routing_ok and output_gain_ok
	print("[TTS-STREAM-GAIN] quiet=", quiet_ok, " loud=", loud_ok, " silence=", silence_ok, " routing=", routing_ok, " output_gain_0db=", output_gain_ok, " ok=", ok)
	service.stop()
	await process_frame
	await process_frame
	service.queue_free()
	bus.queue_free()
	await process_frame
	await process_frame
	quit(0 if ok else 1)


func _pcm(samples: Array[int]) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(samples.size() * 2)
	for index in range(samples.size()):
		result.encode_s16(index * 2, samples[index])
	return result
