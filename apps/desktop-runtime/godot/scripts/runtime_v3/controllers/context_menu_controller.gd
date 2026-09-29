extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ContextMenuController

var menu: Control


func bind_menu(target: Control) -> void:
	menu = target


func show_menu() -> void:
	if is_instance_valid(menu):
		menu.visible = true
		event_bus.publish(&"click_through.refresh_requested", {})


func hide_menu() -> void:
	if is_instance_valid(menu):
		menu.visible = false
		event_bus.publish(&"click_through.refresh_requested", {})
