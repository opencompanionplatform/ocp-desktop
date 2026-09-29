extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3QuickPanelController

var panel: Control
var animation_list: VBoxContainer


func bind_panel(target: Control, target_animation_list: VBoxContainer) -> void:
	panel = target
	animation_list = target_animation_list


func start() -> void:
	event_bus.subscribe(&"quick_panel.open_requested", Callable(self, "_on_open"))
	event_bus.subscribe(&"quick_panel.close_requested", Callable(self, "_on_close"))
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_loaded"))


func stop() -> void:
	event_bus.unsubscribe(&"quick_panel.open_requested", Callable(self, "_on_open"))
	event_bus.unsubscribe(&"quick_panel.close_requested", Callable(self, "_on_close"))
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_loaded"))


func _on_open(_payload: Dictionary) -> void:
	panel.visible = true
	state_machine.transition(&"quick_panel", {})
	event_bus.publish(&"click_through.refresh_requested", {})


func _on_close(_payload: Dictionary) -> void:
	panel.visible = false
	state_machine.transition(&"ready", {})
	event_bus.publish(&"click_through.refresh_requested", {})


func _on_character_loaded(_payload: Dictionary) -> void:
	_rebuild_animations()


func _rebuild_animations() -> void:
	if not is_instance_valid(animation_list):
		return
	for child in animation_list.get_children():
		child.queue_free()

	var names: PackedStringArray = context.character.get("animations", PackedStringArray())
	names.sort()
	for animation_name in names:
		var button := Button.new()
		button.text = "▶ " + animation_name
		button.pressed.connect(func(): event_bus.publish(&"animation.requested", {"name": animation_name}))
		animation_list.add_child(button)
