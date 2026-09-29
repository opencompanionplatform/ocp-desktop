extends Node
class_name RuntimeV3Controller

var context: Node
var event_bus: Node
var services: Node
var state_machine: Node


func configure(runtime_context: Node, bus: Node, runtime_services: Node, machine: Node) -> void:
	context = runtime_context
	event_bus = bus
	services = runtime_services
	state_machine = machine


func start() -> void:
	pass


func stop() -> void:
	pass
