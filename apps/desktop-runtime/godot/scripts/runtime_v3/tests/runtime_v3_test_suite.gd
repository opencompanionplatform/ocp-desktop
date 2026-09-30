extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const MachineScript = preload("res://scripts/runtime_v3/core/runtime_state_machine.gd")
const TracerScript = preload("res://scripts/runtime_v3/core/runtime_event_tracer.gd")
const SettingsScript = preload("res://scripts/runtime_v3/services/settings_service.gd")
const CharacterScript = preload("res://scripts/runtime_v3/services/character_service.gd")
const CharacterControllerScript = preload("res://scripts/runtime_v3/controllers/character_controller.gd")
const HoverControllerScript = preload("res://scripts/runtime_v3/controllers/hover_controller.gd")
const StartupVisibilityControllerScript = preload("res://scripts/runtime_v3/controllers/startup_visibility_controller.gd")
const CoordinateMapperScript = preload("res://scripts/runtime_v3/services/coordinate_mapper.gd")
const PresentationCoordinateResolverScript = preload("res://scripts/runtime_v3/services/presentation_coordinate_resolver.gd")
const PresentationMonitorAttachmentScript = preload("res://scripts/runtime_v3/services/presentation_monitor_attachment.gd")
const MonitorWindowServiceScript = preload("res://scripts/runtime_v3/services/monitor_window_service.gd")
const CanonicalVisualBindingScript = preload("res://scripts/runtime_v3/services/canonical_visual_binding.gd")
const RuntimeModeAuthorityScript = preload("res://scripts/runtime_v3/services/runtime_mode_authority.gd")
const NativePresentationCoordinatorScript = preload("res://scripts/runtime_v3/services/native_presentation_coordinator.gd")
const WindowControllerScript = preload("res://scripts/runtime_v3/controllers/window_controller.gd")
const HybridPresentationRootScene = preload("res://scenes/runtime_v3/HybridPresentationRoot.tscn")


func _initialize() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	var passed: int = 0
	var total: int = 0

	if _test_event_bus():
		passed += 1
	total += 1

	if _test_state_machine():
		passed += 1
	total += 1

	if _test_runtime_context():
		passed += 1
	total += 1

	if _test_event_tracer():
		passed += 1
	total += 1

	if _test_fallback_frames():
		passed += 1
	total += 1

	if _test_character_transition_loop_normalization():
		passed += 1
	total += 1

	if _test_character_mirror_safety_metadata():
		passed += 1
	total += 1

	if _test_position_persistence():
		passed += 1
	total += 1

	if _test_physics_visual_sequence_and_fallback():
		passed += 1
	total += 1

	if _test_canonical_visual_binding_contract():
		passed += 1
	total += 1

	if _test_presentation_coordinate_authority():
		passed += 1
	total += 1

	if _test_baseline_presentation_regression():
		passed += 1
	total += 1

	if _test_hybrid_presentation_root_rollback():
		passed += 1
	total += 1

	if _test_hybrid_monitor_attachment_authority():
		passed += 1
	total += 1

	if _test_hybrid_monitor_window_probe_lifecycle():
		passed += 1
	total += 1

	if _test_monitor_scoped_overlay_coordinate_authority():
		passed += 1
	total += 1

	if _test_negative_monitor_overlay_coordinate_authority():
		passed += 1
	total += 1

	if _test_actual_dpi_two_virtual_desktop_fixture():
		passed += 1
	total += 1

	if _test_mixed_height_three_monitor_visibility_fixture():
		passed += 1
	total += 1

	if _test_animation_facing_authority():
		passed += 1
	total += 1

	if _test_physics_transition_animations():
		passed += 1
	total += 1

	if _test_disappear_keeps_idle_visual_anchor():
		passed += 1
	total += 1

	if _test_native_animation_stable_bounds():
		passed += 1
	total += 1

	if _test_native_canvas_ignores_mixed_dpi_viewport():
		passed += 1
	total += 1

	if _test_native_window_content_scale_policy():
		passed += 1
	total += 1

	if _test_native_exit_waits_for_host_handoff():
		passed += 1
	total += 1

	if _test_overlay_mode_state_authority():
		passed += 1
	total += 1

	if _test_overlay_canvas_authority():
		passed += 1
	total += 1

	if _test_windows_dpi_coordinate_authority():
		passed += 1
	total += 1

	if _test_drag_commit_visual_hold():
		passed += 1
	total += 1

	if _test_runtime_mode_authority_default():
		passed += 1
	total += 1

	if _test_native_presentation_coordinator_contract():
		passed += 1
	total += 1

	if _test_saved_position_topology_validation():
		passed += 1
	total += 1

	if _test_drag_release_capture_contract():
		passed += 1
	total += 1

	if _test_native_drag_animation_bridge():
		passed += 1
	total += 1

	if _test_drag_edge_predictive_prefetch():
		passed += 1
	total += 1

	if _test_native_mouse_capture_contract():
		passed += 1
	total += 1

	if _test_drag_commit_bridge_contract():
		passed += 1
	total += 1

	if _test_log_policy_contract():
		passed += 1
	total += 1

	print("Runtime V3 tests: %d/%d passed" % [passed, total])

	# Allow deferred deletions and RefCounted resources to release before
	# SceneTree quits. This prevents false ObjectDB/resource leak warnings.
	await process_frame
	await process_frame
	await process_frame
	quit(0 if passed == total else 1)


func _test_event_bus() -> bool:
	var holder := Node.new()
	get_root().add_child(holder)

	var bus = BusScript.new()
	holder.add_child(bus)

	var received: Array = []
	var callback := func(payload: Dictionary): received.append(payload.get("value"))
	bus.subscribe(&"test", callback)
	bus.publish(&"test", {"value": 42})
	bus.unsubscribe(&"test", callback)

	var ok: bool = received == [42]
	_report("event bus", ok)

	bus.clear()
	holder.remove_child(bus)
	bus.free()
	holder.free()
	return ok


func _test_state_machine() -> bool:
	var machine = MachineScript.new()
	get_root().add_child(machine)

	var ok: bool = machine.transition(&"ready") \
		and machine.transition(&"dragging") \
		and not machine.transition(&"quick_panel") \
		and machine.transition(&"ready")

	_report("state machine", ok)

	get_root().remove_child(machine)
	machine.free()
	return ok


func _test_runtime_context() -> bool:
	var context = ContextScript.new()
	get_root().add_child(context)

	context.update_character({"name": "Test"})
	context.update_window({"hidden_to_tray": true})

	var ok: bool = context.character.get("name") == "Test" \
		and bool(context.window.get("hidden_to_tray", false)) \
		and str(context.settings.get("ocp_cloud_api_url", "")).begins_with("https://")

	_report("runtime context", ok)

	get_root().remove_child(context)
	context.free()
	return ok


func _test_event_tracer() -> bool:
	var holder := Node.new()
	get_root().add_child(holder)

	var bus = BusScript.new()
	var tracer = TracerScript.new()
	holder.add_child(bus)
	holder.add_child(tracer)

	tracer.configure(bus)
	tracer.set_enabled(true)
	bus.publish(&"trace.test", {"ok": true})

	var ok: bool = tracer.snapshot().size() == 1
	_report("event tracer", ok)

	tracer.shutdown()
	bus.clear()

	holder.remove_child(tracer)
	tracer.free()
	holder.remove_child(bus)
	bus.free()
	holder.free()
	return ok


func _test_fallback_frames() -> bool:
	var holder := Node.new()
	get_root().add_child(holder)

	var context = ContextScript.new()
	var bus = BusScript.new()
	var character = CharacterScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(character)
	character.configure(context, bus)

	var frames: SpriteFrames = character.build_fallback_frames()
	var ok: bool = frames != null and frames.has_animation("idle")
	_report("fallback SpriteFrames", ok)

	# Release texture and SpriteFrames before freeing the service.
	frames = null
	bus.clear()

	holder.remove_child(character)
	character.free()
	holder.remove_child(bus)
	bus.free()
	holder.remove_child(context)
	context.free()
	holder.free()
	return ok


