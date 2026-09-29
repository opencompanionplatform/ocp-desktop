extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")


func _initialize() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var adapter := AdapterScript.new()
	for node in [context, bus, adapter]:
		holder.add_child(node)
	context.update_settings({"tts_enabled": true})
	adapter.configure(context, bus)

	adapter._on_chat_started({"message_id": "turn-1"})
	adapter._on_chat_delta({"message_id": "turn-1", "text": "สวัสดี"})
	adapter._on_chat_delta({"message_id": "turn-1", "text": "สวัสดีครับ 😊"})
	var one_running_message := adapter.chat_messages.size() == 1 \
		and str(adapter.chat_messages[0].get("text", "")) == "สวัสดีครับ 😊" \
		and str(adapter.chat_messages[0].get("status", "")) == "streaming"
	var thinking_state := adapter._chat_presentation_state() == "think"
	adapter.voice_health_state = {"status": "playing", "reasonCode": "", "lastSuccessAtMs": 0}
	var talking_state := adapter._chat_presentation_state() == "talk"
	adapter._on_chat_completed({"message_id": "turn-1", "text": "สวัสดีครับ 😊"})
	adapter.voice_health_state = {"status": "healthy", "reasonCode": "", "lastSuccessAtMs": 1}
	var one_completed_message := adapter.chat_messages.size() == 1 \
		and str(adapter.chat_messages[0].get("status", "")) == "complete"
	var idle_state := adapter._chat_presentation_state() == "idle"
	adapter._apply_chat_visibility({"type": "shell.chat-visibility", "active": true})
	var focus_projected := bool(context.runtime_config.get("chat_focus_active", false)) \
		and bool(context.runtime_config.get("chat_presentation_active", false)) \
		and bool(adapter.chat_presentation_active)
	var ok := AdapterScript.SCHEMA_VERSION == 18 \
		and one_running_message and one_completed_message \
		and thinking_state and talking_state and idle_state and focus_projected
	print("[DESKTOP-SHELL-REALTIME] schema=", AdapterScript.SCHEMA_VERSION, " running=", one_running_message, " completed=", one_completed_message, " states=", [thinking_state, talking_state, idle_state], " focus=", focus_projected)
	holder.free()
	quit(0 if ok else 1)
