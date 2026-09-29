extends Node
class_name RuntimeV3Service

var context: Node
var event_bus: Node


func configure(runtime_context: Node, bus: Node) -> void:
	context = runtime_context
	event_bus = bus


func start() -> void:
	pass


func stop() -> void:
	pass
