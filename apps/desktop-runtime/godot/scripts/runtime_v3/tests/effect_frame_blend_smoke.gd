extends SceneTree

var failures := 0

func check(value: bool, label: String) -> void:
	print("[FX-BLEND] %s=%s" % [label, value])
	if not value:
		failures += 1

func _initialize() -> void:
	var helper = load("res://scripts/runtime_v3/core/effect_frame_blend.gd")
	if helper == null:
		quit(1)
		return
	var image := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var atlas := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	for x in [16, 0]: # Selected range/order must follow SpriteFrames, not atlas indices.
		var tile := AtlasTexture.new()
		tile.atlas = atlas
		tile.region = Rect2(x, 0, 16, 16)
		frames.add_frame(&"default", tile)
	var sprite := AnimatedSprite2D.new()
	sprite.sprite_frames = frames
	sprite.set_frame_and_progress(0, 0.5)
	var state: Dictionary = helper.frame_state(sprite)
	check(state.next_region == Rect2(0, 0, 16, 16), "selected_order")
	check(is_equal_approx(state.weight, 0.5), "half_frame")
	sprite.set_frame_and_progress(1, 0.75)
	state = helper.frame_state(sprite)
	check(state.next_region == Rect2(16, 0, 16, 16), "loop_wrap")
	frames.set_animation_loop(&"default", false)
	state = helper.frame_state(sprite)
	check(state.next_region == state.region and state.weight == 0.0, "burst_holds_last")
	helper.configure(sprite, Color.WHITE, 0.7, true)
	var material := sprite.material
	helper.configure(sprite, Color.CYAN, 0.5, true)
	check(sprite.material == material, "reuse_material")
	sprite.set_frame_and_progress(0, 0.5)
	helper.update(sprite, false)
	check(sprite.material.get_shader_parameter("frame_mix") == 0.0, "reduced_motion")
	check((frames.get_frame_texture(&"default", 0) as AtlasTexture).atlas == atlas, "shared_atlas")
	frames.remove_frame(&"default", 1)
	state = helper.frame_state(sprite)
	check(state.weight == 0.0, "single_frame")
	sprite.free()
	quit(0 if failures == 0 else 1)
