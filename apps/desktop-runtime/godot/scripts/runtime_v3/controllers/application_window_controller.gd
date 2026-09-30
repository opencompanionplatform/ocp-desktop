extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ApplicationWindowController

var application_window: Window
var chat_window: Window
var tabs: TabContainer
var show_bubbles_toggle: CheckButton
var offline_presence_toggle: CheckButton
var update_channel_option: OptionButton
var settings_status_label: Label
var current_version_label: Label
var update_channel_label: Label
var update_readiness_label: Label
var check_updates_button: Button
var install_update_button: Button
var chat_input: TextEdit
var send_chat_button: Button
var voice_chat_button: Button
var chat_transcript: ScrollContainer
var chat_messages: VBoxContainer
var chat_status: Label
var offline_bot_status_label: Label
var resource_cpu_label: Label
var resource_memory_label: Label
var resource_status_label: Label
var theme_preset_option: OptionButton
var application_window_has_opened := false
var chat_stream_rows: Dictionary = {}
var chat_message_sequence := 0


func bind_window(
	target_window: Window,
	target_tabs: TabContainer,
	target_show_bubbles: CheckButton = null,
	target_update_channel: OptionButton = null,
	target_settings_status: Label = null,
	target_current_version: Label = null,
	target_update_channel_label: Label = null,
	target_update_readiness: Label = null,
	target_check_updates: Button = null,
	target_chat_input: TextEdit = null,
	target_send_chat: Button = null,
	target_chat_transcript: ScrollContainer = null,
	target_chat_messages: VBoxContainer = null,
	target_chat_status: Label = null,
	target_voice_chat: Button = null,
	target_offline_presence: CheckButton = null,
	target_install_update: Button = null,
	target_offline_bot_status: Label = null,
	target_resource_cpu: Label = null,
	target_resource_memory: Label = null,
	target_resource_status: Label = null,
	target_theme_preset: OptionButton = null
) -> void:
	application_window = target_window
	chat_window = application_window.call("get_chat_window") as Window if application_window.has_method("get_chat_window") else null
	tabs = target_tabs
	show_bubbles_toggle = target_show_bubbles
	update_channel_option = target_update_channel
	settings_status_label = target_settings_status
	current_version_label = target_current_version
	update_channel_label = target_update_channel_label
	update_readiness_label = target_update_readiness
	check_updates_button = target_check_updates
	chat_input = target_chat_input
	send_chat_button = target_send_chat
	chat_transcript = target_chat_transcript
	chat_messages = target_chat_messages
	chat_status = target_chat_status
	voice_chat_button = target_voice_chat
	offline_presence_toggle = target_offline_presence
	install_update_button = target_install_update
	offline_bot_status_label = target_offline_bot_status
	resource_cpu_label = target_resource_cpu
	resource_memory_label = target_resource_memory
	resource_status_label = target_resource_status
	theme_preset_option = target_theme_preset
	_configure_update_channels()
	_configure_bubble_toggle()
	_configure_presence_toggle()
	_configure_theme_presets()
	_sync_settings_controls()
	if is_instance_valid(send_chat_button) and not send_chat_button.pressed.is_connected(_on_send_chat_pressed):
		send_chat_button.pressed.connect(_on_send_chat_pressed)
	if is_instance_valid(voice_chat_button) and not voice_chat_button.pressed.is_connected(_on_voice_chat_pressed):
		voice_chat_button.pressed.connect(_on_voice_chat_pressed)
	if is_instance_valid(chat_input) and not chat_input.gui_input.is_connected(_on_chat_input_gui_input):
		chat_input.gui_input.connect(_on_chat_input_gui_input)
	if is_instance_valid(offline_presence_toggle) and not offline_presence_toggle.toggled.is_connected(_on_offline_presence_toggled):
		offline_presence_toggle.toggled.connect(_on_offline_presence_toggled)
	if is_instance_valid(theme_preset_option) and not theme_preset_option.item_selected.is_connected(_on_theme_preset_selected):
		theme_preset_option.item_selected.connect(_on_theme_preset_selected)
	if application_window.has_signal("theme_preview_requested") and not application_window.is_connected("theme_preview_requested", Callable(self, "_on_shell_theme_preview_requested")):
		application_window.connect("theme_preview_requested", Callable(self, "_on_shell_theme_preview_requested"))
	if application_window.has_signal("language_preview_requested") and not application_window.is_connected("language_preview_requested", Callable(self, "_on_shell_language_preview_requested")):
		application_window.connect("language_preview_requested", Callable(self, "_on_shell_language_preview_requested"))
	if application_window.has_signal("text_scale_preview_requested") and not application_window.is_connected("text_scale_preview_requested", Callable(self, "_on_shell_text_scale_preview_requested")):
		application_window.connect("text_scale_preview_requested", Callable(self, "_on_shell_text_scale_preview_requested"))
	if application_window.has_signal("offline_presence_changed") and not application_window.is_connected("offline_presence_changed", Callable(self, "_on_shell_offline_presence_changed")):
		application_window.connect("offline_presence_changed", Callable(self, "_on_shell_offline_presence_changed"))
	if application_window.has_signal("ai_settings_save_requested") and not application_window.is_connected("ai_settings_save_requested", Callable(self, "_on_shell_ai_settings_save_requested")):
		application_window.connect("ai_settings_save_requested", Callable(self, "_on_shell_ai_settings_save_requested"))
	if application_window.has_signal("ai_connection_test_requested") and not application_window.is_connected("ai_connection_test_requested", Callable(self, "_on_shell_ai_connection_test_requested")):
		application_window.connect("ai_connection_test_requested", Callable(self, "_on_shell_ai_connection_test_requested"))
	if application_window.has_signal("provider_credential_save_requested") and not application_window.is_connected("provider_credential_save_requested", Callable(self, "_on_shell_provider_credential_save_requested")):
		application_window.connect("provider_credential_save_requested", Callable(self, "_on_shell_provider_credential_save_requested"))
	if application_window.has_signal("tts_test_requested") and not application_window.is_connected("tts_test_requested", Callable(self, "_on_shell_tts_test_requested")):
		application_window.connect("tts_test_requested", Callable(self, "_on_shell_tts_test_requested"))
	var theme_service := _theme_service()
	if is_instance_valid(theme_service):
		theme_service.register_window(application_window)
		if is_instance_valid(chat_window):
			theme_service.register_window(chat_window)
	var localization_service := _localization_service()
	if is_instance_valid(localization_service):
		localization_service.register_window(application_window)
		if is_instance_valid(chat_window):
			localization_service.register_window(chat_window)
	_sync_install_update_button()
	_sync_ai_settings_surface()


