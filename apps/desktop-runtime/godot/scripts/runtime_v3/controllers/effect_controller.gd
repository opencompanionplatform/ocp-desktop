extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3EffectController

const EFFECT_RUNTIME_FRAME_CAP := 384
const EFFECT_RUNTIME_ATLAS_BYTE_CAP := 32 * 1024 * 1024
const EFFECT_FIRST_LOAD_ACCEPTANCE_MS := 150
const EffectPlacementResolver = preload("res://scripts/runtime_v3/core/effect_placement_resolver.gd")
const EffectFrameBlend = preload("res://scripts/runtime_v3/core/effect_frame_blend.gd")

# Internal trial switches; no package/manifest contract change.
var frame_blend_trial := OS.get_environment("OCP_EFFECT_FRAME_BLEND") == "1"
var starter_mist_trial := OS.get_environment("OCP_STARTER_MIST") == "1"

## Character/3 presentation-only effect layer.
##
## Runtime owns WHEN/WHY an effect is requested; Character/3 owns HOW it looks.
## Effects never mutate progression, physics, targeting or game state.

var host: Control
var sprite: AnimatedSprite2D
var active_effects: Dictionary = {}
var runtime_portal: Node2D
var runtime_portal_tween: Tween
var relationship_aura: Node2D
var relationship_aura_rank := ""
var relationship_aura_time := 0.0
var relationship_aura_signature := ""
var relationship_aura_config: Dictionary = {}
var ground_rune: Node2D
var ground_rune_time := 0.0
var ground_rune_signature := ""
var ground_rune_config: Dictionary = {}
var level_up_burst: Node2D
var resource_pressure := "normal"
var presentation_suppressed := false
var ground_effects_layer: Node2D
var back_body_effects_layer: Node2D
var front_effects_layer: Node2D
var effect_colorize_shader: Shader
var effect_performance_metrics := {
	"lastSlot": "",
	"lastBuildMs": 0,
	"lastDecodeMs": 0,
	"lastAtlasBytes": 0,
	"peakAtlasBytes": 0,
	"slowBuildCount": 0,
}


func bind_effect_layer(character_host: Control, character_sprite: AnimatedSprite2D) -> void:
	host = character_host
	sprite = character_sprite
	_ensure_effect_layers()
	if is_instance_valid(host):
		host.clip_contents = false


func _ensure_effect_layers() -> void:
	if not is_instance_valid(host):
		return
	if not is_instance_valid(ground_effects_layer):
		ground_effects_layer = Node2D.new()
		ground_effects_layer.name = "GroundEffects"
		host.add_child(ground_effects_layer)
	if not is_instance_valid(back_body_effects_layer):
		back_body_effects_layer = Node2D.new()
		back_body_effects_layer.name = "BackBodyEffects"
		host.add_child(back_body_effects_layer)
	if not is_instance_valid(front_effects_layer):
		front_effects_layer = Node2D.new()
		front_effects_layer.name = "FrontEffects"
		host.add_child(front_effects_layer)


func _effect_parent(slot_name: String) -> Node:
	_ensure_effect_layers()
	if slot_name == "groundRune" and is_instance_valid(ground_effects_layer):
		return ground_effects_layer
	if slot_name == "levelUpBurst" and is_instance_valid(front_effects_layer):
		return front_effects_layer
	if is_instance_valid(back_body_effects_layer):
		return back_body_effects_layer
	return host


func start() -> void:
	event_bus.subscribe(&"effect.requested", Callable(self, "_on_effect_requested"))
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.subscribe(&"cloud.progression.updated", Callable(self, "_on_progression_updated"))
	event_bus.subscribe(&"progression.effects.changed", Callable(self, "_on_progression_effects_changed"))
	event_bus.subscribe(&"effect_pack.changed", Callable(self, "_on_effect_pack_changed"))
	event_bus.subscribe(&"effect_pack.preview_requested", Callable(self, "_on_effect_pack_preview_requested"))
	event_bus.subscribe(&"companion.presentation_suppressed_changed", Callable(self, "_on_presentation_suppressed_changed"))
	event_bus.subscribe(&"progression.celebration_shown", Callable(self, "_on_progression_celebration_shown"))
	event_bus.subscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor_updated"))
	# CharacterService always publishes character.loaded during startup (including
	# the emergency fallback path). Wait for that event instead of allocating
	# large Effect Pack atlases before the character package is ready; the old
	# eager refresh caused the same Body Aura/Ground Rune textures to be built
	# twice during boot and briefly doubled unified-memory pressure.


func stop() -> void:
	event_bus.unsubscribe(&"effect.requested", Callable(self, "_on_effect_requested"))
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.unsubscribe(&"cloud.progression.updated", Callable(self, "_on_progression_updated"))
	event_bus.unsubscribe(&"progression.effects.changed", Callable(self, "_on_progression_effects_changed"))
	event_bus.unsubscribe(&"effect_pack.changed", Callable(self, "_on_effect_pack_changed"))
	event_bus.unsubscribe(&"effect_pack.preview_requested", Callable(self, "_on_effect_pack_preview_requested"))
	event_bus.unsubscribe(&"companion.presentation_suppressed_changed", Callable(self, "_on_presentation_suppressed_changed"))
	event_bus.unsubscribe(&"progression.celebration_shown", Callable(self, "_on_progression_celebration_shown"))
	event_bus.unsubscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor_updated"))
	_clear_all_effects()
	_clear_runtime_portal()
	_clear_relationship_aura()
	_clear_ground_rune()
	_clear_level_up_burst()


func _on_character_loaded(_payload: Dictionary = {}) -> void:
	_clear_all_effects()
	_clear_runtime_portal()
	_clear_relationship_aura()
	_clear_ground_rune()
	_clear_level_up_burst()
	call_deferred("_refresh_equipped_effects")


func _process(delta: float) -> void:
	if frame_blend_trial:
		for effect in [relationship_aura, ground_rune, level_up_burst]:
			if is_instance_valid(effect) and effect is AnimatedSprite2D and effect.visible:
				EffectFrameBlend.update(effect, _aura_motion_allowed())
	if is_instance_valid(relationship_aura) and relationship_aura.visible:
		if relationship_aura is AnimatedSprite2D:
			_apply_effect_pack_sprite_transform(relationship_aura as AnimatedSprite2D, "bodyAura", relationship_aura_config)
		else:
			relationship_aura.position = _relationship_aura_position()
			if _aura_motion_allowed():
				relationship_aura_time += delta
				var aura_speed := maxf(0.1, float(relationship_aura_config.get("speedPermille", 600)) / 1000.0)
				var pulse := 1.0 + sin(relationship_aura_time * 2.4 * aura_speed) * 0.035
				relationship_aura.scale = Vector2(pulse, pulse)
				relationship_aura.rotation = sin(relationship_aura_time * 0.65 * aura_speed) * 0.025
			else:
				relationship_aura.scale = Vector2.ONE
				relationship_aura.rotation = 0.0
			if starter_mist_trial:
				var mist_speed := maxf(0.1, float(relationship_aura_config.get("speedPermille", 600)) / 1000.0)
				EffectFrameBlend.update_mist(relationship_aura, relationship_aura_time * mist_speed)

	if is_instance_valid(ground_rune) and ground_rune.visible:
		if ground_rune is AnimatedSprite2D:
			_apply_effect_pack_sprite_transform(ground_rune as AnimatedSprite2D, "groundRune", ground_rune_config)
		else:
			ground_rune.position = _ground_rune_position()
			if _aura_motion_allowed():
				ground_rune_time += delta
				var rune_speed := maxf(0.1, float(ground_rune_config.get("speedPermille", 500)) / 1000.0)
				ground_rune.rotation = ground_rune_time * 0.22 * rune_speed
				var rune_pulse := 1.0 + sin(ground_rune_time * 1.8 * rune_speed) * 0.025
				ground_rune.scale = Vector2(rune_pulse, rune_pulse)
			else:
				ground_rune.rotation = 0.0
				ground_rune.scale = Vector2.ONE


