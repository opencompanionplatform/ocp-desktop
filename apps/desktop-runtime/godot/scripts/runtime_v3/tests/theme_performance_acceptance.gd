extends SceneTree

const AmbientWaveScript = preload("res://scripts/runtime_v3/ui/ambient_wave.gd")
const GlassShader = preload("res://shaders/glass_panel.gdshader")
const LiquidShader = preload("res://shaders/liquid_panel.gdshader")

const VIEWPORT_SIZE := Vector2i(1280, 820)
const WARMUP_FRAMES := 90
const SAMPLE_FRAMES := 180
const MIN_ACCEPTABLE_FPS := 30.0
const MAX_RELATIVE_FRAME_COST := 1.65

var _root_control: Control
var _ambient: Control
var _panels: Array[ColorRect] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DisplayServer.window_set_size(VIEWPORT_SIZE)
	DisplayServer.window_set_position(Vector2i(40, 40))

	_root_control = Control.new()
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_root().add_child(_root_control)

	var background := ColorRect.new()
	background.color = Color("#07111f")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_control.add_child(background)

	_ambient = AmbientWaveScript.new()
	background.add_child(_ambient)
	_ambient.configure("shell")

	_create_panel_grid(background)

	for _frame in range(30):
		await process_frame

	var results: Dictionary = {}
	for theme_name in ["solid", "glass", "liquid"]:
		_apply_theme(theme_name)
		for _frame in range(WARMUP_FRAMES):
			await process_frame
		results[theme_name] = await _sample_theme(theme_name)

	var solid_ms := float(results["solid"]["averageFrameMs"])
	var pass_all := true
	for theme_name in ["glass", "liquid"]:
		var item: Dictionary = results[theme_name]
		var average_fps := float(item["averageFps"])
		var relative_cost := float(item["averageFrameMs"]) / maxf(solid_ms, 0.001)
		item["relativeFrameCost"] = relative_cost
		item["pass"] = average_fps >= MIN_ACCEPTABLE_FPS and relative_cost <= MAX_RELATIVE_FRAME_COST
		results[theme_name] = item
		pass_all = pass_all and bool(item["pass"])

	results["solid"]["pass"] = float(results["solid"]["averageFps"]) >= MIN_ACCEPTABLE_FPS
	pass_all = pass_all and bool(results["solid"]["pass"])

	print("OCP_THEME_PERF_REPORT=" + JSON.stringify(results))
	print("OCP_THEME_PERF_PASS=" + str(pass_all).to_lower())
	quit(0 if pass_all else 1)


func _create_panel_grid(parent: Control) -> void:
	var positions := [
		Rect2(80, 120, 330, 180),
		Rect2(455, 120, 330, 180),
		Rect2(830, 120, 330, 180),
		Rect2(80, 340, 520, 180),
		Rect2(640, 340, 520, 180),
		Rect2(80, 560, 330, 160),
		Rect2(455, 560, 330, 160),
		Rect2(830, 560, 330, 160),
	]
	for rect in positions:
		var panel := ColorRect.new()
		panel.position = rect.position
		panel.size = rect.size
		panel.color = Color(0.08, 0.15, 0.24, 0.74)
		parent.add_child(panel)
		_panels.append(panel)


func _apply_theme(theme_name: String) -> void:
	_ambient.apply_ocp_theme({"accent": Color("#23b7ff")}, theme_name)
	var shader: Shader = null
	if theme_name == "glass":
		shader = GlassShader
	elif theme_name == "liquid":
		shader = LiquidShader

	for panel in _panels:
		if shader == null:
			panel.material = null
			panel.color = Color(0.08, 0.15, 0.24, 0.92)
		else:
			var material := ShaderMaterial.new()
			material.shader = shader
			panel.material = material
			panel.color = Color.WHITE


func _sample_theme(theme_name: String) -> Dictionary:
	var frame_times_ms: Array[float] = []
	var previous_us := Time.get_ticks_usec()
	for _frame in range(SAMPLE_FRAMES):
		await process_frame
		var now_us := Time.get_ticks_usec()
		frame_times_ms.append(float(now_us - previous_us) / 1000.0)
		previous_us = now_us

	frame_times_ms.sort()
	var total_ms := 0.0
	for value in frame_times_ms:
		total_ms += value
	var average_ms := total_ms / float(frame_times_ms.size())
	var p95_index := clampi(int(ceil(float(frame_times_ms.size()) * 0.95)) - 1, 0, frame_times_ms.size() - 1)
	var p95_ms := frame_times_ms[p95_index]
	var average_fps := 1000.0 / maxf(average_ms, 0.001)
	var memory_mb := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	return {
		"theme": theme_name,
		"sampleFrames": frame_times_ms.size(),
		"averageFrameMs": snappedf(average_ms, 0.001),
		"p95FrameMs": snappedf(p95_ms, 0.001),
		"averageFps": snappedf(average_fps, 0.1),
		"memoryMb": snappedf(memory_mb, 0.1),
	}
