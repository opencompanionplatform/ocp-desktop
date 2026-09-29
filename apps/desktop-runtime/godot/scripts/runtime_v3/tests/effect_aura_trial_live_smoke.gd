extends "res://scripts/runtime_v3/tests/effect_aura_trial_preview.gd"

func setup() -> void:
	var extensions := GDExtensionManager.get_loaded_extensions()
	print("[FX-LIVE] no_native_extensions=%s" % extensions.is_empty())
	if not extensions.is_empty():
		push_error("Aura Preview must not load runtime native extensions or lock the bridge DLL.")
		quit(1)
		return
	await super.setup()
	var sprite: AnimatedSprite2D = controllers[0].relationship_aura
	var first := sprite.frame
	var mist: ColorRect = controllers[3].relationship_aura.get_node("StarterMistTrial")
	var clock_before: float = mist.material.get_shader_parameter("clock_seconds")
	await RenderingServer.frame_post_draw
	var image_before := root.get_texture().get_image().get_region(Rect2i(0, 70, 230, 240)).get_data()
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 650:
		await RenderingServer.frame_post_draw
	var clock_after: float = mist.material.get_shader_parameter("clock_seconds")
	var moving := sprite.frame != first and clock_after > clock_before
	var image_after := root.get_texture().get_image().get_region(Rect2i(0, 70, 230, 240)).get_data()
	var pixels_changed := image_before != image_after
	print("[FX-LIVE] moving=%s frame=%s->%s mist=%s->%s paused=%s can_process=%s playing=%s" % [moving, first, sprite.frame, clock_before, clock_after, paused, sprite.can_process(), sprite.is_playing()])
	var key := InputEventKey.new()
	key.physical_keycode = KEY_M
	key.pressed = true
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	await RenderingServer.frame_post_draw
	var input_ok := not motion
	print("[FX-LIVE] engine_input=%s viewport_disabled=%s" % [input_ok, root.is_input_disabled()])
	var paused_frame := sprite.frame
	started = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 250:
		await RenderingServer.frame_post_draw
	var paused_ok := sprite.frame == paused_frame
	# Resume through the engine input path (not direct signal emission).
	key.pressed = false
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	key.pressed = true
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	key.pressed = false
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	key.physical_keycode = KEY_B
	key.pressed = true
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	await RenderingServer.frame_post_draw
	var burst_ok: bool = controllers[0].level_up_burst != null and controllers[1].level_up_burst != null
	var resumed_ok := motion
	# Hit-test the actual GUI button through the viewport, rather than emitting pressed.
	var mouse := InputEventMouseButton.new()
	mouse.position = motion_button.get_global_rect().get_center()
	mouse.global_position = mouse.position
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	root.push_input(mouse, true)
	mouse = mouse.duplicate()
	mouse.pressed = false
	root.push_input(mouse, true)
	await RenderingServer.frame_post_draw
	var click_ok := not motion
	print("[FX-LIVE] pixels_changed=%s pause_holds_frame=%s resumed=%s engine_burst=%s button_hit_test=%s" % [pixels_changed, paused_ok, resumed_ok, burst_ok, click_ok])
	if not (moving and pixels_changed and input_ok and paused_ok and resumed_ok and burst_ok and click_ok):
		quit(1)
		return
	key.pressed = false
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	key.physical_keycode = KEY_ESCAPE
	key.pressed = true
	Input.parse_input_event(key.duplicate())
	Input.flush_buffered_events()
	print("[FX-LIVE] Escape sent through engine; process must exit before launcher timeout")
