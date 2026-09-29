extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var wav_path := OS.get_environment("OCP_TTS_DIAG_WAV")
	if wav_path.is_empty():
		push_error("[TTS-AUDIO-LIVE] OCP_TTS_DIAG_WAV is missing")
		quit(2)
		return
	print("[TTS-AUDIO-LIVE] driver=", AudioServer.get_driver_name())
	print("[TTS-AUDIO-LIVE] path=", wav_path, " exists=", FileAccess.file_exists(wav_path))
	var bytes := FileAccess.get_file_as_bytes(wav_path)
	print("[TTS-AUDIO-LIVE] bytes=", bytes.size())
	var file_stream := AudioStreamWAV.load_from_file(wav_path)
	var buffer_stream := AudioStreamWAV.load_from_buffer(bytes)
	print("[TTS-AUDIO-LIVE] load_from_file=", file_stream != null, " load_from_buffer=", buffer_stream != null)
	var stream := file_stream
	if stream == null:
		push_error("[TTS-AUDIO-LIVE] WAV load_from_file failed")
		quit(3)
		return
	print("[TTS-AUDIO-LIVE] length=", stream.get_length())
	var player := AudioStreamPlayer.new()
	get_root().add_child(player)
	player.stream = stream
	player.play()
	await create_timer(0.5).timeout
	print("[TTS-AUDIO-LIVE] after_500ms playing=", player.playing, " position=", player.get_playback_position())
	await create_timer(maxf(0.5, stream.get_length() + 0.5)).timeout
	print("[TTS-AUDIO-LIVE] completed playing=", player.playing, " position=", player.get_playback_position())
	quit(0)
