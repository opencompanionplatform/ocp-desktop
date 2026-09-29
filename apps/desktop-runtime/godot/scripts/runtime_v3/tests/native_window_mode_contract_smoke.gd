extends SceneTree

const TitleBarScript := preload("res://scripts/runtime_v3/ui/ocp_title_bar.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var window := Window.new()
	window.visible = false
	window.title = "OCP window mode smoke"
	window.position = Vector2i(120, 90)
	window.size = Vector2i(520, 320)
	window.min_size = Vector2i(320, 200)
	window.borderless = true
	window.force_native = true
	get_root().add_child(window)

	var title_bar = TitleBarScript.new()
	title_bar.configure(window, "")
	window.add_child(title_bar)
	window.show()
	await process_frame
	await process_frame

	var window_id := window.get_window_id()
	var valid_id := window_id != DisplayServer.INVALID_WINDOW_ID
	var original_position := window.position
	var original_size := window.size
	var screen := DisplayServer.window_get_current_screen(window_id)
	if screen < 0:
		screen = DisplayServer.get_primary_screen()

	await title_bar._toggle_maximize()
	await process_frame
	await process_frame
	var maximized_screen := DisplayServer.window_get_current_screen(window.get_window_id())
	var headless := DisplayServer.get_name().to_lower() == "headless"
	var maximized: bool = bool(title_bar.manual_maximized) \
		and title_bar.restore_screen == screen \
		and (headless or maximized_screen == screen)

	await title_bar._toggle_maximize()
	await process_frame
	await process_frame
	var restored_screen := DisplayServer.window_get_current_screen(window.get_window_id())
	title_bar._process(0.0)
	var restore_resize_guard_rearmed: bool = not title_bar.resize_blocked_until_primary_release
	var restored: bool = not bool(title_bar.manual_maximized) \
		and window.position == original_position \
		and window.size == original_size \
		and (headless or restored_screen == screen) \
		and restore_resize_guard_rearmed

	title_bar._minimize()
	await process_frame
	await process_frame
	var minimized := DisplayServer.window_get_mode(window_id) == DisplayServer.WINDOW_MODE_MINIMIZED

	print("[P3.4.5] native_window_controls id=", window_id, " max=", maximized, " restore=", restored, " restore_resize_rearmed=", restore_resize_guard_rearmed, " min=", minimized)
	window.queue_free()
	await process_frame
	quit(0 if valid_id and maximized and restored and minimized else 1)
