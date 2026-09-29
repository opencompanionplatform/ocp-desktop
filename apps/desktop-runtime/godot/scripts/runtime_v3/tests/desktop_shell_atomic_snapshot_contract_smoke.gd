extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var adapter := AdapterScript.new()
	for node in [context, bus, adapter]:
		holder.add_child(node)
	context.update_settings({"tts_enabled": true})
	adapter.configure(context, bus)
	var directory := ProjectSettings.globalize_path("user://g16_25a_atomic_%s" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(directory)
	adapter.session_directory = directory
	adapter.preview_state = adapter._idle_preview_state()
	adapter._write_snapshot()
	var first := _read_state(directory)
	adapter._apply_chat_visibility({"type": "shell.chat-visibility", "active": true})
	adapter._write_snapshot()
	var visible := _read_state(directory)
	adapter.chat_status = "thinking"
	adapter.chat_active_message_id = "turn-1"
	adapter._write_snapshot()
	var second := _read_state(directory)
	adapter.chat_status = "ready"
	adapter.chat_active_message_id = ""
	adapter._on_tts_requested({"message_id": "read_aloud_a-1_1", "presentation_message_id": "a-1", "chunk_index": 0, "source": "electron-read-aloud"})
	adapter._on_tts_requested({"message_id": "read_aloud_a-1_1", "presentation_message_id": "a-1", "chunk_index": 1, "source": "electron-read-aloud"})
	var synthesizing := _read_state(directory)
	adapter._on_voice_test_started({"message_id": "read_aloud_a-1_1", "chunk_index": 0, "speech_id": "speech-1"})
	var talking := _read_state(directory)
	adapter._on_voice_test_finished({"message_id": "read_aloud_a-1_1", "chunk_index": 0, "speech_id": "speech-1"})
	var between_chunks := _read_state(directory)
	adapter._on_voice_test_started({"message_id": "read_aloud_a-1_1", "chunk_index": 1, "speech_id": "speech-2"})
	var second_talking := _read_state(directory)
	adapter._on_voice_test_finished({"message_id": "read_aloud_a-1_1", "chunk_index": 1, "speech_id": "speech-2"})
	var finished := _read_state(directory)
	var temporary := directory.path_join("state.json.tmp")
	var first_presentation: Dictionary = first.get("chat", {}).get("presentation", {})
	var visible_presentation: Dictionary = visible.get("chat", {}).get("presentation", {})
	var second_presentation: Dictionary = second.get("chat", {}).get("presentation", {})
	var synth_presentation: Dictionary = synthesizing.get("chat", {}).get("presentation", {})
	var talk_presentation: Dictionary = talking.get("chat", {}).get("presentation", {})
	var between_presentation: Dictionary = between_chunks.get("chat", {}).get("presentation", {})
	var second_talk_presentation: Dictionary = second_talking.get("chat", {}).get("presentation", {})
	var finished_presentation: Dictionary = finished.get("chat", {}).get("presentation", {})
	var ok := int(first.get("schemaVersion", 0)) == AdapterScript.SCHEMA_VERSION \
		and str(first.get("status", "")) == "connected" \
		and str(first_presentation.get("owner", "")) == "native" \
		and str(visible_presentation.get("owner", "")) == "chat" \
		and int(visible_presentation.get("sequence", -1)) > int(first_presentation.get("sequence", -1)) \
		and str(second.get("chat", {}).get("status", "")) == "thinking" \
		and str(second_presentation.get("state", "")) == "think" \
		and str(second_presentation.get("reasonCode", "")) == "turn-active" \
		and str(second_presentation.get("turnId", "")) == "turn-1" \
		and int(second_presentation.get("sequence", -1)) > int(visible_presentation.get("sequence", -1)) \
		and str(synth_presentation.get("state", "")) == "think" \
		and str(synth_presentation.get("messageId", "")) == "a-1" \
		and str(talk_presentation.get("state", "")) == "talk" \
		and str(talk_presentation.get("speechId", "")) == "speech-1" \
		and int(talk_presentation.get("sequence", -1)) > int(synth_presentation.get("sequence", -1)) \
		and str(between_presentation.get("state", "")) == "talk" \
		and str(between_presentation.get("messageId", "")) == "a-1" \
		and str(second_talk_presentation.get("state", "")) == "talk" \
		and str(second_talk_presentation.get("speechId", "")) == "speech-2" \
		and str(finished_presentation.get("state", "")) == "idle" \
		and int(finished_presentation.get("sequence", -1)) > int(talk_presentation.get("sequence", -1)) \
		and not FileAccess.file_exists(temporary)
	print("[DESKTOP-SHELL-ATOMIC] schema=", first.get("schemaVersion", 0), " owner=", visible_presentation.get("owner", ""), " states=", [second_presentation.get("state", ""), synth_presentation.get("state", ""), talk_presentation.get("state", ""), finished_presentation.get("state", "")], " seq=", finished_presentation.get("sequence", -1), " temp=", FileAccess.file_exists(temporary), " ok=", ok)
	DirAccess.remove_absolute(directory.path_join("state.json"))
	DirAccess.remove_absolute(temporary)
	DirAccess.remove_absolute(directory)
	holder.free()
	quit(0 if ok else 1)


func _read_state(directory: String) -> Dictionary:
	var file := FileAccess.open(directory.path_join("state.json"), FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}
