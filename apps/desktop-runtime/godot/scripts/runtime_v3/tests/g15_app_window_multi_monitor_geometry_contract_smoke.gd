extends SceneTree

const TITLE_BAR_SCRIPT := preload("res://scripts/runtime_v3/ui/ocp_title_bar.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var synthetic_screens: Array[Rect2i] = [
		Rect2i(Vector2i(0, 0), Vector2i(1920, 1080)),
		Rect2i(Vector2i(-1280, 0), Vector2i(1280, 1024)),
	]
	var second_screen := TITLE_BAR_SCRIPT.select_screen_for_rect(
		Rect2i(Vector2i(-1180, 100), Vector2i(900, 620)),
		synthetic_screens,
		0
	)
	var largest_overlap := TITLE_BAR_SCRIPT.select_screen_for_rect(
		Rect2i(Vector2i(-700, 80), Vector2i(1200, 700)),
		synthetic_screens,
		0
	)
	var fallback := TITLE_BAR_SCRIPT.select_screen_for_rect(
		Rect2i(Vector2i(5000, 5000), Vector2i(300, 200)),
		synthetic_screens,
		0
	)

	var first_window := Window.new()
	first_window.visible = false
	first_window.position = Vector2i(90, 70)
	first_window.size = Vector2i(720, 520)
	first_window.min_size = Vector2i(480, 320)
	first_window.borderless = true
	first_window.force_native = true
	get_root().add_child(first_window)
	var first_bar := TITLE_BAR_SCRIPT.new()
	first_bar.configure(first_window, "Settings")
	first_window.add_child(first_bar)

	var second_window := Window.new()
	second_window.visible = false
	second_window.position = Vector2i(240, 150)
	second_window.size = Vector2i(760, 540)
	second_window.min_size = Vector2i(480, 320)
	second_window.borderless = true
	second_window.force_native = true
	get_root().add_child(second_window)
	var second_bar := TITLE_BAR_SCRIPT.new()
	second_bar.configure(second_window, "Chat")
	second_window.add_child(second_bar)
	await process_frame

	var independent_targets := first_bar.target_window == first_window and second_bar.target_window == second_window
	var resize_handles := first_window.find_children("Resize*", "Control", true, false)
	var required_handles := [
		"ResizeTop", "ResizeBottom", "ResizeLeft", "ResizeRight",
		"ResizeTopLeft", "ResizeTopRight", "ResizeBottomLeft", "ResizeBottomRight",
	]
	var resize_geometry := true
	for handle_name in required_handles:
		var handle := first_window.find_child(handle_name, true, false) as Control
		resize_geometry = resize_geometry and is_instance_valid(handle)
		if not is_instance_valid(handle):
			continue
		if handle_name in ["ResizeTopLeft", "ResizeTopRight", "ResizeBottomLeft", "ResizeBottomRight"]:
			resize_geometry = resize_geometry and handle.size.x >= 22.0 and handle.size.y >= 22.0
		elif handle_name in ["ResizeTop", "ResizeBottom"]:
			resize_geometry = resize_geometry and handle.size.x >= 22.0 and handle.size.y >= 12.0
		else:
			resize_geometry = resize_geometry and handle.size.x >= 12.0 and handle.size.y >= 22.0
	var resize_ready := not first_window.unresizable and not second_window.unresizable \
		and resize_handles.size() == 8 and resize_geometry
	var overlays_above_chrome := true
	for handle_name in required_handles:
		var handle := first_window.find_child(handle_name, true, false) as Control
		overlays_above_chrome = overlays_above_chrome and is_instance_valid(handle) \
			and handle.get_parent() == first_window \
			and handle.get_index() > first_bar.get_index()
	var title_bar_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/ui/ocp_title_bar.gd"
	)
	var monitor_safe_maximize := title_bar_source.contains("window_get_current_screen") \
		and title_bar_source.contains("screen_get_usable_rect") \
		and title_bar_source.contains("window_set_position") \
		and title_bar_source.contains("window_set_size") \
		and title_bar_source.contains("window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED") \
		and title_bar_source.contains("restore-retry-required") \
		and title_bar_source.contains("prepare_for_window_rect") \
		and title_bar_source.contains("prepare_for_native_resize") \
		and title_bar_source.contains("resize_blocked_until_primary_release") \
		and not title_bar_source.contains("target_window.hide()") \
		and not title_bar_source.contains("window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED")

	var ok := second_screen == 1 and largest_overlap == 1 and fallback == 0 \
		and independent_targets and resize_ready and overlays_above_chrome \
		and monitor_safe_maximize
	print(
		"[G15.7] screen2=%s largest_overlap=%s fallback=%s independent_targets=%s resize=%s overlays=%s monitor_safe_maximize=%s"
		% [
			str(second_screen == 1).to_lower(),
			str(largest_overlap == 1).to_lower(),
			str(fallback == 0).to_lower(),
			str(independent_targets).to_lower(),
			str(resize_ready).to_lower(),
			str(overlays_above_chrome).to_lower(),
			str(monitor_safe_maximize).to_lower(),
		]
	)
	first_window.queue_free()
	second_window.queue_free()
	await process_frame
	quit(0 if ok else 1)
