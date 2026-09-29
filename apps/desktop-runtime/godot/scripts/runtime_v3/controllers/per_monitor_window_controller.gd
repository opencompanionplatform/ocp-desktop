extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3PerMonitorWindowController
## Coordinates monitor topology events with MonitorWindowService.
## Does not create windows or read DisplayServer directly.

func start() -> void:
	event_bus.subscribe(&"monitor.topology_changed", Callable(self, "_on_topology_changed"))


func stop() -> void:
	event_bus.unsubscribe(&"monitor.topology_changed", Callable(self, "_on_topology_changed"))
	if bool(context.runtime_config.get("hybrid_monitor_probe_active", false)):
		disable_per_monitor_mode()


func enable_per_monitor_mode() -> void:
	context.update_runtime_config({
		"per_monitor_windows_enabled": true,
		"mixed_dpi_mode": "native_per_monitor",
	})
	services.monitor_window_service.rebuild_descriptors()
	services.monitor_window_service.create_monitor_windows()
	event_bus.publish(&"notification.requested", {
		"text": "Per-monitor window foundation enabled",
	})


func disable_per_monitor_mode() -> void:
	services.monitor_window_service.destroy_monitor_windows()
	context.update_runtime_config({
		"per_monitor_windows_enabled": false,
		"mixed_dpi_mode": "adaptive_single_window",
		"hybrid_monitor_probe_active": false,
		"hybrid_monitor_probe_screen": -1,
	})


func enable_hybrid_probe(screen_index: int = -1) -> bool:
	services.monitor_window_service.rebuild_descriptors()
	if screen_index < 0:
		screen_index = services.monitor_window_service.primary_screen_index()
	if screen_index < 0:
		return false
	context.update_runtime_config({
		"per_monitor_windows_enabled": true,
		"mixed_dpi_mode": "hybrid_monitor_probe",
		"hybrid_monitor_probe_active": true,
		"hybrid_monitor_probe_screen": screen_index,
	})
	var monitor_window: Window = (
		services.monitor_window_service.create_window_for_screen(screen_index, false)
	)
	if not is_instance_valid(monitor_window):
		disable_per_monitor_mode()
		return false
	return true


func _on_topology_changed(_payload: Dictionary) -> void:
	if not bool(context.runtime_config.get("per_monitor_windows_enabled", false)):
		return
	services.monitor_window_service.destroy_monitor_windows()
	services.monitor_window_service.rebuild_descriptors()
	if bool(context.runtime_config.get("hybrid_monitor_probe_active", false)):
		var screen_index := int(
			context.runtime_config.get("hybrid_monitor_probe_screen", -1)
		)
		if screen_index < 0 or not services.monitor_window_service.descriptors.has(
			screen_index
		):
			screen_index = services.monitor_window_service.primary_screen_index()
		context.update_runtime_config({
			"hybrid_monitor_probe_screen": screen_index,
		})
		services.monitor_window_service.create_window_for_screen(
			screen_index,
			false
		)
		return
	services.monitor_window_service.create_monitor_windows()
