extends RefCounted
## Opt-in presentation experiment. Samples the same atlas twice; never decodes images per tick.

const BLEND_SHADER = preload("res://scripts/runtime_v3/core/effect_frame_blend.gdshader")
const MIST_SHADER = preload("res://scripts/runtime_v3/core/effect_starter_mist.gdshader")

static func frame_state(sprite: AnimatedSprite2D) -> Dictionary:
	var frames := sprite.sprite_frames
	if frames == null or not frames.has_animation(sprite.animation):
		return {}
	var count := frames.get_frame_count(sprite.animation)
	if count == 0:
		return {}
	var index := clampi(sprite.frame, 0, count - 1)
	var next := index + 1
	if next >= count:
		next = 0 if frames.get_animation_loop(sprite.animation) else index
	var current := frames.get_frame_texture(sprite.animation, index) as AtlasTexture
	var following := frames.get_frame_texture(sprite.animation, next) as AtlasTexture
	if current == null or following == null or current.atlas != following.atlas:
		return {}
	return {
		"region": current.region, "next_region": following.region,
		"atlas_size": current.atlas.get_size(),
		"weight": clampf(sprite.frame_progress, 0.0, 1.0) if index != next else 0.0,
	}

static func configure(sprite: AnimatedSprite2D, tint: Color, intensity: float, colorize: bool) -> void:
	var material := sprite.material as ShaderMaterial
	if material == null or material.shader != BLEND_SHADER:
		material = ShaderMaterial.new()
		material.shader = BLEND_SHADER
		sprite.material = material
	# Keep atlas coordinates coherent even if AnimatedSprite advances after the
	# controller's process callback in this frame.
	var on_frame := update.bind(sprite)
	if not sprite.frame_changed.is_connected(on_frame):
		sprite.frame_changed.connect(on_frame)
	material.set_shader_parameter("target_color", tint)
	material.set_shader_parameter("effect_intensity", intensity)
	material.set_shader_parameter("colorize", colorize)
	sprite.modulate = Color.WHITE
	update(sprite)

static func update(sprite: AnimatedSprite2D, motion_allowed: bool = true) -> void:
	var material := sprite.material as ShaderMaterial
	if material == null or material.shader != BLEND_SHADER:
		return
	var state := frame_state(sprite)
	if state.is_empty():
		material.set_shader_parameter("frame_mix", 0.0)
		return
	var size: Vector2 = state.atlas_size
	var region: Rect2 = state.region
	var following: Rect2 = state.next_region
	material.set_shader_parameter("current_rect", Vector4(region.position.x / size.x, region.position.y / size.y, region.size.x / size.x, region.size.y / size.y))
	material.set_shader_parameter("next_rect", Vector4(following.position.x / size.x, following.position.y / size.y, following.size.x / size.x, following.size.y / size.y))
	material.set_shader_parameter("frame_mix", state.weight if motion_allowed else 0.0)

static func create_mist(tint: Color, intensity: float) -> ColorRect:
	var mist := ColorRect.new()
	mist.name = "StarterMistTrial"
	mist.position = Vector2(-124, -128)
	mist.size = Vector2(248, 256)
	mist.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = MIST_SHADER
	material.set_shader_parameter("tint", tint)
	material.set_shader_parameter("intensity", intensity)
	mist.material = material
	return mist

static func update_mist(aura: Node2D, elapsed: float) -> void:
	var mist := aura.get_node_or_null("StarterMistTrial") as ColorRect
	if mist != null:
		(mist.material as ShaderMaterial).set_shader_parameter("clock_seconds", elapsed)