func _test_character_transition_loop_normalization() -> bool:
	var character = CharacterScript.new()
	var climb_top_loops: bool = character._effective_animation_loop(&"climb_top", {"loop": true})
	var drag_release_loops: bool = character._effective_animation_loop(&"drag_release", {"loop": true})
	var walk_loops: bool = character._effective_animation_loop(&"walk_left", {"loop": true})
	var idle_defaults_to_one_shot: bool = not character._effective_animation_loop(&"idle", {})
	var ok: bool = not climb_top_loops and not drag_release_loops and walk_loops and idle_defaults_to_one_shot
	_report("character transition loop normalization", ok)
	character.free()
	return ok


func _test_character_mirror_safety_metadata() -> bool:
	var context = ContextScript.new()
	context.character["visual_profiles"] = {
		"default": {"mirrorSafe": true, "mirrorPolicy": "facing"},
		"climb_up": {"mirrorSafe": false, "mirrorPolicy": "surface-normal"},
		"climb_down": {"mirrorPolicy": "none"},
	}
	context.character["animations"] = PackedStringArray([
		"climb_up", "climb_down", "climb_ready",
		"climb_up_left", "climb_up_right", "climb_down_left", "climb_down_right",
		"climb_ready_left", "climb_ready_right",
	])
	context.package["entry"] = {
		"animationRoles": {
			"climb.up.left": "climb_up_left",
			"climb.up.right": "climb_up_right",
			"climb.ready.left": "climb_ready_left",
			"climb.ready.right": "climb_ready_right",
			"climb.down.left": "climb_down_left",
			"climb.down.right": "climb_down_right",
		}
	}
	var character = CharacterControllerScript.new()
	var sprite := AnimatedSprite2D.new()
	character.context = context
	character.sprite = sprite
	var mirror_metadata_ok: bool = not character._animation_allows_runtime_mirror(&"climb_up") \
		and not character._animation_allows_runtime_mirror(&"climb_down") \
		and character._animation_allows_runtime_mirror(&"walk")
	var climb_up_left := character._resolve_movement_animation("climbing", Vector2(0.0, -10.0), "left")
	var climb_up_right := character._resolve_movement_animation("climbing", Vector2(0.0, -10.0), "right")
	var climb_down_left := character._resolve_movement_animation("climbing", Vector2(0.0, 10.0), "left")
	var climb_down_right := character._resolve_movement_animation("climbing", Vector2(0.0, 10.0), "right")
	var climb_ready_left := character._resolve_movement_animation("climb-ready", Vector2.ZERO, "left")
	var climb_ready_right := character._resolve_movement_animation("climb-ready", Vector2.ZERO, "right")
	var directional_ok: bool = climb_up_left == &"climb_up_left" \
		and climb_up_right == &"climb_up_right" \
		and climb_down_left == &"climb_down_left" \
		and climb_down_right == &"climb_down_right" \
		and climb_ready_left == &"climb_ready_left" \
		and climb_ready_right == &"climb_ready_right" \
		and not sprite.flip_h
	var ok: bool = mirror_metadata_ok and directional_ok
	_report("character mirrorSafe metadata and directional climb roles", ok)
	character.free()
	sprite.free()
	context.free()
	return ok


func _test_position_persistence() -> bool:
	var holder := Node.new()
	get_root().add_child(holder)

	var context = ContextScript.new()
	var bus = BusScript.new()
	var settings = SettingsScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(settings)
	settings.configure(context, bus)

	var expected := Vector2(2345.0, 678.0)
	var save_ok: bool = settings.save_character_desktop_position(expected, 1, 1.5)
	var restored: Dictionary = settings.load_character_desktop_position()
	var ok: bool = save_ok and restored.get("position", Vector2.ZERO) == expected
	_report("position persistence", ok)

	restored.clear()
	bus.clear()

	holder.remove_child(settings)
	settings.free()
	holder.remove_child(bus)
	bus.free()
	holder.remove_child(context)
	context.free()
	holder.free()
	return ok


func _test_physics_visual_sequence_and_fallback() -> bool:
	# A SceneTree script running headless may expose a zero-sized root viewport.
	# Use a deterministic viewport so full-visibility assertions test production
	# clamp behavior rather than the host process/windowing backend.
	var test_viewport := SubViewport.new()
	test_viewport.size = Vector2i(1920, 1080)
	test_viewport.disable_3d = true
	get_root().add_child(test_viewport)

	var holder := Node.new()
	test_viewport.add_child(holder)

	var context = ContextScript.new()
	var bus = BusScript.new()
	var machine = MachineScript.new()
	var services := Node.new()
	var host := Control.new()
	var sprite := AnimatedSprite2D.new()
	var controller = CharacterControllerScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(machine)
	holder.add_child(services)
	holder.add_child(host)
	host.add_child(sprite)
	holder.add_child(controller)

	host.size = Vector2(100.0, 200.0)
	var frames := SpriteFrames.new()
	frames.add_animation("walk")
	frames.set_animation_loop("walk", true)
	frames.add_animation("idle")
	frames.set_animation_loop("idle", true)
	sprite.sprite_frames = frames

	context.update_monitor({"virtual_rect": Rect2i(0, 0, 1920, 1080)})
	context.update_window({"canvas_scale": 1.0})
	controller.configure(context, bus, services, machine)
	controller.bind_character(host, sprite)
	var visual_test_screens: Array[Dictionary] = [
		{
			"screen": 0,
			"scale": 1.0,
			"logical": Rect2(0.0, 0.0, 1920.0, 1080.0),
			"physical": Rect2(0.0, 0.0, 1920.0, 1080.0),
		},
	]
	controller.coordinate_mapper.screens = visual_test_screens
	controller.presentation_coordinate_resolver.call(
		"configure", controller.coordinate_mapper
	)
	controller.start()

	bus.publish(&"character.physics_moved", {
		"position": Vector2(300.0, 500.0),
		"velocity": Vector2(-10.0, 0.0),
		"movementState": "walking",
		"motion": "authoritative-snap",
		"sequence": 2,
	})
	var first_position := host.position
	var first_animation: StringName = controller.physics_last_animation
	var first_flip := sprite.flip_h

	bus.publish(&"character.physics_moved", {
		"position": Vector2(900.0, 900.0),
		"velocity": Vector2(10.0, 0.0),
		"movementState": "walking",
		"motion": "authoritative-snap",
		"sequence": 1,
	})

	# Authoritative Physics coordinates must not be rewritten to fit the current
	# debug viewport. Feet=(300,500) and host=(100,200) resolve to top-left
	# (250,300), even when a smaller debug viewport would otherwise clamp it.
	var expected_position := Vector2(250.0, 300.0)
	var ok: bool = first_position.is_equal_approx(expected_position) \
		and host.position.is_equal_approx(first_position) \
		and first_animation == &"walk" \
		and first_flip

	_report("physics visual sequence and fallback", ok)

	controller.stop()
	bus.clear()
	test_viewport.queue_free()
	return ok


