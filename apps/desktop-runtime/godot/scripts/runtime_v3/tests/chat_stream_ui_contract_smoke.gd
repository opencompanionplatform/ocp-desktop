extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const StateMachineScript = preload("res://scripts/runtime_v3/core/runtime_state_machine.gd")
const ControllerScript = preload("res://scripts/runtime_v3/controllers/application_window_controller.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var services := ServicesScript.new()
	var state_machine := StateMachineScript.new()
	var controller := ControllerScript.new()
	var transcript := ScrollContainer.new()
	var messages := VBoxContainer.new()
	messages.name = "ChatMessages"
	transcript.add_child(messages)
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(services)
	holder.add_child(state_machine)
	holder.add_child(controller)
	holder.add_child(transcript)
	context.update_settings({"text_scale": 1.15})
	controller.configure(context, bus, services, state_machine)
	controller.chat_transcript = transcript
	controller.chat_messages = messages

	controller._on_chat_assistant_stream_started({"message_id": "stream-1"})
	controller._on_chat_assistant_stream_delta({
		"message_id": "stream-1",
		"delta": "Hello ",
		"text": "Hello ",
	})
	controller._on_chat_assistant_stream_delta({
		"message_id": "stream-1",
		"delta": "world",
		"text": "Hello world",
	})

	var row := messages.get_node_or_null("AssistantMessage_stream-1") as HBoxContainer
	var label := row.find_child("AssistantMessageText", true, false) as Label if is_instance_valid(row) else null
	var timestamp := row.find_child("MessageTimestamp", true, false) as Label if is_instance_valid(row) else null
	var copy_button := row.find_child("CopyButton", true, false) as Button if is_instance_valid(row) else null
	var streaming_ok := is_instance_valid(row) \
		and is_instance_valid(label) \
		and label.text == "Hello world" \
		and is_instance_valid(timestamp) \
		and not timestamp.visible \
		and is_instance_valid(copy_button) \
		and not copy_button.visible \
		and messages.get_child_count() == 1

	controller._on_chat_assistant_message_received({
		"message_id": "stream-1",
		"text": "Hello world",
	})
	var finalized_ok := messages.get_child_count() == 1 \
		and is_instance_valid(label) \
		and label.text == "Hello world" \
		and is_instance_valid(timestamp) \
		and timestamp.visible \
		and is_instance_valid(copy_button) \
		and copy_button.visible \
		and not controller.chat_stream_rows.has("stream-1")
	if is_instance_valid(copy_button):
		copy_button.pressed.emit()
	var copy_ok := true
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		copy_ok = DisplayServer.clipboard_get() == "Hello world"

	controller._submit_chat("User copy test")
	var user_row := messages.get_child(messages.get_child_count() - 1) as HBoxContainer
	var user_copy_button := user_row.find_child("CopyButton", true, false) as Button if is_instance_valid(user_row) else null
	var user_label := user_row.find_child("UserMessageText", true, false) as Label if is_instance_valid(user_row) else null
	var user_copy_ok := is_instance_valid(user_copy_button) and is_instance_valid(user_label)
	if user_copy_ok:
		user_copy_button.pressed.emit()
	if user_copy_ok and DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		user_copy_ok = DisplayServer.clipboard_get() == "User copy test"

	var ok := streaming_ok and finalized_ok and copy_ok and user_copy_ok
	print("[CHAT-P2.1-UI] streaming=", streaming_ok, " finalized=", finalized_ok, " assistant_copy=", copy_ok, " user_copy=", user_copy_ok, " rows=", messages.get_child_count())
	holder.free()
	quit(0 if ok else 1)
