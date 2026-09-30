extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var bridge := ClassDB.instantiate("OcpRuntimeBridge") as Node
	var ok := is_instance_valid(bridge) \
		and bridge.has_method("request_tts") \
		and bridge.has_method("request_tts_streaming") \
		and bridge.has_signal("speech_started") \
		and bridge.has_signal("speech_started_v2") \
		and bridge.has_signal("speech_stream_started") \
		and bridge.has_signal("speech_stream_started_v2") \
		and bridge.has_signal("speech_audio_chunk") \
		and bridge.has_signal("speech_stream_finished") \
		and bridge.has_signal("speech_finished") \
		and bridge.has_signal("speech_requested") \
		and bridge.has_method("voice_vad_reset") \
		and bridge.has_method("voice_vad_set_echo_guard") \
		and bridge.has_method("voice_vad_process_pcm16") \
		and bridge.has_method("request_asr_start") \
		and bridge.has_method("request_asr_audio") \
		and bridge.has_method("request_asr_end") \
		and bridge.has_signal("asr_ready") \
		and bridge.has_signal("asr_interim") \
		and bridge.has_signal("asr_final") \
		and bridge.has_signal("asr_turn_complete") \
		and bridge.has_signal("asr_error") \
		and bridge.has_method("request_live_voice_start") \
		and bridge.has_method("request_live_voice_activity_start") \
		and bridge.has_method("request_live_voice_audio") \
		and bridge.has_method("request_live_voice_activity_end") \
		and bridge.has_method("request_live_voice_close") \
		and bridge.has_signal("live_voice_ready") \
		and bridge.has_signal("live_voice_input_transcript") \
		and bridge.has_signal("live_voice_output_transcript") \
		and bridge.has_signal("live_voice_audio_chunk") \
		and bridge.has_signal("live_voice_turn_complete") \
		and bridge.has_signal("live_voice_error")
	print("[TTS-BRIDGE] request_tts=", bridge.has_method("request_tts") if is_instance_valid(bridge) else false,
		" streaming_request=", bridge.has_method("request_tts_streaming") if is_instance_valid(bridge) else false,
		" started_v2=", bridge.has_signal("speech_started_v2") if is_instance_valid(bridge) else false,
		" stream_started_v2=", bridge.has_signal("speech_stream_started_v2") if is_instance_valid(bridge) else false,
		" audio_chunk=", bridge.has_signal("speech_audio_chunk") if is_instance_valid(bridge) else false,
		" stream_finished=", bridge.has_signal("speech_stream_finished") if is_instance_valid(bridge) else false,
		" finished=", bridge.has_signal("speech_finished") if is_instance_valid(bridge) else false,
		" vad=", bridge.has_method("voice_vad_process_pcm16") if is_instance_valid(bridge) else false,
		" asr=", bridge.has_method("request_asr_start") if is_instance_valid(bridge) else false,
		" asr_final=", bridge.has_signal("asr_final") if is_instance_valid(bridge) else false,
		" live_voice=", bridge.has_method("request_live_voice_start") if is_instance_valid(bridge) else false,
		" live_audio=", bridge.has_signal("live_voice_audio_chunk") if is_instance_valid(bridge) else false)
	if is_instance_valid(bridge):
		bridge.free()
	quit(0 if ok else 1)