func start() -> void:
	event_bus.subscribe(&"application_window.open_requested", Callable(self, "_on_open"))
	event_bus.subscribe(&"application_window.close_requested", Callable(self, "_on_close"))
	event_bus.subscribe(&"chat_window.open_requested", Callable(self, "_on_chat_open"))
	event_bus.subscribe(&"chat_window.close_requested", Callable(self, "_on_chat_close"))
	event_bus.subscribe(&"update.check_finished", Callable(self, "_on_update_check_finished"))
	event_bus.subscribe(&"update.status_changed", Callable(self, "_on_update_status_changed"))
	event_bus.subscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor_updated"))
	event_bus.subscribe(&"theme.changed", Callable(self, "_on_theme_changed"))
	event_bus.subscribe(&"language.changed", Callable(self, "_on_language_changed"))
	event_bus.subscribe(&"ai.thinking_started", Callable(self, "_on_ai_thinking_started"))
	event_bus.subscribe(&"ai.thinking_finished", Callable(self, "_on_ai_thinking_finished"))
	event_bus.subscribe(&"ai.provider_status_changed", Callable(self, "_on_ai_provider_status_changed"))
	event_bus.subscribe(&"ai.connection_test_completed", Callable(self, "_on_ai_connection_test_completed"))
	event_bus.subscribe(&"chat.assistant_stream_started", Callable(self, "_on_chat_assistant_stream_started"))
	event_bus.subscribe(&"chat.assistant_stream_delta", Callable(self, "_on_chat_assistant_stream_delta"))
	event_bus.subscribe(&"chat.assistant_message_received", Callable(self, "_on_chat_assistant_message_received"))
	event_bus.subscribe(&"chat.response_failed", Callable(self, "_on_chat_response_failed"))
	_sync_theme()
	_sync_startup_registration()
	_sync_ai_provider_status()
	if is_instance_valid(context) and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)


func stop() -> void:
	event_bus.unsubscribe(&"application_window.open_requested", Callable(self, "_on_open"))
	event_bus.unsubscribe(&"application_window.close_requested", Callable(self, "_on_close"))
	event_bus.unsubscribe(&"chat_window.open_requested", Callable(self, "_on_chat_open"))
	event_bus.unsubscribe(&"chat_window.close_requested", Callable(self, "_on_chat_close"))
	event_bus.unsubscribe(&"update.check_finished", Callable(self, "_on_update_check_finished"))
	event_bus.unsubscribe(&"update.status_changed", Callable(self, "_on_update_status_changed"))
	event_bus.unsubscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor_updated"))
	event_bus.unsubscribe(&"theme.changed", Callable(self, "_on_theme_changed"))
	event_bus.unsubscribe(&"language.changed", Callable(self, "_on_language_changed"))
	event_bus.unsubscribe(&"ai.thinking_started", Callable(self, "_on_ai_thinking_started"))
	event_bus.unsubscribe(&"ai.thinking_finished", Callable(self, "_on_ai_thinking_finished"))
	event_bus.unsubscribe(&"ai.provider_status_changed", Callable(self, "_on_ai_provider_status_changed"))
	event_bus.unsubscribe(&"ai.connection_test_completed", Callable(self, "_on_ai_connection_test_completed"))
	event_bus.unsubscribe(&"chat.assistant_stream_started", Callable(self, "_on_chat_assistant_stream_started"))
	event_bus.unsubscribe(&"chat.assistant_stream_delta", Callable(self, "_on_chat_assistant_stream_delta"))
	event_bus.unsubscribe(&"chat.assistant_message_received", Callable(self, "_on_chat_assistant_message_received"))
	event_bus.unsubscribe(&"chat.response_failed", Callable(self, "_on_chat_response_failed"))
	chat_stream_rows.clear()
	if is_instance_valid(context) and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)


func _on_chat_open(_payload: Dictionary = {}) -> void:
	if _try_open_desktop_shell(&"chat"):
		return
	if is_instance_valid(application_window) and application_window.has_method("show_chat_window"):
		application_window.call("show_chat_window")
	elif is_instance_valid(chat_window):
		chat_window.show()
		chat_window.grab_focus()


func _on_chat_close(_payload: Dictionary = {}) -> void:
	if is_instance_valid(application_window) and application_window.has_method("hide_chat_window"):
		application_window.call("hide_chat_window")
	elif is_instance_valid(chat_window):
		chat_window.hide()


func _on_shell_offline_presence_changed(enabled: bool) -> void:
	_on_offline_presence_toggled(enabled)


func _on_shell_theme_preview_requested(theme_name: String) -> void:
	var theme_service := _theme_service()
	if is_instance_valid(theme_service):
		theme_service.select_theme(theme_name)
	# Theme cards already communicate the preview state visually. Keeping a
	# persistent footer sentence made the Control Center look diagnostic rather
	# than product-ready, so reserve the status line for save/error feedback.
	_set_settings_status("")


func _on_shell_language_preview_requested(locale: String) -> void:
	var localization_service := _localization_service()
	if is_instance_valid(localization_service):
		localization_service.select_locale(locale)
	_set_settings_status("")


func _on_shell_text_scale_preview_requested(scale: float) -> void:
	var theme_service := _theme_service()
	if is_instance_valid(theme_service) and theme_service.has_method("preview_text_scale"):
		theme_service.call("preview_text_scale", scale)
	_set_settings_status("")


func _on_shell_ai_settings_save_requested(values: Dictionary) -> void:
	if not is_instance_valid(services) or not is_instance_valid(services.settings_service):
		_set_ai_surface_status({"ok": false, "message": _localized_text("ai.save_failed", "Could not save AI & Voice settings.")})
		return
	var provider_id := str(values.get("ai_provider_id", "offline")).strip_edges().to_lower()
	if provider_id in ["ollama", "openai-compatible"]:
		if str(values.get("ai_base_url", "")).strip_edges().is_empty() or str(values.get("ai_model", "")).strip_edges().is_empty():
			_set_ai_surface_status({
				"ok": false,
				"provider_id": provider_id,
				"message": "Ollama Base URL and model are required." if provider_id == "ollama" else _localized_text("ai.cloud_config_required", "OpenAI-compatible Base URL and model are required."),
			})
			return
	if provider_id == "openai-compatible":
		if not str(values.get("ai_base_url", "")).strip_edges().to_lower().begins_with("https://"):
			_set_ai_surface_status({"ok": false, "provider_id": provider_id, "message": _localized_text("ai.cloud_https_required", "OpenAI-compatible cloud Base URL must use HTTPS.")})
			return
		var has_cloud_key: bool = is_instance_valid(services.credential_service) \
			and services.credential_service.has_method("present") \
			and bool(services.credential_service.call("present", "openai-compatible"))
		if not has_cloud_key:
			_set_ai_surface_status({"ok": false, "provider_id": provider_id, "message": _localized_text("ai.credential.missing_for_save", "Save the cloud API key securely before enabling this provider.")})
			return
	var saved: bool = services.settings_service.save_settings(values)
	if saved and is_instance_valid(services.ai_service) and services.ai_service.has_method("reload_provider"):
		services.ai_service.call("reload_provider")
	_sync_ai_settings_surface()
	_set_ai_surface_status({
		"ok": saved,
		"provider_id": provider_id,
		"message": _localized_text("ai.saved", "AI & Voice settings saved.") if saved else _localized_text("ai.save_failed", "Could not save AI & Voice settings."),
	})


func _on_shell_ai_connection_test_requested(values: Dictionary) -> void:
	if not is_instance_valid(services) or not is_instance_valid(services.ai_service) or not services.ai_service.has_method("test_connection"):
		_set_ai_surface_status({"ok": false, "message": "AI connection test is unavailable."})
		return
	services.ai_service.call("test_connection", values)