func _test_canonical_visual_binding_contract() -> bool:
	var binding = CanonicalVisualBindingScript.new()
	var spawn := {
		"schemaVersion": 1,
		"companionId": "default",
		"bodyId": 7,
		"sequence": 1,
		"revision": 1,
		"desktopFeet": Vector2(100.0, 500.0),
		"velocity": Vector2.ZERO,
		"movementState": "stationary",
		"attachmentState": "grounded",
		"facing": "unchanged",
		"updateKind": "spawn",
	}
	var accepted_spawn: Dictionary = binding.accept_canonical(spawn)

	binding.begin_drag_commit(Vector2(500.0, 500.0))
	var stale_continuous := spawn.duplicate(true)
	stale_continuous["sequence"] = 2
	stale_continuous["revision"] = 2
	stale_continuous["updateKind"] = "continuous"
	stale_continuous["desktopFeet"] = Vector2(100.0, 500.0)
	var held: Dictionary = binding.accept_canonical(stale_continuous)

	var wrong_body := spawn.duplicate(true)
	wrong_body["bodyId"] = 9
	wrong_body["sequence"] = 3
	wrong_body["revision"] = 3
	wrong_body["updateKind"] = "drag-commit"
	wrong_body["desktopFeet"] = Vector2(500.0, 500.0)
	var rejected_body: Dictionary = binding.accept_canonical(wrong_body)

	var mismatch := spawn.duplicate(true)
	mismatch["sequence"] = 4
	mismatch["revision"] = 4
	mismatch["updateKind"] = "drag-commit"
	mismatch["desktopFeet"] = Vector2(700.0, 500.0)
	var accepted_resolved_position: Dictionary = binding.accept_canonical(mismatch)

	var climbing := spawn.duplicate(true)
	climbing["sequence"] = 5
	climbing["revision"] = 5
	climbing["updateKind"] = "continuous"
	climbing["desktopFeet"] = Vector2(636.0, 540.0)
	climbing["velocity"] = Vector2(0.0, -120.0)
	climbing["movementState"] = "climbing"
	climbing["attachmentState"] = "attached"
	var accepted_climbing: Dictionary = binding.accept_canonical(climbing)

	binding.begin_drag_commit(Vector2(500.0, 500.0))
	var committed := spawn.duplicate(true)
	committed["sequence"] = 6
	committed["revision"] = 6
	committed["updateKind"] = "drag-commit"
	committed["desktopFeet"] = Vector2(501.0, 500.0)
	var accepted_commit: Dictionary = binding.accept_canonical(committed)

	var reordered_revision := committed.duplicate(true)
	reordered_revision["sequence"] = 7
	reordered_revision["revision"] = 2
	reordered_revision["movementState"] = "sitting"
	var accepted_reordered_revision: Dictionary = binding.accept_canonical(reordered_revision)

	var duplicate := committed.duplicate(true)
	var rejected_duplicate: Dictionary = binding.accept_canonical(duplicate)

	var ok: bool = bool(accepted_spawn.get("accepted", false)) \
		and binding.body_id == 7 \
		and not bool(held.get("accepted", true)) \
		and held.get("reason") == "drag-commit-pending" \
		and rejected_body.get("reason") == "body-identity-mismatch" \
		and bool(accepted_resolved_position.get("accepted", false)) \
		and accepted_resolved_position.get("desktopFeet") == Vector2(700.0, 500.0) \
		and bool(accepted_climbing.get("accepted", false)) \
		and accepted_climbing.get("movementState") == "climbing" \
		and bool(accepted_commit.get("accepted", false)) \
		and bool(accepted_reordered_revision.get("accepted", false)) \
		and accepted_reordered_revision.get("movementState") == "sitting" \
		and not binding.pending_drag_commit \
		and rejected_duplicate.get("reason") == "stale-sequence"
	_report("presentation authority contract", ok)
	return ok


func _test_presentation_coordinate_authority() -> bool:
	var mapper = CoordinateMapperScript.new()
	var coordinate_test_screens: Array[Dictionary] = [
		{
			"screen": 0,
			"scale": 1.0,
			"logical": Rect2(0.0, 0.0, 3840.0, 1920.0),
			"physical": Rect2(0.0, 0.0, 3840.0, 1920.0),
		},
		{
			"screen": 1,
			"scale": 1.0,
			"logical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
			"physical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
		},
	]
	mapper.screens = coordinate_test_screens
	mapper.primary_screen = 0
	mapper.physical_origin = Vector2(-1920.0, 0.0)

	var resolver = PresentationCoordinateResolverScript.new()
	resolver.configure(mapper)
	var viewport := Vector2(1280.0, 800.0)
	var host_size := Vector2(308.0, 308.0)

	var primary_target: Vector2 = resolver.desktop_feet_to_host_position(
		Vector2(1920.0, 1920.0), host_size, viewport, false
	)
	var negative_target: Vector2 = resolver.desktop_feet_to_host_position(
		Vector2(-960.0, 1080.0), host_size, viewport, false
	)
	var restored_feet: Vector2 = resolver.host_position_to_desktop_feet(
		negative_target, host_size, viewport, false
	)
	var overlay_target: Vector2 = resolver.desktop_feet_to_host_position(
		Vector2(1920.0, 1920.0), host_size, viewport, true
	)

	var ok: bool = primary_target.is_equal_approx(Vector2(486.0, 492.0)) \
		and negative_target.is_equal_approx(Vector2(486.0, 492.0)) \
		and restored_feet.is_equal_approx(Vector2(-960.0, 1080.0)) \
		and overlay_target.is_equal_approx(Vector2(3686.0, 1612.0))
	_report("presentation coordinate authority", ok)
	return ok


func _test_baseline_presentation_regression() -> bool:
	var startup_controller = StartupVisibilityControllerScript.new()
	var detached_main_window := Window.new()
	startup_controller.begin_startup(detached_main_window)
	var detached_startup_ok: bool = not startup_controller.is_revealed()

	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1280)
	viewport.transparent_bg = true
	get_root().add_child(viewport)

	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(layer)
	var host := Control.new()
	host.position = Vector2(500.0, 300.0)
	layer.add_child(host)
	var sprite := AnimatedSprite2D.new()
	host.add_child(sprite)

	var image := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	image.fill(Color(1.0, 1.0, 1.0, 1.0))
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")
	frames.add_animation("idle")
	frames.add_frame("idle", texture)
	sprite.sprite_frames = frames
	sprite.scale = Vector2.ONE * 0.7

	var character = CharacterControllerScript.new()
	character.host = host
	character.sprite = sprite
	character._sync_host_to_sprite_visual_bounds(frames)

	var menu := Control.new()
	menu.size = Vector2(260.0, 170.0)
	layer.add_child(menu)
	var hover = HoverControllerScript.new()
	hover.host = host
	hover.menu = menu
	hover._layout_menu()

	var window_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/window_controller.gd"
	)
	var runtime_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/runtime_app.gd"
	)
	var click_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/click_through_controller.gd"
	)
	var project_source := FileAccess.get_file_as_string("res://project.godot")
	var startup_visibility_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/startup_visibility_controller.gd"
	)

	var expected_rendered_size := Vector2(358.4, 358.4)
	var expected_menu_position := Vector2(220.0, 394.2)
	var ok: bool = (
		detached_startup_ok
		and viewport.transparent_bg
		and host.size.is_equal_approx(expected_rendered_size)
		and sprite.position.is_equal_approx(expected_rendered_size * 0.5)
		and menu.position.distance_to(expected_menu_position) < 0.01
		and window_source.contains("CONTENT_SCALE_MODE_CANVAS_ITEMS")
		and window_source.contains("window.transparent = true")
		and runtime_source.contains("%Background.visible = false")
		and click_source.contains(
			"Rect2(character_host.position, character_host.size)"
		)
		and runtime_source.contains(
			"startup_visibility_controller.begin_startup(get_window())"
		)
		and runtime_source.contains(
			"await startup_visibility_controller.reveal_when_ready()"
		)
		and project_source.contains("boot_splash/bg_color=Color(0, 0, 0, 0)")
		and startup_visibility_source.contains(
			"_can_toggle_native_visibility = can_toggle_native_visibility"
		)
		and startup_visibility_source.contains("if _revealed:")
		and runtime_source.contains("startup_visibility_controller.is_revealed()")
		and not startup_visibility_source.contains("_window != get_tree().root")
	)
	_report("baseline presentation regression", ok)
	hover.free()
	character.free()
	startup_controller.free()
	detached_main_window.free()
	viewport.queue_free()
	return ok


