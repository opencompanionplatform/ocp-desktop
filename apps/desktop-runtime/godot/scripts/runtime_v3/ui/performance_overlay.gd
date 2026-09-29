extends CanvasLayer
class_name RuntimeV3PerformanceOverlay

var label: Label
var elapsed: float = 0.0


func _ready() -> void:
	label = Label.new()
	label.position = Vector2(16, 120)
	add_child(label)
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return

	elapsed += delta
	if elapsed < 0.25:
		return
	elapsed = 0.0

	label.text = "FPS: %.0f\nNodes: %d\nMemory: %.1f MB" % [
		Engine.get_frames_per_second(),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	]