func _on_shell_provider_credential_save_requested(provider_id: String, credential: String) -> void:
	var clean_id := provider_id.strip_edges().to_lower()
	var is_gemini := clean_id == "gemini-cloud"
	var required_key := "voice.credential.required" if is_gemini else "ai.credential.required"
	var required_fallback := "Enter a Gemini API key first." if is_gemini else "Enter a cloud API key first."
	var failed_key := "voice.credential.save_failed" if is_gemini else "ai.credential.save_failed"
	var failed_fallback := "Could not save the Gemini API key to the secure OS credential store." if is_gemini else "Could not save the cloud API key to the secure OS credential store."
	var saved_key := "voice.credential.saved" if is_gemini else "ai.credential.saved"
	var saved_fallback := "Gemini API key saved securely. Use Test voice with Automatic to verify it." if is_gemini else "Cloud API key saved securely. Save provider settings, then send a chat message to verify the endpoint."
	if clean_id.is_empty() or credential.strip_edges().is_empty():
		_sync_provider_credential_status(clean_id, false, _localized_text(required_key, required_fallback))
		return
	if not is_instance_valid(services) or not is_instance_valid(services.credential_service) or not services.credential_service.has_method("store"):
		_sync_provider_credential_status(clean_id, false, _localized_text(failed_key, failed_fallback))
		return
	# Do not place the secret in context/settings/events. It crosses only this
	# synchronous UI -> CredentialService -> native keystore call.
	var result: Dictionary = services.credential_service.call("store", clean_id, credential)
	var saved := bool(result.get("ok", false))
	var present := saved
	if services.credential_service.has_method("present"):
		present = bool(services.credential_service.call("present", clean_id))
	_sync_provider_credential_status(
		clean_id,
		present,
		_localized_text(saved_key, saved_fallback) if saved else _localized_text(failed_key, failed_fallback)
	)


func _on_shell_tts_test_requested(text: String) -> void:
	var preview := text.strip_edges()
	if preview.is_empty() or not is_instance_valid(event_bus):
		return
	var snapshot: Dictionary = {}
	if is_instance_valid(application_window) and application_window.has_method("get_ai_settings_snapshot"):
		snapshot = application_window.call("get_ai_settings_snapshot")
	var message_id := "tts_test_%d" % Time.get_ticks_msec()
	event_bus.publish(&"bubble.requested", {
		"message_id": message_id,
		"text": preview,
		"duration": 6.0,
		"durationMs": 6000,
		"source": "ai-voice-test",
	})
	event_bus.publish(&"tts.requested", {
		"message_id": message_id,
		"chunk_index": 0,
		"text": preview,
		"voice": str(snapshot.get("tts_voice", "neutral")),
		"provider_id": str(snapshot.get("tts_provider_id", "auto")),
		"final": true,
		"source": "ai-voice-test",
	})


func _on_open(payload: Dictionary) -> void:
	var requested_page := str(payload.get("page", "settings")).to_lower()
	var shell_view: StringName = &"home" if requested_page == "home" else (&"updates" if requested_page == "updates" else &"settings")
	if _try_open_desktop_shell(shell_view):
		return
	if not is_instance_valid(application_window):
		return
	_select_page(requested_page)
	_sync_settings_controls()
	_sync_ai_settings_surface()
	# Center only the first time. Repeated Open OCP requests must preserve the
	# user's restored/maximized geometry; re-centering a hidden full-monitor
	# borderless window can fight the title-bar state and make reopen flaky.
	if not application_window_has_opened:
		_center_on_current_monitor()
		application_window_has_opened = true
	application_window.show()
	application_window.grab_focus()


func _try_open_desktop_shell(view: StringName) -> bool:
	# Keep the optional Electron launcher out of the Runtime startup service
	# graph.  The companion must boot exactly as before; only a user menu action
	# with explicit opt-in may load and invoke this presentation helper.
	if OS.get_environment("OCP_DESKTOP_SHELL_ENABLED") != "1":
		return false
	var launcher_script := load("res://scripts/runtime_v3/services/desktop_shell_launcher.gd")
	if launcher_script == null:
		return false
	var launcher: Variant = launcher_script.new()
	var opened: bool = launcher != null and launcher.has_method("try_open") and bool(launcher.call("try_open", view))
	if launcher is Object and is_instance_valid(launcher):
		launcher.free()
	return opened


func _on_close(_payload: Dictionary = {}) -> void:
	if is_instance_valid(application_window):
		application_window.hide()


func _select_page(page: String) -> void:
	var requested := page.to_lower()
	if is_instance_valid(application_window) and application_window.has_method("select_control_page"):
		application_window.call("select_control_page", requested, false)
		return
	if not is_instance_valid(tabs):
		return
	for index in range(tabs.get_tab_count()):
		if tabs.get_tab_title(index).to_lower() == requested:
			tabs.current_tab = index
			return
	tabs.current_tab = 0


func save_settings() -> bool:
	if not is_instance_valid(services) or not is_instance_valid(services.settings_service):
		_set_settings_status("Settings service unavailable")
		return false
	var channel := _selected_update_channel()
	var values := {
		"show_bubbles": show_bubbles_toggle.button_pressed if is_instance_valid(show_bubbles_toggle) else true,
		"offline_presence_enabled": offline_presence_toggle.button_pressed if is_instance_valid(offline_presence_toggle) else true,
		"update_channel": channel,
	}
	if is_instance_valid(application_window) and application_window.has_method("get_settings_snapshot"):
		var shell_values: Dictionary = application_window.call("get_settings_snapshot")
		values.merge(shell_values, true)
	elif is_instance_valid(theme_preset_option):
		values["theme_preset"] = _selected_theme_preset()

	var desired_startup := bool(values.get("start_with_windows", false))
	var previous_startup := bool(context.settings.get("start_with_windows", false)) if is_instance_valid(context) else false
	var startup_changed := desired_startup != previous_startup
	var startup_service := _startup_registration_service()
	if startup_changed:
		if not is_instance_valid(startup_service) or not bool(startup_service.call("set_enabled", desired_startup)):
			var detail := str(startup_service.get("last_error")) if is_instance_valid(startup_service) else "Startup registration service unavailable"
			_set_settings_status("Start with Windows was not changed: %s" % detail)
			if is_instance_valid(application_window) and application_window.has_method("sync_settings"):
				application_window.call("sync_settings", context.settings, context.runtime_config)
			return false

	var saved: bool = services.settings_service.save_settings(values)
	if not saved and startup_changed and is_instance_valid(startup_service):
		startup_service.call("set_enabled", previous_startup)
	if saved:
		var click_enabled := bool(values.get("click_through_enabled", context.runtime_config.get("click_through_enabled", true)))
		if is_instance_valid(context) and context.has_method("update_runtime_config"):
			context.update_runtime_config({"click_through_enabled": click_enabled})
		if is_instance_valid(event_bus):
			event_bus.publish(&"click_through.refresh_requested", {})
		var theme_service := _theme_service()
		if is_instance_valid(theme_service):
			theme_service.select_theme(str(values.get("theme_preset", "solid")))
	_set_settings_status(
		_localized_text("settings.saved", "Settings saved")
		if saved
		else _localized_text("settings.save_failed", "Unable to save settings")
	)
	_sync_update_summary(channel)
	return saved