func _test_hybrid_presentation_root_rollback() -> bool:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 960)
	viewport.transparent_bg = true
	get_root().add_child(viewport)
	var baseline_parent := Control.new()
	baseline_parent.name = "BaselineParent"
	viewport.add_child(baseline_parent)

	var character := Control.new()
	character.name = "Character"
	character.position = Vector2(500.0, 300.0)
	var bubble := Control.new()
	bubble.name = "Bubble"
	bubble.position = Vector2(420.0, 180.0)
	var hover := Control.new()
	hover.name = "Hover"
	hover.position = Vector2(220.0, 390.0)
	baseline_parent.add_child(character)
	baseline_parent.add_child(bubble)
	baseline_parent.add_child(hover)
	var original_character_global := character.global_position
	var original_bubble_global := bubble.global_position
	var original_hover_global := hover.global_position

	var hybrid_root = HybridPresentationRootScene.instantiate()
	viewport.add_child(hybrid_root)
	var attached: bool = hybrid_root.attach_nodes(character, bubble, hover)
	var attached_ok: bool = (
		attached
		and hybrid_root.is_attached()
		and character.get_parent().name == "CharacterSlot"
		and bubble.get_parent().name == "BubbleSlot"
		and hover.get_parent().name == "HoverSlot"
		and character.global_position == original_character_global
		and bubble.global_position == original_bubble_global
		and hover.global_position == original_hover_global
	)

	hybrid_root.detach_all()
	var rollback_ok: bool = (
		not hybrid_root.is_attached()
		and character.get_parent() == baseline_parent
		and bubble.get_parent() == baseline_parent
		and hover.get_parent() == baseline_parent
		and character.global_position == original_character_global
		and bubble.global_position == original_bubble_global
		and hover.global_position == original_hover_global
	)

	var ok: bool = attached_ok and rollback_ok
	_report("hybrid presentation root rollback", ok)
	viewport.queue_free()
	return ok


func _test_hybrid_monitor_attachment_authority() -> bool:
	var attachment = PresentationMonitorAttachmentScript.new()
	var primary := {
		"screen": 0,
		"logical": Rect2(0.0, 0.0, 1440.0, 960.0),
		"physical": Rect2(0.0, 0.0, 2880.0, 1920.0),
	}
	var left := {
		"screen": 1,
		"logical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
		"physical": Rect2(0.0, 0.0, 3840.0, 2160.0),
	}

	var attached_primary: bool = attachment.attach(primary)
	var primary_local: Vector2 = attachment.desktop_to_local(Vector2(720.0, 480.0))
	var switched_left: bool = attachment.attach(left)
	var left_local: Vector2 = attachment.desktop_to_local(Vector2(-960.0, 540.0))
	var restored_left: Vector2 = attachment.local_to_desktop(left_local)
	var clamped: Vector2 = attachment.clamp_desktop_point(Vector2(-2200.0, 1200.0))

	var ok: bool = (
		attached_primary
		and switched_left
		and attachment.screen_index() == 1
		and primary_local.is_equal_approx(Vector2(1440.0, 960.0))
		and left_local.is_equal_approx(Vector2(1920.0, 1080.0))
		and restored_left.distance_to(Vector2(-960.0, 540.0)) < 0.01
		and clamped.is_equal_approx(Vector2(-1920.0, 1080.0))
	)
	_report("hybrid monitor attachment authority", ok)
	return ok


func _test_hybrid_monitor_window_probe_lifecycle() -> bool:
	var holder := Node.new()
	get_root().add_child(holder)
	var context = ContextScript.new()
	var bus = BusScript.new()
	var service = MonitorWindowServiceScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	service.configure(context, bus)
	context.update_runtime_config({
		"per_monitor_windows_enabled": true,
	})
	service.descriptors = {
		0: {
			"screen_index": 0,
			"desktop_rect": Rect2i(0, 0, 1536, 976),
			"scale": 1.25,
			"dpi": 120,
			"window_name": "MonitorWindow0",
		},
		2: {
			"screen_index": 2,
			"desktop_rect": Rect2i(-1920, 0, 1920, 1032),
			"scale": 2.0,
			"dpi": 192,
			"window_name": "MonitorWindow2",
		},
	}

	var first: Window = service.create_window_for_screen(0, false)
	var first_ok: bool = (
		is_instance_valid(first)
		and not first.visible
		and first.position == Vector2i(0, 0)
		and first.size == Vector2i(1536, 976)
		and first.content_scale_size == Vector2i(1536, 976)
		and service.active_screen_index == 0
		and service.windows.size() == 1
	)
	var second: Window = service.create_window_for_screen(2, false)
	var switch_ok: bool = (
		is_instance_valid(second)
		and second != first
		and not second.visible
		and second.position == Vector2i(-1920, 0)
		and second.size == Vector2i(1920, 1032)
		and service.active_screen_index == 2
		and service.active_window() == second
		and service.windows.size() == 1
	)
	service.destroy_monitor_windows()
	var rollback_ok: bool = (
		service.windows.is_empty()
		and service.active_screen_index == -1
		and service.active_window() == null
	)
	var ok: bool = first_ok and switch_ok and rollback_ok
	_report("hybrid monitor window probe lifecycle", ok)
	holder.queue_free()
	return ok


func _test_monitor_scoped_overlay_coordinate_authority() -> bool:
	var mapper = CoordinateMapperScript.new()
	var coordinate_test_screens: Array[Dictionary] = [
		{
			"screen": 0,
			"scale": 1.25,
			"logical": Rect2(0.0, 0.0, 1536.0, 1024.0),
			"physical": Rect2(0.0, 0.0, 1920.0, 1280.0),
		},
		{
			"screen": 1,
			"scale": 1.0,
			"logical": Rect2(1536.0, 0.0, 1920.0, 1080.0),
			"physical": Rect2(1920.0, 0.0, 1920.0, 1080.0),
		},
	]
	mapper.screens = coordinate_test_screens
	mapper.primary_screen = 0
	mapper.physical_origin = Vector2.ZERO

	var resolver = PresentationCoordinateResolverScript.new()
	resolver.configure(mapper)
	var changed: bool = resolver.set_overlay_screen(
		coordinate_test_screens[1]
	)
	# The production overlay is one virtual-desktop canvas, not a monitor-sized
	# canvas. The second monitor therefore maps into the right-hand portion of
	# the spanning viewport.
	var viewport := Vector2(3840.0, 1280.0)
	var desktop_point := Vector2(3283.0, 900.0)
	var local_point: Vector2 = resolver.desktop_point_to_local(
		desktop_point,
		viewport,
		true
	)
	var restored: Vector2 = resolver.local_point_to_desktop(
		local_point,
		viewport,
		true
	)

	var ok: bool = (
		changed
		and resolver.active_overlay_screen == 1
		and local_point.x >= 0.0
		and local_point.x <= viewport.x
		and local_point.y >= 0.0
		and local_point.y <= viewport.y
		and restored.distance_to(desktop_point) < 0.01
	)
	_report("virtual desktop overlay coordinate authority", ok)
	return ok


func _test_negative_monitor_overlay_coordinate_authority() -> bool:
	var mapper = CoordinateMapperScript.new()
	var coordinate_test_screens: Array[Dictionary] = [
		{
			"screen": 0,
			"scale": 1.0,
			"logical": Rect2(0.0, 0.0, 1440.0, 960.0),
			"physical": Rect2(0.0, 0.0, 1440.0, 960.0),
		},
		{
			"screen": 1,
			"scale": 1.0,
			"logical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
			"physical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
		},
	]
	mapper.screens = coordinate_test_screens
	mapper.primary_screen = 0
	mapper.physical_origin = Vector2(-1920.0, 0.0)

	var resolver = PresentationCoordinateResolverScript.new()
	resolver.configure(mapper)
	var changed: bool = resolver.set_overlay_screen(
		coordinate_test_screens[1]
	)
	var desktop_feet := Vector2(-66.0, 1032.0)
	var local_feet: Vector2 = resolver.desktop_point_to_local(
		desktop_feet,
		Vector2(1920.0, 1080.0),
		true
	)
	var restored: Vector2 = resolver.local_point_to_desktop(
		local_feet,
		Vector2(1920.0, 1080.0),
		true
	)

	var ok: bool = (
		changed
		and resolver.active_overlay_screen == 1
		and local_feet.is_equal_approx(Vector2(1854.0, 1032.0))
		and restored.is_equal_approx(desktop_feet)
	)
	_report("negative monitor overlay coordinate authority", ok)
	return ok


