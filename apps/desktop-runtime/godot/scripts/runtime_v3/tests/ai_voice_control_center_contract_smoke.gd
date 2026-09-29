extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shell := Window.new()
	shell.name = "ApplicationWindow"
	shell.set_script(load("res://scripts/runtime_v3/ui/production_app_shell.gd"))
	get_root().add_child(shell)
	await process_frame

	var tabs := TabContainer.new()
	tabs.name = "ApplicationTabs"
	var settings := Control.new()
	settings.name = "Settings"
	var updates := Control.new()
	updates.name = "Updates"
	tabs.add_child(settings)
	tabs.add_child(updates)
	shell.add_child(tabs)
	shell.set("tabs", tabs)
	shell.call("_build_control_rail")
	shell.call("_build_ai_voice_page")
	shell.call("sync_ai_settings", {
		"ai_provider_id": "ollama",
		"ai_base_url": "http://127.0.0.1:11434",
		"ai_model": "smoke-model",
		"ai_timeout_seconds": 60,
		"tts_enabled": true,
		"tts_provider_id": "auto",
		"tts_model": "gemini-2.5-flash-preview-tts",
		"tts_voice": "Kore",
	}, {"provider_id": "ollama", "configured": true, "reachable": false, "status_message": "Not tested"})
	var snapshot: Dictionary = shell.call("get_ai_settings_snapshot")
	shell.call("select_control_page", "ai_voice", false)
	var nav: Dictionary = shell.get("nav_buttons")
	var nav_ok: bool = nav.has("settings") and nav.has("ai_voice") and nav.has("updates") \
		and (nav["ai_voice"] as Button).button_pressed \
		and not (nav["settings"] as Button).button_pressed \
		and not (nav["updates"] as Button).button_pressed
	var page_ok: bool = tabs.get_tab_count() == 3 \
		and tabs.get_tab_title(tabs.current_tab) == "AI & Voice" \
		and tabs.get_node_or_null("AI & Voice") != null
	var settings_ok: bool = snapshot.get("ai_provider_id") == "ollama" \
		and snapshot.get("ai_base_url") == "http://127.0.0.1:11434" \
		and snapshot.get("ai_model") == "smoke-model" \
		and int(snapshot.get("ai_timeout_seconds")) == 60 \
		and bool(snapshot.get("tts_enabled")) \
		and snapshot.get("tts_voice") == "Kore"
	var tts_test_button := shell.find_child("TTSTestButton", true, false) as Button
	var voice_test_ok: bool = is_instance_valid(tts_test_button) and tts_test_button.text == "Test voice"
	var credential_input := shell.find_child("GeminiCredentialInput", true, false) as LineEdit
	var credential_status := shell.find_child("GeminiCredentialStatus", true, false) as Label
	var credential_button := shell.find_child("GeminiCredentialSaveButton", true, false) as Button
	var credential_capture: Dictionary = {}
	shell.connect("provider_credential_save_requested", func(provider_id: String, credential: String) -> void:
		credential_capture["provider_id"] = provider_id
		credential_capture["credential"] = credential
	)
	shell.call("sync_provider_credential_status", "gemini-cloud", true)
	if is_instance_valid(credential_input):
		credential_input.text = "smoke-secret-never-persist"
	if is_instance_valid(credential_button):
		credential_button.emit_signal("pressed")
	var secure_credential_ok: bool = is_instance_valid(credential_input) \
		and credential_input.secret \
		and credential_input.text.is_empty() \
		and is_instance_valid(credential_status) \
		and not credential_status.text.contains("smoke-secret-never-persist") \
		and credential_capture.get("provider_id", "") == "gemini-cloud" \
		and credential_capture.get("credential", "") == "smoke-secret-never-persist" \
		and not snapshot.has("gemini_api_key") \
		and not snapshot.has("credential")
	var provider_option := shell.find_child("AIProviderOption", true, false) as OptionButton
	var cloud_provider_ok: bool = is_instance_valid(provider_option) \
		and provider_option.item_count >= 3 \
		and str(provider_option.get_item_metadata(2)) == "openai-compatible"
	var cloud_input := shell.find_child("CloudCredentialInput", true, false) as LineEdit
	var cloud_status := shell.find_child("CloudCredentialStatus", true, false) as Label
	var cloud_button := shell.find_child("CloudCredentialSaveButton", true, false) as Button
	shell.call("sync_provider_credential_status", "openai-compatible", true)
	if is_instance_valid(cloud_input):
		cloud_input.text = "cloud-secret-never-persist"
	if is_instance_valid(cloud_button):
		cloud_button.emit_signal("pressed")
	var cloud_credential_ok: bool = is_instance_valid(cloud_input) \
		and cloud_input.secret \
		and cloud_input.text.is_empty() \
		and is_instance_valid(cloud_status) \
		and not cloud_status.text.contains("cloud-secret-never-persist") \
		and credential_capture.get("provider_id", "") == "openai-compatible" \
		and credential_capture.get("credential", "") == "cloud-secret-never-persist" \
		and not snapshot.has("api_key")
	var ok: bool = nav_ok and page_ok and settings_ok and voice_test_ok and secure_credential_ok and cloud_provider_ok and cloud_credential_ok
	print("[AI-VOICE-UI] nav=", nav_ok, " page=", page_ok, " settings=", settings_ok, " voice_test=", voice_test_ok, " secure_credential=", secure_credential_ok, " cloud_provider=", cloud_provider_ok, " cloud_credential=", cloud_credential_ok, " snapshot=", snapshot)
	shell.queue_free()
	await process_frame
	quit(0 if ok else 1)