func _on_progression_updated(_payload: Dictionary = {}) -> void:
	_refresh_equipped_effects()


func _on_progression_effects_changed(_payload: Dictionary = {}) -> void:
	_refresh_equipped_effects()


func _on_effect_pack_changed(_payload: Dictionary = {}) -> void:
	_refresh_equipped_effects()


func _on_effect_pack_preview_requested(_payload: Dictionary = {}) -> void:
	if presentation_suppressed:
		return
	_refresh_equipped_effects()
	_play_equipped_level_up_burst()
	if is_instance_valid(relationship_aura) and relationship_aura.visible:
		var tween := create_tween()
		tween.tween_property(relationship_aura, "scale", Vector2(1.16, 1.16), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(relationship_aura, "scale", Vector2.ONE, 0.32)


func _on_presentation_suppressed_changed(payload: Dictionary) -> void:
	var suppressed := bool(payload.get("suppressed", false))
	if presentation_suppressed == suppressed:
		return
	presentation_suppressed = suppressed
	if suppressed:
		# Focused shell surfaces hide the native companion. Release sprite-sheet
		# GPU textures while hidden instead of keeping large atlases resident
		# beside Chromium preview resources.
		_clear_relationship_aura()
		_clear_ground_rune()
		_clear_level_up_burst()
		print("[EffectPack] presentation-suppressed=true heavy-textures-released")
		return
	print("[EffectPack] presentation-suppressed=false restoring-equipped-effects")
	call_deferred("_refresh_equipped_effects")


func _on_resource_monitor_updated(payload: Dictionary) -> void:
	var pressure := str(payload.get("pressure", "normal"))
	resource_pressure = pressure if pressure in ["normal", "high"] else "normal"
	_refresh_equipped_effects()


func _on_progression_celebration_shown(_payload: Dictionary = {}) -> void:
	if presentation_suppressed:
		return
	if is_instance_valid(relationship_aura) and relationship_aura.visible:
		var tween := create_tween()
		if relationship_aura is AnimatedSprite2D:
			var target_alpha := clampf(float(relationship_aura_config.get("intensity", 100)) / 100.0, 0.0, 1.0)
			tween.tween_property(relationship_aura, "modulate:a", 1.0, 0.12)
			tween.tween_property(relationship_aura, "modulate:a", target_alpha, 0.34)
		else:
			tween.set_parallel(true)
			tween.tween_property(relationship_aura, "scale", Vector2(1.22, 1.22), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			tween.tween_property(relationship_aura, "modulate:a", 1.0, 0.12)
			tween.chain().tween_property(relationship_aura, "scale", Vector2.ONE, 0.34)
			tween.parallel().tween_property(relationship_aura, "modulate:a", _aura_alpha_for_rank(relationship_aura_rank), 0.34)
	_play_equipped_level_up_burst()


func _refresh_equipped_effects() -> void:
	if presentation_suppressed:
		return
	_refresh_relationship_aura()
	_refresh_ground_rune()


func _refresh_relationship_aura() -> void:
	if not is_instance_valid(host) or not is_instance_valid(sprite) or not is_instance_valid(context):
		return
	if not bool(context.settings.get("progression_aura_enabled", false)):
		_clear_relationship_aura()
		return

	var rank := _current_relationship_rank()
	if rank.is_empty():
		rank = "stranger"
	var config := {}
	var effect_pack_service := _effect_pack_service()
	if is_instance_valid(effect_pack_service):
		var resolved_value: Variant = effect_pack_service.resolve_slot("bodyAura")
		# An installed Effect Pack service is authoritative. An empty resolution
		# means the slot is disabled/unequipped; do not resurrect the legacy aura
		# fallback or the Character Manager checkbox can never turn Aura off.
		if not resolved_value is Dictionary or (resolved_value as Dictionary).is_empty():
			_clear_relationship_aura()
			return
		var config_value: Variant = (resolved_value as Dictionary).get("config", {})
		if config_value is Dictionary:
			config = (config_value as Dictionary).duplicate(true)
			config["_packagePath"] = str((resolved_value as Dictionary).get("path", ""))
	if not config.is_empty() and not config.has("contentBounds") and relationship_aura_config.has("contentBounds"):
		config["contentBounds"] = (relationship_aura_config.get("contentBounds", {}) as Dictionary).duplicate(true)
	# Keep the procedural legacy fallback only for runtimes without Effect Pack
	# services. Normal OCP V3 runs always use the service state above.
	if config.is_empty():
		config = {
			"renderer": "procedural-rings-v1",
			"preset": "halo",
			"tint": _aura_color_for_rank(rank).to_html(false),
			"intensity": int(round(_legacy_aura_alpha_for_rank(rank) * 100.0)),
			"speedPermille": 600,
		}
	var signature := JSON.stringify(config)
	if not is_instance_valid(relationship_aura):
		_build_relationship_aura(rank, config)
	elif signature != relationship_aura_signature:
		if _can_reuse_effect_pack_sprite(relationship_aura, relationship_aura_config, config):
			relationship_aura_config = config.duplicate(true)
			relationship_aura_signature = signature
			relationship_aura_rank = rank
			_apply_effect_pack_sprite_style(relationship_aura as AnimatedSprite2D, "bodyAura", config)
		else:
			_build_relationship_aura(rank, config)
	if is_instance_valid(relationship_aura):
		relationship_aura.visible = true
		if relationship_aura is AnimatedSprite2D:
			_apply_effect_pack_sprite_transform(relationship_aura as AnimatedSprite2D, "bodyAura", relationship_aura_config)
		else:
			relationship_aura.position = _relationship_aura_position()
			relationship_aura.modulate.a = _aura_alpha_for_rank(rank)


func _refresh_ground_rune() -> void:
	if not is_instance_valid(host) or not is_instance_valid(sprite):
		return
	var resolved := {}
	var effect_pack_service := _effect_pack_service()
	if is_instance_valid(effect_pack_service):
		var value: Variant = effect_pack_service.resolve_slot("groundRune")
		if value is Dictionary:
			resolved = value as Dictionary
	if resolved.is_empty():
		_clear_ground_rune()
		return
	var config_value: Variant = resolved.get("config", {})
	if not config_value is Dictionary:
		_clear_ground_rune()
		return
	var config := (config_value as Dictionary).duplicate(true)
	config["_packagePath"] = str(resolved.get("path", ""))
	if not config.has("contentBounds") and ground_rune_config.has("contentBounds"):
		config["contentBounds"] = (ground_rune_config.get("contentBounds", {}) as Dictionary).duplicate(true)
	var signature := JSON.stringify(config)
	if not is_instance_valid(ground_rune):
		_build_ground_rune(config)
	elif signature != ground_rune_signature:
		if _can_reuse_effect_pack_sprite(ground_rune, ground_rune_config, config):
			ground_rune_config = config.duplicate(true)
			ground_rune_signature = signature
			_apply_effect_pack_sprite_style(ground_rune as AnimatedSprite2D, "groundRune", config)
		else:
			_build_ground_rune(config)
	if is_instance_valid(ground_rune):
		ground_rune.visible = true
		if ground_rune is AnimatedSprite2D:
			_apply_effect_pack_sprite_transform(ground_rune as AnimatedSprite2D, "groundRune", ground_rune_config)
		else:
			ground_rune.position = _ground_rune_position()


func _current_relationship_rank() -> String:
	if not is_instance_valid(services) or not is_instance_valid(services.cloud_progression_service):
		return ""
	var progression_service: Node = services.cloud_progression_service
	if not progression_service.has_method("canonical_projection"):
		return ""
	var projection_value: Variant = progression_service.call("canonical_projection")
	if not projection_value is Dictionary:
		return ""
	var character_id := str(context.character.get("id", "")).strip_edges()
	if character_id.is_empty():
		return ""
	var companions_value: Variant = (projection_value as Dictionary).get("companions", [])
	if not companions_value is Array:
		return ""
	for companion_value in companions_value:
		if not companion_value is Dictionary:
			continue
		var companion: Dictionary = companion_value
		if str(companion.get("characterId", "")) != character_id:
			continue
		var relationship_value: Variant = companion.get("relationship", {})
		if relationship_value is Dictionary:
			return str((relationship_value as Dictionary).get("bondRank", "stranger"))
	return ""


func _build_relationship_aura(rank: String, config: Dictionary = {}) -> void:
	_clear_relationship_aura()
	if not is_instance_valid(host):
		return
	if str(config.get("renderer", "")) == "sprite-sheet-2d":
		var sprite_effect := _build_effect_pack_sprite("bodyAura", config)
		if is_instance_valid(sprite_effect):
			relationship_aura = sprite_effect
			relationship_aura_rank = rank
			relationship_aura_time = 0.0
			relationship_aura_config = config.duplicate(true)
			relationship_aura_signature = JSON.stringify(config)
		return
	var root := Node2D.new()
	root.name = "RelationshipAura"
	# Body Aura owns only the behind-body halo. Ground geometry belongs to the
	# independent Ground Rune slot; baking floor ellipses into Aura caused a
	# duplicate rune whenever both Starter FX slots were enabled.
	root.z_index = -10
	root.position = _relationship_aura_position()
	var color := _effect_color(str(config.get("tint", "")), _aura_color_for_rank(rank))
	var intensity := clampf(float(config.get("intensity", 70)) / 100.0, 0.05, 1.0)
	if starter_mist_trial:
		root.add_child(EffectFrameBlend.create_mist(color, intensity))
	root.add_child(_aura_ring(Vector2(112.0, 126.0), 3.6, Color(color, 0.62 * intensity)))
	root.add_child(_aura_ring(Vector2(94.0, 108.0), 2.2, Color(color.lightened(0.20), 0.48 * intensity)))
	root.z_as_relative = false
	_effect_parent("bodyAura").add_child(root)
	relationship_aura = root
	relationship_aura_rank = rank
	relationship_aura_time = 0.0
	relationship_aura_config = config.duplicate(true)
	relationship_aura_signature = JSON.stringify(config)
	root.modulate.a = _aura_alpha_for_rank(rank)


func _relationship_aura_position() -> Vector2:
	if not is_instance_valid(host):
		return Vector2.ZERO
	var center := sprite.position if is_instance_valid(sprite) else host.size * 0.5
	# Body halo radius is 126 px vertically. Keep it completely inside the
	# companion surface even when authored alpha bounds move the sprite close to
	# the bottom edge.
	return Vector2(
		clampf(center.x, 124.0, maxf(124.0, host.size.x - 124.0)),
		clampf(center.y, 128.0, maxf(128.0, host.size.y - 128.0))
	)


func _aura_ring(radii: Vector2, width: float, color: Color) -> Line2D:
	var ring := Line2D.new()
	ring.width = width
	ring.default_color = color
	ring.antialiased = true
	var points := PackedVector2Array()
	for index in range(65):
		var angle := TAU * float(index) / 64.0
		points.append(Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	ring.points = points
	return ring


func _build_ground_rune(config: Dictionary) -> void:
	_clear_ground_rune()
	if not is_instance_valid(host):
		return
	if str(config.get("renderer", "")) == "sprite-sheet-2d":
		var sprite_effect := _build_effect_pack_sprite("groundRune", config)
		if is_instance_valid(sprite_effect):
			ground_rune = sprite_effect
			ground_rune_time = 0.0
			ground_rune_config = config.duplicate(true)
			ground_rune_signature = JSON.stringify(config)
		return
	var color := _effect_color(str(config.get("tint", "")), Color(0.22, 0.74, 1.0))
	var intensity := clampf(float(config.get("intensity", 80)) / 100.0, 0.05, 1.0)
	var root := Node2D.new()
	root.name = "GroundRune"
	root.z_index = -20
	root.position = _ground_rune_position()

	# Concentric rings.
	root.add_child(_aura_ring(Vector2(122.0, 23.0), 4.0, Color(color, 0.90 * intensity)))
	root.add_child(_aura_ring(Vector2(101.0, 18.0), 2.0, Color(color.lightened(0.24), 0.72 * intensity)))
	root.add_child(_aura_ring(Vector2(72.0, 12.0), 1.6, Color(color.lightened(0.38), 0.58 * intensity)))

	# Rune spokes and diamond glyphs are generated from trusted data only. Pack
	# authors select tint/speed/intensity; they never execute code.
	for index in range(12):
		var angle := TAU * float(index) / 12.0
		var inner := Vector2(cos(angle) * 76.0, sin(angle) * 12.5)
		var outer := Vector2(cos(angle) * 116.0, sin(angle) * 21.0)
		var spoke := Line2D.new()
		spoke.width = 1.2
		spoke.default_color = Color(color.lightened(0.22), 0.48 * intensity)
		spoke.antialiased = true
		spoke.points = PackedVector2Array([inner, outer])
		root.add_child(spoke)

		var glyph := _rune_diamond(Color(color.lightened(0.36), 0.78 * intensity))
		glyph.position = Vector2(cos(angle) * 95.0, sin(angle) * 16.0)
		glyph.scale = Vector2(0.70, 0.28)
		root.add_child(glyph)

	root.z_as_relative = false
	_effect_parent("groundRune").add_child(root)
	ground_rune = root
	ground_rune_time = 0.0
	ground_rune_config = config.duplicate(true)
	ground_rune_signature = JSON.stringify(config)


func _ground_rune_position() -> Vector2:
	if not is_instance_valid(host):
		return Vector2.ZERO
	var character_rect := _character_visual_rect()
	# Procedural starter rune uses the same semantic feet-center anchor as
	# sprite-sheet packs. Keep the legacy ellipse inside the native surface.
	return Vector2(
		clampf(character_rect.get_center().x, 124.0, maxf(124.0, host.size.x - 124.0)),
		clampf(character_rect.end.y - 8.0, 24.0, maxf(24.0, host.size.y - 24.0))
	)


func _rune_diamond(color: Color) -> Line2D:
	var glyph := Line2D.new()
	glyph.width = 1.5
	glyph.default_color = color
	glyph.antialiased = true
	glyph.points = PackedVector2Array([
		Vector2(0, -8), Vector2(5, 0), Vector2(0, 8), Vector2(-5, 0), Vector2(0, -8)
	])
	return glyph


func _infer_sprite_content_bounds(
	image: Image,
	frame_width: int,
	frame_height: int,
	columns: int,
	frame_count: int
) -> Rect2i:
	return EffectPlacementResolver.infer_content_bounds(
		image,
		frame_width,
		frame_height,
		columns,
		frame_count
	)


func _crop_sprite_sheet_to_bounds(
	image: Image,
	frame_width: int,
	frame_height: int,
	columns: int,
	rows: int,
	frame_count: int,
	bounds: Rect2i
) -> Image:
	var cropped := Image.create(columns * bounds.size.x, rows * bounds.size.y, false, image.get_format())
	cropped.fill(Color(0, 0, 0, 0))
	for index in range(frame_count):
		var row := floori(float(index) / float(columns))
		var source_rect := Rect2i(
			(index % columns) * frame_width + bounds.position.x,
			row * frame_height + bounds.position.y,
			bounds.size.x,
			bounds.size.y
		)
		var target := Vector2i(
			(index % columns) * bounds.size.x,
			row * bounds.size.y
		)
		cropped.blit_rect(image, source_rect, target)
	return cropped


func performance_snapshot() -> Dictionary:
	return effect_performance_metrics.duplicate(true)


func _runtime_atlas_frame_size(frame_width: int, frame_height: int, columns: int, rows: int) -> Vector2i:
	var target_width := maxi(1, frame_width)
	var target_height := maxi(1, frame_height)
	var authored_max := maxi(target_width, target_height)
	if authored_max > EFFECT_RUNTIME_FRAME_CAP:
		var frame_scale := float(EFFECT_RUNTIME_FRAME_CAP) / float(authored_max)
		target_width = maxi(1, roundi(float(target_width) * frame_scale))
		target_height = maxi(1, roundi(float(target_height) * frame_scale))
	var atlas_bytes := int(columns) * int(rows) * target_width * target_height * 4
	if atlas_bytes > EFFECT_RUNTIME_ATLAS_BYTE_CAP:
		var atlas_scale := sqrt(float(EFFECT_RUNTIME_ATLAS_BYTE_CAP) / float(atlas_bytes))
		target_width = maxi(1, floori(float(target_width) * atlas_scale))
		target_height = maxi(1, floori(float(target_height) * atlas_scale))
	return Vector2i(target_width, target_height)


func _record_effect_build_metrics(slot_name: String, build_started_ms: int, decode_ms: int, atlas_bytes: int) -> void:
	var build_ms := maxi(0, Time.get_ticks_msec() - build_started_ms)
	effect_performance_metrics["lastSlot"] = slot_name
	effect_performance_metrics["lastBuildMs"] = build_ms
	effect_performance_metrics["lastDecodeMs"] = maxi(0, decode_ms)
	effect_performance_metrics["lastAtlasBytes"] = maxi(0, atlas_bytes)
	effect_performance_metrics["peakAtlasBytes"] = maxi(int(effect_performance_metrics.get("peakAtlasBytes", 0)), maxi(0, atlas_bytes))
	if build_ms > EFFECT_FIRST_LOAD_ACCEPTANCE_MS:
		effect_performance_metrics["slowBuildCount"] = int(effect_performance_metrics.get("slowBuildCount", 0)) + 1
		push_warning("[EffectPerformance] slow first-load slot=%s build_ms=%d decode_ms=%d atlas_mib=%.2f budget_ms=%d" % [
			slot_name,
			build_ms,
			decode_ms,
			float(atlas_bytes) / 1048576.0,
			EFFECT_FIRST_LOAD_ACCEPTANCE_MS,
		])
	else:
		print("[EffectPerformance] slot=%s build_ms=%d decode_ms=%d atlas_mib=%.2f budget_ms=%d" % [
			slot_name,
			build_ms,
			decode_ms,
			float(atlas_bytes) / 1048576.0,
			EFFECT_FIRST_LOAD_ACCEPTANCE_MS,
		])


func _build_effect_pack_sprite(slot_name: String, config: Dictionary) -> AnimatedSprite2D:
	if not is_instance_valid(host):
		return null
	var build_started_ms := Time.get_ticks_msec()
	var package_path := str(config.get("_packagePath", "")).strip_edges()
	var asset_path := str(config.get("asset", "")).strip_edges()
	if package_path.is_empty() or asset_path.is_empty():
		push_warning("[EffectPack] sprite slot '%s' is missing package/asset path" % slot_name)
		return null
	var image_path := package_path.path_join(asset_path)
	if not FileAccess.file_exists(image_path):
		push_warning("[EffectPack] sprite asset not found for '%s': %s" % [slot_name, image_path])
		return null

	var decode_started_ms := Time.get_ticks_msec()
	var image := Image.load_from_file(image_path)
	var decode_ms := Time.get_ticks_msec() - decode_started_ms
	if image == null or image.is_empty():
		push_warning("[EffectPack] sprite asset could not be decoded for '%s'" % slot_name)
		return null
	var frame_width := int(config.get("frameWidth", 0))
	var frame_height := int(config.get("frameHeight", 0))
	if frame_width < 1 or frame_height < 1:
		return null
	var columns := maxi(1, image.get_width() / frame_width)
	var rows := maxi(1, image.get_height() / frame_height)
	var frame_count := clampi(int(config.get("frameCount", 1)), 1, columns * rows)
	var start_frame := clampi(int(config.get("startFrame", 0)), 0, frame_count - 1)
	var end_frame := clampi(int(config.get("endFrame", frame_count - 1)), start_frame, frame_count - 1)
	var runtime_content_authored := Rect2i(0, 0, frame_width, frame_height)
	if config.has("contentBounds"):
		var bounds_value: Variant = config.get("contentBounds", {})
		if bounds_value is Dictionary:
			var bounds := bounds_value as Dictionary
			runtime_content_authored = Rect2i(
				int(bounds.get("x", 0)),
				int(bounds.get("y", 0)),
				int(bounds.get("width", frame_width)),
				int(bounds.get("height", frame_height))
			)
	else:
		var inferred_bounds := _infer_sprite_content_bounds(image, frame_width, frame_height, columns, frame_count)
		if inferred_bounds.size != Vector2i.ZERO:
			print("[EffectPack] inferred-content-bounds slot=%s rect=%s" % [slot_name, str(inferred_bounds)])
			runtime_content_authored = inferred_bounds
			if inferred_bounds != Rect2i(0, 0, frame_width, frame_height):
				image = _crop_sprite_sheet_to_bounds(
					image,
					frame_width,
					frame_height,
					columns,
					rows,
					frame_count,
					inferred_bounds
				)
				frame_width = inferred_bounds.size.x
				frame_height = inferred_bounds.size.y
				runtime_content_authored = Rect2i(0, 0, frame_width, frame_height)
				print("[EffectPack] runtime-atlas-cropped slot=%s frame=%dx%d atlas=%dx%d" % [
					slot_name,
					frame_width,
					frame_height,
					image.get_width(),
					image.get_height(),
				])

	# The companion's canonical native surface is 384x384. Crop transparent
	# margins first, then downscale only the runtime copy; package/source artwork
	# remains untouched.
	var pre_resize_frame_width := frame_width
	var pre_resize_frame_height := frame_height
	var runtime_frame_size := _runtime_atlas_frame_size(frame_width, frame_height, columns, rows)
	frame_width = runtime_frame_size.x
	frame_height = runtime_frame_size.y
	if frame_width != pre_resize_frame_width or frame_height != pre_resize_frame_height:
		image.resize(
			columns * frame_width,
			rows * frame_height,
			Image.INTERPOLATE_LANCZOS
		)
		print("[EffectPack] runtime-atlas-downscaled slot=%s frame=%dx%d->%dx%d atlas=%dx%d cap_mib=%.1f" % [
			slot_name,
			pre_resize_frame_width,
			pre_resize_frame_height,
			frame_width,
			frame_height,
			image.get_width(),
			image.get_height(),
			float(EFFECT_RUNTIME_ATLAS_BYTE_CAP) / 1048576.0,
		])
	var content_scale_x := float(frame_width) / maxf(1.0, float(pre_resize_frame_width))
	var content_scale_y := float(frame_height) / maxf(1.0, float(pre_resize_frame_height))
	var runtime_content_rect := Rect2(
		Vector2(runtime_content_authored.position.x * content_scale_x, runtime_content_authored.position.y * content_scale_y),
		Vector2(runtime_content_authored.size.x * content_scale_x, runtime_content_authored.size.y * content_scale_y)
	)
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	frames.add_animation(&"effect")
	var looped := bool(config.get("looped", slot_name != "levelUpBurst"))
	frames.set_animation_loop(&"effect", looped)
	var speed_scale := maxf(0.1, float(config.get("speedPermille", 1000)) / 1000.0)
	frames.set_animation_speed(&"effect", clampf(float(config.get("fps", 12)) * speed_scale, 0.1, 60.0))
	for index in range(start_frame, end_frame + 1):
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		var row := floori(float(index) / float(columns))
		atlas.region = Rect2(
			float(index % columns) * float(frame_width),
			float(row) * float(frame_height),
			float(frame_width),
			float(frame_height)
		)
		frames.add_frame(&"effect", atlas)

	var effect_sprite := AnimatedSprite2D.new()
	effect_sprite.name = "EffectPackSprite_%s" % slot_name
	effect_sprite.sprite_frames = frames
	effect_sprite.animation = &"effect"
	effect_sprite.centered = true
	effect_sprite.set_meta(&"ocp_effect_content_rect", runtime_content_rect)
	effect_sprite.scale = Vector2.ONE
	effect_sprite.z_as_relative = false
	_effect_parent(slot_name).add_child(effect_sprite)
	_apply_effect_pack_sprite_style(effect_sprite, slot_name, config)
	effect_sprite.play(&"effect")
	var atlas_bytes := image.get_width() * image.get_height() * 4
	_record_effect_build_metrics(slot_name, build_started_ms, decode_ms, atlas_bytes)
	return effect_sprite


func prepare_effect_preview_asset(config: Dictionary) -> Dictionary:
	# Pure preparation contract for Character Manager preview. This intentionally
	# mirrors _build_effect_pack_sprite() for atlas cropping, runtime frame-cap
	# downscaling and content-rect projection, but creates no scene nodes.
	var package_path := str(config.get("_packagePath", "")).strip_edges()
	var asset_path := str(config.get("asset", "")).strip_edges()
	if package_path.is_empty() or asset_path.is_empty():
		return {}
	var image_path := package_path.path_join(asset_path)
	if not FileAccess.file_exists(image_path):
		return {}
	var image := Image.load_from_file(image_path)
	if image == null or image.is_empty():
		return {}
	var frame_width := int(config.get("frameWidth", 0))
	var frame_height := int(config.get("frameHeight", 0))
	if frame_width < 1 or frame_height < 1:
		return {}
	var columns := maxi(1, image.get_width() / frame_width)
	var rows := maxi(1, image.get_height() / frame_height)
	var frame_count := clampi(int(config.get("frameCount", 1)), 1, columns * rows)
	var start_frame := clampi(int(config.get("startFrame", 0)), 0, frame_count - 1)
	var end_frame := clampi(int(config.get("endFrame", frame_count - 1)), start_frame, frame_count - 1)
	var runtime_content_authored := Rect2i(0, 0, frame_width, frame_height)
	if config.has("contentBounds"):
		var bounds_value: Variant = config.get("contentBounds", {})
		if bounds_value is Dictionary:
			var bounds := bounds_value as Dictionary
			runtime_content_authored = Rect2i(
				int(bounds.get("x", 0)),
				int(bounds.get("y", 0)),
				int(bounds.get("width", frame_width)),
				int(bounds.get("height", frame_height))
			)
	else:
		var inferred_bounds := _infer_sprite_content_bounds(image, frame_width, frame_height, columns, frame_count)
		if inferred_bounds.size != Vector2i.ZERO:
			runtime_content_authored = inferred_bounds
			if inferred_bounds != Rect2i(0, 0, frame_width, frame_height):
				image = _crop_sprite_sheet_to_bounds(
					image,
					frame_width,
					frame_height,
					columns,
					rows,
					frame_count,
					inferred_bounds
				)
				frame_width = inferred_bounds.size.x
				frame_height = inferred_bounds.size.y
				runtime_content_authored = Rect2i(0, 0, frame_width, frame_height)

	var pre_resize_frame_width := frame_width
	var pre_resize_frame_height := frame_height
	var runtime_frame_size := _runtime_atlas_frame_size(frame_width, frame_height, columns, rows)
	frame_width = runtime_frame_size.x
	frame_height = runtime_frame_size.y
	if frame_width != pre_resize_frame_width or frame_height != pre_resize_frame_height:
		image.resize(
			columns * frame_width,
			rows * frame_height,
			Image.INTERPOLATE_LANCZOS
		)
	var content_scale_x := float(frame_width) / maxf(1.0, float(pre_resize_frame_width))
	var content_scale_y := float(frame_height) / maxf(1.0, float(pre_resize_frame_height))
	var runtime_content_rect := Rect2(
		Vector2(runtime_content_authored.position.x * content_scale_x, runtime_content_authored.position.y * content_scale_y),
		Vector2(runtime_content_authored.size.x * content_scale_x, runtime_content_authored.size.y * content_scale_y)
	)
	return {
		"image": image,
		"frameWidth": frame_width,
		"frameHeight": frame_height,
		"columns": columns,
		"rows": rows,
		"frameCount": frame_count,
		"startFrame": start_frame,
		"endFrame": end_frame,
		"contentRect": runtime_content_rect,
		"source": "runtime-asset",
	}


func _sprite_sheet_asset_signature(config: Dictionary) -> String:
	return "%s|%s|%s|%s|%s|%s|%s" % [
		str(config.get("_packagePath", "")),
		str(config.get("asset", "")),
		str(config.get("frameWidth", "")),
		str(config.get("frameHeight", "")),
		str(config.get("frameCount", "")),
		str(config.get("startFrame", 0)),
		str(config.get("endFrame", "")),
	]


func _can_reuse_effect_pack_sprite(node: Node, previous_config: Dictionary, next_config: Dictionary) -> bool:
	return node is AnimatedSprite2D \
		and str(previous_config.get("renderer", "")) == "sprite-sheet-2d" \
		and str(next_config.get("renderer", "")) == "sprite-sheet-2d" \
		and _sprite_sheet_asset_signature(previous_config) == _sprite_sheet_asset_signature(next_config)


func _effect_colorize_material(color: Color, intensity: float) -> ShaderMaterial:
	if effect_colorize_shader == null:
		effect_colorize_shader = Shader.new()
		effect_colorize_shader.code = """
shader_type canvas_item;
uniform vec4 target_color : source_color = vec4(1.0);
uniform float effect_intensity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float luminance = max(max(tex.r, tex.g), tex.b);
	COLOR = vec4(target_color.rgb * luminance, tex.a * effect_intensity);
}
"""
	var material := ShaderMaterial.new()
	material.shader = effect_colorize_shader
	material.set_shader_parameter("target_color", color)
	material.set_shader_parameter("effect_intensity", intensity)
	return material


func _apply_effect_pack_sprite_style(effect_sprite: AnimatedSprite2D, slot_name: String, config: Dictionary) -> void:
	_apply_effect_pack_sprite_transform(effect_sprite, slot_name, config)
	var color := _effect_color(str(config.get("tint", "#FFFFFF")), Color.WHITE)
	var intensity := clampf(float(config.get("intensity", 100)) / 100.0, 0.0, 1.0)
	if frame_blend_trial:
		EffectFrameBlend.configure(effect_sprite, color, intensity, bool(config.get("_colorize", false)))
	elif bool(config.get("_colorize", false)):
		effect_sprite.material = _effect_colorize_material(color, intensity)
		effect_sprite.modulate = Color.WHITE
	else:
		effect_sprite.material = null
		effect_sprite.modulate = Color(color.r, color.g, color.b, intensity)
	if effect_sprite.sprite_frames != null and effect_sprite.sprite_frames.has_animation(&"effect"):
		var looped := bool(config.get("looped", slot_name != "levelUpBurst"))
		var speed_scale := maxf(0.1, float(config.get("speedPermille", 1000)) / 1000.0)
		effect_sprite.sprite_frames.set_animation_loop(&"effect", looped)
		effect_sprite.sprite_frames.set_animation_speed(&"effect", clampf(float(config.get("fps", 12)) * speed_scale, 0.1, 60.0))


func _character_visual_rect() -> Rect2:
	if not is_instance_valid(sprite):
		return Rect2(host.size * 0.25, host.size * 0.5)
	var frame_texture: Texture2D = null
	if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(sprite.animation):
		var count := sprite.sprite_frames.get_frame_count(sprite.animation)
		if count > 0:
			frame_texture = sprite.sprite_frames.get_frame_texture(sprite.animation, clampi(sprite.frame, 0, count - 1))
	if frame_texture == null:
		return Rect2(sprite.position - Vector2(90, 90), Vector2(180, 180))
	var frame_size := frame_texture.get_size()
	var used := Rect2(Vector2.ZERO, frame_size)
	if frame_texture.has_meta(&"ocp_alpha_rect"):
		var cached_value: Variant = frame_texture.get_meta(&"ocp_alpha_rect")
		if cached_value is Rect2i and (cached_value as Rect2i).size != Vector2i.ZERO:
			var rect := cached_value as Rect2i
			used = Rect2(Vector2(rect.position), Vector2(rect.size))
	var top_left_local := used.position - frame_size * 0.5
	var bottom_right_local := used.end - frame_size * 0.5
	var point_a := sprite.position + Vector2(top_left_local.x * sprite.scale.x, top_left_local.y * sprite.scale.y)
	var point_b := sprite.position + Vector2(bottom_right_local.x * sprite.scale.x, bottom_right_local.y * sprite.scale.y)
	var left := minf(point_a.x, point_b.x)
	var top := minf(point_a.y, point_b.y)
	var right := maxf(point_a.x, point_b.x)
	var bottom := maxf(point_a.y, point_b.y)
	return Rect2(Vector2(left, top), Vector2(maxf(1.0, right - left), maxf(1.0, bottom - top)))


func _effect_content_rect_runtime(effect_sprite: AnimatedSprite2D, config: Dictionary) -> Rect2:
	if effect_sprite.has_meta(&"ocp_effect_content_rect"):
		var cached_value: Variant = effect_sprite.get_meta(&"ocp_effect_content_rect")
		if cached_value is Rect2 and (cached_value as Rect2).size.x > 0.0 and (cached_value as Rect2).size.y > 0.0:
			return cached_value as Rect2
	var frame_size := Vector2(1, 1)
	if effect_sprite.sprite_frames != null and effect_sprite.sprite_frames.has_animation(&"effect") and effect_sprite.sprite_frames.get_frame_count(&"effect") > 0:
		var texture := effect_sprite.sprite_frames.get_frame_texture(&"effect", 0)
		if texture != null:
			frame_size = texture.get_size()
	var authored_w := maxf(1.0, float(config.get("frameWidth", frame_size.x)))
	var authored_h := maxf(1.0, float(config.get("frameHeight", frame_size.y)))
	var sx := frame_size.x / authored_w
	var sy := frame_size.y / authored_h
	var bounds_value: Variant = config.get("contentBounds", {})
	if bounds_value is Dictionary:
		var bounds := bounds_value as Dictionary
		var bw := float(bounds.get("width", authored_w))
		var bh := float(bounds.get("height", authored_h))
		if bw > 0.0 and bh > 0.0:
			return Rect2(
				Vector2(float(bounds.get("x", 0.0)) * sx, float(bounds.get("y", 0.0)) * sy),
				Vector2(bw * sx, bh * sy)
			)
	return Rect2(Vector2.ZERO, frame_size)


func _default_effect_scale_mode(slot_name: String) -> String:
	return "character-width" if slot_name == "groundRune" else "character-height"


func _default_effect_scale(slot_name: String) -> float:
	if slot_name == "groundRune":
		return 1.40
	if slot_name == "levelUpBurst":
		return 1.10
	return 1.12


func _default_effect_z(slot_name: String) -> int:
	if slot_name == "groundRune":
		return -20
	if slot_name == "levelUpBurst":
		return 20
	return -10


func _apply_effect_pack_sprite_transform(effect_sprite: AnimatedSprite2D, slot_name: String, config: Dictionary) -> void:
	if not is_instance_valid(host):
		return
	var character_rect := _character_visual_rect()
	var content_rect := _effect_content_rect_runtime(effect_sprite, config)
	var frame_size := Vector2(1, 1)
	if effect_sprite.sprite_frames != null and effect_sprite.sprite_frames.has_animation(&"effect") and effect_sprite.sprite_frames.get_frame_count(&"effect") > 0:
		var texture := effect_sprite.sprite_frames.get_frame_texture(&"effect", 0)
		if texture != null:
			frame_size = texture.get_size()
	var presentation_scale := 1.0
	if context != null:
		presentation_scale = clampf(float(context.character.get("presentation_scale", 1.0)), 0.25, 1.25)
	var placement := EffectPlacementResolver.resolve(
		slot_name,
		config,
		character_rect,
		content_rect,
		frame_size,
		Vector2(host.size),
		presentation_scale
	)
	effect_sprite.scale = placement.get("scale", Vector2.ONE)
	effect_sprite.position = placement.get("position", character_rect.get_center())
	effect_sprite.z_index = int(placement.get("z", EffectPlacementResolver.default_z(slot_name)))
	effect_sprite.rotation = 0.0


func resolve_preview_effect_placement(
	slot_name: String,
	config: Dictionary,
	content_rect: Rect2,
	frame_size: Vector2,
	expected_character_id: String = ""
) -> Dictionary:
	if not is_instance_valid(host) or not is_instance_valid(sprite):
		return {}
	var active_character_id := ""
	var presentation_scale := 1.0
	if context != null:
		active_character_id = str(context.character.get("id", "")).strip_edges()
		presentation_scale = clampf(float(context.character.get("presentation_scale", 1.0)), 0.25, 1.25)
	if not expected_character_id.is_empty() and expected_character_id != active_character_id:
		return {}
	var character_rect := _character_visual_rect()
	var surface_size := Vector2(host.size)
	var placement := EffectPlacementResolver.resolve(
		slot_name,
		config,
		character_rect,
		content_rect,
		frame_size,
		surface_size,
		presentation_scale
	)
	return {
		"characterId": active_character_id,
		"characterRect": character_rect,
		"surfaceSize": surface_size,
		"presentationScale": presentation_scale,
		"position": placement.get("position", character_rect.get_center()),
		"scale": placement.get("scale", Vector2.ONE),
		"z": int(placement.get("z", EffectPlacementResolver.default_z(slot_name))),
	}


func preview_runtime_character_geometry(expected_character_id: String = "") -> Dictionary:
	if not is_instance_valid(host) or not is_instance_valid(sprite):
		return {}
	var active_character_id := ""
	var presentation_scale := 1.0
	if context != null:
		active_character_id = str(context.character.get("id", "")).strip_edges()
		presentation_scale = clampf(float(context.character.get("presentation_scale", 1.0)), 0.25, 1.25)
	if not expected_character_id.is_empty() and expected_character_id != active_character_id:
		return {}
	return {
		"characterId": active_character_id,
		"characterRect": _character_visual_rect(),
		"surfaceSize": Vector2(host.size),
		"spritePosition": sprite.position,
		"spriteScale": Vector2(absf(sprite.scale.x), absf(sprite.scale.y)),
		"presentationScale": presentation_scale,
		"animation": str(sprite.animation),
		"frame": sprite.frame,
	}


func capture_live_effect_preview_layer(slot_name: String, expected_character_id: String = "") -> Dictionary:
	if not is_instance_valid(host) or not is_instance_valid(sprite):
		return {}
	var active_character_id := ""
	if context != null:
		active_character_id = str(context.character.get("id", "")).strip_edges()
	if not expected_character_id.is_empty() and expected_character_id != active_character_id:
		return {}

	var node: Node = null
	var config: Dictionary = {}
	if slot_name == "bodyAura":
		node = relationship_aura
		config = relationship_aura_config.duplicate(true)
	elif slot_name == "groundRune":
		node = ground_rune
		config = ground_rune_config.duplicate(true)
	elif slot_name == "levelUpBurst":
		node = level_up_burst
	else:
		return {}
	if not is_instance_valid(node) or not node is AnimatedSprite2D:
		return {}

	var effect_sprite := node as AnimatedSprite2D
	if effect_sprite.sprite_frames == null:
		return {}
	var animation := effect_sprite.animation
	if not effect_sprite.sprite_frames.has_animation(animation):
		return {}
	var frame_count := effect_sprite.sprite_frames.get_frame_count(animation)
	if frame_count <= 0:
		return {}
	var frame_index := clampi(effect_sprite.frame, 0, frame_count - 1)
	var texture := effect_sprite.sprite_frames.get_frame_texture(animation, frame_index)
	if texture == null:
		return {}
	var image := texture.get_image()
	if image == null or image.is_empty():
		return {}
	image.convert(Image.FORMAT_RGBA8)
	return {
		"characterId": active_character_id,
		"slot": slot_name,
		"image": image,
		"frameSize": texture.get_size(),
		"position": effect_sprite.position,
		"scale": Vector2(absf(effect_sprite.scale.x), absf(effect_sprite.scale.y)),
		"z": effect_sprite.z_index,
		"modulate": effect_sprite.modulate,
		"config": config,
	}


func _effect_pack_anchor_position(anchor: String, slot_name: String) -> Vector2:
	if not is_instance_valid(host):
		return Vector2.ZERO
	return EffectPlacementResolver.anchor_position(_character_visual_rect(), anchor, slot_name)


func _play_equipped_level_up_burst() -> void:
	_clear_level_up_burst()
	if not is_instance_valid(host):
		return
	var resolved := {}
	var effect_pack_service := _effect_pack_service()
	if is_instance_valid(effect_pack_service):
		var value: Variant = effect_pack_service.resolve_slot("levelUpBurst")
		if value is Dictionary:
			resolved = value as Dictionary
	if resolved.is_empty():
		return
	var config_value: Variant = resolved.get("config", {})
	if not config_value is Dictionary:
		return
	var config := (config_value as Dictionary).duplicate(true)
	config["_packagePath"] = str(resolved.get("path", ""))
	if str(config.get("renderer", "")) == "sprite-sheet-2d":
		var sprite_effect := _build_effect_pack_sprite("levelUpBurst", config)
		if is_instance_valid(sprite_effect):
			level_up_burst = sprite_effect
			if bool(context.settings.get("reduce_motion", false)) or resource_pressure == "high":
				(sprite_effect as AnimatedSprite2D).pause()
				var timer := get_tree().create_timer(0.45)
				timer.timeout.connect(_clear_level_up_burst)
			else:
				(sprite_effect as AnimatedSprite2D).animation_finished.connect(_clear_level_up_burst, CONNECT_ONE_SHOT)
			return
	var color := _effect_color(str(config.get("tint", "")), Color(1.0, 0.84, 0.22))
	var intensity := clampf(float(config.get("intensity", 100)) / 100.0, 0.05, 1.0)
	var character_rect := _character_visual_rect()
	var anchor := str(config.get("anchor", "character-feet-bottom"))
	if anchor not in ["character-feet", "character-feet-bottom"]:
		anchor = "character-feet-bottom"
	var root := Node2D.new()
	root.name = "LevelUpBurst"
	root.z_index = 4
	root.position = EffectPlacementResolver.anchor_position(character_rect, anchor, "levelUpBurst") + Vector2(
		float(config.get("offsetX", 0.0)),
		float(config.get("offsetY", 0.0))
	)

	# Level-up is a ground-origin burst: a rune-like base at the feet with rays
	# fanning upward. The old radial burst was centered above the head, which
	# clipped in Character Manager and did not match authored Level-Up assets.
	for index in range(11):
		var ratio := float(index) / 10.0
		var angle := lerpf(deg_to_rad(-160.0), deg_to_rad(-20.0), ratio)
		var ray := Line2D.new()
		ray.width = 2.4
		ray.default_color = Color(color, 0.90 * intensity)
		ray.antialiased = true
		ray.points = PackedVector2Array([
			Vector2(cos(angle), sin(angle)) * 18.0,
			Vector2(cos(angle), sin(angle)) * 80.0,
		])
		root.add_child(ray)
	root.add_child(_aura_ring(Vector2(70.0, 14.0), 3.0, Color(color.lightened(0.22), 0.82 * intensity)))
	root.add_child(_aura_ring(Vector2(48.0, 9.0), 1.8, Color(color.lightened(0.34), 0.62 * intensity)))
	root.z_as_relative = false
	_effect_parent("levelUpBurst").add_child(root)
	level_up_burst = root
	var base_scale := clampf(float(config.get("scale", 1.05)), 0.25, 4.0)
	root.scale = Vector2.ONE * (base_scale * 0.62)
	root.modulate.a = 0.0

	if bool(context.settings.get("reduce_motion", false)) or resource_pressure == "high":
		root.scale = Vector2.ONE * base_scale
		root.modulate.a = 0.72
		var timer := get_tree().create_timer(0.45)
		timer.timeout.connect(_clear_level_up_burst)
		return

	var speed := maxf(0.25, float(config.get("speedPermille", 1000)) / 1000.0)
	var grow_duration := 0.24 / speed
	var fade_duration := 0.52 / speed
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(root, "scale", Vector2.ONE * (base_scale * 1.08), grow_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(root, "modulate:a", 1.0, grow_duration * 0.75)
	tween.chain().tween_property(root, "modulate:a", 0.0, fade_duration)
	tween.chain().tween_callback(_clear_level_up_burst)


func _clear_ground_rune() -> void:
	if is_instance_valid(ground_rune):
		ground_rune.queue_free()
	ground_rune = null
	ground_rune_time = 0.0
	ground_rune_signature = ""
	ground_rune_config.clear()


func _clear_level_up_burst() -> void:
	if is_instance_valid(level_up_burst):
		level_up_burst.queue_free()
	level_up_burst = null


func _effect_color(value: String, fallback: Color) -> Color:
	var clean := value.strip_edges()
	if clean.is_empty():
		return fallback
	var parsed := Color.from_string(clean, fallback)
	return parsed


func _aura_color_for_rank(rank: String) -> Color:
	match rank:
		"best-companion":
			return Color(1.0, 0.78, 0.28)
		"partner":
			return Color(0.76, 0.38, 1.0)
		"close-friend":
			return Color(0.36, 0.48, 1.0)
		"friend":
			return Color(0.18, 0.78, 1.0)
		_:
			return Color(0.12, 0.88, 1.0)


func _legacy_aura_alpha_for_rank(rank: String) -> float:
	match rank:
		"best-companion": return 0.90
		"partner": return 0.80
		"close-friend": return 0.72
		"friend": return 0.62
		_: return 0.52


func _aura_alpha_for_rank(rank: String) -> float:
	var alpha := _legacy_aura_alpha_for_rank(rank)
	if not relationship_aura_config.is_empty():
		alpha = clampf(float(relationship_aura_config.get("intensity", 70)) / 100.0, 0.05, 1.0)
	if resource_pressure == "high":
		alpha *= 0.65
	return alpha


func _aura_motion_allowed() -> bool:
	return resource_pressure != "high" and not bool(context.settings.get("reduce_motion", false))


func _clear_relationship_aura() -> void:
	if is_instance_valid(relationship_aura):
		relationship_aura.queue_free()
	relationship_aura = null
	relationship_aura_rank = ""
	relationship_aura_time = 0.0
	relationship_aura_signature = ""
	relationship_aura_config.clear()


func _effect_pack_service() -> Node:
	if not is_instance_valid(services) or not ("effect_pack_service" in services):
		return null
	var value: Variant = services.get("effect_pack_service")
	return value as Node if value is Node else null


func _on_effect_requested(payload: Dictionary) -> void:
	var name := str(payload.get("name", "")).strip_edges()
	if name.is_empty():
		return
	if name in ["teleport_out", "teleport_in"]:
		_play_teleport(name)
		return
	var binding := _effect_binding(name)
	var effect_id := str(binding.get("effect", ""))
	if effect_id.is_empty():
		return
	_play_package_effect(effect_id, name)


func _play_teleport(name: String) -> void:
	var teleport := _teleport_profile()
	var mode := str(teleport.get("mode", "runtime-default")).strip_edges().to_lower()
	if mode == "disabled":
		return
	if mode == "package-override":
		var effect_id := str(teleport.get("effect", ""))
		if not effect_id.is_empty():
			_play_package_effect(effect_id, name)
		return
	_play_runtime_portal(name, teleport)


func _play_runtime_portal(name: String, profile: Dictionary) -> void:
	if not is_instance_valid(host) or not is_instance_valid(sprite):
		return
	_ensure_runtime_portal()
	if not is_instance_valid(runtime_portal):
		return
	if is_instance_valid(runtime_portal_tween):
		runtime_portal_tween.kill()
	var scale_value := maxf(0.1, float(profile.get("scale", 1.0)))
	var offset := _vector2_from(profile.get("offset", [0, 0]))
	runtime_portal.position = _anchor_position(str(profile.get("anchor", "below-feet"))) + offset
	runtime_portal.visible = true
	runtime_portal.modulate.a = 1.0
	runtime_portal.scale = Vector2(scale_value * 0.70, scale_value * 0.23)
	runtime_portal.rotation = 0.0
	runtime_portal_tween = create_tween()
	runtime_portal_tween.set_parallel(true)
	var duration := 0.14 if name == "teleport_out" else 0.24
	runtime_portal_tween.tween_property(runtime_portal, "modulate:a", 0.0, duration)
	runtime_portal_tween.tween_property(runtime_portal, "scale", Vector2(scale_value * 1.18, scale_value * 0.38), duration)
	runtime_portal_tween.tween_property(runtime_portal, "rotation", 0.45 if name == "teleport_out" else -0.55, duration)
	runtime_portal_tween.chain().tween_callback(Callable(self, "_finish_runtime_portal").bind(name))
	event_bus.publish(&"effect.started", {"name": name, "effect": "runtime.portal", "source": "runtime-default"})


func _ensure_runtime_portal() -> void:
	if is_instance_valid(runtime_portal) or not is_instance_valid(host):
		return
	var root := Node2D.new()
	root.name = "RuntimeTeleportPortal"
	root.z_index = -20
	root.visible = false
	root.add_child(_portal_ring(112.0, 5.0, Color(0.08, 0.92, 1.0, 0.95)))
	root.add_child(_portal_ring(82.0, 2.5, Color(0.72, 0.98, 1.0, 0.85)))
	root.add_child(_portal_ring(56.0, 1.5, Color(0.20, 0.58, 1.0, 0.70)))
	host.add_child(root)
	runtime_portal = root


func _portal_ring(radius: float, width: float, color: Color) -> Line2D:
	var ring := Line2D.new()
	ring.width = width
	ring.default_color = color
	ring.antialiased = true
	var points := PackedVector2Array()
	for index in range(49):
		var angle := TAU * float(index) / 48.0
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	ring.points = points
	return ring


func _finish_runtime_portal(name: String) -> void:
	if is_instance_valid(runtime_portal):
		runtime_portal.visible = false
	event_bus.publish(&"effect.finished", {"name": name, "effect": "runtime.portal", "source": "runtime-default"})


func _clear_runtime_portal() -> void:
	if is_instance_valid(runtime_portal_tween):
		runtime_portal_tween.kill()
	runtime_portal_tween = null
	if is_instance_valid(runtime_portal):
		runtime_portal.queue_free()
	runtime_portal = null


func _play_package_effect(effect_id: String, semantic_name: String) -> void:
	var effect := _effect_asset(effect_id)
	if effect.is_empty() or not is_instance_valid(host):
		event_bus.publish(&"effect.missing", {"name": semantic_name, "effect": effect_id})
		return
	var relative_path := str(effect.get("path", ""))
	var root := str(context.package.get("installed_path", "")) if is_instance_valid(context) else ""
	var image_path := root.path_join(relative_path)
	if root.is_empty() or relative_path.is_empty() or not FileAccess.file_exists(image_path):
		event_bus.publish(&"effect.missing", {"name": semantic_name, "effect": effect_id})
		return
	var image := Image.load_from_file(image_path)
	if image == null or image.is_empty():
		event_bus.publish(&"effect.missing", {"name": semantic_name, "effect": effect_id})
		return
	var frame_size_value: Variant = effect.get("frameSize", [image.get_width(), image.get_height()])
	var frame_size: Array = frame_size_value if frame_size_value is Array else [image.get_width(), image.get_height()]
	var frame_width := clampi(int(frame_size[0]), 1, image.get_width())
	var frame_height := clampi(int(frame_size[1]), 1, image.get_height())
	var columns := maxi(1, image.get_width() / frame_width)
	var rows := maxi(1, image.get_height() / frame_height)
	var requested_frames := clampi(int(effect.get("frames", columns * rows)), 1, columns * rows)
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	frames.add_animation(&"effect")
	frames.set_animation_loop(&"effect", bool(effect.get("loop", false)))
	frames.set_animation_speed(&"effect", clampf(float(effect.get("fps", 12.0)), 0.1, 60.0))
	for index in range(requested_frames):
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2(
			(index % columns) * frame_width,
			(index / columns) * frame_height,
			frame_width,
			frame_height
		)
		frames.add_frame(&"effect", atlas)

	_stop_effect(effect_id)
	var effect_sprite := AnimatedSprite2D.new()
	effect_sprite.name = "CharacterEffect_%s" % effect_id
	effect_sprite.sprite_frames = frames
	effect_sprite.animation = &"effect"
	effect_sprite.centered = true
	effect_sprite.z_index = _layer_z(str(effect.get("layer", "behind-character")))
	effect_sprite.position = _anchor_position(str(effect.get("anchor", "body-center"))) + _vector2_from(effect.get("offset", [0, 0]))
	var scale_value := maxf(0.01, float(effect.get("scale", 1.0)))
	effect_sprite.scale = Vector2(scale_value, scale_value)
	host.add_child(effect_sprite)
	active_effects[effect_id] = effect_sprite
	if not bool(effect.get("loop", false)):
		effect_sprite.animation_finished.connect(_on_package_effect_finished.bind(effect_id, semantic_name), CONNECT_ONE_SHOT)
	effect_sprite.play(&"effect")
	event_bus.publish(&"effect.started", {"name": semantic_name, "effect": effect_id, "source": "character/3"})


func _on_package_effect_finished(effect_id: String, semantic_name: String) -> void:
	_stop_effect(effect_id)
	event_bus.publish(&"effect.finished", {"name": semantic_name, "effect": effect_id, "source": "character/3"})


func _stop_effect(effect_id: String) -> void:
	var node: Variant = active_effects.get(effect_id)
	if is_instance_valid(node):
		(node as Node).queue_free()
	active_effects.erase(effect_id)


func _clear_all_effects() -> void:
	for effect_id in active_effects.keys():
		_stop_effect(str(effect_id))
	active_effects.clear()


func _effects_profile() -> Dictionary:
	if not is_instance_valid(context):
		return {}
	var value: Variant = context.character.get("effects_profile", {})
	return value if value is Dictionary else {}


func _effect_binding(name: String) -> Dictionary:
	var value: Variant = _effects_profile().get("bindings", {})
	var bindings: Dictionary = value if value is Dictionary else {}
	var binding_value: Variant = bindings.get(name, {})
	return binding_value if binding_value is Dictionary else {}


func _effect_asset(effect_id: String) -> Dictionary:
	var value: Variant = _effects_profile().get("effects", [])
	var effects: Array = value if value is Array else []
	for raw in effects:
		if raw is Dictionary and str(raw.get("id", "")) == effect_id:
			return raw
	return {}


func _teleport_profile() -> Dictionary:
	var value: Variant = _effects_profile().get("teleport", {})
	return value if value is Dictionary else {}


func _anchor_position(anchor: String) -> Vector2:
	var center := sprite.position if is_instance_valid(sprite) else (host.size * 0.5 if is_instance_valid(host) else Vector2.ZERO)
	match anchor.to_lower():
		"head":
			return center + Vector2(0, -105)
		"feet":
			return center + Vector2(0, 105)
		"below-feet":
			return center + Vector2(0, 118)
		"above-head":
			return center + Vector2(0, -130)
		_:
			return center


func _layer_z(layer: String) -> int:
	match layer.to_lower():
		"background": return -30
		"ground-rune": return -2
		"back-aura": return -1
		"behind-character": return -10
		"front-fx": return 4
		"front-character": return 10
		"ui-overlay": return 100
		_: return -10


func _vector2_from(value: Variant) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO
