extends SceneTree

const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")

class FakeEffectPackService:
	extends Node
	var package_root := ""
	var procedural_mode := false
	var enabled := {"bodyAura": true, "groundRune": true, "levelUpBurst": true}

	func set_slot_enabled(slot_name: String, value: bool) -> bool:
		if slot_name not in enabled:
			return false
		enabled[slot_name] = value
		return true

	func resolve_slot(slot_name: String, include_disabled: bool = false, _character_id: String = "") -> Dictionary:
		if slot_name not in ["bodyAura", "groundRune", "levelUpBurst"]:
			return {}
		if not include_disabled and not bool(enabled.get(slot_name, true)):
			return {}
		if procedural_mode:
			var procedural_config := {
				"renderer": "procedural-rings-v1",
				"looped": slot_name != "levelUpBurst",
				"fps": 30,
				"durationMs": 1400 if slot_name == "levelUpBurst" else 4000,
				"intensity": 80,
				"speedPermille": 600,
				"tint": "#22D3EE",
				"preset": "halo" if slot_name == "bodyAura" else ("rune" if slot_name == "groundRune" else "burst"),
			}
			if slot_name == "bodyAura":
				procedural_config["anchor"] = "character-center"
			elif slot_name == "groundRune":
				procedural_config["anchor"] = "character-feet"
			else:
				procedural_config["anchor"] = "character-feet-bottom"
				procedural_config["scaleMode"] = "character-height"
				procedural_config["scale"] = 1.05
				procedural_config["offsetX"] = 0
				procedural_config["offsetY"] = 0
			return {
				"packageId": "effect.starter-neon",
				"version": "1.0.0",
				"name": "OCP Starter FX",
				"slot": slot_name,
				"path": package_root,
				"config": procedural_config,
			}

		if slot_name == "levelUpBurst":
			return {}
		var config := {
			"renderer": "sprite-sheet-2d",
			"asset": "preview-aura.png",
			"frameWidth": 64,
			"frameHeight": 64,
			"frameCount": 1,
			"fps": 12,
			"looped": true,
			"anchor": "character-center",
			"scaleMode": "character-height",
			"scale": 1.15,
			"offsetX": 0,
			"offsetY": -6,
			"zIndex": -10,
			"contentBounds": {"x": 0, "y": 0, "width": 64, "height": 64},
			"tint": "#22D3EE",
			"intensity": 100,
		}
		if slot_name == "groundRune":
			config["anchor"] = "character-feet"
			config["scaleMode"] = "character-width"
			config["scale"] = 1.45
			config["offsetY"] = -8
			config["zIndex"] = -20
			# Legacy packs did not author placement-v2 contentBounds. Preview must
			# infer the same stable alpha union as Runtime before placement.
			config.erase("contentBounds")
		return {
			"packageId": "effect.preview-smoke",
			"version": "1.0.0",
			"name": "Preview Smoke",
			"slot": slot_name,
			"path": package_root,
			"config": config,
		}


class FakeServices:
	extends Node
	var effect_pack_service: Node


