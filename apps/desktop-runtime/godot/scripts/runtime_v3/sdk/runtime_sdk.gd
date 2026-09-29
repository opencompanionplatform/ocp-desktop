extends Node
class_name RuntimeV3SDK
## Stable façade for plugins, AppShell and future agent integrations.

var context: Node
var event_bus: Node
var services: Node
var _action_last_play_ms: Dictionary = {}


func configure(runtime_context: Node, bus: Node, runtime_services: Node) -> void:
	context = runtime_context
	event_bus = bus
	services = runtime_services


func play_animation(name: StringName) -> void:
	event_bus.publish(&"animation.requested", {"name": name})


func play_action(name: StringName) -> bool:
	if not is_instance_valid(context):
		return false
	var entry_value: Variant = context.package.get("entry", {})
	if not (entry_value is Dictionary):
		return false
	var actions_value: Variant = entry_value.get("actions", {})
	if not (actions_value is Dictionary):
		return false
	var action_value: Variant = actions_value.get(str(name), {})
	if not (action_value is Dictionary):
		return false
	var animation := StringName(str(action_value.get("animation", "")))
	if animation == &"":
		return false
	var action_key: String = str(name)
	var cooldown_ms: int = maxi(0, int(action_value.get("cooldownMs", 0)))
	var now_ms: int = Time.get_ticks_msec()
	var previous_ms: int = int(_action_last_play_ms.get(action_key, -cooldown_ms - 1))
	if cooldown_ms > 0 and now_ms - previous_ms < cooldown_ms:
		return false
	_action_last_play_ms[action_key] = now_ms
	event_bus.publish(&"animation.requested", {
		"name": animation,
		"source": "character-action",
		"action": action_key,
		"priority": str(action_value.get("priority", "presentation")),
		"interruptible": bool(action_value.get("interruptible", true)),
	})
	return true


func show_bubble(text: String, duration: float = 4.0) -> void:
	event_bus.publish(&"bubble.requested", {"text": text, "duration": duration})


func show_notification(text: String, duration: float = 3.0) -> void:
	event_bus.publish(&"notification.requested", {"text": text, "duration": duration})


func open_quick_panel() -> void:
	event_bus.publish(&"quick_panel.open_requested", {})


func open_character_picker() -> void:
	event_bus.publish(&"character_picker.open_requested", {})


func hide_to_tray() -> void:
	event_bus.publish(&"window.hide_to_tray_requested", {})


func restore_window() -> void:
	event_bus.publish(&"window.restore_requested", {})


func ask_ai(prompt: String) -> void:
	event_bus.publish(&"ai.prompt_requested", {"prompt": prompt})


func write_memory(key: String, value: Variant) -> void:
	event_bus.publish(&"memory.write_requested", {"key": key, "value": value})


func runtime_snapshot() -> Dictionary:
	return context.snapshot()
