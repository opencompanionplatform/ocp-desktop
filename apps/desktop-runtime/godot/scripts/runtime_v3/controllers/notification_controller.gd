extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3NotificationController

var panel: Control
var label: Label
var generation: int = 0


func bind_ui(target_panel: Control, target_label: Label) -> void:
	panel = target_panel
	label = target_label
	if is_instance_valid(panel):
		panel.visible = false


func start() -> void:
	event_bus.subscribe(&"notification.requested", Callable(self, "_on_notification_requested"))
	event_bus.subscribe(&"package.installed", Callable(self, "_on_package_installed"))
	event_bus.subscribe(&"package.install_failed", Callable(self, "_on_package_failed"))
	event_bus.subscribe(&"animation.missing", Callable(self, "_on_animation_missing"))


func stop() -> void:
	event_bus.unsubscribe(&"notification.requested", Callable(self, "_on_notification_requested"))
	event_bus.unsubscribe(&"package.installed", Callable(self, "_on_package_installed"))
	event_bus.unsubscribe(&"package.install_failed", Callable(self, "_on_package_failed"))
	event_bus.unsubscribe(&"animation.missing", Callable(self, "_on_animation_missing"))


func _on_notification_requested(payload: Dictionary) -> void:
	if not is_instance_valid(panel) or not is_instance_valid(label):
		return

	generation += 1
	var current: int = generation
	label.text = str(payload.get("text", ""))
	panel.visible = true
	event_bus.publish(&"notification.shown", payload)
	event_bus.publish(&"click_through.refresh_requested", {})

	var duration: float = float(payload.get("duration", 3.0))
	await get_tree().create_timer(duration).timeout
	if current == generation:
		panel.visible = false
		event_bus.publish(&"click_through.refresh_requested", {})


func _on_package_installed(payload: Dictionary) -> void:
	_on_notification_requested({
		"text": "Installed %s@%s" % [payload.get("packageId", ""), payload.get("version", "")],
	})


func _on_package_failed(payload: Dictionary) -> void:
	_on_notification_requested({"text": "Install failed: " + str(payload.get("error", "")), "duration": 6.0})


func _on_animation_missing(payload: Dictionary) -> void:
	_on_notification_requested({"text": "Animation unavailable: " + str(payload.get("name", ""))})
