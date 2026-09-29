extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3SoundController
## Character/3 SFX controller.
##
## TTS remains owned by RuntimeV3TTSService. This controller only plays signed
## character-package SFX declared in `audioProfile`, plus direct runtime sound
## requests. Master mute uses Godot's Master audio bus, while SFX enable/disable
## only affects this controller.

var player: AudioStreamPlayer
var active_animation: String = ""
var active_clip: Dictionary = {}
var volume_tween: Tween


func bind_player(target: AudioStreamPlayer) -> void:
	player = target


func start() -> void:
	event_bus.subscribe(&"sound.play_requested", Callable(self, "_on_sound_requested"))
	event_bus.subscribe(&"sound.master_toggle_requested", Callable(self, "_on_master_toggle_requested"))
	event_bus.subscribe(&"sound.sfx_toggle_requested", Callable(self, "_on_sfx_toggle_requested"))
	event_bus.subscribe(&"animation.started", Callable(self, "_on_animation_started"))
	event_bus.subscribe(&"animation.finished", Callable(self, "_on_animation_finished"))
	event_bus.subscribe(&"character.changed", Callable(self, "_on_character_changed"))
	_apply_initial_sound_state()


func stop() -> void:
	event_bus.unsubscribe(&"sound.play_requested", Callable(self, "_on_sound_requested"))
	event_bus.unsubscribe(&"sound.master_toggle_requested", Callable(self, "_on_master_toggle_requested"))
	event_bus.unsubscribe(&"sound.sfx_toggle_requested", Callable(self, "_on_sfx_toggle_requested"))
	event_bus.unsubscribe(&"animation.started", Callable(self, "_on_animation_started"))
	event_bus.unsubscribe(&"animation.finished", Callable(self, "_on_animation_finished"))
	event_bus.unsubscribe(&"character.changed", Callable(self, "_on_character_changed"))
	_stop_active_sfx(0.0)


func _on_sound_requested(payload: Dictionary) -> void:
	var stream: AudioStream = payload.get("stream")
	if not is_instance_valid(player) or stream == null or not _sfx_enabled():
		event_bus.publish(&"sound.missing", payload)
		return

	_stop_active_sfx(0.0)
	player.stream = stream
	player.volume_db = float(payload.get("gainDb", 0.0))
	player.play()
	event_bus.publish(&"sound.started", payload)


func _on_animation_started(payload: Dictionary) -> void:
	if not _sfx_enabled():
		return
	var animation_name := str(payload.get("name", "")).strip_edges()
	if animation_name.is_empty():
		return
	var binding := _audio_binding(animation_name)
	if binding.is_empty():
		return
	var clip := _audio_clip(str(binding.get("clip", "")))
	if clip.is_empty():
		event_bus.publish(&"sound.missing", {"animation": animation_name, "reason": "clip-missing"})
		return
	var stream := _load_character_audio(str(clip.get("path", "")))
	if stream == null:
		event_bus.publish(&"sound.missing", {"animation": animation_name, "clip": clip.get("id", ""), "reason": "asset-unavailable"})
		return

	_stop_active_sfx(0.0)
	active_animation = animation_name
	active_clip = clip.duplicate(true)
	_configure_loop(stream, bool(clip.get("loop", false)))
	player.stream = stream
	var gain_db := clampf(float(clip.get("gainDb", 0.0)), -60.0, 12.0)
	var fade_in := maxf(0.0, float(clip.get("fadeInSeconds", 0.0)))
	if fade_in > 0.0:
		player.volume_db = -60.0
		player.play(maxf(0.0, float(clip.get("startSeconds", 0.0))))
		volume_tween = create_tween()
		volume_tween.tween_property(player, "volume_db", gain_db, fade_in)
	else:
		player.volume_db = gain_db
		player.play(maxf(0.0, float(clip.get("startSeconds", 0.0))))
	event_bus.publish(&"sound.started", {"animation": animation_name, "clip": clip.get("id", ""), "source": "character/3"})