func _test_actual_dpi_two_virtual_desktop_fixture() -> bool:
	var mapper = CoordinateMapperScript.new()
	var actual_screens: Array[Dictionary] = [
		{
			"screen": 0,
			"scale": 2.0,
			"logical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
			"physical": Rect2(0.0, 0.0, 3840.0, 2160.0),
		},
		{
			"screen": 1,
			"scale": 2.0,
			"logical": Rect2(0.0, 0.0, 1440.0, 960.0),
			"physical": Rect2(3840.0, 0.0, 2880.0, 1920.0),
		},
		{
			"screen": 2,
			"scale": 2.0,
			"logical": Rect2(2880.0, 0.0, 1080.0, 1920.0),
			"physical": Rect2(6720.0, 0.0, 2160.0, 3840.0),
		},
	]
	mapper.screens = actual_screens
	mapper.primary_screen = 1
	mapper.physical_origin = Vector2.ZERO

	var left_local: Vector2 = mapper.desktop_to_overlay(Vector2(-1856.0, 1032.0))
	var primary_local: Vector2 = mapper.desktop_to_overlay(Vector2(640.0, 912.0))
	var right_local: Vector2 = mapper.desktop_to_overlay(Vector2(2880.0, 960.0))
	var ok: bool = (
		left_local.is_equal_approx(Vector2(128.0, 2064.0))
		and primary_local.is_equal_approx(Vector2(5120.0, 1824.0))
		and right_local.is_equal_approx(Vector2(6720.0, 1920.0))
	)
	_report("actual DPI two virtual desktop fixture", ok)
	return ok


func _test_mixed_height_three_monitor_visibility_fixture() -> bool:
	var mapper = CoordinateMapperScript.new()
	var fixture_screens: Array[Dictionary] = [
		{
			"screen": 0,
			"logical": Rect2(0.0, 0.0, 1440.0, 960.0),
			"physical": Rect2(6000.0, 286.0, 2880.0, 1920.0),
		},
		{
			"screen": 1,
			"logical": Rect2(-3000.0, -143.0, 1080.0, 1920.0),
			"physical": Rect2(0.0, 0.0, 2160.0, 3840.0),
		},
		{
			"screen": 2,
			"logical": Rect2(-1920.0, 0.0, 1920.0, 1080.0),
			"physical": Rect2(2160.0, 286.0, 3840.0, 2160.0),
		},
	]
	mapper.screens = fixture_screens
	mapper.primary_screen = 0
	mapper.physical_origin = Vector2.ZERO

	var resolver = PresentationCoordinateResolverScript.new()
	resolver.configure(mapper)
	var canvas_size := Vector2(8880.0, 3840.0)
	var host_size := Vector2(308.0, 308.0)
	var desktop_feet := Vector2(-353.5, 1032.0)
	var host_position: Vector2 = resolver.desktop_feet_to_host_position(
		desktop_feet,
		host_size,
		canvas_size,
		true
	)
	var restored: Vector2 = resolver.host_position_to_desktop_feet(
		host_position,
		host_size,
		canvas_size,
		true
	)
	var ok: bool = resolver.overlay_canvas_contains_host(
		host_position,
		host_size,
		canvas_size
	) and restored.is_equal_approx(desktop_feet)
	_report("mixed-height three-monitor visibility fixture", ok)
	return ok


func _report(name: String, ok: bool) -> void:
	if ok:
		print("[PASS] ", name)
	else:
		push_error("[FAIL] " + name)


func _test_native_presentation_coordinator_contract() -> bool:
	var context = ContextScript.new()
	var bus = BusScript.new()
	var coordinator = NativePresentationCoordinatorScript.new()
	coordinator.configure(context, bus)
	coordinator.start()

	var disabled_rejected: bool = not coordinator.request("default", "host-token")
	var default_overlay: bool = coordinator.state_name() == "fallback" \
		and context.runtime_config.get("presentation_owner", "") == "overlay"

	context.update_runtime_config({"native_presentation_enabled": true})
	var requested: bool = coordinator.request("default", "host-token")
	var ready: bool = coordinator.accept_ready("default", "host-token")
	var resized: bool = coordinator.accept_resized(256, 256) \
		and context.runtime_config.get("native_presentation_client_size", Vector2i.ZERO) == Vector2i(256, 256)
	var attached: bool = coordinator.accept_attached("default")
	var detached: bool = coordinator.accept_detached("default")
	var invalid_fallback: bool = not coordinator.accept_attached("wrong") \
		and coordinator.state_name() == "fallback" \
		and context.runtime_config.get("presentation_owner", "") == "overlay"

	coordinator.stop()
	var ok: bool = disabled_rejected and default_overlay and requested and ready and resized \
		and attached and detached and invalid_fallback
	_report("native presentation coordinator contract", ok)
	coordinator.free()
	bus.free()
	context.free()
	return ok


func _test_animation_facing_authority() -> bool:
	var controller = CharacterControllerScript.new()
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	frames.add_animation("walk_left")
	frames.set_animation_loop("walk_left", true)
	frames.add_animation("walk_right")
	frames.set_animation_loop("walk_right", true)
	frames.add_animation("surprised")
	frames.set_animation_loop("surprised", false)
	frames.add_animation("idle")
	frames.set_animation_loop("idle", true)
	frames.add_animation("climb_up")
	frames.set_animation_loop("climb_up", true)
	frames.add_animation("climb_ready")
	frames.set_animation_loop("climb_ready", false)
	frames.add_animation("climb_down")
	frames.set_animation_loop("climb_down", true)
	frames.add_animation("climb_top")
	frames.set_animation_loop("climb_top", false)
	frames.add_animation("hang")
	frames.set_animation_loop("hang", true)
	frames.add_animation("hang_left")
	frames.set_animation_loop("hang_left", true)
	frames.add_animation("hang_right")
	frames.set_animation_loop("hang_right", true)
	frames.add_animation("hang_traverse")
	frames.set_animation_loop("hang_traverse", true)
	frames.add_animation("sit")
	frames.set_animation_loop("sit", true)
	sprite.sprite_frames = frames
	controller.sprite = sprite

	var left_animation: StringName = controller._resolve_movement_animation(
		"walking", Vector2(-140.0, 0.0), "left"
	)
	var left_not_double_flipped: bool = not sprite.flip_h
	var right_animation: StringName = controller._resolve_movement_animation(
		"walking", Vector2(140.0, 0.0), "right"
	)
	var right_not_flipped: bool = not sprite.flip_h
	var jump_fallback: StringName = controller._resolve_movement_animation(
		"airborne-rising", Vector2(0.0, -590.0), "right"
	)
	var climb_fallback: StringName = controller._resolve_movement_animation(
		"climbing", Vector2(0.0, -120.0), "right"
	)
	var climb_down: StringName = controller._resolve_movement_animation(
		"climbing", Vector2(0.0, 120.0), "right"
	)
	var hanging_fallback: StringName = controller._resolve_movement_animation(
		"hanging", Vector2.ZERO, "right"
	)
	var hang_left_animation: StringName = controller._resolve_movement_animation(
		"hanging", Vector2(-140.0, 0.0), "left"
	)
	var hang_left_not_double_flipped: bool = not sprite.flip_h
	var hang_right_animation: StringName = controller._resolve_movement_animation(
		"hanging", Vector2(140.0, 0.0), "right"
	)
	var hang_right_not_flipped: bool = not sprite.flip_h
	var climb_ready: StringName = controller._resolve_movement_animation(
		"climb-ready", Vector2.ZERO, "left"
	)
	var climb_ready_faces_left: bool = sprite.flip_h
	var sitting_animation: StringName = controller._resolve_movement_animation(
		"sitting", Vector2.ZERO, "right"
	)
	sprite.flip_h = true
	controller._apply_started_animation_facing(&"happy")
	var emotion_preserves_artwork: bool = not sprite.flip_h
	sprite.flip_h = true
	controller._apply_started_animation_facing(&"climb_up")
	var climb_keeps_directional_facing: bool = sprite.flip_h

	var ok: bool = left_animation == &"walk_left" \
		and left_not_double_flipped \
		and right_animation == &"walk_right" \
		and right_not_flipped \
		and jump_fallback == &"surprised" \
		and climb_fallback == &"climb_up" \
		and climb_down == &"climb_down" \
		and hanging_fallback == &"hang" \
		and hang_left_animation == &"hang_left" \
		and hang_left_not_double_flipped \
		and hang_right_animation == &"hang_right" \
		and hang_right_not_flipped \
		and climb_ready == &"climb_ready" \
		and climb_ready_faces_left \
		and not frames.get_animation_loop("climb_ready") \
		and sitting_animation == &"sit" \
		and emotion_preserves_artwork \
		and climb_keeps_directional_facing
	_report("animation facing authority", ok)
	sprite.free()
	controller.free()
	return ok


