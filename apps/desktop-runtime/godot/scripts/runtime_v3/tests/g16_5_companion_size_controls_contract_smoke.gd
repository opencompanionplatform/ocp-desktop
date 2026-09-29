extends SceneTree

const CharacterControllerScript = preload(
	"res://scripts/runtime_v3/controllers/character_controller.gd"
)
const AnimationControllerScript = preload(
	"res://scripts/runtime_v3/controllers/animation_controller.gd"
)
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const SettingsServiceScript = preload("res://scripts/runtime_v3/services/settings_service.gd")
const NativeHostLifecycleScript = preload(
	"res://scripts/runtime_v3/services/native_host_lifecycle.gd"
)


class FakeContext:
	extends Node
	var character: Dictionary = {
		"id": "character.size-smoke",
		"scale": 0.6,
		"render_size": Vector2i(384, 384),
		"visual_profiles": {},
	}
	var runtime_config: Dictionary = {
		"native_presentation_enabled": true,
		"overlay_enabled": false,
	}
	var settings: Dictionary = {}
	var monitor: Dictionary = {"scales": []}

	func update_character(values: Dictionary) -> void:
		character.merge(values, true)


class FakeSettingsService:
	extends Node
	var saved_scales: Dictionary = {}

	func load_character_presentation_scale(character_id: String) -> float:
		return float(saved_scales.get(character_id, 1.0))

	func save_character_presentation_scale(character_id: String, scale: float) -> bool:
		saved_scales[character_id] = scale
		return true


