extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var window := Window.new()
	window.visible = false
	window.title = "OCP native OS mode smoke"
	window.position = Vector2i(140, 110)
	window.size = Vector2i(540, 340)
	window.min_size = Vector2i(320, 200)
	window.borderless = true
	window.force_native = true
	get_root().add_child(window)
	window.show()
	await process_frame
	await process_frame
	var id := window.get_window_id()
	var original_position := DisplayServer.window_get_position(id)
	var original_size := DisplayServer.window_get_size(id)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED, id)
	await process_frame
	await process_frame
	await process_frame
	var max_mode := DisplayServer.window_get_mode(id)
	var max_pos := DisplayServer.window_get_position(id)
	var max_size := DisplayServer.window_get_size(id)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED, id)
	await process_frame
	await process_frame
	await process_frame
	var restore_mode := DisplayServer.window_get_mode(id)
	var restore_pos := DisplayServer.window_get_position(id)
	var restore_size := DisplayServer.window_get_size(id)
	var ok := id != DisplayServer.INVALID_WINDOW_ID and max_mode == DisplayServer.WINDOW_MODE_MAXIMIZED and restore_mode == DisplayServer.WINDOW_MODE_WINDOWED
	print("[P3.4.6] os_native_modes id=", id, " max_mode=", max_mode, " max_pos=", max_pos, " max_size=", max_size, " restore_mode=", restore_mode, " restore_pos=", restore_pos, " restore_size=", restore_size, " original_pos=", original_position, " original_size=", original_size)
	window.queue_free()
	await process_frame
	quit(0 if ok else 1)