func _test_physics_transition_animations() -> bool:
	var controller = CharacterControllerScript.new()
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	for animation_name in [
		&"idle", &"land", &"climb_top", &"climb_down", &"drag_release", &"fall", &"appear", &"disappear"
	]:
		frames.add_animation(animation_name)
	frames.set_animation_loop(&"idle", true)
	frames.set_animation_loop(&"land", false)
	frames.set_animation_loop(&"climb_top", false)
	frames.set_animation_loop(&"drag_release", false)
	frames.set_animation_loop(&"fall", true)
	sprite.sprite_frames = frames
	controller.sprite = sprite
	var bus = BusScript.new()
	controller.event_bus = bus
	var requested: Array[StringName] = []
	bus.subscribe(&"animation.requested", func(payload: Dictionary):
		requested.append(StringName(payload.get("name", "")))
	)

	controller.physics_last_movement_state = "airborne-falling"
	controller._apply_physics_animation("stationary", Vector2.ZERO)
	controller._on_animation_finished({"name": &"land"})
	controller.physics_last_movement_state = "hanging"
	controller._apply_physics_animation("stationary", Vector2.ZERO)
	controller.physics_last_movement_state = "hanging"
	controller._apply_physics_animation("climbing", Vector2(0.0, 120.0))
	controller.physics_last_animation = &"drag_release"
	controller.drag_release_visual_deadline_ms = Time.get_ticks_msec() + 350
	controller.physics_last_movement_state = "airborne-falling"
	controller.physics_last_velocity = Vector2(0.0, 120.0)
	var before_drag_release_fall := requested.size()
	controller._apply_physics_animation("airborne-falling", Vector2(0.0, 120.0))
	var drag_release_lock_ok := requested.size() == before_drag_release_fall
	controller._on_animation_finished({"name": &"drag_release"})
	controller._on_appear_requested({})
	controller._on_animation_finished({"name": &"appear"})
	controller._on_disappear_requested({})

	var ok: bool = drag_release_lock_ok and requested == [
		&"land", &"idle", &"climb_top", &"climb_down", &"fall", &"appear", &"idle", &"disappear"
	]
	_report("physics transition animations", ok)
	bus.free()
	sprite.free()
	controller.free()
	return ok


func _test_disappear_keeps_idle_visual_anchor() -> bool:
	var controller = CharacterControllerScript.new()
	var context = ContextScript.new()
	context.update_runtime_config({
		"native_presentation_enabled": true,
		"native_presentation_client_size": Vector2i(384, 384),
	})
	context.update_character({
		"scale": 1.0,
		"render_size": Vector2i(384, 384),
	})

	var host := Control.new()
	host.size = Vector2(384, 384)
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	var idle_image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	idle_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	idle_image.fill_rect(Rect2i(20, 12, 24, 48), Color.WHITE)
	var disappear_image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	disappear_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	disappear_image.fill_rect(Rect2i(4, 2, 56, 28), Color.WHITE)
	frames.add_animation(&"idle")
	frames.add_frame(&"idle", ImageTexture.create_from_image(idle_image))
	frames.add_animation(&"disappear")
	frames.add_frame(&"disappear", ImageTexture.create_from_image(disappear_image))
	sprite.sprite_frames = frames
	sprite.scale = Vector2.ONE

	controller.context = context
	controller.host = host
	controller.sprite = sprite

	sprite.animation = &"idle"
	controller.lifecycle_animation = &""
	controller._sync_host_to_sprite_visual_bounds(frames)
	var idle_position := sprite.position

	sprite.animation = &"disappear"
	controller.lifecycle_animation = &"disappear"
	controller._sync_host_to_sprite_visual_bounds(frames)
	var disappear_position := sprite.position
	var ok: bool = idle_position.is_equal_approx(disappear_position)
	_report("disappear keeps idle visual anchor", ok)

	sprite.free()
	host.free()
	context.free()
	controller.free()
	return ok


func _test_native_animation_stable_bounds() -> bool:
	var controller = CharacterControllerScript.new()
	var context = ContextScript.new()
	context.update_runtime_config({
		"native_presentation_enabled": true,
		"native_presentation_client_size": Vector2i(384, 384),
	})
	context.update_character({"render_size": Vector2i(384, 384)})
	var host := Control.new()
	host.size = Vector2(384, 384)
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	frames.add_animation(&"hang")
	var frame0 := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	frame0.fill(Color(0.0, 0.0, 0.0, 0.0))
	frame0.fill_rect(Rect2i(20, 8, 24, 32), Color.WHITE)
	var frame1 := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	frame1.fill(Color(0.0, 0.0, 0.0, 0.0))
	frame1.fill_rect(Rect2i(20, 8, 24, 56), Color.WHITE)
	frames.add_frame(&"hang", ImageTexture.create_from_image(frame0))
	frames.add_frame(&"hang", ImageTexture.create_from_image(frame1))
	sprite.sprite_frames = frames
	sprite.animation = &"hang"
	sprite.scale = Vector2.ONE
	controller.context = context
	controller.host = host
	controller.sprite = sprite
	var stable := controller._animation_alpha_rect(frames, &"hang")
	controller._sync_host_to_sprite_visual_bounds(frames)
	var late_texture: Texture2D = frames.get_frame_texture(&"hang", 1)
	var late_used := controller._texture_alpha_rect(late_texture)
	var late_bottom := sprite.position.y + (float(late_used.end.y) - float(late_texture.get_height()) * 0.5) * absf(sprite.scale.y)
	var ok: bool = stable.end.y == 64 and late_bottom <= host.size.y + 0.01
	_report("native animation stable bounds prevent late-frame clipping", ok)
	sprite.free()
	host.free()
	context.free()
	controller.free()
	return ok


func _test_native_canvas_ignores_mixed_dpi_viewport() -> bool:
	var controller = CharacterControllerScript.new()
	var context = ContextScript.new()
	context.update_runtime_config({"native_presentation_enabled": true})
	context.update_character({"render_size": Vector2i(384, 384)})

	var viewport := SubViewport.new()
	viewport.size = Vector2i(768, 768)
	get_root().add_child(viewport)
	var host := Control.new()
	viewport.add_child(host)
	controller.context = context
	controller.host = host

	var mixed_dpi_canvas := controller._native_canvas_size()
	viewport.size = Vector2i(768, 640)
	var unsettled_canvas := controller._native_canvas_size()
	var ok: bool = mixed_dpi_canvas.is_equal_approx(Vector2(384, 384)) \
		and unsettled_canvas.is_equal_approx(Vector2(384, 384))
	_report("native canvas ignores mixed-DPI viewport", ok)

	viewport.queue_free()
	context.free()
	controller.free()
	return ok


func _test_native_window_content_scale_policy() -> bool:
	var controller = WindowControllerScript.new()
	var policy: Dictionary = controller.native_canvas_policy(384)
	var minimum: Dictionary = controller.native_canvas_policy(64)
	var maximum: Dictionary = controller.native_canvas_policy(1024)
	var ok: bool = int(policy.get("mode", -1)) \
		== Window.CONTENT_SCALE_MODE_CANVAS_ITEMS \
		and int(policy.get("aspect", -1)) == Window.CONTENT_SCALE_ASPECT_IGNORE \
		and policy.get("size", Vector2i.ZERO) == Vector2i(384, 384) \
		and minimum.get("size", Vector2i.ZERO) == Vector2i(128, 128) \
		and maximum.get("size", Vector2i.ZERO) == Vector2i(768, 768)
	_report("native window keeps one authored canvas across DPI", ok)

	controller.free()
	return ok