class FakeServices:
	extends Node
	var settings_service := FakeSettingsService.new()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := EventBusScript.new()
	var services := FakeServices.new()
	var controller := CharacterControllerScript.new()
	var state_machine := Node.new()
	var host := Control.new()
	var sprite := AnimatedSprite2D.new()
	host.add_child(sprite)
	for node in [context, bus, services, controller, state_machine, host]:
		holder.add_child(node)
	services.add_child(services.settings_service)
	controller.configure(context, bus, services, state_machine)
	controller.bind_character(host, sprite)
	controller.start()

	var frames := _frames()
	sprite.sprite_frames = frames
	sprite.animation = &"idle"
	controller.lifecycle_animation = &""
	controller._fit_native_render_scale(frames)
	controller._sync_host_to_sprite_visual_bounds(frames)
	var base_scale := sprite.scale.x
	controller.last_canonical_desktop_feet = Vector2(640.0, 888.0)

	controller._on_presentation_scale_requested({"scale": 0.25, "source": "smoke"})
	var quarter_ok: bool = is_equal_approx(controller.presentation_size_scale, 0.25) \
		and is_equal_approx(sprite.scale.x, base_scale * 0.25) \
		and context.character.get("presentation_scale", 0.0) == 0.25 \
		and services.settings_service.saved_scales.get("character.size-smoke", 0.0) == 0.25 \
		and controller.last_canonical_desktop_feet == Vector2(640.0, 888.0)

	# Regression: AnimationController must not overwrite the fitted native scale
	# when a new clip starts. CharacterController is the single native scale
	# authority and will refit/reposition after animation.started.
	context.character["visual_profiles"] = {"walk_left": {"scale": 2.0}}
	var animation_controller := AnimationControllerScript.new()
	holder.add_child(animation_controller)
	animation_controller.configure(context, bus, services, state_machine)
	animation_controller.bind_sprite(sprite)
	var native_scale_before_animation := sprite.scale.x
	animation_controller._apply_visual_profile(&"walk_left")
	var animation_scale_ownership_ok := is_equal_approx(sprite.scale.x, native_scale_before_animation)

	controller.physics_last_movement_state = "hanging"
	controller._on_presentation_scale_requested({"scale": 1.25, "source": "smoke"})
	var deferred_ok: bool = is_equal_approx(controller.presentation_size_scale, 0.25) \
		and is_equal_approx(controller.pending_presentation_size_scale, 1.25)
	controller.physics_last_movement_state = "stationary"
	controller._try_apply_pending_presentation_scale()
	var applied_after_safe: bool = is_equal_approx(controller.presentation_size_scale, 1.25) \
		and is_equal_approx(sprite.scale.x, base_scale * 1.25) \
		and controller.pending_presentation_size_scale < 0.0 \
		and controller.last_canonical_desktop_feet == Vector2(640.0, 888.0)

	controller._on_presentation_scale_requested({"scale": 0.33, "source": "smoke"})
	var invalid_rejected: bool = is_equal_approx(controller.presentation_size_scale, 1.25)

	# Preloading the production persistence service keeps this smoke a parse
	# check for its allowlist without mutating a developer's real user:// state.
	var persistence = SettingsServiceScript.new()
	var persistence_ok: bool = persistence._is_presentation_scale_allowed(0.25) \
		and persistence._is_presentation_scale_allowed(1.25) \
		and not persistence._is_presentation_scale_allowed(0.33) \
		and is_equal_approx(persistence._default_presentation_scale("character.bible"), 0.50) \
		and is_equal_approx(persistence._default_presentation_scale("character.other"), 1.00) \
		and services.settings_service.saved_scales.get("character.size-smoke", 0.0) == 1.25

	var lifecycle := NativeHostLifecycleScript.new()
	holder.add_child(lifecycle)
	lifecycle.configure(context, bus)
	var scale_state_path := ProjectSettings.globalize_path("user://g16_5_native_scale_state.json")
	lifecycle.ui_command_path = scale_state_path
	lifecycle.host_token = "g16.5-smoke-token"
	lifecycle.pending_native_hitbox = Rect2(0.10, 0.05, 0.80, 0.90)
	lifecycle.pending_native_anchor = Vector2(0.50, 0.95)
	lifecycle._on_presentation_scale_applied({"scale": 1.25})
	var scale_state: Dictionary = {}
	if FileAccess.file_exists(scale_state_path):
		var scale_state_file := FileAccess.open(scale_state_path, FileAccess.READ)
		if scale_state_file != null:
			var parsed: Variant = JSON.parse_string(scale_state_file.get_as_text())
			scale_state_file.close()
			if parsed is Dictionary:
				scale_state = parsed
	var geometry_hitbox: Array = scale_state.get("normalized_hitbox", [])
	var geometry_anchor: Array = scale_state.get("normalized_anchor", [])
	var active_feedback_ok: bool = str(scale_state.get("status", "")) == "presentation-geometry-state" \
		and is_equal_approx(float(scale_state.get("scale", 0.0)), 1.25) \
		and str(scale_state.get("token", "")) == "g16.5-smoke-token" \
		and geometry_hitbox.size() == 4 \
		and is_equal_approx(float(geometry_hitbox[2]), 0.80) \
		and geometry_anchor.size() == 2 \
		and is_equal_approx(float(geometry_anchor[1]), 0.95)

	# Regression: opening the native Hover menu after a character swap must
	# re-assert the active character's Runtime-owned scale instead of keeping the
	# previous character's highlighted size segment.
	context.character["presentation_scale"] = 1.0
	lifecycle._on_native_hover_entered({"source": "smoke"})
	var hover_state: Dictionary = {}
	if FileAccess.file_exists(scale_state_path):
		var hover_state_file := FileAccess.open(scale_state_path, FileAccess.READ)
		if hover_state_file != null:
			var hover_parsed: Variant = JSON.parse_string(hover_state_file.get_as_text())
			hover_state_file.close()
			if hover_parsed is Dictionary:
				hover_state = hover_parsed
	var hover_scale_replay_ok: bool = str(hover_state.get("status", "")) == "presentation-geometry-state" \
		and is_equal_approx(float(hover_state.get("scale", 0.0)), 1.0)
	DirAccess.remove_absolute(scale_state_path)

	var ok: bool = quarter_ok and animation_scale_ownership_ok and deferred_ok and applied_after_safe and invalid_rejected \
		and persistence_ok and active_feedback_ok and hover_scale_replay_ok
	print("[G16.5] quarter=", quarter_ok, " animation_scale_owner=", animation_scale_ownership_ok, " deferred=", deferred_ok, " applied=", applied_after_safe, " rejected=", invalid_rejected, " persistence=", persistence_ok, " active_feedback=", active_feedback_ok, " hover_replay=", hover_scale_replay_ok, " ok=", ok)
	controller.stop()
	sprite.sprite_frames = null
	persistence.free()
	holder.free()
	await process_frame
	await process_frame
	quit(0 if ok else 1)


func _frames() -> SpriteFrames:
	var image := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(72, 16, 112, 228), Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	frames.add_animation(&"idle")
	frames.set_animation_loop(&"idle", true)
	frames.add_frame(&"idle", texture)
	return frames
