extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3BridgeAdapter
## Adapts Rust bridge signals into RuntimeEventBus topics.

var bridge: Node
var connected_signals: PackedStringArray = []


func bind_bridge(target: Node) -> void:
	bridge = target
	_connect_bridge_signals()


func start() -> void:
	if bridge != null:
		_connect_bridge_signals()


func _connect_bridge_signals() -> void:
	if bridge == null:
		return

	_connect_if_available(
		&"animation_requested",
		Callable(self, "_on_animation_requested")
	)
	_connect_if_available(
		&"emotion_changed",
		Callable(self, "_on_emotion_changed")
	)
	_connect_if_available(
		&"bubble_requested",
		Callable(self, "_on_bubble_requested")
	)
	_connect_if_available(
		&"character_reload_requested",
		Callable(self, "_on_character_reload_requested")
	)
	_connect_if_available(
		&"runtime_command_received",
		Callable(self, "_on_runtime_command_received")
	)
	_connect_if_available(
		&"world_event_received",
		Callable(self, "_on_world_event_received")
	)
	_connect_if_available(
		&"companion_presentation_state",
		Callable(self, "_on_companion_presentation_state")
	)
	_connect_if_available(
		&"companion_moved",
		Callable(self, "_on_companion_moved")
	)
	_connect_if_available(
		&"connection_lost",
		Callable(self, "_on_connection_lost")
	)
	_connect_if_available(
		&"connection_restored",
		Callable(self, "_on_connection_restored")
	)
	_connect_if_available(
		&"render_host_ready",
		Callable(self, "_on_render_host_ready")
	)
	_connect_if_available(
		&"render_host_resized",
		Callable(self, "_on_render_host_resized")
	)
	_connect_if_available(
		&"render_host_detached",
		Callable(self, "_on_render_host_detached")
	)


func _connect_if_available(
	signal_name: StringName,
	callback: Callable
) -> void:
	if bridge.has_signal(signal_name) \
	and not bridge.is_connected(signal_name, callback):
		bridge.connect(signal_name, callback)
		connected_signals.append(String(signal_name))


func _on_emotion_changed(
	companion_id: String,
	emotion: String,
	emotion_instance: String
) -> void:
	event_bus.publish(&"emotion.changed", {
		"companionId": companion_id,
		"emotion": emotion,
		"emotionInstance": emotion_instance,
		"source": "kernel",
	})


func _on_animation_requested(
	companion_id: String,
	animation_id: String,
	looped: bool,
	priority: String,
	blend_ms: int,
	animation_instance: String
) -> void:
	event_bus.publish(&"animation.requested", {
		"companionId": companion_id,
		"animationId": animation_id,
		"name": animation_id,
		"loop": looped,
		"priority": priority,
		"blendMs": blend_ms,
		"animationInstance": animation_instance,
	})


func _on_bubble_requested(
	companion_id: String,
	bubble_id: String,
	text: String,
	tone: String,
	duration_ms: int,
	truncated: bool
) -> void:
	event_bus.publish(&"bubble.requested", {
		"companionId": companion_id,
		"bubbleId": bubble_id,
		"text": text,
		"tone": tone,
		"durationMs": duration_ms,
		"truncated": truncated,
	})


func _on_character_reload_requested() -> void:
	event_bus.publish(&"character.load_active_requested", {})


func _on_runtime_command_received(command: Dictionary) -> void:
	var command_type: String = str(command.get("type", ""))
	match command_type:
		"animation":
			event_bus.publish(&"animation.requested", {
				"name": command.get("name", "idle"),
			})
		"bubble":
			event_bus.publish(&"bubble.requested", {
				"text": command.get("text", ""),
			})
		"quick_panel":
			event_bus.publish(&"quick_panel.open_requested", {})


func _on_world_event_received(
	event_type: String,
	payload_json: String
) -> void:
	var parsed: Variant = JSON.parse_string(payload_json)
	if parsed is Dictionary:
		event_bus.publish(&"desktop_world.event_received", {
			"type": event_type,
			"payload": parsed,
		})


func _on_companion_presentation_state(payload: Dictionary) -> void:
	if not payload.has("bodyId"):
		event_bus.publish(&"character.presentation_contract_rejected", {
			"reason": "missing-body-id",
			"payload": payload.duplicate(true),
		})
		return
	event_bus.publish(&"character.presentation_state", payload.duplicate(true))


func _on_companion_moved(payload: Dictionary) -> void:
	event_bus.publish(&"character.physics_moved", payload.duplicate(true))


func begin_native_mouse_capture(native_window_handle: int) -> bool:
	if not is_instance_valid(bridge):
		return false
	if not bridge.has_method("begin_native_mouse_capture"):
		return false
	return bool(bridge.call(
		"begin_native_mouse_capture",
		native_window_handle
	))


func end_native_mouse_capture() -> bool:
	if not is_instance_valid(bridge):
		return false
	if not bridge.has_method("end_native_mouse_capture"):
		return false
	return bool(bridge.call("end_native_mouse_capture"))


# Canonical overlay drag commit. Presentation holds the released point until acknowledgement.
func commit_companion_position(
	companion_id: String,
	feet_desktop: Vector2
) -> bool:
	if bridge == null:
		push_error("[drag-sync] commit unavailable: bridge is null")
		return false
	if not bridge.has_method("commit_companion_position"):
		push_error(
			"[drag-sync] commit unavailable: GDExtension method missing"
		)
		return false

	var result: Variant = bridge.call(
		"commit_companion_position",
		companion_id,
		float(feet_desktop.x),
		float(feet_desktop.y)
	)
	return bool(result)


func request_companion_movement(companion_id: String, action: String) -> bool:
	if bridge == null or companion_id.strip_edges().is_empty():
		return false
	if action not in ["walk-left", "walk-right", "climb-up", "climb-down", "hang-left", "hang-right", "hang-to-center", "hang-to-far-edge", "hang-to-climb-down-edge", "detach", "teleport-current-monitor", "stop"]:
		return false
	if not bridge.has_method("request_companion_movement"):
		push_error("[offline-walk] request unavailable: GDExtension method missing")
		return false
	return bool(bridge.call("request_companion_movement", companion_id, action))


func _on_connection_lost() -> void:
	event_bus.publish(&"desktop_world.connection_changed", {
		"connected": false,
	})


func _on_connection_restored() -> void:
	event_bus.publish(&"desktop_world.connection_changed", {
		"connected": true,
	})


func _on_render_host_ready(companion_id: String, host_token: String) -> void:
	event_bus.publish(&"native_presentation.ready", {
		"companionId": companion_id,
		"hostToken": host_token,
	})


func _on_render_host_resized(width: int, height: int) -> void:
	event_bus.publish(&"native_presentation.resized", {
		"width": width,
		"height": height,
	})


func _on_render_host_detached(companion_id: String) -> void:
	event_bus.publish(&"native_presentation.detached", {
		"companionId": companion_id,
	})
