extends PanelContainer
class_name OcpTitleBar

## Reusable borderless-window chrome for OCP native windows.
## The OS title bar is removed; this node owns drag/minimize/maximize/close.

signal close_requested

const HEIGHT := 46.0
const TEXT := Color("#d9e7fb")
const MUTED := Color("#8ba1bf")
const RESIZE_EDGE_THICKNESS := 12.0
const RESIZE_CORNER_SIZE := 22.0

var target_window: Window
var title_label: Label
var minimize_button: Button
var maximize_button: Button
var close_button: Button
var drag_zone: Control
var resize_handles: Array[Control] = []
var restore_position := Vector2i.ZERO
var restore_size := Vector2i.ZERO
var restore_screen := -1
var manual_maximized := false
var geometry_transition_in_progress := false
var resize_blocked_until_primary_release := false


func configure(window: Window, title_text: String = "") -> void:
	target_window = window
	# Borderless OCP application windows supply their own chrome. Keep the native
	# window explicitly resizable so start_resize() is not disabled by a scene or
	# platform default.
	target_window.unresizable = false
	name = "OcpTitleBar"
	set_meta("ocp_mock_theme_locked", true)
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build(title_text)
	# configure() is deliberately called before this title bar is attached to its
	# Window. Defer the overlays so they are inserted *after* the title bar and
	# every content control in the Window's input order.
	call_deferred("_build_resize_handles")
	apply_ocp_theme(_fallback_palette(), "solid")


func set_title(title_text: String) -> void:
	if is_instance_valid(title_label):
		title_label.text = title_text


func _process(_delta: float) -> void:
	# Restore moves the top-right chrome away while its mouse press is still
	# active. Release only that gesture lock as soon as the physical button is
	# up; a time-based lock made normal edge resizing feel intermittently dead.
	if resize_blocked_until_primary_release \
		and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		resize_blocked_until_primary_release = false


func _build(title_text: String) -> void:
	if get_child_count() > 0:
		if is_instance_valid(title_label):
			title_label.text = title_text
		return

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 4)
	add_child(margin)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_theme_constant_override("separation", 2)
	margin.add_child(row)

	drag_zone = HBoxContainer.new()
	drag_zone.name = "DragZone"
	drag_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	drag_zone.mouse_filter = Control.MOUSE_FILTER_STOP
	drag_zone.gui_input.connect(_on_drag_zone_gui_input)
	row.add_child(drag_zone)

	title_label = Label.new()
	title_label.name = "WindowTitle"
	title_label.text = title_text
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.add_theme_font_size_override("font_size", 15)
	drag_zone.add_child(title_label)

	var title_spacer := Control.new()
	title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_zone.add_child(title_spacer)

	minimize_button = _new_chrome_button("", "Minimize")
	minimize_button.icon = _chrome_icon_texture("minimize")
	minimize_button.pressed.connect(_minimize)
	row.add_child(minimize_button)

	maximize_button = _new_chrome_button("", "Maximize")
	_set_maximize_icon(false)
	maximize_button.pressed.connect(_toggle_maximize)
	row.add_child(maximize_button)

	close_button = _new_chrome_button("", "Close")
	close_button.icon = _chrome_icon_texture("close")
	close_button.pressed.connect(func(): close_requested.emit())
	row.add_child(close_button)