func check_update_readiness() -> void:
	if is_instance_valid(services) and is_instance_valid(services.update_service):
		var result: Dictionary = services.update_service.request_check()
		if is_instance_valid(update_readiness_label):
			update_readiness_label.text = _localized_update_message(str(result.get("message", "Update check unavailable")))
		_sync_install_update_button()
		return
	var manifest_url := OS.get_environment("OCP_UPDATE_MANIFEST_URL")
	var key_id := OS.get_environment("OCP_UPDATE_KEY_ID")
	var public_key := OS.get_environment("OCP_UPDATE_PUBLIC_KEY_B64")
	if manifest_url.is_empty() or key_id.is_empty() or public_key.is_empty():
		_sync_update_summary(_selected_update_channel())
		if is_instance_valid(update_readiness_label):
			update_readiness_label.text = _localized_text(
				"update.status.config_incomplete_detail",
				"Update check not run: signed update configuration is incomplete.\nNo network request or download was performed."
			)
		return
	if is_instance_valid(update_readiness_label):
			update_readiness_label.text = _localized_text(
			"update.status.config_ready",
			"Signed update configuration is ready.\nThe Rust updater adapter is ready to report the final result."
		)


func _on_update_check_finished(payload: Dictionary) -> void:
	if is_instance_valid(update_readiness_label):
		update_readiness_label.text = _localized_update_message(str(payload.get("message", "Update check finished")))
	_sync_install_update_button()


func _on_update_status_changed(payload: Dictionary) -> void:
	if is_instance_valid(update_readiness_label):
		update_readiness_label.text = _localized_update_message(str(payload.get("message", "Update status changed")))
	_sync_install_update_button()


func _on_install_update_pressed() -> void:
	if not is_instance_valid(services) or not is_instance_valid(services.update_service):
		return
	var result: Dictionary = services.update_service.request_apply()
	if is_instance_valid(update_readiness_label):
		update_readiness_label.text = _localized_update_message(str(result.get("message", "Update apply unavailable")))
	_sync_install_update_button()
	if bool(result.get("ok", false)):
		# The external helper waits for this process and owns the restart/rollback.
		# Request the normal native shutdown only after the helper has been spawned.
		event_bus.publish(&"window.exit_requested", {"source": "update-apply"})


func _sync_install_update_button() -> void:
	if not is_instance_valid(install_update_button):
		return
	var available: bool = is_instance_valid(services) \
		and is_instance_valid(services.update_service) \
		and services.update_service.has_method("can_apply") \
		and bool(services.update_service.can_apply())
	install_update_button.disabled = not available
	install_update_button.text = (
		_localized_text("update.install_ready", "Install staged update")
		if available
		else _localized_text("update.install", "Install staged update (check first)")
	)


func _on_ai_thinking_started(_payload: Dictionary = {}) -> void:
	_set_chat_typing_visible(true)
	# Keep the companion visibly engaged for the entire LLM wait, before any
	# TTS/audio exists. The ChatSessionOrchestrator also emits this event with
	# animation.requested=think, so this is only the UI-side waiting indicator.


func _on_ai_thinking_finished(_payload: Dictionary = {}) -> void:
	_set_chat_typing_visible(false)


func _set_chat_typing_visible(visible: bool) -> void:
	if not is_instance_valid(chat_messages):
		return
	var typing := chat_messages.get_node_or_null("TypingIndicator") as Label
	if not is_instance_valid(typing):
		return

	var old_tween: Tween = null
	if typing.has_meta("_typing_tween"):
		old_tween = typing.get_meta("_typing_tween") as Tween
	if old_tween != null and old_tween.is_valid():
		old_tween.kill()
	if typing.has_meta("_typing_tween"):
		typing.remove_meta("_typing_tween")

	typing.visible = visible
	if not visible:
		typing.text = _localized_text("chat.typing", "Thinking")
		typing.modulate.a = 1.0
		return

	typing.text = _localized_text("chat.typing", "Thinking") + "  ···"
	typing.modulate.a = 1.0
	# Lightweight UI animation: no polling loop and no extra scene nodes.
	# It continues until ai.thinking_finished, which is emitted when the LLM
	# response is complete (success or failure).
	var tween := create_tween().set_loops()
	tween.tween_property(typing, "modulate:a", 0.45, 0.55)
	tween.tween_property(typing, "modulate:a", 1.0, 0.55)
	typing.set_meta("_typing_tween", tween)
	if visible and is_instance_valid(chat_transcript):
		call_deferred("_scroll_chat_to_bottom")


func _scroll_chat_to_bottom() -> void:
	if not is_instance_valid(chat_transcript):
		return
	var scroll_bar := chat_transcript.get_v_scroll_bar()
	if is_instance_valid(scroll_bar):
		chat_transcript.scroll_vertical = int(scroll_bar.max_value)


func _on_send_chat_pressed() -> void:
	_submit_chat(chat_input.text if is_instance_valid(chat_input) else "")


func _on_chat_input_gui_input(event: InputEvent) -> void:
	# Enter is the familiar AI-chat send gesture. Ctrl+Enter is intentionally
	# not intercepted, so TextEdit inserts a newline using its native behavior.
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ENTER and not key_event.ctrl_pressed:
		_submit_chat(chat_input.text if is_instance_valid(chat_input) else "")
		get_viewport().set_input_as_handled()


func _submit_chat(text: String) -> void:
	var message := text.strip_edges()
	if message.is_empty():
		return
	# Keep this UI local and truthful until an approved AI transport is bound.
	var safe_message := message.replace("[", "(").replace("]", ")")
	if is_instance_valid(chat_messages):
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.alignment = BoxContainer.ALIGNMENT_END
		row.custom_minimum_size = Vector2(0, 48)

		var stack := VBoxContainer.new()
		stack.size_flags_horizontal = Control.SIZE_SHRINK_END
		stack.alignment = BoxContainer.ALIGNMENT_END
		stack.add_theme_constant_override("separation", 4)

		var card := PanelContainer.new()
		var bubble_width := _message_bubble_width(safe_message)
		card.custom_minimum_size = Vector2(bubble_width, 0)
		card.size_flags_horizontal = Control.SIZE_SHRINK_END
		card.add_theme_stylebox_override("panel", _user_card_style())
		var margins := MarginContainer.new()
		margins.add_theme_constant_override("margin_left", 14)
		margins.add_theme_constant_override("margin_top", 9)
		margins.add_theme_constant_override("margin_right", 14)
		margins.add_theme_constant_override("margin_bottom", 9)
		var label := Label.new()
		label.name = "UserMessageText"
		label.text = safe_message
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(maxf(88.0, bubble_width - 28.0), 0)
		label.add_theme_color_override("font_color", Color("#e4efff"))
		var text_scale := float(context.settings.get("text_scale", 1.15)) if is_instance_valid(context) else 1.15
		label.add_theme_font_size_override("font_size", maxi(14, int(round(16.0 * text_scale))))
		margins.add_child(label)
		card.add_child(margins)
		stack.add_child(card)

		var copy_button := Button.new()
		copy_button.name = "CopyButton"
		copy_button.text = _localized_text("chat.copy", "Copy")
		copy_button.tooltip_text = _localized_text("chat.copy_user_tooltip", "Copy message")
		copy_button.flat = true
		copy_button.focus_mode = Control.FOCUS_NONE
		copy_button.custom_minimum_size = Vector2(72.0, 24.0)
		copy_button.add_theme_font_size_override("font_size", maxi(10, int(round(11.0 * text_scale))))
		copy_button.add_theme_color_override("font_color", Color("#8ecbff"))
		copy_button.add_theme_color_override("font_hover_color", Color("#ffffff"))
		copy_button.pressed.connect(Callable(self, "_copy_chat_text").bind(label))
		stack.add_child(copy_button)

		var timestamp := Label.new()
		timestamp.name = "MessageTimestamp"
		timestamp.text = Time.get_time_string_from_system().substr(0, 5)
		timestamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		timestamp.add_theme_font_size_override("font_size", maxi(10, int(round(11.0 * text_scale))))
		timestamp.add_theme_color_override("font_color", Color("#7898bd"))
		stack.add_child(timestamp)

		row.add_child(stack)
		chat_messages.add_child(row)
		call_deferred("_scroll_chat_to_bottom")
	chat_message_sequence += 1
	var message_id := "msg_%d_%d" % [Time.get_ticks_msec(), chat_message_sequence]
	if is_instance_valid(chat_input):
		chat_input.clear()
	if is_instance_valid(event_bus):
		event_bus.publish(&"ai.prompt_requested", {
			"message_id": message_id,
			"prompt": message,
			"source": "chat-window",
		})


