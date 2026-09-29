extends Node
## Bounded editor-only readback. Uses the actual trial shaders, not an imitation.
const Blend = preload("res://scripts/runtime_v3/core/effect_frame_blend.gd")
var viewport: SubViewport
var sprite: Sprite2D
var fog: ColorRect
var textures: Dictionary = {}

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.transparent_bg = true
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	sprite = Sprite2D.new()
	sprite.centered = false
	sprite.region_enabled = true
	sprite.material = _readback_material(Blend.BLEND_SHADER)
	viewport.add_child(sprite)
	fog = Blend.create_mist(Color.WHITE, 1.0)
	fog.position = Vector2.ZERO
	fog.material = _readback_material(Blend.MIST_SHADER)
	viewport.add_child(fog)

func _readback_material(source: Shader) -> ShaderMaterial:
	# Image.blend_rect expects straight RGBA. Disable framebuffer blending for
	# this single-layer pass; the shared shader still computes the same colors.
	var shader := Shader.new()
	shader.code = source.code.replace("shader_type canvas_item;", "shader_type canvas_item;\nrender_mode blend_disabled;")
	var material := ShaderMaterial.new()
	material.shader = shader
	return material

func blend(sheet: Image, key: String, current: Rect2i, following: Rect2i, weight: float) -> Image:
	if not textures.has(key):
		# At most three slot atlases; discarded with this node on stop/switch.
		if textures.size() >= 3:
			textures.clear()
		textures[key] = ImageTexture.create_from_image(sheet)
	sprite.texture = textures[key]
	sprite.region_rect = Rect2(current)
	sprite.visible = true
	fog.visible = false
	var size := Vector2(sheet.get_size())
	var material := sprite.material as ShaderMaterial
	for entry in [["current_rect", current], ["next_rect", following]]:
		var rect: Rect2i = entry[1]
		material.set_shader_parameter(entry[0], Vector4(rect.position.x / size.x, rect.position.y / size.y, rect.size.x / size.x, rect.size.y / size.y))
	material.set_shader_parameter("frame_mix", clampf(weight, 0.0, 1.0))
	RenderingServer.canvas_item_clear(sprite.get_canvas_item())
	RenderingServer.canvas_item_add_texture_rect_region(sprite.get_canvas_item(), Rect2(Vector2.ZERO, Vector2(current.size)), sprite.texture.get_rid(), Rect2(current))
	return _capture(current.size)

func mist(tint: Color, intensity: float, seconds: float) -> Image:
	sprite.visible = false
	fog.visible = true
	var material := fog.material as ShaderMaterial
	material.set_shader_parameter("tint", tint)
	material.set_shader_parameter("intensity", intensity)
	material.set_shader_parameter("clock_seconds", seconds)
	RenderingServer.canvas_item_clear(fog.get_canvas_item())
	RenderingServer.canvas_item_add_rect(fog.get_canvas_item(), Rect2(Vector2.ZERO, fog.size), Color.WHITE)
	return _capture(Vector2i(248, 256))

func _capture(size: Vector2i) -> Image:
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.force_draw(false)
	var result := viewport.get_texture().get_image()
	if result != null:
		result.convert(Image.FORMAT_RGBA8)
	return result
