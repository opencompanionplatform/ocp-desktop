extends Node
class_name RuntimeV3EventTracer

var enabled: bool = false
var max_entries: int = 200
var entries: Array[Dictionary] = []
var event_bus: Node


func configure(bus: Node) -> void:
	shutdown()
	event_bus = bus
	if event_bus != null and not event_bus.event_published.is_connected(_on_event_published):
		event_bus.event_published.connect(_on_event_published)


func set_enabled(value: bool) -> void:
	enabled = value


func clear() -> void:
	entries.clear()


func snapshot() -> Array:
	return entries.duplicate(true)


func shutdown() -> void:
	if event_bus != null \
	and is_instance_valid(event_bus) \
	and event_bus.event_published.is_connected(_on_event_published):
		event_bus.event_published.disconnect(_on_event_published)

	event_bus = null
	enabled = false
	entries.clear()


func _on_event_published(topic: StringName, payload: Dictionary) -> void:
	if not enabled:
		return

	entries.append({
		"time_msec": Time.get_ticks_msec(),
		"topic": String(topic),
		"payload": payload.duplicate(true),
	})
	while entries.size() > max_entries:
		entries.pop_front()


func _exit_tree() -> void:
	shutdown()