func _test_native_exit_waits_for_host_handoff() -> bool:
	var holder := Node.new()
	get_root().add_child(holder)
	var bus = BusScript.new()
	holder.add_child(bus)
	var context = ContextScript.new()
	context.update_runtime_config({"native_presentation_enabled": true})
	var controller = WindowControllerScript.new()
	controller.event_bus = bus
	controller.context = context

	var shutdown_events := [0]
	bus.subscribe(&"system.shutting_down", func(_payload: Dictionary): shutdown_events[0] += 1)
	controller._on_exit_requested({"source": "test"})
	# Reaching this assertion proves the native path did not quit SceneTree.
	var native_lifecycle_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/services/native_host_lifecycle.gd"
	)
	var runtime_app_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/runtime_app.gd"
	)
	var host_closed_start := native_lifecycle_source.find('elif status == "host-closed"')
	var host_closed_end := native_lifecycle_source.find("_process_native_event()", host_closed_start)
	var host_closed_block := native_lifecycle_source.substr(
		host_closed_start,
		maxi(0, host_closed_end - host_closed_start)
	) if host_closed_start >= 0 and host_closed_end > host_closed_start else ""
	var publish_offset := host_closed_block.find('event_bus.publish(&"system.exit_ready"')
	var fallback_quit_offset := host_closed_block.find("get_tree().quit(0)")
	var graceful_start := runtime_app_source.find("func _graceful_shutdown_and_quit()")
	var graceful_end := runtime_app_source.find("func _shutdown_runtime()", graceful_start + 1)
	var graceful_block := runtime_app_source.substr(
		graceful_start,
		maxi(0, graceful_end - graceful_start)
	) if graceful_start >= 0 and graceful_end > graceful_start else ""
	var cleanup_offset := graceful_block.find("_shutdown_runtime()")
	var quit_offset := graceful_block.find("get_tree().quit(0)")
	var graceful_order_ok := publish_offset >= 0 \
		and fallback_quit_offset > publish_offset \
		and cleanup_offset >= 0 \
		and quit_offset > cleanup_offset \
		and graceful_block.count("await get_tree().process_frame") >= 2
	var ok: bool = shutdown_events[0] == 1 and graceful_order_ok
	_report("native exit waits for detach handoff", ok)

	bus.clear()
	holder.remove_child(bus)
	bus.free()
	context.free()
	controller.free()
	holder.free()
	return ok


func _test_overlay_mode_state_authority() -> bool:
	var context = ContextScript.new()
	var controller = WindowControllerScript.new()
	controller.context = context

	controller._set_overlay_enabled(true)
	var overlay_ok: bool = bool(
		context.runtime_config.get("overlay_enabled", false)
	) and bool(context.window.get("overlay_enabled", false))

	controller._set_overlay_enabled(false)
	var debug_ok: bool = not bool(
		context.runtime_config.get("overlay_enabled", true)
	) and not bool(context.window.get("overlay_enabled", true))

	var ok: bool = overlay_ok and debug_ok
	_report("overlay mode state authority", ok)
	controller.free()
	context.free()
	return ok


func _test_overlay_canvas_authority() -> bool:
	var window_controller = WindowControllerScript.new()
	var overlay_rect := Rect2i(-3840, 0, 11760, 3744)
	var overlay_canvas: Vector2i = window_controller.presentation_canvas_size(
		&"overlay", overlay_rect
	)
	var debug_canvas: Vector2i = window_controller.presentation_canvas_size(
		&"debug", Rect2i()
	)

	var mapper = CoordinateMapperScript.new()
	var screens: Array[Dictionary] = [
		{
			"screen": 0,
			"scale": 1.0,
			"logical": Rect2(-1920.0, 0.0, 1920.0, 1920.0),
			"physical": Rect2(-3840.0, 0.0, 3840.0, 2064.0),
		},
		{
			"screen": 1,
			"scale": 1.0,
			"logical": Rect2(0.0, 0.0, 3960.0, 1920.0),
			"physical": Rect2(0.0, 0.0, 7920.0, 3744.0),
		},
	]
	mapper.screens = screens
	mapper.physical_origin = Vector2(-3840.0, 0.0)

	var resolver = PresentationCoordinateResolverScript.new()
	resolver.configure(mapper)
	var host_size := Vector2(308.0, 308.0)
	var host_position: Vector2 = resolver.desktop_feet_to_host_position(
		Vector2(3896.0, 1920.0),
		host_size,
		Vector2(overlay_canvas),
		true
	)
	var visible_in_overlay: bool = resolver.overlay_canvas_contains_host(
		host_position,
		host_size,
		Vector2(overlay_canvas)
	)

	var ok: bool = overlay_canvas == overlay_rect.size \
		and debug_canvas == Vector2i(1280, 800) \
		and visible_in_overlay \
		and host_position.x > 1280.0
	_report("overlay canvas authority", ok)
	window_controller.free()
	return ok


func _test_windows_dpi_coordinate_authority() -> bool:
	var mapper = CoordinateMapperScript.new()
	var effective_scale: float = mapper.effective_windows_scale(1.0, 192)
	var primary_position := Vector2(3840.0, 0.0)

	var primary_logical: Rect2 = mapper.derive_logical_rect(
		Rect2(3840.0, 0.0, 2880.0, 1920.0),
		primary_position,
		effective_scale,
		effective_scale
	)
	var left_logical: Rect2 = mapper.derive_logical_rect(
		Rect2(0.0, 0.0, 3840.0, 2160.0),
		primary_position,
		effective_scale,
		effective_scale
	)
	var right_logical: Rect2 = mapper.derive_logical_rect(
		Rect2(9600.0, 0.0, 2160.0, 3840.0),
		primary_position,
		effective_scale,
		effective_scale
	)

	var ok: bool = is_equal_approx(effective_scale, 2.0) \
		and primary_logical == Rect2(0.0, 0.0, 1440.0, 960.0) \
		and left_logical == Rect2(-1920.0, 0.0, 1920.0, 1080.0) \
		and right_logical == Rect2(2880.0, 0.0, 1080.0, 1920.0) \
		and is_equal_approx(left_logical.position.x, -1920.0) \
		and is_equal_approx(right_logical.end.x, 3960.0)
	_report("windows DPI coordinate authority", ok)
	return ok


func _test_drag_commit_visual_hold() -> bool:
	var controller = CharacterControllerScript.new()
	var host := Control.new()
	host.size = Vector2(100.0, 200.0)
	host.position = Vector2(500.0, 300.0)
	controller.host = host
	controller.presentation_drag_commit_pending = true
	controller.presentation_drag_commit_started_ms = Time.get_ticks_msec()
	controller.pending_drag_desktop_feet = Vector2(550.0, 500.0)
	controller.physics_target_active = true
	controller.physics_target_position = Vector2.ZERO
	controller._process(1.0)
	var ok: bool = host.position == Vector2(500.0, 300.0)
	_report("drag commit visual hold", ok)
	host.free()
	controller.free()
	return ok


