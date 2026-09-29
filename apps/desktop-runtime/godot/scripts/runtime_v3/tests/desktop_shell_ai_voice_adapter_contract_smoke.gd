extends SceneTree

const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")


class FakeContext:
	extends Node
	var character := {"voice_profile": {"gender": "female", "age": "child", "thaiSpeechStyle": "feminine"}}
	var settings := {
		"ai_provider_id": "offline", "ai_base_url": "", "ai_model": "", "ai_timeout_seconds": 45,
		"tts_enabled": true, "tts_provider_id": "auto", "tts_model": "gemini-2.5-flash-preview-tts", "tts_voice": "auto",
	}
	var runtime_config := {}
	func update_settings(values: Dictionary) -> void:
		settings = values.duplicate(true)
	func snapshot() -> Dictionary:
		return {"character": character.duplicate(true), "settings": settings.duplicate(true)}


class FakeBus:
	extends Node
	var published: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})
	func subscribe(_topic: StringName, _callback: Callable) -> void:
		pass
	func unsubscribe(_topic: StringName, _callback: Callable) -> void:
		pass


class FakeSettings:
	extends Node
	var context: FakeContext
	var saved := {}
	func save_settings(values: Dictionary) -> bool:
		saved = values.duplicate(true)
		var merged := context.settings.duplicate(true)
		merged.merge(values, true)
		context.update_settings(merged)
		return true


class FakeAI:
	extends Node
	var provider_id := "ollama"
	var tested := {}
	var discovered := {}
	var reloads := 0
	func reload_provider() -> void:
		reloads += 1
	func test_connection(values: Dictionary = {}) -> void:
		tested = values.duplicate(true)
	func discover_models(values: Dictionary = {}) -> void:
		discovered = values.duplicate(true)
	func provider_status() -> Dictionary:
		return {"configured": true, "reachable": false}


class FakeCredential:
	extends Node
	var present_ids := {"openai-compatible": true, "gemini-cloud": true}
	func present(provider_id: String) -> bool:
		return bool(present_ids.get(provider_id, false))


class FakeNativeBridge:
	extends Node
	func start_credential_broker(_capability: String) -> PackedStringArray:
		return PackedStringArray(["--ocp-credential-pipe=ocp-credential-%s" % "a".repeat(32), "--ocp-credential-capability=%s" % "b".repeat(64)])


class FakeBridgeAdapter:
	extends Node
	var bridge := FakeNativeBridge.new()


class FakeNativeHostLifecycle:
	extends Node
	var focus_states: Array[bool] = []
	func set_chat_focus_active(active: bool) -> void:
		focus_states.append(active)