func _on_chat_assistant_stream_started(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	if message_id.is_empty() or not is_instance_valid(chat_messages):
		return
	var existing: Variant = chat_stream_rows.get(message_id, null)
	if existing is Node and is_instance_valid(existing):
		return
	_append_assistant_message("", message_id, false)
	var row := chat_messages.get_node_or_null("AssistantMessage_%s" % message_id) as HBoxContainer
	if not is_instance_valid(row):
		return
	chat_stream_rows[message_id] = row
	var text_label := row.find_child("AssistantMessageText", true, false) as Label
	if is_instance_valid(text_label):
		text_label.text = ""
	var timestamp := row.find_child("MessageTimestamp", true, false) as Label
	if is_instance_valid(timestamp):
		timestamp.visible = false
	var copy_button := row.find_child("CopyButton", true, false) as Button
	if is_instance_valid(copy_button):
		copy_button.visible = false
	# Keep the thinking indicator visible until the first actual text delta.
	# This avoids an empty assistant bubble flashing on screen while a provider
	# has only announced that streaming has started.
	call_deferred("_scroll_chat_to_bottom")


func _on_chat_assistant_stream_delta(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	var full_text := str(payload.get("text", ""))
	if message_id.is_empty() or full_text.is_empty():
		return
	var typing := chat_messages.get_node_or_null("TypingIndicator") if is_instance_valid(chat_messages) else null
	if is_instance_valid(typing):
		typing.visible = false
	var should_follow := _chat_is_near_bottom()
	var row: HBoxContainer = chat_stream_rows.get(message_id, null) as HBoxContainer
	if not is_instance_valid(row):
		_on_chat_assistant_stream_started(payload)
		row = chat_stream_rows.get(message_id, null) as HBoxContainer
	if not is_instance_valid(row):
		return
	var text_label := row.find_child("AssistantMessageText", true, false) as Label
	var card := row.find_child("AssistantMessageCard", true, false) as PanelContainer
	if is_instance_valid(text_label):
		text_label.text = full_text
	var bubble_width := clampf(_message_bubble_width(full_text) + 40.0, 220.0, 500.0)
	if is_instance_valid(card):
		card.custom_minimum_size.x = bubble_width
	if is_instance_valid(text_label):
		text_label.custom_minimum_size.x = maxf(180.0, bubble_width - 28.0)
	if should_follow:
		call_deferred("_scroll_chat_to_bottom")


func _finalize_streamed_assistant_message(message_id: String, text: String, is_error: bool = false) -> bool:
	var row: HBoxContainer = chat_stream_rows.get(message_id, null) as HBoxContainer
	if not is_instance_valid(row):
		return false
	var text_label := row.find_child("AssistantMessageText", true, false) as Label
	var card := row.find_child("AssistantMessageCard", true, false) as PanelContainer
	var timestamp := row.find_child("MessageTimestamp", true, false) as Label
	if is_instance_valid(text_label):
		text_label.text = text
		text_label.add_theme_color_override("font_color", Color("#e4efff") if not is_error else Color("#ffc6c6"))
	if is_instance_valid(card):
		card.add_theme_stylebox_override("panel", _assistant_card_style(is_error))
	if is_instance_valid(timestamp):
		timestamp.text = Time.get_time_string_from_system().substr(0, 5)
		timestamp.visible = true
	var copy_button := row.find_child("CopyButton", true, false) as Button
	if is_instance_valid(copy_button):
		copy_button.visible = not is_error
	chat_stream_rows.erase(message_id)
	call_deferred("_scroll_chat_to_bottom")
	return true


func _chat_is_near_bottom() -> bool:
	if not is_instance_valid(chat_transcript):
		return true
	var scroll_bar := chat_transcript.get_v_scroll_bar()
	if not is_instance_valid(scroll_bar):
		return true
	return (scroll_bar.max_value - scroll_bar.value) <= 96.0


func _on_chat_assistant_message_received(payload: Dictionary) -> void:
	var text := str(payload.get("text", "")).strip_edges()
	if text.is_empty():
		return
	var message_id := str(payload.get("message_id", ""))
	if not message_id.is_empty() and _finalize_streamed_assistant_message(message_id, text, false):
		return
	_append_assistant_message(text, message_id, false)


func _on_chat_response_failed(payload: Dictionary) -> void:
	var typing := chat_messages.get_node_or_null("TypingIndicator") if is_instance_valid(chat_messages) else null
	if is_instance_valid(typing):
		typing.visible = false
	var error_text := str(payload.get("error", "AI response failed")).strip_edges()
	if error_text.is_empty():
		error_text = "AI response failed"
	var message_id := str(payload.get("message_id", ""))
	if not message_id.is_empty() and _finalize_streamed_assistant_message(message_id, error_text, true):
		return
	_append_assistant_message(error_text, message_id, true)


func _append_assistant_message(text: String, message_id: String, is_error: bool) -> void:
	if not is_instance_valid(chat_messages):
		return
	var row := HBoxContainer.new()
	row.name = "AssistantMessage_%s" % (message_id if not message_id.is_empty() else str(chat_message_sequence))
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 10)

	var avatar_shell := PanelContainer.new()
	avatar_shell.custom_minimum_size = Vector2(38, 38)
	avatar_shell.add_theme_stylebox_override("panel", _assistant_avatar_style())
	var avatar_center := CenterContainer.new()
	avatar_shell.add_child(avatar_center)
	var avatar := TextureRect.new()
	avatar.custom_minimum_size = Vector2(30, 30)
	avatar.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var source_avatar := chat_window.find_child("AssistantAvatarTexture", true, false) as TextureRect if is_instance_valid(chat_window) else null
	if is_instance_valid(source_avatar):
		avatar.texture = source_avatar.texture
	avatar_center.add_child(avatar)
	row.add_child(avatar_shell)

	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stack.add_theme_constant_override("separation", 4)
	var card := PanelContainer.new()
	card.name = "AssistantMessageCard"
	var bubble_width := clampf(_message_bubble_width(text) + 40.0, 220.0, 500.0)
	card.custom_minimum_size = Vector2(bubble_width, 0)
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	card.add_theme_stylebox_override("panel", _assistant_card_style(is_error))
	var margins := MarginContainer.new()
	margins.add_theme_constant_override("margin_left", 14)
	margins.add_theme_constant_override("margin_top", 10)
	margins.add_theme_constant_override("margin_right", 14)
	margins.add_theme_constant_override("margin_bottom", 10)
	var label := Label.new()
	label.name = "AssistantMessageText"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(maxf(180.0, bubble_width - 28.0), 0)
	var text_scale := float(context.settings.get("text_scale", 1.15)) if is_instance_valid(context) else 1.15
	label.add_theme_font_size_override("font_size", maxi(14, int(round(16.0 * text_scale))))
	label.add_theme_color_override("font_color", Color("#e4efff") if not is_error else Color("#ffc6c6"))
	margins.add_child(label)
	card.add_child(margins)
	stack.add_child(card)

	var meta_row := HBoxContainer.new()
	meta_row.name = "MessageMeta"
	meta_row.add_theme_constant_override("separation", 8)
	var timestamp := Label.new()
	timestamp.name = "MessageTimestamp"
	timestamp.text = Time.get_time_string_from_system().substr(0, 5)
	timestamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	timestamp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timestamp.add_theme_font_size_override("font_size", maxi(10, int(round(11.0 * text_scale))))
	timestamp.add_theme_color_override("font_color", Color("#7898bd"))
	meta_row.add_child(timestamp)
	var copy_button := Button.new()
	copy_button.name = "CopyButton"
	copy_button.text = _localized_text("chat.copy", "Copy")
	copy_button.tooltip_text = _localized_text("chat.copy_tooltip", "Copy response text")
	copy_button.flat = true
	copy_button.focus_mode = Control.FOCUS_NONE
	copy_button.custom_minimum_size = Vector2(72.0, 24.0)
	copy_button.add_theme_font_size_override("font_size", maxi(10, int(round(11.0 * text_scale))))
	copy_button.add_theme_color_override("font_color", Color("#8ecbff"))
	copy_button.add_theme_color_override("font_hover_color", Color("#ffffff"))
	copy_button.pressed.connect(Callable(self, "_copy_chat_text").bind(label))
	meta_row.add_child(copy_button)
	stack.add_child(meta_row)
	row.add_child(stack)
	chat_messages.add_child(row)

	var typing := chat_messages.get_node_or_null("TypingIndicator")
	if is_instance_valid(typing):
		chat_messages.move_child(typing, chat_messages.get_child_count() - 1)
	call_deferred("_scroll_chat_to_bottom")


func _copy_chat_text(label: Label) -> void:
	if not is_instance_valid(label):
		return
	var text := label.text.strip_edges()
	if text.is_empty():
		return
	DisplayServer.clipboard_set(text)
	var button := label.get_parent().get_parent().get_parent().find_child("CopyButton", true, false) as Button
	if is_instance_valid(button):
		var original := button.text
		button.text = _localized_text("chat.copied", "Copied")
		get_tree().create_timer(1.0).timeout.connect(func() -> void:
			if is_instance_valid(button):
				button.text = original
		)


func _assistant_card_style(is_error: bool = false) -> StyleBoxFlat:
	var surface := Color("#102642")
	var border := Color("#315d88")
	var accent := Color("#2f8cff")
	var theme_service := services.get_node_or_null("ThemeService") if is_instance_valid(services) else null
	if is_instance_valid(theme_service):
		var palette: Dictionary = theme_service.presets.get(theme_service.current_name, {})
		if not palette.is_empty():
			surface = Color(palette.get("surface", surface))
			border = Color(palette.get("border", border))
			accent = Color(palette.get("accent", accent))
	if is_error:
		accent = Color("#d96b75")
	var style := StyleBoxFlat.new()
	style.bg_color = Color(surface, 0.86)
	style.border_color = Color(accent if is_error else border, 0.54)
	style.set_border_width_all(1)
	style.corner_radius_top_left = 14
	style.corner_radius_top_right = 14
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 14
	style.shadow_color = Color(accent, 0.06)
	style.shadow_size = 2
	return style


func _assistant_avatar_style() -> StyleBoxFlat:
	var accent := Color("#2f8cff")
	var theme_service := services.get_node_or_null("ThemeService") if is_instance_valid(services) else null
	if is_instance_valid(theme_service):
		var palette: Dictionary = theme_service.presets.get(theme_service.current_name, {})
		if not palette.is_empty():
			accent = Color(palette.get("accent", accent))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.07, 0.15, 0.80)
	style.border_color = Color(accent, 0.66)
	style.set_border_width_all(1)
	style.corner_radius_top_left = 18
	style.corner_radius_top_right = 18
	style.corner_radius_bottom_left = 18
	style.corner_radius_bottom_right = 18
	return style


