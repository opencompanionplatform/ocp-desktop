extends SceneTree

const TitleBarScript := preload("res://scripts/runtime_v3/ui/ocp_title_bar.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var window := Window.new()
	window.visible = false
	window.title = "render maximize smoke"
	window.position = Vector2i(120, 90)
	window.size = Vector2i(900, 620)
	window.min_size = Vector2i(640, 420)
	window.borderless = true
	window.force_native = true
	get_root().add_child(window)

	var bg := ColorRect.new()
	bg.color = Color("#173b72")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	window.add_child(bg)
	var label := Label.new()
	label.text = "VISIBLE"
	label.position = Vector2(80, 80)
	label.add_theme_font_size_override("font_size", 48)
	bg.add_child(label)

	var title_bar = TitleBarScript.new()
	title_bar.configure(window, "")
	window.add_child(title_bar)
	window.show()
	await process_frame
	await process_frame
	await process_frame
	var window_id := window.get_window_id()
	var original_position := DisplayServer.window_get_position(window_id)
	var original_size := DisplayServer.window_get_size(window_id)

	var before := window.get_texture().get_image()
	var before_color := before.get_pixel(before.get_width() / 2, before.get_height() / 2)
	title_bar._toggle_maximize()
	await process_frame
	await process_frame
	await process_frame
	await process_frame
	var after := window.get_texture().get_image()
	var after_color := after.get_pixel(after.get_width() / 2, after.get_height() / 2)
	var rendered := after_color.b > 0.1 and after_color.a > 0.5
	await title_bar._toggle_maximize()
	await process_frame
	await process_frame
	await process_frame
	var restored_position := DisplayServer.window_get_position(window_id)
	var restored_size := DisplayServer.window_get_size(window_id)
	var restored: bool = restored_position == original_position and restored_size == original_size \
		and not title_bar.manual_maximized
	print("[P3.4.8] render_after_max before_size=", before.get_size(), " after_size=", after.get_size(), " before=", before_color, " after=", after_color, " rendered=", rendered, " restored=", restored, " restored_position=", restored_position, " restored_size=", restored_size)
	window.queue_free()
	await process_frame
	quit(0 if rendered and restored else 1)