func _test_runtime_mode_authority_default() -> bool:
	var authority = RuntimeModeAuthorityScript.new()
	var previous := OS.get_environment("OCP_PRESENTATION_MODE")
	var previous_probe := OS.get_environment("OCP_HYBRID_MONITOR_WINDOW_PROBE")
	OS.set_environment("OCP_PRESENTATION_MODE", "")
	var defaults_to_overlay: bool = authority.resolve_start_overlay({})
	var saved_debug_is_respected: bool = not authority.resolve_start_overlay({
		"startInOverlay": false,
	})
	OS.set_environment("OCP_PRESENTATION_MODE", "overlay")
	var forced_overlay: bool = authority.resolve_start_overlay({
		"startInOverlay": false,
	})
	OS.set_environment("OCP_PRESENTATION_MODE", "debug")
	var forced_debug: bool = not authority.resolve_start_overlay({
		"startInOverlay": true,
	})
	OS.set_environment("OCP_PRESENTATION_MODE", "hybrid-monitor")
	var hybrid_is_explicit: bool = (
		authority.resolve_requested_mode({}) == &"hybrid-monitor"
		and authority.is_hybrid_monitor_requested()
	)
	OS.set_environment("OCP_HYBRID_MONITOR_WINDOW_PROBE", "true")
	var hybrid_probe_is_explicit: bool = (
		authority.is_hybrid_monitor_window_probe_requested()
	)
	OS.set_environment("OCP_PRESENTATION_MODE", previous)
	OS.set_environment("OCP_HYBRID_MONITOR_WINDOW_PROBE", previous_probe)
	var ok := (
		defaults_to_overlay
		and saved_debug_is_respected
		and forced_overlay
		and forced_debug
		and hybrid_is_explicit
		and hybrid_probe_is_explicit
	)
	_report("runtime mode authority", ok)
	return ok


func _test_saved_position_topology_validation() -> bool:
	var mapper = CoordinateMapperScript.new()
	var screens: Array[Dictionary] = [{
		"screen": 0,
		"scale": 1.25,
		"logical": Rect2(0.0, 0.0, 1536.0, 1024.0),
		"physical": Rect2(0.0, 0.0, 1920.0, 1280.0),
	}]
	mapper.screens = screens
	var inside: bool = mapper.contains_desktop_point(Vector2(640.0, 700.0))
	var stale: bool = not mapper.contains_desktop_point(Vector2(2345.0, 678.0))
	var clamped := mapper.clamp_desktop_point(Vector2(2345.0, 678.0))
	var ok := inside and stale and is_equal_approx(clamped.x, 1536.0)
	_report("saved position topology validation", ok)
	return ok


func _test_drag_release_capture_contract() -> bool:
	var character_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/character_controller.gd"
	)
	var click_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/click_through_controller.gd"
	)
	var native_lifecycle_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/services/native_host_lifecycle.gd"
	)
	var ok: bool = (
		character_source.contains("_finish_drag_commit")
		and character_source.contains("poll-release-fallback")
		and character_source.contains("click_through.drag_capture_started")
		and not character_source.contains(
			'event_bus.publish(&"click_through.refresh_requested", {})\n'
			+ '\t\thost.get_viewport().set_input_as_handled()\n\n\nfunc _on_character_loaded'
		)
		and click_source.contains("drag_capture_active")
		and click_source.contains("_on_drag_capture_started")
		and native_lifecycle_source.contains('elif status == "drag-probe":')
		and native_lifecycle_source.contains('"recoveredFromProbe": true')
		and character_source.contains('"motion:fall-to-land"')
		and character_source.contains('"motion:climb-to-hang"')
	)
	_report("drag release capture contract", ok)
	return ok


func _test_native_drag_animation_bridge() -> bool:
	var controller = CharacterControllerScript.new()
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	for animation_name in [&"idle", &"drag_hold", &"drag_release", &"fall"]:
		frames.add_animation(animation_name)
	frames.set_animation_loop(&"idle", true)
	frames.set_animation_loop(&"drag_hold", true)
	frames.set_animation_loop(&"drag_release", false)
	frames.set_animation_loop(&"fall", true)
	sprite.sprite_frames = frames
	controller.sprite = sprite
	var bus = BusScript.new()
	controller.event_bus = bus
	var requested: Array[StringName] = []
	bus.subscribe(&"animation.requested", func(payload: Dictionary):
		requested.append(StringName(payload.get("name", "")))
	)

	controller._on_character_drag_started({"source": "native-host"})
	var hold_ok: bool = controller.native_drag_visual_active \
		and controller.physics_last_animation == &"drag_hold" \
		and requested == [&"drag_hold"]
	var before_hold_physics := requested.size()
	controller._apply_physics_animation("airborne-falling", Vector2(0.0, 120.0))
	var hold_locked := requested.size() == before_hold_physics

	controller.physics_last_movement_state = "airborne-falling"
	controller.physics_last_velocity = Vector2(0.0, 120.0)
	controller._on_character_drag_finished({
		"source": "native-host",
		"desktopFeet": Vector2(640.0, 480.0),
	})
	var release_ok: bool = not controller.native_drag_visual_active \
		and controller.physics_last_animation == &"drag_release" \
		and controller.drag_release_visual_deadline_ms > Time.get_ticks_msec() \
		and controller.drag_release_requested_feet == Vector2(640.0, 480.0) \
		and controller._native_anchor_is_locked() \
		and controller._native_hitbox_is_locked() \
		and requested == [&"drag_hold", &"drag_release"]
	var before_release_physics := requested.size()
	controller._apply_physics_animation("airborne-falling", Vector2(0.0, 120.0))
	var release_locked := requested.size() == before_release_physics
	controller._on_animation_finished({"name": &"drag_release"})
	var resumed_fall := requested == [&"drag_hold", &"drag_release", &"fall"]
	var release_unlocked := not controller._native_anchor_is_locked() \
		and not controller._native_hitbox_is_locked()

	var ok: bool = hold_ok and hold_locked and release_ok and release_locked \
		and resumed_fall and release_unlocked
	_report("native drag animation bridge", ok)
	bus.free()
	sprite.free()
	controller.free()
	return ok


func _test_drag_edge_predictive_prefetch() -> bool:
	var controller = CharacterControllerScript.new()
	var context = ContextScript.new()
	# Production MultiMonitorController stores Rect2i values from DisplayServer.
	context.update_monitor({"rects": [Rect2i(0, 0, 1920, 1080)]})
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	for animation_name in [&"idle", &"climb_ready_left", &"climb_ready_right"]:
		frames.add_animation(animation_name)
	frames.set_animation_loop(&"idle", true)
	sprite.sprite_frames = frames
	sprite.animation = &"idle"
	controller.context = context
	controller.sprite = sprite

	var left := controller._predict_drag_edge_animation(Vector2(100.0, 500.0))
	var right := controller._predict_drag_edge_animation(Vector2(1820.0, 500.0))
	var middle := controller._predict_drag_edge_animation(Vector2(960.0, 500.0))
	var outside := controller._predict_drag_edge_animation(Vector2(100.0, 1200.0))
	var ok := str(left.get("edge", "")) == "left" \
		and str(left.get("facing", "")) == "right" \
		and StringName(left.get("animation", &"")) == &"climb_ready_right" \
		and str(right.get("edge", "")) == "right" \
		and str(right.get("facing", "")) == "left" \
		and StringName(right.get("animation", &"")) == &"climb_ready_left" \
		and middle.is_empty() \
		and outside.is_empty()
	_report("drag edge predictive prefetch", ok)
	sprite.free()
	context.free()
	controller.free()
	return ok


func _test_native_mouse_capture_contract() -> bool:
	var character_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/character_controller.gd"
	)
	var adapter_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/services/runtime_bridge_adapter.gd"
	)
	var ok: bool = (
		character_source.contains("begin_native_mouse_capture")
		and character_source.contains("end_native_mouse_capture")
		and character_source.contains("[drag-sync] finish")
		and adapter_source.contains("begin_native_mouse_capture")
		and adapter_source.contains("end_native_mouse_capture")
	)
	_report("native mouse capture contract", ok)
	return ok


func _test_drag_commit_bridge_contract() -> bool:
	var adapter_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/services/runtime_bridge_adapter.gd"
	)
	var ok: bool = (
		adapter_source.contains('bridge.has_method("commit_companion_position")')
		and adapter_source.contains('"authoritative-snap"') == false
	)
	# The wire schema is owned and unit-tested in the Rust bridge. This test
	# verifies that GDScript delegates to that single authority.
	_report("drag commit bridge contract", ok)
	return ok


func _test_log_policy_contract() -> bool:
	var character_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/character_controller.gd"
	)
	var ok: bool = (
		character_source.contains("if not render_debug_enabled:")
		and not character_source.contains(
			'phase not in [\n\t\t"bind-character",\n\t\t"controller-start"'
		)
	)
	_report("log policy contract", ok)
	return ok
