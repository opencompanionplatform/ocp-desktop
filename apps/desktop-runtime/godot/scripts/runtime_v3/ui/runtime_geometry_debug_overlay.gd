class_name RuntimeV3GeometryDebugOverlay
extends Control
## Draws character origin, bubble anchor and hitbox for RC validation.
##
## Control does not provide Node2D.to_local(). Coordinates are converted from
## canvas space through this Control's inverse global canvas transform.

@export var origin_radius: float = 5.0
@export var anchor_radius: float = 7.0

var bubble_anchor_controller: RuntimeV3BubbleAnchorController = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func bind_controller(
	controller: RuntimeV3BubbleAnchorController
) -> void:
	bubble_anchor_controller = controller
	queue_redraw()


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _draw() -> void:
	if bubble_anchor_controller == null:
		return

	var companion: Node2D = bubble_anchor_controller._companion

	if companion == null:
		return

	var origin_canvas: Vector2 = companion.global_position
	var anchor_canvas: Vector2 = (
		bubble_anchor_controller.get_anchor_global_position()
	)
	var hitbox_canvas: Rect2 = (
		bubble_anchor_controller.get_hitbox_global_rect()
	)

	var origin_local: Vector2 = _canvas_point_to_local(origin_canvas)
	var anchor_local: Vector2 = _canvas_point_to_local(anchor_canvas)

	var hitbox_top_left: Vector2 = _canvas_point_to_local(
		hitbox_canvas.position
	)
	var hitbox_bottom_right: Vector2 = _canvas_point_to_local(
		hitbox_canvas.end
	)
	var hitbox_local := Rect2(
		hitbox_top_left,
		hitbox_bottom_right - hitbox_top_left
	)

	draw_circle(
		origin_local,
		origin_radius,
		Color(0.2, 0.8, 1.0, 0.95)
	)
	draw_circle(
		anchor_local,
		anchor_radius,
		Color(1.0, 0.35, 0.2, 0.95)
	)
	draw_line(
		origin_local,
		anchor_local,
		Color(1.0, 1.0, 1.0, 0.65),
		2.0
	)
	draw_rect(
		hitbox_local,
		Color(1.0, 0.85, 0.1, 0.95),
		false,
		2.0
	)

	draw_string(
		ThemeDB.fallback_font,
		anchor_local + Vector2(10.0, -8.0),
		"bubbleAnchor",
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		14,
		Color.WHITE
	)


func _canvas_point_to_local(canvas_point: Vector2) -> Vector2:
	var inverse_transform: Transform2D = (
		get_global_transform_with_canvas().affine_inverse()
	)

	return inverse_transform * canvas_point
