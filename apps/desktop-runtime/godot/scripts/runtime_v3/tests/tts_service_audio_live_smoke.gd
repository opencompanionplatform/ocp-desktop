extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const TTSServiceScript = preload("res://scripts/runtime_v3/services/tts_service.gd")

class FakeBridge:
	extends Node
	signal speech_started(companion_id: String, speech_id: String, text: String)
	signal speech_requested(companion_id: String, speech_id: String, text: String, subtitle: bool, audio_path: String)
	signal speech_finished(speech_id: String, companion_id: String, outcome: String)
	var outcome := ""

	func report_speech_finished(speech_id: String, companion_id: String, result: String) -> void:
		outcome = result
		speech_finished.emit(speech_id, companion_id, result)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var wav_path := OS.get_environment("OCP_TTS_DIAG_WAV")
	if wav_path.is_empty() or not FileAccess.file_exists(wav_path):
		push_error("[TTS-SERVICE-AUDIO-LIVE] missing OCP_TTS_DIAG_WAV")
		quit(2)
		return
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
	print("[TTS-SERVICE-AUDIO-LIVE] driver=", AudioServer.get_driver_name(), " path=", wav_path)
	bridge.speech_requested.emit("default", "speech-live", "live playback", false, wav_path)
	await process_frame
	var player := service._players.get("speech-live") as AudioStreamPlayer
	var ok: bool = is_instance_valid(player) \
		and player.playing \
		and player.stream != null \
		and player.stream.get_length() > 0.0
	print("[TTS-SERVICE-AUDIO-LIVE] playing=", player.playing if is_instance_valid(player) else false, " length=", player.stream.get_length() if is_instance_valid(player) and player.stream != null else 0.0, " ok=", ok)
	service.stop()
	holder.queue_free()
	await process_frame
	await process_frame
	quit(0 if ok else 1)
