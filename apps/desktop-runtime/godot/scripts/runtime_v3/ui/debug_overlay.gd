extends CanvasLayer
class_name RuntimeV3DebugOverlay

var label: Label
var context: Node
var state_machine: Node


func configure(runtime_context: Node, machine: Node) -> void:
	context = runtime_context
	state_machine = machine


func _ready() -> void:
	label = Label.new()
	label.position = Vector2(16, 16)
	add_child(label)
	visible = false


func _process(_delta: float) -> void:
	if not visible or context == null or state_machine == null:
		return
	label.text = "Runtime V3\nState: %s\nCharacter: %s\nMonitors: %s" % [
		state_machine.current_state,
		context.character.get("name", "(none)"),
		context.monitor.get("count", 0),
	]
