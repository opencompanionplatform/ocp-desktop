extends SceneTree

const ControllerScript = preload(
	"res://scripts/runtime_v3/controllers/application_window_controller.gd"
)
const NativeHostLifecycleScript = preload(
	"res://scripts/runtime_v3/services/native_host_lifecycle.gd"
)


class FakeSettingsService:
	extends Node
	var saved: Dictionary = {}

	func save_settings(values: Dictionary) -> bool:
		saved = values.duplicate(true)
		return true


class FakeServices:
	extends Node
	var settings_service := FakeSettingsService.new()
	var update_service: Node = null


class FakeContext:
	extends Node
	var settings: Dictionary = {
		"show_bubbles": false,
		"offline_presence_enabled": false,
		"update_channel": "preview",
	}
	var runtime_config: Dictionary = {
		"native_presentation_enabled": true,
	}

	func update_settings(values: Dictionary) -> void:
		settings.merge(values, true)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var controller = ControllerScript.new()
	var window := Window.new()
	var tabs := TabContainer.new()
	var show_bubbles := CheckButton.new()
	var offline_presence := CheckButton.new()
	var offline_bot_status := Label.new()
	var channels := OptionButton.new()
	var status := Label.new()
	var version := Label.new()
	var channel_label := Label.new()
	var readiness := Label.new()
	var chat_input := TextEdit.new()
	var send_chat := Button.new()
	var voice_chat := Button.new()
	var chat_transcript := ScrollContainer.new()
	var chat_messages := VBoxContainer.new()
	chat_transcript.add_child(chat_messages)
	var chat_status := Label.new()
	var fake_services := FakeServices.new()
	var fake_context := FakeContext.new()
	holder.add_child(controller)
	holder.add_child(fake_services)
	holder.add_child(fake_context)
	fake_services.add_child(fake_services.settings_service)
	for control in [
		show_bubbles,
		offline_presence,
		channels,
		status,
		version,
		channel_label,
		readiness,
		chat_input,
		send_chat,
		voice_chat,
		chat_transcript,
		chat_status,
		offline_bot_status,
	]:
		holder.add_child(control)
	holder.add_child(window)
	window.add_child(tabs)
	for title in ["Chat", "Settings", "Updates"]:
		var page := Control.new()
		page.name = title
		tabs.add_child(page)
	controller.context = fake_context
	controller.services = fake_services
	controller.bind_window(
		window,
		tabs,
		show_bubbles,
		channels,
		status,
		version,
		channel_label,
		readiness,
		null,
		chat_input,
		send_chat,
		chat_transcript,
		chat_messages,
		chat_status,
		voice_chat,
		offline_presence,
		null,
		offline_bot_status
	)
	var offline_bot_stopped_initial := offline_bot_status.text.begins_with("Offline Bot: Stopped")
	chat_input.text = "hello from smoke"
	controller._on_send_chat_pressed()
	var first_row := chat_messages.get_child(chat_messages.get_child_count() - 1)
	var first_stack := first_row.get_child(0)
	var first_card := first_stack.get_child(0)
	var user_card_text: String = str(first_card.get_child(0).get_child(0).text)
	var first_timestamp := first_stack.get_node_or_null("MessageTimestamp") as Label
	var chat_ok: bool = (
		chat_input.text.is_empty()
		and user_card_text.contains("hello from smoke")
		and first_card.custom_minimum_size.x >= 140.0
		and first_card.custom_minimum_size.x <= 520.0
		and is_instance_valid(first_timestamp)
		and not first_timestamp.text.is_empty()
	)
	chat_input.text = "line one\nline two"
	var newline_key := InputEventKey.new()
	newline_key.keycode = KEY_ENTER
	newline_key.ctrl_pressed = true
	newline_key.pressed = true
	controller._on_chat_input_gui_input(newline_key)
	var ctrl_enter_keeps_text := chat_input.text == "line one\nline two"
	var enter_key := InputEventKey.new()
	enter_key.keycode = KEY_ENTER
	enter_key.pressed = true
	controller._on_chat_input_gui_input(enter_key)
	var multiline_row := chat_messages.get_child(chat_messages.get_child_count() - 1)
	var multiline_stack := multiline_row.get_child(0)
	var multiline_card_text: String = str(multiline_stack.get_child(0).get_child(0).get_child(0).text)
	chat_ok = chat_ok and ctrl_enter_keeps_text and chat_input.text.is_empty() and multiline_card_text.contains("line one\nline two")
	print("[G13.1] chat_ok=", chat_ok, " input=", chat_input.text, " card=", user_card_text)
	var settings_ok := not show_bubbles.button_pressed and not offline_presence.button_pressed and channels.selected == 1
	show_bubbles.button_pressed = true
	offline_presence.button_pressed = true
	controller._on_offline_presence_toggled(true)
	channels.select(1)
	settings_ok = settings_ok and controller.save_settings()
	settings_ok = settings_ok and fake_services.settings_service.saved == {
		"show_bubbles": true,
		"offline_presence_enabled": true,
		"update_channel": "preview",
	}
	offline_presence.button_pressed = false
	controller._on_offline_presence_toggled(false)
	var offline_bot_stopped := offline_bot_status.text.begins_with("Offline Bot: Stopped")
	offline_presence.button_pressed = true
	controller._on_offline_presence_toggled(true)
	var offline_bot_running := offline_bot_status.text.begins_with("Offline Bot: Running")
	settings_ok = settings_ok and offline_bot_stopped_initial and offline_bot_stopped and offline_bot_running
	controller.check_update_readiness()
	settings_ok = settings_ok and readiness.text.contains("configuration is incomplete")

	controller._select_page("settings")
	var ok: bool = settings_ok and chat_ok and tabs.current_tab == 1
	controller._select_page("updates")
	ok = ok and tabs.current_tab == 2
	controller._select_page("missing")
	ok = ok and tabs.current_tab == 0

	window.show()
	controller._on_close()
	ok = ok and not window.visible
	var original_id := window.get_instance_id()
	controller._on_open({"page": "settings"})
	controller._on_open({"page": "chat"})
	ok = ok and window.get_instance_id() == original_id
	ok = ok and tabs.current_tab == 0
	ok = ok and _native_restore_repositions_before_reveal(fake_context)

	print("[G13.1] application settings contract smoke %s" % ("passed" if ok else "failed"))
	holder.free()
	await process_frame
	await process_frame
	quit(0 if ok else 1)


func _native_restore_repositions_before_reveal(fake_context: Node) -> bool:
	var lifecycle = NativeHostLifecycleScript.new()
	lifecycle.context = fake_context
	lifecycle.host_token = "restore-contract-token"
	lifecycle.latest_presentation_state = {
		"desktop_feet": [432.0, 654.0],
		"movement_state": "stationary",
		"attachment_state": "grounded",
		"surface_kind": "desktop_floor",
	}
	var payload: Variant = lifecycle._restore_request_payload()
	var ok: bool = false
	if payload is Dictionary:
		var restored: Dictionary = payload
		ok = str(restored.get("status", "")) == "restore-request" \
			and restored.get("desktop_feet", []) == [432.0, 654.0] \
			and str(restored.get("surface_kind", "")) == "desktop_floor"
	print("[G13.1] native_restore_atomic=", ok)
	return ok
