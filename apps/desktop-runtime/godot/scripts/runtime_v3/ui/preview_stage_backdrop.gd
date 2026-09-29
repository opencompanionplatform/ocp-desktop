extends Control
class_name RuntimeV3PreviewStageBackdrop

## Decorative only. The isolated preview keeps its own dark depth even when
## the rest of OCP uses a brighter theme.

const CYAN := Color("#25c8ff")
const VIOLET := Color("#8d63ff")

var phase := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	phase = fmod(phase + delta * 0.45, TAU)
	queue_redraw()


func _draw() -> void:
	if size.x <= 2.0 or size.y <= 2.0:
		return
	var center := Vector2(size.x * 0.5, size.y * 0.46)
	var pulse := 0.5 + sin(phase) * 0.5
	var radius := minf(size.x * 0.43, size.y * 0.58)
	for index in range(6, 0, -1):
		var progress := float(index) / 6.0
		var color := VIOLET.lerp(CYAN, 1.0 - progress)
		color.a = 0.008 + (1.0 - progress) * (0.018 + pulse * 0.008)
		draw_circle(center + Vector2(0, -radius * 0.08), radius * progress, color)
	for index in range(12):
		var angle := phase + float(index) * TAU / 12.0
		var point := center + Vector2(cos(angle) * radius * 0.84, sin(angle) * radius * 0.48)
		var mote := CYAN if index % 2 == 0 else VIOLET
		mote.a = 0.10 + pulse * 0.10
		draw_circle(point, 1.2, mote)