func _message_bubble_width(message: String) -> float:
	var max_line_chars := 1
	for line in message.split("\n"):
		max_line_chars = maxi(max_line_chars, line.length())
	var text_scale := float(context.settings.get("text_scale", 1.15)) if is_instance_valid(context) else 1.15
	var estimated := 30.0 + float(max_line_chars) * 7.8 * clampf(text_scale, 1.0, 1.8)
	return clampf(estimated, 108.0, 480.0)


func _user_card_style() -> StyleBoxFlat:
	var surface := Color("#24528d")
	var border := Color("#5d9be8")
	var accent := Color("#2f8cff")
	var theme_service := services.get_node_or_null("ThemeService") if is_instance_valid(services) else null
	if is_instance_valid(theme_service):
		var palette: Dictionary = theme_service.presets.get(theme_service.current_name, {})
		if not palette.is_empty():
			surface = Color(palette.get("surface_alt", surface))
			border = Color(palette.get("border", border))
			accent = Color(palette.get("accent", accent))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(surface.lerp(accent, 0.14), 0.90)
	style.border_color = Color(border, 0.68)
	style.set_border_width_all(1)
	style.corner_radius_top_left = 14
	style.corner_radius_top_right = 14
	style.corner_radius_bottom_left = 14
	style.corner_radius_bottom_right = 5
	style.shadow_color = Color(accent, 0.10)
	style.shadow_size = 3
	style.content_margin_left = 2
	style.content_margin_right = 2
	return style


func _on_voice_chat_pressed() -> void:
	if is_instance_valid(chat_status):
		chat_status.text = "Voice chat requested - audio input adapter is not configured"
	event_bus.publish(&"voice.input_requested", {"source": "chat-window"})


func _on_context_changed(section: StringName) -> void:
	if section == &"settings":
		_sync_settings_controls()
		_sync_offline_bot_status()
		_sync_ai_settings_surface()
	if section == &"runtime_config":
		_sync_resource_monitor()


func _on_resource_monitor_updated(payload: Dictionary) -> void:
	_render_resource_monitor(payload)


func _on_theme_changed(_payload: Dictionary = {}) -> void:
	# ThemeService owns cross-window application before publishing this event.
	_sync_theme()


func _on_language_changed(_payload: Dictionary = {}) -> void:
	_sync_update_summary(_selected_update_channel())
	_sync_ai_provider_status()


