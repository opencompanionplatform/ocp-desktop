extends SceneTree

const EffectControllerScript = preload("res://scripts/runtime_v3/controllers/effect_controller.gd")
const RuntimeContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var temp_root := "user://sprite_fx_smoke"
	var assets_dir := temp_root.path_join("assets")
	DirAccess.make_dir_recursive_absolute(assets_dir)
	var image := Image.create(1024, 512, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(0, 0, 512, 512), Color(0.0, 0.9, 1.0, 1.0))
	image.fill_rect(Rect2i(512, 0, 512, 512), Color(0.8, 0.2, 1.0, 1.0))
	var asset_path := assets_dir.path_join("bodyAura.png")
	var save_error := image.save_png(asset_path)
	if save_error != OK:
		print("[EFFECT-SPRITE] save=false")
		quit(1)
		return

	var host := Control.new()
	host.size = Vector2(384, 384)
	var character := AnimatedSprite2D.new()
	character.position = Vector2(192, 205)
	var character_position_before_effects := character.position
	host.add_child(character)
	root.add_child(host)

	var controller := EffectControllerScript.new()
	root.add_child(controller)
	var runtime_context := RuntimeContextScript.new()
	root.add_child(runtime_context)
	runtime_context.character["presentation_scale"] = 1.0
	controller.context = runtime_context
	controller.bind_effect_layer(host, character)

	var config := {
		"renderer": "sprite-sheet-2d",
		"anchor": "character-center",
		"layer": "back-aura",
		"looped": true,
		"fps": 12,
		"durationMs": 166,
		"intensity": 90,
		"speedPermille": 1000,
		"tint": "#FFFFFF",
		"asset": "assets/bodyAura.png",
		"frameWidth": 512,
		"frameHeight": 512,
		"frameCount": 2,
		"_packagePath": temp_root,
	}
	var effect := controller._build_effect_pack_sprite("bodyAura", config)
	var first_load_metrics: Dictionary = controller.performance_snapshot()
	var first_load_performance_ok := int(first_load_metrics.get("lastBuildMs", 999999)) <= controller.EFFECT_FIRST_LOAD_ACCEPTANCE_MS \
		and int(first_load_metrics.get("lastAtlasBytes", 999999999)) <= controller.EFFECT_RUNTIME_ATLAS_BYTE_CAP \
		and int(first_load_metrics.get("slowBuildCount", 1)) == 0
	var stress_frame_size: Vector2i = controller._runtime_atlas_frame_size(2048, 2048, 12, 10)
	var stress_atlas_bytes := 12 * 10 * stress_frame_size.x * stress_frame_size.y * 4
	var memory_gate_ok := stress_frame_size.x <= controller.EFFECT_RUNTIME_FRAME_CAP \
		and stress_frame_size.y <= controller.EFFECT_RUNTIME_FRAME_CAP \
		and stress_atlas_bytes <= controller.EFFECT_RUNTIME_ATLAS_BYTE_CAP
	await process_frame

	var built_ok := is_instance_valid(effect)
	var frame_ok := built_ok 		and effect.sprite_frames != null 		and effect.sprite_frames.get_frame_count(&"effect") == 2 		and effect.sprite_frames.get_animation_loop(&"effect")
	var layer_ok := built_ok and effect.z_index == -10 and effect.z_as_relative == false and effect.get_parent().name == "BackBodyEffects"
	var anchor_ok := built_ok 		and effect.position.x >= 124.0 		and effect.position.x <= host.size.x - 124.0 		and effect.position.y >= 128.0 		and effect.position.y <= host.size.y - 128.0
	var style_ok := built_ok and is_equal_approx(effect.modulate.a, 0.9)
	var first_texture: Texture2D = effect.sprite_frames.get_frame_texture(&"effect", 0) if built_ok else null
	var downscale_ok := first_texture is AtlasTexture \
		and (first_texture as AtlasTexture).region.size == Vector2(384, 384) \
		and (first_texture as AtlasTexture).atlas.get_size() == Vector2(768, 384)
	var preview_asset := controller.prepare_effect_preview_asset(config)
	var preview_asset_image: Image = preview_asset.get("image") as Image
	var preview_asset_ok := not preview_asset.is_empty() \
		and preview_asset_image != null \
		and preview_asset_image.get_size() == Vector2i(768, 384) \
		and int(preview_asset.get("frameWidth", 0)) == 384 \
		and int(preview_asset.get("frameHeight", 0)) == 384 \
		and (preview_asset.get("contentRect", Rect2()) as Rect2).size == Vector2(384, 384)
	var variant_config := config.duplicate(true)
	variant_config["tint"] = "#FACC15"
	variant_config["intensity"] = 100
	variant_config["speedPermille"] = 1120
	variant_config["_colorize"] = true
	var reuse_ok := controller._can_reuse_effect_pack_sprite(effect, config, variant_config)
	controller._apply_effect_pack_sprite_style(effect, "bodyAura", variant_config)
	reuse_ok = reuse_ok \
		and is_equal_approx(effect.modulate.a, 1.0) \
		and effect.modulate.r > 0.9 \
		and effect.material is ShaderMaterial \
		and effect.sprite_frames.get_animation_speed(&"effect") > 13.0 \
		and effect.sprite_frames.get_frame_texture(&"effect", 0) == first_texture

	var range_config := config.duplicate(true)
	range_config["startFrame"] = 1
	range_config["endFrame"] = 1
	var ranged := controller._build_effect_pack_sprite("bodyAura", range_config)
	await process_frame
	var ranged_texture: Texture2D = ranged.sprite_frames.get_frame_texture(&"effect", 0) if is_instance_valid(ranged) else null
	var frame_range_ok := is_instance_valid(ranged) \
		and ranged.sprite_frames.get_frame_count(&"effect") == 1 \
		and ranged_texture is AtlasTexture \
		and is_equal_approx((ranged_texture as AtlasTexture).region.position.x, 384.0)
	if is_instance_valid(ranged):
		ranged.queue_free()

	# Runtime placement must follow the actual companion presentation scale.
	# This reproduces the production BIBLE size-control path without rebuilding
	# the Effect Pack atlas.
	var character_image := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	character_image.fill(Color.TRANSPARENT)
	character_image.fill_rect(Rect2i(72, 16, 112, 228), Color.WHITE)
	var character_texture := ImageTexture.create_from_image(character_image)
	character_texture.set_meta(&"ocp_alpha_rect", Rect2i(72, 16, 112, 228))
	var character_frames := SpriteFrames.new()
	if character_frames.has_animation(&"default"):
		character_frames.remove_animation(&"default")
	character_frames.add_animation(&"idle")
	character_frames.add_frame(&"idle", character_texture)
	character.sprite_frames = character_frames
	character.animation = &"idle"
	character.scale = Vector2.ONE
	controller._apply_effect_pack_sprite_transform(effect, "bodyAura", config)
	var full_character_effect_scale := effect.scale.x
	character.scale = Vector2.ONE * 0.5
	controller._apply_effect_pack_sprite_transform(effect, "bodyAura", config)
	var half_character_effect_scale := effect.scale.x
	var dynamic_scale_ok := full_character_effect_scale > 0.0 \
		and is_equal_approx(half_character_effect_scale, full_character_effect_scale * 0.5)
	character.scale = Vector2.ONE
	controller._apply_effect_pack_sprite_transform(effect, "bodyAura", config)

	# Authored offsets must scale with the selected presentation preset, and an
	# oversized 125% aura must stay centered on the character instead of being
	# shifted by an impossible native-surface clamp.
	var offset_config := config.duplicate(true)
	offset_config["offsetX"] = 20
	offset_config["offsetY"] = -6
	runtime_context.character["presentation_scale"] = 0.25
	character.scale = Vector2.ONE * 0.25
	controller._apply_effect_pack_sprite_transform(effect, "bodyAura", offset_config)
	var quarter_center := controller._character_visual_rect().get_center()
	var quarter_offset_ok := effect.position.distance_to(quarter_center + Vector2(5.0, -1.5)) <= 0.25
	runtime_context.character["presentation_scale"] = 1.25
	character.scale = Vector2.ONE * 2.0
	controller._apply_effect_pack_sprite_transform(effect, "bodyAura", offset_config)
	var oversized_center := controller._character_visual_rect().get_center()
	var oversized_anchor_ok := effect.position.distance_to(oversized_center + Vector2(25.0, -7.5)) <= 0.25
	runtime_context.character["presentation_scale"] = 1.0
	character.scale = Vector2.ONE
	controller._apply_effect_pack_sprite_transform(effect, "bodyAura", config)

	var ground_config := config.duplicate(true)
	ground_config["anchor"] = "character-feet"
	ground_config["layer"] = "ground-rune"
	ground_config["scaleMode"] = "character-width"
	ground_config["scale"] = 1.40
	ground_config["offsetY"] = 0
	ground_config["zIndex"] = -20
	ground_config["maxHeightRatio"] = 0.32
	var ground := controller._build_effect_pack_sprite("groundRune", ground_config)
	await process_frame
	var ground_texture: Texture2D = ground.sprite_frames.get_frame_texture(&"effect", 0) if is_instance_valid(ground) else null
	var ground_half_h := (ground_texture.get_size().y * ground.scale.y * 0.5) if ground_texture != null else 0.0
	var ground_ok := is_instance_valid(ground) \
		and ground.get_parent().name == "GroundEffects" \
		and ground.z_index == -20 \
		and ground.position.y > character.position.y \
		and ground.scale.y < ground.scale.x \
		and ground.position.y + ground_half_h <= host.size.y + 0.1

	var burst_config := config.duplicate(true)
	burst_config["anchor"] = "character-feet-bottom"
	burst_config["layer"] = "front-fx"
	burst_config["scaleMode"] = "character-height"
	burst_config["scale"] = 1.10
	burst_config["offsetY"] = 0
	burst_config["zIndex"] = 20
	var burst := controller._build_effect_pack_sprite("levelUpBurst", burst_config)
	await process_frame
	var burst_texture: Texture2D = burst.sprite_frames.get_frame_texture(&"effect", 0) if is_instance_valid(burst) else null
	var burst_half_h := (burst_texture.get_size().y * burst.scale.y * 0.5) if burst_texture != null else 0.0
	var expected_burst_bottom := controller._character_visual_rect().end.y
	var burst_ground_anchor_ok := is_instance_valid(burst) \
		and burst.get_parent().name == "FrontEffects" \
		and burst.z_index == 20 \
		and absf((burst.position.y + burst_half_h) - expected_burst_bottom) <= 0.25
	# Ground-plane effects must never move the actual Runtime companion. The
	# standing-on-rune illusion comes from feet anchoring/z-order, not a physics
	# or sprite lift that would break WALK/LAND/CLIMB ground contracts.
	var character_not_lifted_ok := character.position.is_equal_approx(character_position_before_effects)

	# Desktop Shell preview asks EffectController for the exact Runtime placement
	# contract, then only projects that geometry into the editor camera.
	runtime_context.character["id"] = "character.preview-smoke"
	var ground_content_rect := controller._effect_content_rect_runtime(ground, ground_config)
	var runtime_contract := controller.resolve_preview_effect_placement(
		"groundRune",
		ground_config,
		ground_content_rect,
		ground_texture.get_size() if ground_texture != null else Vector2.ONE,
		"character.preview-smoke"
	)
	var runtime_contract_ok := not runtime_contract.is_empty() \
		and (runtime_contract.get("position", Vector2.ZERO) as Vector2).distance_to(ground.position) <= 0.25 \
		and (runtime_contract.get("scale", Vector2.ZERO) as Vector2).distance_to(ground.scale) <= 0.001 \
		and int(runtime_contract.get("z", 0)) == ground.z_index

	controller.relationship_aura = effect
	controller.relationship_aura_config = config.duplicate(true)
	controller.ground_rune = ground
	controller.ground_rune_config = ground_config.duplicate(true)
	controller.level_up_burst = burst
	var live_aura_snapshot := controller.capture_live_effect_preview_layer("bodyAura", "character.preview-smoke")
	var live_aura_image: Image = live_aura_snapshot.get("image") as Image
	var live_snapshot_ok := not live_aura_snapshot.is_empty() \
		and live_aura_image != null \
		and not live_aura_image.is_empty() \
		and live_aura_image.get_size() == Vector2i(384, 384) \
		and (live_aura_snapshot.get("position", Vector2.ZERO) as Vector2).distance_to(effect.position) <= 0.01 \
		and (live_aura_snapshot.get("scale", Vector2.ZERO) as Vector2).distance_to(Vector2(absf(effect.scale.x), absf(effect.scale.y))) <= 0.001 \
		and int(live_aura_snapshot.get("z", 0)) == effect.z_index
	controller._on_presentation_suppressed_changed({"suppressed": true})
	await process_frame
	var release_ok := not is_instance_valid(effect) and not is_instance_valid(ground) and not is_instance_valid(burst) and controller.presentation_suppressed
	var ok := built_ok and frame_ok and layer_ok and anchor_ok and style_ok and downscale_ok and preview_asset_ok and reuse_ok and frame_range_ok and dynamic_scale_ok and quarter_offset_ok and oversized_anchor_ok and ground_ok and burst_ground_anchor_ok and character_not_lifted_ok and runtime_contract_ok and live_snapshot_ok and first_load_performance_ok and memory_gate_ok and release_ok
	print("[EFFECT-SPRITE] built=%s frames=%s layer=%s anchor=%s style=%s downscale=%s preview_asset=%s reuse=%s frame_range=%s dynamic_scale=%s quarter_offset=%s oversized_anchor=%s ground=%s burst_ground=%s character_not_lifted=%s runtime_contract=%s live_snapshot=%s first_load_perf=%s memory_gate=%s release=%s" % [
		str(built_ok).to_lower(),
		str(frame_ok).to_lower(),
		str(layer_ok).to_lower(),
		str(anchor_ok).to_lower(),
		str(style_ok).to_lower(),
		str(downscale_ok).to_lower(),
		str(preview_asset_ok).to_lower(),
		str(reuse_ok).to_lower(),
		str(frame_range_ok).to_lower(),
		str(dynamic_scale_ok).to_lower(),
		str(quarter_offset_ok).to_lower(),
		str(oversized_anchor_ok).to_lower(),
		str(ground_ok).to_lower(),
		str(burst_ground_anchor_ok).to_lower(),
		str(character_not_lifted_ok).to_lower(),
		str(runtime_contract_ok).to_lower(),
		str(live_snapshot_ok).to_lower(),
		str(first_load_performance_ok).to_lower(),
		str(memory_gate_ok).to_lower(),
		str(release_ok).to_lower(),
	])
	quit(0 if ok else 1)
