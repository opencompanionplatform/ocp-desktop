extends Node
class_name RuntimeV3Bootstrap
## Starts and stops Runtime V3. It does not own services/controllers/UI.

signal startup_completed
signal shutdown_completed

var app: Node
var context: Node
var event_bus: Node
var state_machine: Node


func configure(runtime_app: Node, runtime_context: Node, bus: Node, machine: Node) -> void:
	app = runtime_app
	context = runtime_context
	event_bus = bus
	state_machine = machine


func start_system() -> void:
	event_bus.publish(&"system.starting", {})
	await get_tree().process_frame

	state_machine.transition(&"ready", {"source": "RuntimeV3Bootstrap"}, true)
	event_bus.publish(&"system.ready", {"context": context.snapshot()})
	startup_completed.emit()


func stop_system() -> void:
	state_machine.transition(&"shutting_down", {}, true)
	event_bus.publish(&"system.shutting_down", {})
	shutdown_completed.emit()