func _new_chrome_button(text_value: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text_value
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(44, 36)
	button.add_theme_constant_override("icon_max_width", 18)
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	return button


func _build_resize_handles() -> void:
	if not is_instance_valid(target_window) or not resize_handles.is_empty():
		return
	if get_parent() != target_window:
		# A caller may configure the bar and attach it on separate frames.
		call_deferred("_build_resize_handles")
		return
	# These hit targets live inside the borderless client area. Five pixels was
	# too narrow under Windows DPI scaling and the top edge could lose hit tests
	# to the title bar. Use a deliberate 12 px edge / 22 px corner zone and keep
	# edges out of corners so each gesture has exactly one native resize route.
	# They must be Window siblings, not PanelContainer children: PanelContainer
	# lays out every direct child as its content and would make all corner hit
	# targets overlap. Being inserted after the chrome gives the overlays the
	# first hit-test without covering the drag zone away from the outer border.
	_add_resize_handle("ResizeTop", DisplayServer.WINDOW_EDGE_TOP, Control.CURSOR_VSIZE, Vector2(0, 0), Vector2(1, 0), Vector2(RESIZE_CORNER_SIZE, 0), Vector2(-RESIZE_CORNER_SIZE, RESIZE_EDGE_THICKNESS))
	_add_resize_handle("ResizeBottom", DisplayServer.WINDOW_EDGE_BOTTOM, Control.CURSOR_VSIZE, Vector2(0, 1), Vector2(1, 1), Vector2(RESIZE_CORNER_SIZE, -RESIZE_EDGE_THICKNESS), Vector2(-RESIZE_CORNER_SIZE, 0))
	_add_resize_handle("ResizeLeft", DisplayServer.WINDOW_EDGE_LEFT, Control.CURSOR_HSIZE, Vector2(0, 0), Vector2(0, 1), Vector2(0, RESIZE_CORNER_SIZE), Vector2(RESIZE_EDGE_THICKNESS, -RESIZE_CORNER_SIZE))
	_add_resize_handle("ResizeRight", DisplayServer.WINDOW_EDGE_RIGHT, Control.CURSOR_HSIZE, Vector2(1, 0), Vector2(1, 1), Vector2(-RESIZE_EDGE_THICKNESS, RESIZE_CORNER_SIZE), Vector2(0, -RESIZE_CORNER_SIZE))
	_add_resize_handle("ResizeTopLeft", DisplayServer.WINDOW_EDGE_TOP_LEFT, Control.CURSOR_FDIAGSIZE, Vector2(0, 0), Vector2(0, 0), Vector2(0, 0), Vector2(RESIZE_CORNER_SIZE, RESIZE_CORNER_SIZE))
	_add_resize_handle("ResizeTopRight", DisplayServer.WINDOW_EDGE_TOP_RIGHT, Control.CURSOR_BDIAGSIZE, Vector2(1, 0), Vector2(1, 0), Vector2(-RESIZE_CORNER_SIZE, 0), Vector2(0, RESIZE_CORNER_SIZE))
	_add_resize_handle("ResizeBottomLeft", DisplayServer.WINDOW_EDGE_BOTTOM_LEFT, Control.CURSOR_BDIAGSIZE, Vector2(0, 1), Vector2(0, 1), Vector2(0, -RESIZE_CORNER_SIZE), Vector2(RESIZE_CORNER_SIZE, 0))
	_add_resize_handle("ResizeBottomRight", DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT, Control.CURSOR_FDIAGSIZE, Vector2(1, 1), Vector2(1, 1), Vector2(-RESIZE_CORNER_SIZE, -RESIZE_CORNER_SIZE), Vector2(0, 0))


func _add_resize_handle(handle_name: String, edge: int, cursor: int, anchor_begin: Vector2, anchor_end: Vector2, offset_begin: Vector2, offset_end: Vector2) -> void:
	var handle := Control.new()
	handle.name = handle_name
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = cursor
	handle.anchor_left = anchor_begin.x
	handle.anchor_top = anchor_begin.y
	handle.anchor_right = anchor_end.x
	handle.anchor_bottom = anchor_end.y
	handle.offset_left = offset_begin.x
	handle.offset_top = offset_begin.y
	handle.offset_right = offset_end.x
	handle.offset_bottom = offset_end.y
	handle.z_index = 4096
	handle.gui_input.connect(func(event: InputEvent): _on_resize_gui_input(event, edge, handle_name))
	target_window.add_child(handle)
	target_window.move_child(handle, target_window.get_child_count() - 1)
	resize_handles.append(handle)


func _on_resize_gui_input(event: InputEvent, edge: int, handle_name: String) -> void:
	if not is_instance_valid(target_window) \
		or manual_maximized \
		or geometry_transition_in_progress \
		or resize_blocked_until_primary_release:
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			# Responsive app shells may have expanded their child minimum widths
			# while the window was large. Release those preferred widths before
			# asking Windows to begin a native shrink gesture.
			if target_window.has_method("prepare_for_native_resize"):
				target_window.call("prepare_for_native_resize")
			_log_geometry("resize:%s" % handle_name, _screen_for_target_geometry())
			target_window.start_resize(edge)


func _on_drag_zone_gui_input(event: InputEvent) -> void:
	if not is_instance_valid(target_window):
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			if mouse_event.double_click:
				_toggle_maximize()
			elif manual_maximized:
				_restore_then_drag()
			else:
				target_window.start_drag()


func _restore_then_drag() -> void:
	if not is_instance_valid(target_window) or geometry_transition_in_progress:
		return
	await _toggle_maximize()
	if is_instance_valid(target_window):
		target_window.start_drag()


func _minimize() -> void:
	if not is_instance_valid(target_window):
		return
	# Window.mode is unreliable for force_native child windows on Windows.
	# Address the exact native window instead of falling back to MAIN_WINDOW_ID.
	var window_id := target_window.get_window_id()
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED, window_id)


