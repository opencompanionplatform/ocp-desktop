extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var script = load("res://scripts/runtime_v3/core/effect_comparison_renderer.gd")
	if script == null:
		quit(1)
		return
	var renderer = script.new()
	root.add_child(renderer)
	var sheet := Image.create(32, 16, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)
	sheet.fill_rect(Rect2i(0, 0, 16, 16), Color.WHITE)
	var a: Image = renderer.blend(sheet, "fixture", Rect2i(0, 0, 16, 16), Rect2i(16, 0, 16, 16), 0.5)
	var passed := a != null and absf(a.get_pixel(8, 8).a - 0.5) < 0.04 and a.get_pixel(8, 8).r > 0.95
	var original: Image = renderer.blend(sheet, "fixture", Rect2i(0, 0, 16, 16), Rect2i(16, 0, 16, 16), 0.0)
	passed = passed and original.get_pixel(8, 8).a > 0.95 and renderer.textures.size() == 1
	var mist_a: Image = renderer.mist(Color.CYAN, 0.9, 0.0)
	var mist_b: Image = renderer.mist(Color.CYAN, 0.9, 2.0)
	print("pixels=", a.get_pixel(8, 8), " original=", original.get_pixel(8, 8), " mist=", mist_a.get_used_rect(), " changed=", mist_a.get_data() != mist_b.get_data())
	passed = passed and mist_a.get_used_rect().has_area() and mist_a.get_data() != mist_b.get_data()
	print("[EffectComparisonGPU] blend_alpha_and_straight_rgb, shared_texture, moving_mist: ", passed)
	renderer.free()
	quit(0 if passed else 1)
