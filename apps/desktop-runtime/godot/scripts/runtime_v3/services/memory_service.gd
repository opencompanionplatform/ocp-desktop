extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3MemoryService

var _session_memory: Dictionary = {}


func start() -> void:
	event_bus.subscribe(&"memory.read_requested", Callable(self, "_on_read_requested"))
	event_bus.subscribe(&"memory.write_requested", Callable(self, "_on_write_requested"))


func stop() -> void:
	event_bus.unsubscribe(&"memory.read_requested", Callable(self, "_on_read_requested"))
	event_bus.unsubscribe(&"memory.write_requested", Callable(self, "_on_write_requested"))


func read(key: String, fallback: Variant = null) -> Variant:
	return _session_memory.get(key, fallback)


func write(key: String, value: Variant) -> void:
	_session_memory[key] = value


func _on_read_requested(payload: Dictionary) -> void:
	var key: String = str(payload.get("key", ""))
	var reply_topic: StringName = StringName(payload.get("reply_topic", "memory.read_result"))
	event_bus.publish(reply_topic, {"key": key, "value": read(key)})


func _on_write_requested(payload: Dictionary) -> void:
	write(str(payload.get("key", "")), payload.get("value"))
