extends SceneTree
const Controller = preload("res://scripts/runtime_v3/controllers/effect_controller.gd")
const Context = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const Blend = preload("res://scripts/runtime_v3/core/effect_frame_blend.gd")

class PackService:
	extends Node
	var config: Dictionary
	func resolve_slot(_slot: String) -> Dictionary:
		return {"path": "user://aura_trial", "config": config}

class Services:
	extends Node
	var effect_pack_service: Node

var failures := 0
func check(value: bool, label: String) -> void:
	print("[FX-TRIAL] %s=%s" % [label, value])
	if not value:
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute("user://aura_trial/assets")
	var image := Image.create(128, 96, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	image.save_png("user://aura_trial/assets/fx.png")
	var host := Control.new()
	host.size = Vector2(384, 384)
	root.add_child(host)
	var character := AnimatedSprite2D.new()
	character.position = Vector2(192, 192)
	host.add_child(character)
	var context := Context.new()
	root.add_child(context)
	var services := Services.new()
	var pack_service := PackService.new()
	services.effect_pack_service = pack_service
	services.add_child(pack_service)
	root.add_child(services)
	var controller := Controller.new()
	controller.context = context
	controller.services = services
	controller.frame_blend_trial = true
	controller.starter_mist_trial = true
	root.add_child(controller)
	controller.bind_effect_layer(host, character)
	controller._build_relationship_aura("partner", {"intensity": 90})
	check(controller.level_up_burst == null, "no_idle_burst")
	var mist: ColorRect = controller.relationship_aura.get_node("StarterMistTrial")
	check(mist.material.shader == Blend.MIST_SHADER and controller.relationship_aura.z_index < 0, "mist_behind")
	controller._process(0.5)
	var clock_before: float = mist.material.get_shader_parameter("clock_seconds")
	context.settings["reduce_motion"] = true
	controller._process(0.5)
	check(is_equal_approx(clock_before, mist.material.get_shader_parameter("clock_seconds")), "mist_reduced_motion")
	context.settings["reduce_motion"] = false
	controller.resource_pressure = "high"
	controller._process(0.5)
	check(is_equal_approx(clock_before, mist.material.get_shader_parameter("clock_seconds")), "mist_high_pressure")
	controller.resource_pressure = "normal"
	pack_service.config = {
		"renderer": "sprite-sheet-2d", "asset": "assets/fx.png", "frameWidth": 16,
		"frameHeight": 16, "frameCount": 48, "fps": 12, "durationMs": 4000,
		"looped": false, "zIndex": -20, "intensity": 90, "_colorize": true,
		"contentBounds": {"x": 0, "y": 0, "width": 16, "height": 16},
	}
	controller._on_progression_celebration_shown()
	var burst: AnimatedSprite2D = controller.level_up_burst
	check(is_instance_valid(burst) and burst.z_index == -20 and burst.material.shader == Blend.BLEND_SHADER, "event_burst_behind_blended")
	check(burst.sprite_frames.get_frame_count(&"effect") == 48 and burst.sprite_frames.get_animation_speed(&"effect") == 12.0, "four_seconds_preserved")
	await create_timer(4.25).timeout
	check(controller.level_up_burst == null, "event_burst_released")
	controller._on_presentation_suppressed_changed({"suppressed": true})
	check(controller.relationship_aura == null and controller.ground_rune == null, "hidden_cleanup")
	controller.queue_free()
	host.queue_free()
	context.queue_free()
	services.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
