extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed := load("res://scenes/runtime_v3/RuntimeApp.tscn") as PackedScene
	var runtime := packed.instantiate()
	var app := runtime.get_node("ApplicationWindow") as Window
	runtime.remove_child(app)
	runtime.free()
	get_root().add_child(app)
	app.position = Vector2i(140, 90)
	app.size = Vector2i(1050, 720)
	app.show()
	await process_frame
	await process_frame
	await process_frame
	var before := app.get_texture().get_image()
	var before_center := before.get_pixel(before.get_width() / 2, before.get_height() / 2)
	var bar := app.get_node("OcpTitleBar")
	bar.call("_toggle_maximize")
	for i in range(6):
		await process_frame
	var after := app.get_texture().get_image()
	var center := after.get_pixel(after.get_width() / 2, after.get_height() / 2)
	var sample := after.get_pixel(mini(320, after.get_width()-1), mini(120, after.get_height()-1))
	var rendered := center.a > 0.5 and (center.r + center.g + center.b) > 0.03 and sample.a > 0.5 and (sample.r + sample.g + sample.b) > 0.03
	print("[P3.4.9] production_render_after_max before=", before.get_size(), " after=", after.get_size(), " before_center=", before_center, " center=", center, " sample=", sample, " rendered=", rendered, " app_size=", app.size)
	app.queue_free()
	await process_frame
	quit(0 if rendered else 1)