func _toggle_maximize() -> void:
	if not is_instance_valid(target_window) or geometry_transition_in_progress:
		return
	geometry_transition_in_progress = true
	if manual_maximized:
		# A Restore press starts in the maximized top-right corner. Once the
		# window moves, that same physical press can land over a resize overlay
		# and immediately start ResizeTopRight. Keep resize input blocked beyond
		# the geometry transition so the original mouse gesture cannot leak.
		resize_blocked_until_primary_release = true
		var restored := await _apply_window_rect_safely(restore_position, restore_size)
		if restored:
			manual_maximized = false
			_set_maximize_icon(false)
			maximize_button.tooltip_text = "Maximize"
			_log_geometry("restore", _screen_for_target_geometry())
		else:
			# Do not discard the only valid normal rect. A later Restore click must
			# retry this rect instead of treating the full-screen rect as normal.
			_log_geometry("restore-retry-required", _screen_for_target_geometry())
		geometry_transition_in_progress = false
		return
	var screen := _native_screen_for_target()
	restore_position = target_window.position
	restore_size = target_window.size
	restore_screen = screen
	# Keep the exact HWND in ordinary windowed mode and resize it through the same
	# WM_SIZE path used by interactive edge dragging. WINDOW_MODE_MAXIMIZED turns
	# this borderless force-native surface black on the production D3D12/OpenGL
	# bridge, while hide/show destroys the HWND and can move it to the primary
	# monitor. A direct usable-rect update avoids both failure modes.
	var usable_rect := DisplayServer.screen_get_usable_rect(screen)
	var maximized := await _apply_window_rect_safely(usable_rect.position, usable_rect.size)
	if maximized:
		manual_maximized = true
		_set_maximize_icon(true)
		maximize_button.tooltip_text = "Restore"
		_log_geometry("maximize", screen)
	else:
		_log_geometry("maximize-failed", screen)
	geometry_transition_in_progress = false


func _apply_window_rect_safely(target_position: Vector2i, target_size: Vector2i) -> bool:
	if not is_instance_valid(target_window):
		return false
	# Let responsive shells lower any preferred child widths/heights computed
	# for the current large rect. Otherwise Windows correctly refuses WM_SIZE
	# because the content minimum still describes the maximized layout.
	if target_window.has_method("prepare_for_window_rect"):
		target_window.call("prepare_for_window_rect", target_size)
		await get_tree().process_frame
	var window_id := target_window.get_window_id()
	if window_id != DisplayServer.INVALID_WINDOW_ID:
		var current_size := DisplayServer.window_get_size(window_id)
		var shrinking := target_size.x * target_size.y < current_size.x * current_size.y
		# Windows clamps a position while the still-full-size borderless HWND
		# would cross its work area. Restore must therefore shrink first and move
		# second; maximize uses the inverse order to stay on the current monitor.
		if shrinking:
			# Setting a borderless HWND to the exact work-area rect can make Windows
			# classify it as maximized even though OCP never requested native
			# WINDOW_MODE_MAXIMIZED. Size changes are ignored in that OS state.
			# Leaving it is safe and does not use the black-screen maximize path.
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED, window_id)
			await get_tree().process_frame
			DisplayServer.window_set_size(target_size, window_id)
			await get_tree().process_frame
			DisplayServer.window_set_position(target_position, window_id)
		else:
			DisplayServer.window_set_position(target_position, window_id)
			await get_tree().process_frame
			DisplayServer.window_set_size(target_size, window_id)
	else:
		target_window.position = target_position
		target_window.size = target_size
	await get_tree().process_frame
	if not is_instance_valid(target_window):
		return false
	target_window.grab_focus()
	await get_tree().process_frame
	if window_id == DisplayServer.INVALID_WINDOW_ID:
		return target_window.position == target_position and target_window.size == target_size
	var applied := _native_rect_matches(window_id, target_position, target_size)
	if not applied:
		# One retry handles delayed WM_SIZE/WM_MOVE processing without replacing,
		# hiding, or changing the mode of the render-backed HWND.
		DisplayServer.window_set_size(target_size, window_id)
		await get_tree().process_frame
		DisplayServer.window_set_position(target_position, window_id)
		await get_tree().process_frame
		applied = _native_rect_matches(window_id, target_position, target_size)
	return applied


func _native_rect_matches(window_id: int, expected_position: Vector2i, expected_size: Vector2i) -> bool:
	if DisplayServer.get_name().to_lower() == "headless":
		return true
	var actual_position := DisplayServer.window_get_position(window_id)
	var actual_size := DisplayServer.window_get_size(window_id)
	return (actual_position - expected_position).abs().x <= 2 \
		and (actual_position - expected_position).abs().y <= 2 \
		and (actual_size - expected_size).abs().x <= 2 \
		and (actual_size - expected_size).abs().y <= 2


func _screen_for_target_geometry() -> int:
	return _native_screen_for_target()


func _native_screen_for_target() -> int:
	if not is_instance_valid(target_window):
		return DisplayServer.get_primary_screen()
	var window_id := target_window.get_window_id()
	if window_id != DisplayServer.INVALID_WINDOW_ID:
		var native_screen := DisplayServer.window_get_current_screen(window_id)
		if native_screen >= 0 and native_screen < DisplayServer.get_screen_count():
			return native_screen
	var desktop_rect := Rect2i(target_window.position, target_window.size)
	return select_screen_for_rect(desktop_rect, _screen_rects(), DisplayServer.get_primary_screen())


func _screen_rects() -> Array[Rect2i]:
	var rects: Array[Rect2i] = []
	for screen_index in range(DisplayServer.get_screen_count()):
		rects.append(Rect2i(
			DisplayServer.screen_get_position(screen_index),
			DisplayServer.screen_get_size(screen_index)
		))
	return rects


static func select_screen_for_rect(
	target_rect: Rect2i,
	screen_rects: Array[Rect2i],
	fallback_screen: int = 0
) -> int:
	if screen_rects.is_empty():
		return fallback_screen
	var selected := -1
	var selected_area := -1
	for screen_index in range(screen_rects.size()):
		var overlap := target_rect.intersection(screen_rects[screen_index])
		var overlap_area := maxi(0, overlap.size.x) * maxi(0, overlap.size.y)
		if overlap_area > selected_area:
			selected = screen_index
			selected_area = overlap_area
	if selected_area > 0:
		return selected
	var center := target_rect.position + target_rect.size / 2
	for screen_index in range(screen_rects.size()):
		if screen_rects[screen_index].has_point(center):
			return screen_index
	return clampi(fallback_screen, 0, screen_rects.size() - 1)


func _log_geometry(action: String, screen: int) -> void:
	if not is_instance_valid(target_window):
		return
	var window_id := target_window.get_window_id()
	var observed_position := target_window.position
	var observed_size := target_window.size
	var observed_mode := DisplayServer.WINDOW_MODE_WINDOWED
	if window_id != DisplayServer.INVALID_WINDOW_ID:
		observed_position = DisplayServer.window_get_position(window_id)
		observed_size = DisplayServer.window_get_size(window_id)
		observed_mode = DisplayServer.window_get_mode(window_id)
	print(
		"[OcpAppWindowGeometry] action=%s window_id=%d mode=%d screen=%d position=%s size=%s normal_position=%s normal_size=%s"
		% [
			action,
			window_id,
			observed_mode,
			screen,
			observed_position,
			observed_size,
			restore_position,
			restore_size,
		]
	)


func _set_maximize_icon(restoring: bool) -> void:
	if not is_instance_valid(maximize_button):
		return
	maximize_button.icon = _chrome_icon_texture("restore" if restoring else "maximize")


func _chrome_icon_texture(kind: String) -> Texture2D:
	var body := ""
	match kind:
		"minimize":
			body = '<path d="M4 12h16"/>'
		"restore":
			body = '<rect x="7" y="5" width="11" height="11" rx="1"/><path d="M5 8H4v11h11v-1"/>'
		"close":
			body = '<path d="M6 6l12 12M18 6L6 18"/>'
		_:
			body = '<rect x="5" y="5" width="14" height="14" rx="1"/>'
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#d9e7fb" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">%s</svg>' % body
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func apply_ocp_theme(palette: Dictionary, _theme_name: String = "solid") -> void:
	var strong: Color = palette.get("surface_strong", Color("#020817"))
	var surface: Color = palette.get("surface", Color("#071a38"))
	var border: Color = palette.get("border", Color("#236fb8"))
	var text: Color = palette.get("text", TEXT)
	var muted: Color = palette.get("muted", MUTED)
	var chrome := _style(Color(strong, 0.985), Color(border, 0.42), 0, 0, 0)
	chrome.border_width_top = 1
	chrome.border_width_left = 1
	chrome.border_width_right = 1
	chrome.corner_radius_top_left = 16
	chrome.corner_radius_top_right = 16
	add_theme_stylebox_override("panel", chrome)
	if is_instance_valid(title_label):
		title_label.add_theme_color_override("font_color", muted if title_label.text.is_empty() else text)
	for button in [minimize_button, maximize_button, close_button]:
		if not is_instance_valid(button):
			continue
		button.add_theme_color_override("font_color", text)
		button.add_theme_color_override("font_hover_color", Color.WHITE)
		button.add_theme_stylebox_override("normal", _style(Color.TRANSPARENT, Color.TRANSPARENT, 8, 0, 0))
		button.add_theme_stylebox_override("pressed", _style(Color(surface, 0.92), Color(border, 0.38), 8, 0, 0))
		button.add_theme_stylebox_override("hover", _style(Color(surface, 0.72), Color(border, 0.28), 8, 0, 0))
	if is_instance_valid(close_button):
		close_button.add_theme_stylebox_override("hover", _style(Color("#51202b"), Color("#c4546b"), 8, 0, 0))
		close_button.add_theme_stylebox_override("pressed", _style(Color("#6d2635"), Color("#e06a80"), 8, 0, 0))


func _style(background: Color, border: Color, radius: int, shadow: int, bottom_border: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.border_width_bottom = bottom_border
	style.set_corner_radius_all(radius)
	if shadow > 0:
		style.shadow_color = Color(0, 0, 0, 0.28)
		style.shadow_size = shadow
	return style


func _fallback_palette() -> Dictionary:
	return {
		"surface": Color("#071a38"),
		"surface_strong": Color("#020817"),
		"text": TEXT,
		"muted": MUTED,
		"border": Color(0.16, 0.58, 1.0, 0.62),
	}
