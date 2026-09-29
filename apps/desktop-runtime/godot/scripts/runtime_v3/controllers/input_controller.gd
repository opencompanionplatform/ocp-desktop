extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3InputController

func handle_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				event_bus.publish(&"quick_panel.close_requested", {})
				event_bus.publish(&"character_picker.close_requested", {})
			KEY_F8:
				event_bus.publish(&"bubble.requested", {"text": "Runtime V3 bubble test", "duration": 4.0})
			KEY_F9:
				event_bus.publish(&"debug.toggle_requested", {})
			KEY_F10:
				event_bus.publish(&"performance.toggle_requested", {})