func _on_ai_provider_status_changed(payload: Dictionary = {}) -> void:
	_sync_ai_provider_status(payload)
	_sync_ai_settings_surface(payload)


func _on_ai_connection_test_completed(payload: Dictionary = {}) -> void:
	_set_ai_surface_status(payload)


func _sync_ai_settings_surface(status: Dictionary = {}) -> void:
	if not is_instance_valid(application_window) or not application_window.has_method("sync_ai_settings") or not is_instance_valid(context):
		return
	if status.is_empty() and is_instance_valid(services) and is_instance_valid(services.ai_service) and services.ai_service.has_method("provider_status"):
		status = services.ai_service.call("provider_status")
	application_window.call("sync_ai_settings", context.settings, status)
	var gemini_present := false
	var cloud_present := false
	if is_instance_valid(services) and is_instance_valid(services.credential_service) and services.credential_service.has_method("present"):
		gemini_present = bool(services.credential_service.call("present", "gemini-cloud"))
		cloud_present = bool(services.credential_service.call("present", "openai-compatible"))
	_sync_provider_credential_status("gemini-cloud", gemini_present)
	_sync_provider_credential_status("openai-compatible", cloud_present)


func _sync_provider_credential_status(provider_id: String, present: bool, message: String = "") -> void:
	if is_instance_valid(application_window) and application_window.has_method("sync_provider_credential_status"):
		application_window.call("sync_provider_credential_status", provider_id, present, message)


func _set_ai_surface_status(payload: Dictionary) -> void:
	if is_instance_valid(application_window) and application_window.has_method("set_ai_connection_status"):
		application_window.call("set_ai_connection_status", payload)


func _sync_ai_provider_status(status: Dictionary = {}) -> void:
	if status.is_empty() and is_instance_valid(services) and is_instance_valid(services.ai_service) and services.ai_service.has_method("provider_status"):
		status = services.ai_service.call("provider_status")
	if status.is_empty() or not is_instance_valid(chat_window):
		return
	var provider_id := str(status.get("provider_id", "offline")).to_lower()
	var configured := bool(status.get("configured", false))
	var display_name := str(status.get("display_name", provider_id.capitalize()))
	var model_option := chat_window.find_child("ChatModelOption", true, false) as OptionButton
	if is_instance_valid(model_option):
		if model_option.item_count == 0:
			model_option.add_item("")
		model_option.set_item_text(0, _localized_text("chat.profile_local", "Local") if provider_id == "offline" else display_name)
		model_option.select(0)
	var badge_label := chat_window.find_child("ChatConnectionBadgeLabel", true, false) as Label
	if is_instance_valid(badge_label):
		badge_label.text = (
			_localized_text("chat.connection_online", "Connected")
			if configured
			else _localized_text("chat.connection_offline", "Offline mode")
		)


func _sync_theme() -> void:
	if not is_instance_valid(theme_preset_option):
		return
	var selected := str(context.runtime_config.get("theme_preset", "solid"))
	for index in range(theme_preset_option.item_count):
		if theme_preset_option.get_item_text(index).to_lower() == selected:
			theme_preset_option.select(index)
			break


func _configure_theme_presets() -> void:
	if not is_instance_valid(theme_preset_option):
		return
	theme_preset_option.clear()
	for name in ["Solid", "Glass", "Liquid"]:
		theme_preset_option.add_item(name)


func _on_theme_preset_selected(index: int) -> void:
	var theme_service := _theme_service()
	if not is_instance_valid(theme_service):
		return
	var name := theme_preset_option.get_item_text(index).to_lower()
	theme_service.select_theme(name)
	_set_settings_status("Theme preset changed to %s. Save settings to keep this choice." % name.capitalize())


func _selected_theme_preset() -> String:
	if not is_instance_valid(theme_preset_option) or theme_preset_option.item_count == 0:
		return "solid"
	return theme_preset_option.get_item_text(theme_preset_option.selected).to_lower()


func _theme_service() -> Node:
	if not is_instance_valid(services):
		return null
	return services.get_node_or_null("ThemeService")


func _localization_service() -> Node:
	if not is_instance_valid(services):
		return null
	return services.get_node_or_null("LocalizationService")


func _localized_text(key: String, fallback: String) -> String:
	var localization_service := _localization_service()
	if is_instance_valid(localization_service) and localization_service.has_method("text"):
		return str(localization_service.call("text", key, fallback))
	return fallback


func _localized_textf(key: String, values: Dictionary, fallback: String) -> String:
	var localization_service := _localization_service()
	if is_instance_valid(localization_service) and localization_service.has_method("textf"):
		return str(localization_service.call("textf", key, values, fallback))
	var rendered := fallback
	for token in values.keys():
		rendered = rendered.replace("{%s}" % str(token), str(values[token]))
	return rendered


func _localized_update_message(message: String) -> String:
	var normalized := message.strip_edges().to_lower()
	match normalized:
		"signed update configuration is incomplete":
			return _localized_text("update.status.config_incomplete", "Signed update configuration is incomplete.")
		"rust updater executable is not installed":
			return _localized_text("update.status.updater_missing", "Rust updater executable is not installed.")
		"could not start rust updater":
			return _localized_text("update.status.updater_start_failed", "Could not start Rust updater.")
		"rust updater started; installation was not modified":
			return _localized_text("update.status.updater_started", "Rust updater started; installation was not modified.")
		"update check unavailable":
			return _localized_text("update.status.check_unavailable", "Update check unavailable.")
		"update check finished":
			return _localized_text("update.status.check_finished", "Update check finished.")
		"update status changed":
			return _localized_text("update.status.changed", "Update status changed.")
		"update apply unavailable":
			return _localized_text("update.status.apply_unavailable", "Update apply unavailable.")
	return message


func _startup_registration_service() -> Node:
	if not is_instance_valid(services):
		return null
	if services is RuntimeV3Services:
		return services.startup_registration_service
	return services.get_node_or_null("StartupRegistrationService")


func _sync_startup_registration() -> void:
	if not is_instance_valid(context):
		return
	var startup_service := _startup_registration_service()
	if not is_instance_valid(startup_service):
		return
	var enabled := bool(context.settings.get("start_with_windows", false))
	# Reconcile persisted intent with the per-user Windows Run key on startup.
	# This also upgrades settings saved by earlier UI-only builds into a real
	# startup registration without requiring the user to toggle it again.
	if not bool(startup_service.call("set_enabled", enabled)):
		push_warning("ApplicationWindowController: unable to reconcile Start with Windows: %s" % str(startup_service.get("last_error")))


func _sync_resource_monitor() -> void:
	if is_instance_valid(context):
		_render_resource_monitor(context.runtime_config.get("resource_monitor", {}))


func _render_resource_monitor(payload: Dictionary) -> void:
	if is_instance_valid(application_window) and application_window.has_method("set_resource_monitor"):
		application_window.call("set_resource_monitor", payload)
	if not is_instance_valid(resource_cpu_label):
		return
	if not bool(payload.get("available", false)):
		resource_cpu_label.text = "CPU  —"
		resource_memory_label.text = "Memory  —"
		resource_status_label.text = str(payload.get("message", "Resource telemetry unavailable"))
		resource_status_label.modulate = Color("#9aa6b8")
		return
	resource_cpu_label.text = "CPU  %d%%" % roundi(float(payload.get("cpu_percent", 0.0)))
	resource_memory_label.text = "System RAM  %d%%" % roundi(float(payload.get("memory_percent", 0.0)))
	var high := str(payload.get("pressure", "normal")) == "high"
	resource_status_label.text = "High resource usage" if high else "Normal resource usage"
	resource_status_label.modulate = Color("#ffbd66") if high else Color("#9fc4f3")


