extends Control
class_name RuntimeV3PreviewAuraStage

## Presentation-only animated platform for Character Manager preview. It owns
## no package state and stays below the isolated preview sprite.

const CYAN := Color("#32d5ff")
const VIOLET := Color("#9b6cff")

var phase := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	queue_redraw()


func _process(delta: float) -> void:
	phase = fmod(phase + delta, TAU)
	queue_redraw()


func _draw() -> void:
	if size.x <= 2.0 or size.y <= 2.0:
		return
	var center := Vector2(size.x * 0.5, size.y * 0.70)
	var pulse := 0.5 + 0.5 * sin(phase * 1.6)
	var base_radius := minf(size.x * 0.28, 180.0)

	# A soft filled floor glow, then several thin elliptical energy rings.
	draw_set_transform(center, 0.0, Vector2(1.0, 0.22))
	draw_circle(Vector2.ZERO, base_radius * (1.12 + pulse * 0.05), Color(CYAN, 0.025 + pulse * 0.02))
	draw_circle(Vector2.ZERO, base_radius * (0.76 + pulse * 0.04), Color(VIOLET, 0.045 + pulse * 0.025))
	for index in range(4):
		var ring_radius := base_radius * (0.55 + index * 0.18) + sin(phase * 1.6 + index) * 3.0
		var ring_color := CYAN.lerp(VIOLET, float(index) / 3.0)
		ring_color.a = 0.18 + pulse * 0.18 - index * 0.025
		draw_arc(Vector2.ZERO, ring_radius, 0.08, TAU - 0.08, 72, ring_color, 1.6, true)
	draw_set_transform(Vector2.ZERO)

	# Small orbiting motes make the platform feel alive without occluding the character.
	for index in range(10):
		var angle := phase * (0.9 + (index % 3) * 0.12) + float(index) * TAU / 10.0
		var orbit_radius := base_radius * (0.58 + (index % 2) * 0.22)
		var mote := center + Vector2(cos(angle) * orbit_radius, sin(angle) * orbit_radius * 0.22)
		var mote_color := CYAN if index % 2 == 0 else VIOLET
		mote_color.a = 0.35 + pulse * 0.38
		draw_circle(mote, 1.8 + pulse * 1.2, mote_color)

	# A restrained vertical bloom grounds the selected character above the platform.
	for index in range(5):
		var height := 16.0 + index * 14.0
		var bloom_color := CYAN.lerp(VIOLET, float(index) / 4.0)
		bloom_color.a = (0.035 + pulse * 0.03) * (1.0 - index * 0.12)
		draw_line(center + Vector2(0, -height), center + Vector2(0, height * 0.2), bloom_color, 1.0)
