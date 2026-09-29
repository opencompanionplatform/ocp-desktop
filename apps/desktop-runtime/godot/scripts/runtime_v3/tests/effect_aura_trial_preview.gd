extends SceneTree
## Standalone A/B preview. Never starts RuntimeApp or reads installed packages/settings.
const Controller = preload("res://scripts/runtime_v3/controllers/effect_controller.gd")
const Context = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const Blend = preload("res://scripts/runtime_v3/core/effect_frame_blend.gd")
var controllers: Array[Node] = []
var pack: Dictionary
var pack_path := ""
var capture_path := ""
var elapsed := 0.0
var captured := false
var motion := true
var motion_button: Button
var playback_status: Label
var last_action := "Ready"
var next_status_update := 0.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pack="):
			pack_path = arg.trim_prefix("--pack=")
		if arg.begins_with("--capture="):
			capture_path = arg.trim_prefix("--capture=")
	call_deferred("setup")

func label_at(text: String, position: Vector2, size: int = 18) -> void:
	var label := Label.new()
	label.text = text
	label.position = position
	label.add_theme_font_size_override("font_size", size)
	root.add_child(label)

func setup() -> void:
	root.size = Vector2i(1120, 500)
	root.content_scale_size = Vector2i(1120, 500)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	root.transparent_bg = false
	root.borderless = false
	root.always_on_top = false
	root.set_flag(Window.FLAG_NO_FOCUS, false)
	root.set_disable_input(false)
	root.title = "OCP Aura trial r3 — live playback"
	root.window_input.connect(_input)
	root.close_requested.connect(quit)
	RenderingServer.set_default_clear_color(Color("111927"))
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(pack_path.path_join("assets/effect.json")))
	if not parsed is Dictionary:
		push_error("Supply --pack=<extracted preview package directory>")
		quit(1)
		return
	pack = parsed
	var titles := ["VIDEO ORIGINAL", "VIDEO FRAME BLEND", "STARTER ORIGINAL", "STARTER + MIST"]
	for index in range(4):
		label_at(titles[index], Vector2(15 + index * 280, 12))
	label_at("Source: uploaded video-neon 1.0.0", Vector2(15, 38), 14)
	label_at("Procedural Starter FX (different artwork)", Vector2(575, 38), 14)
	label_at("4 s / 48 frames / 12 FPS | Preview controls only: click this window before using keys.", Vector2(15, 385), 15)
	for index in range(4):
		var host := Control.new()
		host.position = Vector2(index * 280, 60)
		host.size = Vector2(280, 320)
		root.add_child(host)
		var character := AnimatedSprite2D.new()
		var image := Image.create(90, 190, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		image.fill_rect(Rect2i(23, 5, 44, 44), Color("adb8cc"))
		image.fill_rect(Rect2i(12, 54, 66, 100), Color("647590"))
		image.fill_rect(Rect2i(15, 150, 23, 40), Color("adb8cc"))
		image.fill_rect(Rect2i(52, 150, 23, 40), Color("adb8cc"))
		var frames := SpriteFrames.new()
		frames.add_frame(&"default", ImageTexture.create_from_image(image))
		character.sprite_frames = frames
		character.position = Vector2(140, 170)
		host.add_child(character)
		var controller := Controller.new()
		controller.frame_blend_trial = index == 1
		controller.starter_mist_trial = index == 3
		var context := Context.new()
		root.add_child(context)
		controller.context = context
		root.add_child(controller)
		controller.bind_effect_layer(host, character)
		host.clip_contents = true # Separate comparison panels, not runtime clipping policy.
		controllers.append(controller)
		if index < 2:
			controller._build_relationship_aura("close", slot_config("bodyAura"))
			controller._build_ground_rune(slot_config("groundRune"))
		else:
			controller._build_relationship_aura("close", {"tint": "#66d9ff", "intensity": 90, "speedPermille": 600})
			controller._build_ground_rune({"tint": "#66d9ff", "intensity": 90})
	add_button("BurstButton", "[B] Burst (video panels)", Vector2(15, 410), play_burst)
	motion_button = add_button("MotionButton", "[M] Reduce Motion: OFF", Vector2(300, 410), toggle_motion)
	add_button("CloseButton", "[Esc] Close preview", Vector2(590, 410), quit)
	playback_status = Label.new()
	playback_status.position = Vector2(15, 457)
	playback_status.add_theme_font_size_override("font_size", 16)
	root.add_child(playback_status)
	await verify_gpu_blend()
	# Synchronize both videos after decoding, so an A/B view compares the same instant.
	for controller in controllers.slice(0, 2):
		controller.relationship_aura.set_frame_and_progress(0, 0.0)
		controller.ground_rune.set_frame_and_progress(0, 0.0)
	elapsed = 0.0
	root.grab_focus()

func slot_config(slot: String) -> Dictionary:
	var config: Dictionary = pack.slots[slot].duplicate(true)
	config["_packagePath"] = pack_path
	return config

func verify_gpu_blend() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(16, 16)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var image := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	image.fill_rect(Rect2i(0, 0, 16, 16), Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	for x in [0, 16]:
		var tile := AtlasTexture.new()
		tile.atlas = texture
		tile.region = Rect2(x, 0, 16, 16)
		frames.add_frame(&"default", tile)
	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = frames
	sprite.position = Vector2(8, 8)
	sprite.set_frame_and_progress(0, 0.5)
	viewport.add_child(sprite)
	Blend.configure(sprite, Color.WHITE, 1.0, false)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var pixel := viewport.get_texture().get_image().get_pixel(8, 8)
	# Transparent viewport readback contains premultiplied RGB: half-white is 0.5,
	# whereas a dark fringe from straight-alpha interpolation would yield 0.25.
	var passed := absf(pixel.a - 0.5) < 0.04 and absf(pixel.r - 0.5) < 0.04
	print("[FX-GPU] premultiplied_blend=%s pixel=%s" % [passed, pixel])
	viewport.queue_free()
	if not passed:
		quit(1)

func _process(delta: float) -> bool:
	elapsed += delta
	if is_instance_valid(playback_status) and controllers.size() == 4 and elapsed >= next_status_update:
		next_status_update = elapsed + 0.1
		var video: AnimatedSprite2D = controllers[0].relationship_aura
		playback_status.text = "%s | Video frame %02d/48 | Time %.1fs | %s" % ["PLAYING" if motion else "REDUCED MOTION", video.frame + 1, elapsed, last_action]
	if not capture_path.is_empty() and elapsed > 2.0 and not captured and controllers.size() == 4:
		captured = true
		capture.call_deferred()
	return false

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		match key:
			KEY_B:
				play_burst()
			KEY_M:
				toggle_motion()
			KEY_ESCAPE:
				quit()

func add_button(node_name: String, text: String, position: Vector2, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.position = position
	button.size = Vector2(270, 32)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	root.add_child(button)
	return button

func play_burst() -> void:
	last_action = "Burst received"
	print("[FX-INPUT] burst")
	for controller in controllers.slice(0, 2):
		controller._clear_level_up_burst()
		var burst: AnimatedSprite2D = controller._build_effect_pack_sprite("levelUpBurst", slot_config("levelUpBurst"))
		controller.level_up_burst = burst
		burst.animation_finished.connect(controller._clear_level_up_burst, CONNECT_ONE_SHOT)
		if not motion:
			burst.pause()

func toggle_motion() -> void:
	motion = not motion
	last_action = "Motion resumed" if motion else "Motion paused"
	print("[FX-INPUT] motion=%s" % motion)
	if is_instance_valid(motion_button):
		motion_button.text = "[M] Reduce Motion: OFF" if motion else "[M] Reduce Motion: ON"
	for controller in controllers:
		controller.context.settings["reduce_motion"] = not motion
		for effect in [controller.relationship_aura, controller.ground_rune, controller.level_up_burst]:
			if effect is AnimatedSprite2D:
				if motion:
					effect.play()
				else:
					effect.pause()

func capture() -> void:
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(capture_path)
	print("[FX-PREVIEW] capture=%s" % error)
	quit(0 if error == OK else 1)