func _on_animation_finished(payload: Dictionary) -> void:
	var animation_name := str(payload.get("name", ""))
	if animation_name.is_empty() or animation_name != active_animation:
		return
	var binding := _audio_binding(animation_name)
	if str(binding.get("stop", "")) != "animation-stop" and not bool(active_clip.get("loop", false)):
		active_animation = ""
		active_clip.clear()
		return
	_stop_active_sfx(maxf(0.0, float(active_clip.get("fadeOutSeconds", 0.0))))


func _on_character_changed(_payload: Dictionary = {}) -> void:
	_stop_active_sfx(0.0)


func _on_master_toggle_requested(_payload: Dictionary = {}) -> void:
	var bus_index := AudioServer.get_bus_index("Master")
	if bus_index < 0:
		return
	var muted := not AudioServer.is_bus_mute(bus_index)
	AudioServer.set_bus_mute(bus_index, muted)
	if is_instance_valid(context):
		context.update_settings({"master_sound_muted": muted})
	event_bus.publish(&"sound.master_changed", {"muted": muted})


func _on_sfx_toggle_requested(_payload: Dictionary = {}) -> void:
	var enabled := not _sfx_enabled()
	if is_instance_valid(context):
		context.update_settings({"sfx_enabled": enabled})
	if not enabled:
		_stop_active_sfx(0.05)
	event_bus.publish(&"sound.sfx_changed", {"enabled": enabled})


func _apply_initial_sound_state() -> void:
	var muted := false
	if is_instance_valid(context):
		muted = bool(context.settings.get("master_sound_muted", false))
	var bus_index := AudioServer.get_bus_index("Master")
	if bus_index >= 0:
		AudioServer.set_bus_mute(bus_index, muted)
	event_bus.publish(&"sound.master_changed", {"muted": muted})
	event_bus.publish(&"sound.sfx_changed", {"enabled": _sfx_enabled()})


func _sfx_enabled() -> bool:
	if not is_instance_valid(context):
		return true
	return bool(context.settings.get("sfx_enabled", true))


func _audio_profile() -> Dictionary:
	if not is_instance_valid(context):
		return {}
	var profile: Variant = context.character.get("audio_profile", {})
	return profile if profile is Dictionary else {}


func _audio_binding(animation_name: String) -> Dictionary:
	var bindings_value: Variant = _audio_profile().get("bindings", {})
	var bindings: Dictionary = bindings_value if bindings_value is Dictionary else {}
	var binding_value: Variant = bindings.get(animation_name, {})
	return binding_value if binding_value is Dictionary else {}


func _audio_clip(clip_id: String) -> Dictionary:
	if clip_id.is_empty():
		return {}
	var clips_value: Variant = _audio_profile().get("clips", [])
	var clips: Array = clips_value if clips_value is Array else []
	for value in clips:
		if value is Dictionary and str(value.get("id", "")) == clip_id:
			return value
	return {}


func _load_character_audio(relative_path: String) -> AudioStream:
	if relative_path.is_empty() or not is_instance_valid(context):
		return null
	var root := str(context.package.get("installed_path", ""))
	if root.is_empty():
		return null
	var audio_path := root.path_join(relative_path)
	if not FileAccess.file_exists(audio_path):
		return null
	var lower := audio_path.to_lower()
	if lower.ends_with(".wav"):
		return AudioStreamWAV.load_from_file(audio_path)
	if lower.ends_with(".ogg"):
		return AudioStreamOggVorbis.load_from_file(audio_path)
	return null


func _configure_loop(stream: AudioStream, enabled: bool) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD if enabled else AudioStreamWAV.LOOP_DISABLED
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = enabled


func _stop_active_sfx(fade_seconds: float) -> void:
	if is_instance_valid(volume_tween):
		volume_tween.kill()
	volume_tween = null
	if not is_instance_valid(player):
		active_animation = ""
		active_clip.clear()
		return
	if fade_seconds > 0.0 and player.playing:
		volume_tween = create_tween()
		volume_tween.tween_property(player, "volume_db", -60.0, fade_seconds)
		volume_tween.finished.connect(Callable(self, "_finish_faded_stop"), CONNECT_ONE_SHOT)
	else:
		player.stop()
	active_animation = ""
	active_clip.clear()


func _finish_faded_stop() -> void:
	if is_instance_valid(player):
		player.stop()