func _configure_update_channels() -> void:
	if not is_instance_valid(update_channel_option):
		return
	update_channel_option.clear()
	for channel in ["Stable", "Preview"]:
		update_channel_option.add_item(channel)
	var popup := update_channel_option.get_popup()
	if is_instance_valid(popup):
		popup.add_theme_font_size_override("font_size", 17)
		popup.add_theme_color_override("font_color", Color("#e5efff"))
		popup.add_theme_color_override("font_hover_color", Color("#ffffff"))
		popup.add_theme_stylebox_override("panel", _dropdown_panel_style())
		popup.add_theme_stylebox_override("hover", _dropdown_hover_style())


func _configure_bubble_toggle() -> void:
	_configure_toggle(show_bubbles_toggle)


func _configure_presence_toggle() -> void:
	_configure_toggle(offline_presence_toggle)


func _configure_toggle(toggle: CheckButton) -> void:
	if not is_instance_valid(toggle):
		return
	var on_texture := _toggle_texture(true)
	var off_texture := _toggle_texture(false)
	if on_texture != null:
		# CheckButton uses the checked/unchecked theme keys. The shorter
		# on/off names are not read by the Godot 4 default theme.
		toggle.add_theme_icon_override("checked", on_texture)
		toggle.add_theme_icon_override("checked_disabled", on_texture)
	if off_texture != null:
		toggle.add_theme_icon_override("unchecked", off_texture)
		toggle.add_theme_icon_override("unchecked_disabled", off_texture)
	toggle.custom_minimum_size = Vector2(0, 52)


func _toggle_texture(enabled: bool) -> Texture2D:
	var track := "#2563eb" if enabled else "#334155"
	var knob_x := "46" if enabled else "18"
	var svg := """
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="36" viewBox="0 0 64 36">
  <rect x="1" y="1" width="62" height="34" rx="17" fill="%s" stroke="#94a3b8" stroke-width="2"/>
  <circle cx="%s" cy="18" r="11" fill="#ffffff"/>
</svg>
""" % [track, knob_x]
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _dropdown_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#18243a")
	style.border_color = Color("#315b91")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _dropdown_hover_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#2563a8")
	style.set_corner_radius_all(7)
	style.content_margin_left = 8
	style.content_margin_right = 8
	return style


func _sync_settings_controls() -> void:
	if not is_instance_valid(context):
		return
	var settings: Dictionary = context.settings
	if is_instance_valid(show_bubbles_toggle):
		show_bubbles_toggle.button_pressed = bool(settings.get("show_bubbles", true))
	if is_instance_valid(offline_presence_toggle):
		offline_presence_toggle.button_pressed = bool(settings.get("offline_presence_enabled", true))
	if settings.has("click_through_enabled") and is_instance_valid(context) and context.has_method("update_runtime_config"):
		var saved_click_through := bool(settings.get("click_through_enabled", true))
		if bool(context.runtime_config.get("click_through_enabled", true)) != saved_click_through:
			context.update_runtime_config({"click_through_enabled": saved_click_through})
			if is_instance_valid(event_bus):
				event_bus.publish(&"click_through.refresh_requested", {})
	var channel := str(settings.get("update_channel", "stable")).to_lower()
	if channel in ["beta", "nightly"]:
		channel = "preview"
	if is_instance_valid(update_channel_option):
		for index in range(update_channel_option.item_count):
			if update_channel_option.get_item_text(index).to_lower() == channel:
				update_channel_option.select(index)
				break
	_sync_update_summary(channel)
	_sync_install_update_button()
	_sync_offline_bot_status()
	_sync_resource_monitor()
	_sync_theme()
	if is_instance_valid(application_window) and application_window.has_method("sync_settings"):
		application_window.call("sync_settings", settings, context.runtime_config)


func _sync_offline_bot_status() -> void:
	if not is_instance_valid(offline_bot_status_label):
		return
	var enabled := is_instance_valid(context) and bool(context.settings.get("offline_presence_enabled", true))
	if enabled:
		offline_bot_status_label.text = "Offline Bot: Running — local-only animations and floor walks"
		offline_bot_status_label.modulate = Color("#9fc4f3")
	else:
		offline_bot_status_label.text = "Offline Bot: Stopped — no scheduled actions"
		offline_bot_status_label.modulate = Color("#9aa6b8")


func _on_offline_presence_toggled(enabled: bool) -> void:
	if is_instance_valid(context):
		context.update_settings({"offline_presence_enabled": enabled})
	_sync_offline_bot_status()
	_set_settings_status("Offline companion activity is %s. Save settings to keep this choice." % ("enabled" if enabled else "disabled"))


func _selected_update_channel() -> String:
	if not is_instance_valid(update_channel_option) or update_channel_option.item_count == 0:
		return "stable"
	return update_channel_option.get_item_text(update_channel_option.selected).to_lower()


func _sync_update_summary(channel: String) -> void:
	if is_instance_valid(current_version_label):
		current_version_label.text = _localized_textf(
			"update.current_version",
			{"version": _application_version()},
			"Current version: {version}"
		)
	if is_instance_valid(update_channel_label):
		var channel_name := _localized_text("update.channel.%s" % channel.to_lower(), channel.capitalize())
		update_channel_label.text = _localized_textf(
			"update.channel",
			{"channel": channel_name},
			"Channel: {channel}"
		)
	if is_instance_valid(update_readiness_label):
		update_readiness_label.text = "%s\n%s" % [
			_localized_text("update.dev_disabled", "Signed update check is not enabled in this development build."),
			_localized_text("update.pin_required", "A pinned verification key and packaged Rust updater are required."),
		]


func _application_version() -> String:
	# Portable bundles carry the authoritative application version beside the
	# executable. This keeps the UI and updater aligned with the release tag.
	var build_info_path := OS.get_executable_path().get_base_dir().path_join("BUILD-INFO.json")
	if FileAccess.file_exists(build_info_path):
		var file := FileAccess.open(build_info_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and not str(parsed.get("version", "")).is_empty():
				return str(parsed.get("version"))
	var configured := str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	return configured if not configured.is_empty() else "0.1.0"


func _set_settings_status(message: String) -> void:
	if is_instance_valid(settings_status_label):
		settings_status_label.text = message


func _center_on_current_monitor() -> void:
	if not is_instance_valid(application_window):
		return
	if application_window.has_method("center_on_own_monitor"):
		application_window.call("center_on_own_monitor")
		return
	var window_id := application_window.get_window_id()
	var screen := DisplayServer.window_get_current_screen(window_id)
	if screen < 0:
		screen = DisplayServer.get_primary_screen()
	var usable_rect := DisplayServer.screen_get_usable_rect(screen)
	application_window.position = usable_rect.position + Vector2i(
		maxi(0, (usable_rect.size.x - application_window.size.x) / 2),
		maxi(0, (usable_rect.size.y - application_window.size.y) / 2)
	)
