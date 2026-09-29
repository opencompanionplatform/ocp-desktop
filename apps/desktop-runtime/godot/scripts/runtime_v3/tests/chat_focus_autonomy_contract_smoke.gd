extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ControllerScript = preload("res://scripts/runtime_v3/controllers/autonomous_floor_walk_controller.gd")


class FakeBridge:
	extends Node
	var requests: Array[String] = []
	func request_companion_movement(_companion_id: String, action: String) -> bool:
		requests.append(action)
		return true


class FakeServices:
	extends Node
	var bridge_adapter: Node


func _initialize() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var bridge := FakeBridge.new()
	var services := FakeServices.new()
	var controller := ControllerScript.new()
	var state_machine := Node.new()
	services.bridge_adapter = bridge
	for node in [context, bus, bridge, services, controller, state_machine]:
		holder.add_child(node)
	context.update_settings({"offline_presence_enabled": true})
	context.update_window({"hidden_to_tray": false})
	controller.configure(context, bus, services, state_machine)
	controller.start()
	var initially_allowed := controller._is_allowed()
	controller.last_surface_kind = "desktop_floor"
	var started := controller._start_walk()
	context.update_runtime_config({"chat_focus_active": true})
	var focus_stopped := controller.chat_focus_active \
		and not controller._is_allowed() \
		and not controller.walking \
		and bridge.requests.has("stop")
	context.update_runtime_config({"chat_focus_active": false})
	var release_cooldown := not controller.chat_focus_active \
		and controller._is_allowed() \
		and controller.cooldown_remaining_seconds >= 3.0
	controller.cooldown_remaining_seconds = 0.0
	controller.last_surface_kind = "desktop_floor"
	var restarted := controller._start_walk()
	var requests_before_hover := bridge.requests.size()
	bus.publish(&"character.hover_entered", {"source": "native-host"})
	# Hover is intentionally passive: it blocks starting a new autonomous
	# action while the pointer is over the companion, but must not interrupt an
	# already-running route merely because the companion moved under the cursor.
	var hover_passive: bool = controller.hover_menu_active \
		and controller._is_allowed() \
		and controller.walking \
		and bridge.requests.size() == requests_before_hover
	bus.publish(&"character.hover_exited", {"source": "native-host"})
	var hover_release_active_route: bool = not controller.hover_menu_active \
		and controller._is_allowed() \
		and controller.walking \
		and controller.cooldown_remaining_seconds < controller.HOVER_RELEASE_COOLDOWN_SECONDS
	var ok: bool = initially_allowed and started and focus_stopped and release_cooldown \
		and restarted and hover_passive and hover_release_active_route
	print("[CHAT-FOCUS-AUTONOMY] initially_allowed=", initially_allowed, " focus_stopped=", focus_stopped, " release_cooldown=", release_cooldown, " hover_passive=", hover_passive, " hover_release_active_route=", hover_release_active_route)
	controller.stop()
	holder.free()
	quit(0 if ok else 1)
