extends Control
class_name OcpResourceGauge

var metric_name := "CPU"
var value := 0.0
var accent := Color("#23b7ff")
var track := Color(0.16, 0.25, 0.40, 0.62)
var text_color := Color("#f2f7ff")
var muted_color := Color("#8ea7c9")


func configure(name: String, accent_color: Color) -> void:
	metric_name = name
	accent = accent_color
	custom_minimum_size = Vector2(230, 118)
	queue_redraw()


func set_value(percent: float) -> void:
	value = clampf(percent, 0.0, 100.0)
	queue_redraw()


func apply_ocp_theme(palette: Dictionary, _theme_name: String = "") -> void:
	text_color = palette.get("text", text_color)
	muted_color = palette.get("muted", muted_color)
	track = Color(palette.get("border", track), 0.30)
	queue_redraw()


func _draw() -> void:
	var center := Vector2(60.0, size.y * 0.5)
	var radius := 36.0
	var start_angle := -PI * 0.78
	var span := PI * 1.56
	var end_angle := start_angle + span
	# Soft under-ring and a slightly brighter progress arc give the gauges the
	# layered neon depth used by the approved mock without requiring textures.
	draw_arc(center, radius, start_angle, end_angle, 56, Color(track, 0.40), 11.0, true)
	draw_arc(center, radius, start_angle, end_angle, 56, track, 7.0, true)
	var value_end := start_angle + span * (value / 100.0)
	if value > 0.0:
		draw_arc(center, radius, start_angle, value_end, 56, Color(accent, 0.20), 13.0, true)
		draw_arc(center, radius, start_angle, value_end, 56, accent, 7.5, true)
	_draw_metric_icon(center)
	var font := get_theme_default_font()
	var metric_size := 15
	var value_size := 36
	draw_string(font, Vector2(116, 43), metric_name, HORIZONTAL_ALIGNMENT_LEFT, 96, metric_size, muted_color)
	draw_string(font, Vector2(116, 84), "%d%%" % roundi(value), HORIZONTAL_ALIGNMENT_LEFT, 102, value_size, text_color)


func _draw_metric_icon(center: Vector2) -> void:
	if metric_name.to_upper() == "RAM":
		var rect := Rect2(center - Vector2(9, 9), Vector2(18, 18))
		draw_rect(rect, Color.TRANSPARENT, false, 2.0)
		draw_line(Vector2(rect.position.x, rect.position.y), Vector2(rect.end.x, rect.position.y), accent, 2.0)
		draw_line(Vector2(rect.end.x, rect.position.y), rect.end, accent, 2.0)
		draw_line(rect.end, Vector2(rect.position.x, rect.end.y), accent, 2.0)
		draw_line(Vector2(rect.position.x, rect.end.y), rect.position, accent, 2.0)
		for offset in [-6.0, 0.0, 6.0]:
			draw_line(center + Vector2(offset, -13), center + Vector2(offset, -9), accent, 1.4)
			draw_line(center + Vector2(offset, 9), center + Vector2(offset, 13), accent, 1.4)
			draw_line(center + Vector2(-13, offset), center + Vector2(-9, offset), accent, 1.4)
			draw_line(center + Vector2(9, offset), center + Vector2(13, offset), accent, 1.4)
		return
	var points := PackedVector2Array([
		center + Vector2(-13, 1),
		center + Vector2(-7, 1),
		center + Vector2(-3, -7),
		center + Vector2(2, 8),
		center + Vector2(6, -2),
		center + Vector2(13, -2),
	])
	draw_polyline(points, accent, 2.0, true)
