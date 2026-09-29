extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3DraggablePanelController

var panel: Control
var drag_handle: Control
var dragging: bool = false
var drag_mouse_origin: Vector2 = Vector2.ZERO
var drag_panel_origin: Vector2 = Vector2.ZERO
var viewport_margin: float = 12.0


func bind_panel(target_panel: Control, target_handle: Control) -> void:
	panel = target_panel
	drag_handle = target_handle

	if is_instance_valid(drag_handle):
		drag_handle.mouse_filter = Control.MOUSE_FILTER_STOP
		drag_handle.gui_input.connect(_on_handle_gui_input)


func _on_handle_gui_input(event: InputEvent) -> void:
	if not is_instance_valid(panel):
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			drag_mouse_origin = panel.get_viewport().get_mouse_position()
			drag_panel_origin = panel.position
			drag_handle.accept_event()
		else:
			dragging = false
			drag_handle.accept_event()

	elif event is InputEventMouseMotion and dragging:
		var mouse_position: Vector2 = panel.get_viewport().get_mouse_position()
		panel.position = _clamp_position(
			drag_panel_origin + (mouse_position - drag_mouse_origin)
		)
		event_bus.publish(&"click_through.refresh_requested", {})
		drag_handle.accept_event()


func _clamp_position(target: Vector2) -> Vector2:
	var viewport_size: Vector2 = panel.get_viewport_rect().size
	return Vector2(
		clampf(
			target.x,
			viewport_margin,
			maxf(viewport_margin, viewport_size.x - panel.size.x - viewport_margin)
		),
		clampf(
			target.y,
			viewport_margin,
			maxf(viewport_margin, viewport_size.y - panel.size.y - viewport_margin)
		)
	)