class FakeServices:
	extends Node
	var settings_service := FakeSettings.new()
	var ai_service := FakeAI.new()
	var credential_service := FakeCredential.new()
	var bridge_adapter := FakeBridgeAdapter.new()
	var native_host_lifecycle := FakeNativeHostLifecycle.new()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := FakeBus.new()
	var services := FakeServices.new()
	var adapter := AdapterScript.new()
	for node in [context, bus, services, adapter]:
		holder.add_child(node)
	for service in [services.settings_service, services.ai_service, services.credential_service, services.bridge_adapter, services.native_host_lifecycle]:
		services.add_child(service)
	services.bridge_adapter.add_child(services.bridge_adapter.bridge)
	services.settings_service.context = context
	adapter.configure(context, bus)
	adapter.bind_services(services)

	var ai_settings := {
		"providerId": "ollama", "baseUrl": "http://127.0.0.1:11434", "model": "smoke-model",
		"timeoutSeconds": 45, "ttsEnabled": true, "ttsProviderId": "auto", "ttsModel": "gemini-2.5-flash-preview-tts", "ttsVoice": "auto",
		"ttsVoiceMode": "custom", "ttsVoiceGender": "female", "ttsVoiceAge": "adult", "thaiSpeechStyle": "feminine",
	}
	# Exercise the same JSON wire representation Electron writes. Godot parses
	# JSON numbers as floats, while direct Dictionary construction above uses ints.
	var wire_command_value: Variant = JSON.parse_string(JSON.stringify({"type": "control.ai.update", "settings": ai_settings}))
	var wire_command: Dictionary = wire_command_value if wire_command_value is Dictionary else {}
	adapter._handle_command(wire_command, "ai-save-1")
	var save_ok: bool = services.settings_service.saved.get("ai_provider_id", "") == "ollama" \
		and services.settings_service.saved.get("ai_base_url", "") == "http://127.0.0.1:11434" \
		and services.settings_service.saved.get("ai_model", "") == "smoke-model" \
		and int(services.settings_service.saved.get("ai_timeout_seconds", 0)) == 45 \
		and bool(services.settings_service.saved.get("tts_enabled", false)) \
		and services.settings_service.saved.get("tts_model", "") == "gemini-2.5-flash-preview-tts" \
		and services.ai_service.reloads == 1

	var wire_ai_test_value: Variant = JSON.parse_string(JSON.stringify({"type": "control.ai.test", "settings": ai_settings}))
	var wire_ai_test: Dictionary = wire_ai_test_value if wire_ai_test_value is Dictionary else {}
	adapter._handle_command(wire_ai_test, "ai-test-1")
	var ai_started: bool = not adapter.pending_ai_test.is_empty() \
		and services.ai_service.tested.get("ai_provider_id", "") == "ollama" \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "ai-test-1" and result.get("status", "") == "accepted")
	adapter._on_ai_test_completed({"provider_id": "ollama", "ok": true, "message": "raw provider detail must not project"})
	var ai_finished: bool = adapter.ai_test_state.get("status", "") == "succeeded" \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "ai-test-1" and result.get("status", "") == "succeeded" and result.get("errorCode", "invalid") == "")

	var wire_discovery_value: Variant = JSON.parse_string(JSON.stringify({"type": "control.ai.discover", "settings": ai_settings}))
	var wire_discovery: Dictionary = wire_discovery_value if wire_discovery_value is Dictionary else {}
	adapter._handle_command(wire_discovery, "ai-discover-1")
	var discovery_started: bool = not adapter.pending_ai_discovery.is_empty() \
		and services.ai_service.discovered.get("ai_provider_id", "") == "ollama" \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "ai-discover-1" and result.get("status", "") == "accepted")
	adapter._on_ai_models_discovered({
		"provider_id": "ollama", "ok": true,
		"models": ["qwen3.5:latest", "gemma3:4b", "qwen3.5:latest", "", "bad\nname"],
		"message": "raw discovery detail must not project",
	})
	var discovery_finished: bool = adapter.pending_ai_discovery.is_empty() \
		and adapter.command_results.any(func(result: Dictionary) -> bool:
			return result.get("id", "") == "ai-discover-1" \
				and result.get("status", "") == "succeeded" \
				and result.get("models", []) == ["qwen3.5:latest", "gemma3:4b"] \
				and not JSON.stringify(result).contains("raw discovery detail"))

	var wire_voice_test_value: Variant = JSON.parse_string(JSON.stringify({"type": "control.voice.test", "settings": ai_settings}))
	var wire_voice_test: Dictionary = wire_voice_test_value if wire_voice_test_value is Dictionary else {}
	adapter._handle_command(wire_voice_test, "voice-test-1")
	var voice_request: Dictionary = bus.published.back() if not bus.published.is_empty() else {}
	var voice_payload: Dictionary = voice_request.get("payload", {})
	var voice_started: bool = voice_request.get("topic", &"") == &"tts.requested" \
		and voice_payload.get("text", "") == AdapterScript.RUNTIME_VOICE_TEST_PHRASE \
		and voice_payload.get("provider_id", "") == "auto" \
		and voice_payload.get("model_id", "") == "gemini-2.5-flash-preview-tts" \
		and voice_payload.get("voice", "") == "profile:female:adult"
	adapter._on_voice_test_finished({"message_id": voice_payload.get("message_id", ""), "outcome": "finished"})
	var voice_finished: bool = adapter.voice_test_state.get("status", "") == "succeeded" \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "voice-test-1" and result.get("status", "") == "succeeded")
	context.settings["language"] = "th"
	adapter._handle_command(wire_voice_test, "voice-test-th")
	var thai_voice_request: Dictionary = bus.published.back() if not bus.published.is_empty() else {}
	var thai_voice_payload: Dictionary = thai_voice_request.get("payload", {})
	var voice_language_ok: bool = thai_voice_request.get("topic", &"") == &"tts.requested" \
		and thai_voice_payload.get("text", "") == AdapterScript.RUNTIME_VOICE_TEST_PHRASE_TH
	adapter._on_voice_test_finished({"message_id": thai_voice_payload.get("message_id", ""), "outcome": "finished"})
	adapter._on_tts_requested({"message_id": "chat-voice-1"})
	var voice_synthesizing: bool = adapter.voice_health_state.get("status", "") == "synthesizing"
	adapter._on_voice_test_started({"message_id": "chat-voice-1"})
	var voice_playing: bool = adapter.voice_health_state.get("status", "") == "playing"
	adapter._on_voice_test_finished({"message_id": "chat-voice-1", "outcome": "finished"})
	var playback_healthy: bool = adapter.voice_health_state.get("status", "") == "healthy" \
		and int(adapter.voice_health_state.get("lastSuccessAtMs", 0)) > 0
	adapter._on_voice_test_failed({"message_id": "chat-voice-2", "outcome": "tts-unavailable", "reason_code": "local-voice-not-installed", "error": "private detail"})
	var playback_failed_safe: bool = adapter.voice_health_state == {
		"status": "failed", "reasonCode": "local-voice-not-installed", "lastSuccessAtMs": adapter.voice_health_state.get("lastSuccessAtMs", 0),
	} and not JSON.stringify(adapter.voice_health_state).contains("private detail")
	adapter._handle_command({"type": "shell.chat-focus", "active": true}, "")
	adapter._handle_command({"type": "shell.chat-focus", "active": false}, "")
	var focus_coordinated: bool = services.native_host_lifecycle.focus_states == [true, false]

	var projection: Dictionary = adapter._ai_control_snapshot()
	var projection_ok: bool = projection.get("settings", {}).get("providerId", "") == "ollama" \
		and projection.get("settings", {}).get("ttsVoiceMode", "") == "custom" \
		and projection.get("settings", {}).get("ttsVoiceGender", "") == "female" \
		and projection.get("settings", {}).get("ttsVoiceAge", "") == "adult" \
		and projection.get("settings", {}).get("thaiSpeechStyle", "") == "feminine" \
		and projection.get("credentials", {}).get("openAiCompatiblePresent", false) \
		and projection.get("credentials", {}).get("geminiPresent", false) \
		and not projection.has("credential") \
		and not JSON.stringify(projection).contains("raw provider detail")
	# Legacy builds could persist a concrete provider persona. Character mode must
	# ignore that stale override and project/use the active Character/3 profile.
	context.update_settings(context.settings.merged({"tts_voice_mode": "character", "tts_voice": "Enceladus"}, true))
	var character_projection: Dictionary = adapter._ai_control_snapshot().get("settings", {})
	var character_profile_projection_ok: bool = character_projection.get("ttsVoiceMode", "") == "character" \
		and character_projection.get("ttsVoice", "") == "auto" \
		and character_projection.get("ttsVoiceGender", "") == "female" \
		and character_projection.get("ttsVoiceAge", "") == "child" \
		and character_projection.get("thaiSpeechStyle", "") == "feminine" \
		and adapter._resolved_voice_setting(character_projection) == "profile:female:child"
	var saved_before_invalid := services.settings_service.saved.duplicate(true)
	adapter._handle_command({"type": "control.ai.update", "settings": ai_settings.merged({"credential": "must-not-cross"})}, "ai-invalid-1")
	var secret_rejected: bool = services.settings_service.saved == saved_before_invalid \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "ai-invalid-1" and result.get("status", "") == "failed")
	adapter._handle_command({"type": "chat.reconnect"}, "chat-reconnect-1")
	var reconnect_started: bool = adapter.pending_ai_test.get("commandType", "") == "chat.reconnect"
	adapter._on_ai_test_completed({"provider_id": "ollama", "ok": true, "message": "connected"})
	var reconnect_finished: bool = adapter.chat_status == "ready" \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "chat-reconnect-1" and result.get("status", "") == "succeeded")
	adapter.chat_messages = [{"id": "u-1", "role": "user", "text": "hello", "status": "complete"}]
	adapter._handle_command({"type": "chat.session.clear"}, "chat-clear-1")
	var clear_ok: bool = adapter.chat_messages.is_empty() \
		and adapter.command_results.any(func(result: Dictionary) -> bool: return result.get("id", "") == "chat-clear-1" and result.get("status", "") == "succeeded")

	var ok: bool = save_ok and ai_started and ai_finished and discovery_started and discovery_finished and voice_started and voice_finished and voice_language_ok \
		and voice_synthesizing and voice_playing and playback_healthy and playback_failed_safe \
		and focus_coordinated and projection_ok and character_profile_projection_ok and secret_rejected and reconnect_started and reconnect_finished and clear_ok
	print("[G16.27] AI/Voice adapter save=", save_ok, " ai_test=", ai_started and ai_finished, " discovery=", discovery_started and discovery_finished, " voice_test=", voice_started and voice_finished, " playback_health=", voice_synthesizing and voice_playing and playback_healthy and playback_failed_safe, " chat_focus=", focus_coordinated, " reconnect=", reconnect_started and reconnect_finished, " clear=", clear_ok, " projection=", projection_ok, " character_profile_projection=", character_profile_projection_ok, " secret_rejected=", secret_rejected, " ok=", ok)
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