class FakeRuntimeEffectController:
	extends Node
	var live_snapshot_enabled := false
	var character_rect := Rect2(100, 80, 80, 160)
	var sprite_position := Vector2(192, 304)
	var sprite_scale := Vector2(0.5, 0.5)

	func resolve_preview_effect_placement(
		_slot_name: String,
		_config: Dictionary,
		_content_rect: Rect2,
		_frame_size: Vector2,
		_expected_character_id: String = ""
	) -> Dictionary:
		return {
			"characterId": "character.preview-smoke",
			"characterRect": Rect2(100, 80, 80, 160),
			"surfaceSize": Vector2(384, 384),
			"presentationScale": 1.0,
			"position": Vector2(120, 232),
			"scale": Vector2(0.5, 0.25),
			"z": -20,
		}

	func preview_runtime_character_geometry(_expected_character_id: String = "") -> Dictionary:
		return {
			"characterId": "character.preview-smoke",
			"characterRect": character_rect,
			"surfaceSize": Vector2(384, 384),
			"spritePosition": sprite_position,
			"spriteScale": sprite_scale,
			"presentationScale": 1.0,
			"animation": "idle",
			"frame": 0,
		}

	func capture_live_effect_preview_layer(_slot_name: String, _expected_character_id: String = "") -> Dictionary:
		if not live_snapshot_enabled:
			return {}
		var image := Image.create(40, 20, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		return {
			"image": image,
			"position": Vector2(140, 210),
			"scale": Vector2(2.0, 1.5),
			"z": -20,
			"config": {"tint": "#FFFFFF", "intensity": 100},
		}


func _initialize() -> void:
	var package_root := "user://effect-preview-smoke"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(package_root))
	var aura := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	aura.fill(Color.TRANSPARENT)
	aura.fill_rect(Rect2i(5, 5, 54, 54), Color(1.0, 1.0, 1.0, 0.55))
	var aura_path := package_root.path_join("preview-aura.png")
	if aura.save_png(aura_path) != OK:
		push_error("could not create preview aura fixture")
		quit(1)
		return

	var character := Image.create(160, 240, false, Image.FORMAT_RGBA8)
	character.fill(Color.TRANSPARENT)
	character.fill_rect(Rect2i(28, 12, 104, 216), Color.WHITE)
	var character_bytes := character.save_png_to_buffer()
	var character_encoded := Marshalls.raw_to_base64(character_bytes)

	var fake_effect := FakeEffectPackService.new()
	fake_effect.package_root = package_root
	var fake_services := FakeServices.new()
	fake_services.effect_pack_service = fake_effect
	get_root().add_child(fake_effect)
	get_root().add_child(fake_services)

	var adapter := AdapterScript.new()
	get_root().add_child(adapter)
	adapter.services = fake_services
	adapter.preview_state = adapter._idle_preview_state()
	adapter.preview_state["packageId"] = "character.preview-smoke"
	adapter.preview_state["version"] = "1.0.0"
	adapter.preview_state["selectedAnimation"] = "idle"
	adapter.preview_state["status"] = "ready"
	adapter.preview_active_payload = {
		"animation": "idle",
		"encoded_frames": [character_encoded],
		"frame_width": 160,
		"frame_height": 240,
		"source_frame_width": 160,
		"source_frame_height": 240,
		"source_crop_x": 0,
		"source_crop_y": 0,
		"source_crop_width": 160,
		"source_crop_height": 240,
		"runtime_union_alpha": {"x": 28, "y": 12, "width": 104, "height": 216},
		"runtime_alpha_rects": [{"x": 28, "y": 12, "width": 104, "height": 216}],
		"idle_profile_scale": 1.0,
		"fps": 8.0,
	}
	adapter.preview_animation_cache["idle"] = adapter.preview_active_payload.duplicate(true)

	var colorize_source := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	colorize_source.set_pixel(0, 0, Color(0.0, 1.0, 1.0, 1.0))
	var colorized := adapter._tint_effect_preview_image(colorize_source, Color.from_string("#FACC15", Color.WHITE), 1.0, true)
	var colorized_pixel := colorized.get_pixel(0, 0)
	var colorize_ok := colorized_pixel.r > 0.90 and colorized_pixel.g > 0.70 and colorized_pixel.b < 0.20 and colorized_pixel.a > 0.99

	# Character-first framing must be identical with FX off/on. Preview camera
	# uses fixed pixel targets so enlarging the card adds breathing room instead
	# of scaling the companion. Ground Rune owns the lower FX safe zone.
	adapter.effect_preview_mode = ""
	var base_preview: Dictionary = adapter._compose_preview_frame(character_encoded, 0)
	var base_reference: Rect2 = base_preview.get("displayReferenceRect", Rect2())
	var base_scale := float(base_preview.get("displayScale", 0.0))
	var base_origin: Vector2 = base_preview.get("displayOrigin", Vector2.ZERO)
	var base_display_rect := Rect2(
		base_origin + base_reference.position * base_scale,
		base_reference.size * base_scale
	)
	var fit_ok := not base_preview.is_empty() \
		and int(base_preview.get("width", 0)) > 0 \
		and int(base_preview.get("height", 0)) > 0 \
		and absf(base_display_rect.size.y - 220.0) <= 2.5 \
		and absf(base_display_rect.end.y - 246.0) <= 2.5

	adapter.effect_preview_mode = "bodyAura"
	var composite: Dictionary = adapter._compose_effect_preview_frame(character_encoded)
	var camera_invariant_ok := not composite.is_empty() 		and is_equal_approx(float(composite.get("displayScale", 0.0)), base_scale) 		and (composite.get("displayOrigin", Vector2.ZERO) as Vector2).is_equal_approx(base_origin)
	var composite_ok := not composite.is_empty() 		and int(composite.get("width", 0)) == int(base_preview.get("width", 0)) 		and int(composite.get("height", 0)) == int(base_preview.get("height", 0))

	adapter.effect_preview_tuning.clear()
	var runtime_character_rect: Rect2 = composite.get("runtimeCharacterRect", Rect2(140, 90, 100, 200))
	var legacy_ground_layer := adapter._effect_preview_layer(
		"groundRune",
		runtime_character_rect,
		Vector2(384, 384),
		1.0
	)
	var legacy_ground_image: Image = legacy_ground_layer.get("image") as Image
	var legacy_bounds_ok := not legacy_ground_layer.is_empty() 		and legacy_ground_image != null 		and legacy_ground_image.get_width() > 100 		and int(legacy_ground_layer.get("z", 0)) == -20

	var default_ground_position: Vector2i = legacy_ground_layer.get("position", Vector2i.ZERO)
	adapter.effect_preview_tuning["groundRune"] = {
		"fps": 12,
		"startFrame": 0,
		"endFrame": 0,
		"scale": 1.45,
		"offsetX": 0,
		"offsetY": -40,
		"anchor": "character-feet",
		"scaleMode": "character-width",
	}
	var moved_ground_layer := adapter._effect_preview_layer(
		"groundRune",
		runtime_character_rect,
		Vector2(384, 384),
		1.0
	)
	var moved_ground_position: Vector2i = moved_ground_layer.get("position", Vector2i.ZERO)
	var offset_ok: bool = moved_ground_position.y < default_ground_position.y

	adapter.effect_preview_tuning["groundRune"]["offsetY"] = -8
	adapter.effect_preview_tuning["groundRune"]["scale"] = 2.0
	var scaled_ground_layer := adapter._effect_preview_layer(
		"groundRune",
		runtime_character_rect,
		Vector2(384, 384),
		1.0
	)
	var scaled_ground_image: Image = scaled_ground_layer.get("image") as Image
	var effect_scale_ok := scaled_ground_image != null \
		and legacy_ground_image != null \
		and scaled_ground_image.get_width() > legacy_ground_image.get_width()

	# When Runtime is available, Preview must project Runtime's placement result
	# into its own canonical character rect instead of resolving anchors again.
	var fake_runtime_effect := FakeRuntimeEffectController.new()
	get_root().add_child(fake_runtime_effect)
	adapter.bind_effect_controller(fake_runtime_effect)
	adapter.effect_preview_tuning.clear()
	var runtime_sourced_layer := adapter._effect_preview_layer(
		"groundRune",
		runtime_character_rect,
		Vector2(384, 384),
		1.0
	)
	var runtime_sourced_center: Vector2 = runtime_sourced_layer.get("center", Vector2.ZERO)
	var relation_x := runtime_character_rect.size.x / 80.0
	var relation_y := runtime_character_rect.size.y / 160.0
	var expected_runtime_center := runtime_character_rect.position + Vector2(
		(120.0 - 100.0) * relation_x,
		(232.0 - 80.0) * relation_y
	)
	var runtime_geometry_ok := str(runtime_sourced_layer.get("placementSource", "")) == "runtime" \
		and runtime_sourced_center.distance_to(expected_runtime_center) <= 0.5
	adapter.effect_preview_mode = "bodyAura"
	# Simulate opening Character Manager while the live Runtime is temporarily on
	# a tiny transition frame. Preview geometry must come from its own payload,
	# using only Runtime's native surface/scale, so this transient rect cannot
	# blow the character up.
	fake_runtime_effect.character_rect = Rect2(185, 340, 14, 32)
	var runtime_character_composite := adapter._compose_preview_frame(character_encoded, 0)
	var expected_preview_runtime_rect := Rect2(166, 276, 52, 108)
	var runtime_character_geometry_ok := str(runtime_character_composite.get("geometrySource", "")) == "runtime-scale-native-anchor-camera-locked" \
		and (runtime_character_composite.get("runtimeCharacterRect", Rect2()) as Rect2).is_equal_approx(expected_preview_runtime_rect)
	var locked_scale := float(runtime_character_composite.get("displayScale", 0.0))
	var locked_origin: Vector2 = runtime_character_composite.get("displayOrigin", Vector2.ZERO)
	# Simulate Runtime alpha bounds changing on the next animation frame while the
	# actual sprite transform remains fixed. The Character Manager camera must not
	# refit/zoom to the new visual rect.
	fake_runtime_effect.character_rect = Rect2(108, 92, 64, 136)
	var next_runtime_character_composite := adapter._compose_preview_frame(character_encoded, 0)
	var camera_lock_ok := is_equal_approx(float(next_runtime_character_composite.get("displayScale", 0.0)), locked_scale) \
		and (next_runtime_character_composite.get("displayOrigin", Vector2.ZERO) as Vector2).is_equal_approx(locked_origin) \
		and (next_runtime_character_composite.get("runtimeCharacterRect", Rect2()) as Rect2).is_equal_approx(expected_preview_runtime_rect)

	fake_runtime_effect.live_snapshot_enabled = true
	adapter.effect_preview_tuning.clear()
	var live_node_layer := adapter._effect_preview_layer(
		"groundRune",
		runtime_character_rect,
		Vector2(384, 384),
		1.0
	)
	var live_node_image: Image = live_node_layer.get("image") as Image
	var live_node_ok := str(live_node_layer.get("placementSource", "")) == "runtime-live-node" \
		and str(live_node_layer.get("assetSource", "")) == "runtime-live-frame" \
		and (live_node_layer.get("center", Vector2.ZERO) as Vector2).distance_to(Vector2(140, 210)) <= 0.01 \
		and live_node_image != null \
		and live_node_image.get_size() == Vector2i(80, 30)
	adapter.bind_effect_controller(null)
	fake_runtime_effect.queue_free()

	# Built-in Starter FX uses procedural-rings-v1 rather than a sprite sheet.
	# Character Manager must still render every slot, and disabling a slot must
	# immediately remove it from the composite preview.
	fake_effect.procedural_mode = true
	adapter.effect_preview_tuning.clear()
	var procedural_aura := adapter._effect_preview_layer("bodyAura", runtime_character_rect, Vector2(384, 384), 1.0)
	var procedural_rune := adapter._effect_preview_layer("groundRune", runtime_character_rect, Vector2(384, 384), 1.0)
	var procedural_burst := adapter._effect_preview_layer("levelUpBurst", runtime_character_rect, Vector2(384, 384), 1.0)
	var procedural_burst_center: Vector2 = procedural_burst.get("center", Vector2.ZERO)
	var procedural_burst_position: Vector2i = procedural_burst.get("position", Vector2i.ZERO)
	var procedural_burst_image: Image = procedural_burst.get("image") as Image
	var procedural_burst_ground_ok := not procedural_burst.is_empty() \
		and absf(procedural_burst_center.y - (runtime_character_rect.end.y - 8.0)) <= 0.5 \
		and procedural_burst_image != null \
		and procedural_burst_position.y < int(round(procedural_burst_center.y)) \
		and procedural_burst_position.y + procedural_burst_image.get_height() <= int(round(procedural_burst_center.y + 24.0))
	var procedural_ok := not procedural_aura.is_empty() \
		and not procedural_rune.is_empty() \
		and not procedural_burst.is_empty() \
		and procedural_burst_ground_ok \
		and str(procedural_aura.get("assetSource", "")) == "procedural-rings-v1" \
		and str(procedural_rune.get("assetSource", "")) == "procedural-rings-v1" \
		and str(procedural_burst.get("assetSource", "")) == "procedural-rings-v1" \
		and int(procedural_aura.get("z", 0)) == -10 \
		and int(procedural_rune.get("z", 0)) == -20 \
		and int(procedural_burst.get("z", 0)) >= 0
	adapter.effect_preview_mode = "all"
	var disable_result := adapter._set_effect_pack_slot_enabled({"type": "effect-pack.slot-enabled", "slot": "bodyAura", "enabled": false})
	var disabled_aura := adapter._effect_preview_layer("bodyAura", runtime_character_rect, Vector2(384, 384), 1.0)
	adapter.effect_preview_mode = "bodyAura"
	var disabled_slot_inspection := adapter._effect_preview_layer("bodyAura", runtime_character_rect, Vector2(384, 384), 1.0)
	var toggle_ok := str(disable_result.get("status", "")) == "succeeded" \
		and disabled_aura.is_empty() \
		and not disabled_slot_inspection.is_empty()
	adapter._set_effect_pack_slot_enabled({"type": "effect-pack.slot-enabled", "slot": "bodyAura", "enabled": true})
	fake_effect.procedural_mode = false
	adapter.effect_preview_mode = ""

	adapter.effect_preview_tuning.clear()
	var started: Dictionary = adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "bodyAura"})
	var active_ok := str(started.get("status", "")) == "succeeded" 		and adapter.effect_preview_mode == "bodyAura" 		and int(adapter.preview_state.get("frameWidth", 0)) > 0

	var tuned: Dictionary = adapter._preview_effect_pack_tune({
		"type": "effect-pack.preview-tune",
		"slot": "bodyAura",
		"tuning": {"fps": 24, "startFrame": 0, "endFrame": 0, "scale": 0.75, "offsetX": 12, "offsetY": -18, "anchor": "character-center", "scaleMode": "character-height"},
	})
	var tune_queued_ok := adapter.effect_preview_refresh_pending
	adapter._update_effect_preview(0.0)
	var tune_ok := str(tuned.get("status", "")) == "succeeded" 		and int((adapter.effect_preview_tuning.get("bodyAura", {}) as Dictionary).get("fps", 0)) == 24 		and is_equal_approx(float((adapter.effect_preview_tuning.get("bodyAura", {}) as Dictionary).get("scale", 0.0)), 0.75) 		and tune_queued_ok 		and not adapter.effect_preview_refresh_pending

	var invalid_tune: Dictionary = adapter._preview_effect_pack_tune({
		"type": "effect-pack.preview-tune",
		"slot": "bodyAura",
		"tuning": {"fps": 60, "startFrame": 0, "endFrame": 0, "scale": 0.75, "offsetX": 12, "offsetY": -18, "anchor": "character-center", "scaleMode": "character-height"},
	})
	var invalid_tune_ok := str(invalid_tune.get("status", "")) == "failed"

	var stopped: Dictionary = adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "off"})
	var stop_ok := str(stopped.get("status", "")) == "succeeded" 		and adapter.effect_preview_mode.is_empty() 		and int(adapter.preview_state.get("frameWidth", 0)) > 0 		and int(adapter.preview_state.get("frameHeight", 0)) > 0

	print("[DESKTOP-SHELL-EFFECT-PREVIEW] composite=%s fit=%s camera_invariant=%s camera_lock=%s legacy_bounds=%s offset=%s effect_scale=%s runtime_geometry=%s runtime_character_geometry=%s live_node=%s procedural=%s toggle=%s colorize=%s active=%s tune=%s invalid_tune=%s stop=%s" % [
		str(composite_ok).to_lower(),
		str(fit_ok).to_lower(),
		str(camera_invariant_ok).to_lower(),
		str(camera_lock_ok).to_lower(),
		str(legacy_bounds_ok).to_lower(),
		str(offset_ok).to_lower(),
		str(effect_scale_ok).to_lower(),
		str(runtime_geometry_ok).to_lower(),
		str(runtime_character_geometry_ok).to_lower(),
		str(live_node_ok).to_lower(),
		str(procedural_ok).to_lower(),
		str(toggle_ok).to_lower(),
		str(colorize_ok).to_lower(),
		str(active_ok).to_lower(),
		str(tune_ok).to_lower(),
		str(invalid_tune_ok).to_lower(),
		str(stop_ok).to_lower(),
	])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(aura_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(package_root))
	quit(0 if composite_ok and fit_ok and camera_invariant_ok and camera_lock_ok and legacy_bounds_ok and offset_ok and effect_scale_ok and runtime_geometry_ok and runtime_character_geometry_ok and live_node_ok and procedural_ok and toggle_ok and colorize_ok and active_ok and tune_ok and invalid_tune_ok and stop_ok else 1)
