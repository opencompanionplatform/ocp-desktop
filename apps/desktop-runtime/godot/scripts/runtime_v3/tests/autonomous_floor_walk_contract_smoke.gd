extends SceneTree

const ControllerScript = preload("res://scripts/runtime_v3/controllers/autonomous_floor_walk_controller.gd")
const AnimationControllerScript = preload("res://scripts/runtime_v3/controllers/animation_controller.gd")
const CharacterControllerScript = preload("res://scripts/runtime_v3/controllers/character_controller.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")


class FakeContext:
	extends Node
	signal context_changed(section: StringName)
	var character: Dictionary = {"scale": 1.0, "visual_profiles": {}}
	var settings: Dictionary = {"offline_presence_enabled": true}
	var window: Dictionary = {"hidden_to_tray": false}
	var runtime_config: Dictionary = {"overlay_enabled": false, "native_presentation_enabled": false}
	var monitor: Dictionary = {"scales": []}

	func set_enabled(enabled: bool) -> void:
		settings["offline_presence_enabled"] = enabled
		context_changed.emit(&"settings")

	func update_character(values: Dictionary) -> void:
		character.merge(values, true)


class FakeBridge:
	extends Node
	var requests: Array[String] = []

	func request_companion_movement(_companion_id: String, action: String) -> bool:
		requests.append(action)
		return true


class FakeServices:
	extends Node
	var bridge_adapter: Node


class TeleportVisualProbe:
	extends Node
	var order: Array[String] = []
	var lifecycle_events := 0

	func start(bus: Node) -> void:
		bus.subscribe(&"character.teleport_visual_requested", _on_requested)
		bus.subscribe(&"character.teleport_visual_ready", _on_ready)
		bus.subscribe(&"character.appear_requested", _on_lifecycle)
		bus.subscribe(&"character.disappear_requested", _on_lifecycle)

	func _on_requested(_payload: Dictionary) -> void:
		order.append("requested")

	func _on_ready(_payload: Dictionary) -> void:
		order.append("ready")

	func _on_lifecycle(_payload: Dictionary) -> void:
		lifecycle_events += 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := EventBusScript.new()
	var bridge := FakeBridge.new()
	var services := FakeServices.new()
	var controller := ControllerScript.new()
	var animation_controller := AnimationControllerScript.new()
	var teleport_character_controller := CharacterControllerScript.new()
	var teleport_host := Control.new()
	var teleport_sprite := AnimatedSprite2D.new()
	var teleport_probe := TeleportVisualProbe.new()
	var sprite := AnimatedSprite2D.new()
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	for animation_name in [&"idle", &"think", &"happy", &"wave", &"walk_left"]:
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, true)
		frames.set_animation_speed(animation_name, 8.0)
		var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		image.fill(Color.WHITE)
		var texture := ImageTexture.create_from_image(image)
		frames.add_frame(animation_name, texture)
		frames.add_frame(animation_name, texture)
	sprite.sprite_frames = frames
	var teleport_frames := SpriteFrames.new()
	if teleport_frames.has_animation(&"default"):
		teleport_frames.remove_animation(&"default")
	teleport_frames.add_animation(&"idle")
	teleport_frames.set_animation_loop(&"idle", true)
	var teleport_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	teleport_image.fill(Color.WHITE)
	teleport_frames.add_frame(&"idle", ImageTexture.create_from_image(teleport_image))
	teleport_sprite.sprite_frames = teleport_frames
	teleport_host.size = Vector2(64.0, 64.0)
	teleport_host.add_child(teleport_sprite)
	var state_machine := Node.new()
	services.bridge_adapter = bridge
	for node in [context, bus, bridge, services, state_machine, controller, animation_controller, sprite, teleport_host, teleport_character_controller, teleport_probe]:
		holder.add_child(node)
	controller.configure(context, bus, services, state_machine)
	animation_controller.configure(context, bus, services, state_machine)
	animation_controller.bind_sprite(sprite)
	teleport_character_controller.configure(context, bus, services, state_machine)
	teleport_character_controller.bind_character(teleport_host, teleport_sprite)
	teleport_probe.start(bus)
	controller.start()
	animation_controller.start()
	# Production receives surfaceKind on canonical presentation_state; the
	# companion_moved mirror intentionally carries only movement fields.
	bus.publish(&"character.presentation_state", {
		"companionId": "default",
		"movementState": "stationary",
		"surfaceKind": "desktop_floor",
	})
	var profile_ids: Array[String] = []
	var profile_bounds := true
	for profile_index in range(8):
		var profile := controller._behavior_profile(profile_index)
		profile_ids.append(str(profile.get("id", "")))
		profile_bounds = profile_bounds \
			and float(profile.get("walk_seconds", 0.0)) >= 9.0 \
			and float(profile.get("walk_seconds", 0.0)) <= 13.0 \
			and float(profile.get("rest_seconds", 0.0)) >= 16.0 \
			and float(profile.get("rest_seconds", 0.0)) <= 22.0 \
			and float(profile.get("hang_settle_seconds", 0.0)) >= 0.85 \
			and float(profile.get("hang_settle_seconds", 0.0)) <= 1.25
	var deterministic_profiles: bool = profile_ids == [
		"patrol-left-medium", "patrol-right-short", "teleport-left-reset", "patrol-right-long",
		"patrol-left-medium", "patrol-right-short", "teleport-left-reset", "patrol-right-long",
	]
	var no_adjacent_profile_repeat := true
	for profile_index in range(1, profile_ids.size()):
		no_adjacent_profile_repeat = no_adjacent_profile_repeat and profile_ids[profile_index] != profile_ids[profile_index - 1]

	var starts_left: bool = controller._start_walk() and bridge.requests == ["walk-left"]
	var patrol_state: bool = controller.policy_state == "Patrol"
	bus.publish(&"animation.requested", {"name": "think", "source": "offline-presence"})
	var offline_think_deferred: bool = bridge.requests == ["walk-left"] and controller.walking
	bus.publish(&"animation.requested", {"name": "happy", "source": "offline-presence"})
	bus.publish(&"animation.requested", {"name": "wave", "source": "offline-presence"})
	bus.publish(&"animation.requested", {"name": "idle", "source": "offline-presence"})
	bus.publish(&"animation.requested", {"name": "walk_left", "source": "physics"})
	var physics_animation_visible: bool = not animation_controller.presentation_lock \
		and sprite.animation == &"walk_left" and sprite.is_playing()
	controller._stop_walk("smoke")
	var finite_stop: bool = bridge.requests == ["walk-left", "stop"]
	var starts_right: bool = controller._start_walk() and bridge.requests.back() == "walk-right"
	controller._stop_walk("before-surface-smoke")
	var profile_request_count := bridge.requests.size()
	var profile_patrol_requested: bool = controller._start_next_action() \
		and bridge.requests.size() == profile_request_count + 1 \
		and bridge.requests.back() == "walk-left" \
		and controller.active_profile_id == "patrol-left-medium" \
		and is_equal_approx(controller.walk_remaining_seconds, 11.0) \
		and is_equal_approx(controller.rest_interval_seconds, 18.0) \
		and is_equal_approx(controller.active_hang_settle_seconds, 0.85)
	controller._stop_walk("profile-smoke")
	var random_plan_a := controller._choose_hang_exit_plan()
	var random_plan_b := controller._choose_hang_exit_plan()
	var random_hang_plans: bool = random_plan_a in ["middle-fall", "edge-fall", "climb-down"] \
		and random_plan_b in ["middle-fall", "edge-fall", "climb-down"] \
		and random_plan_a != random_plan_b
	var climb_requested: bool = controller._start_climb() and bridge.requests.back() == "climb-up"
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge"})
	var climbing_state: bool = controller.movement_phase == "climbing" and controller.policy_state == "Climb"
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climb-ready", "surfaceKind": "monitor_edge"})
	var selected_hang_plan := controller.hang_exit_plan
	var expected_hang_route := "hang-to-center" if selected_hang_plan == "middle-fall" else "hang-to-climb-down-edge"
	var random_route_requested: bool = controller.movement_phase == "hanging-route" \
		and controller.policy_state == "Hang" \
		and selected_hang_plan in ["middle-fall", "edge-fall", "climb-down"] \
		and bridge.requests.back() == expected_hang_route
	bus.publish(&"animation.requested", {"name": "think", "source": "offline-presence"})
	var offline_think_keeps_hang_route: bool = controller.movement_phase == "hanging-route" and bridge.requests.back() == expected_hang_route
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "velocity": Vector2(140.0, 0.0)})
	var route_motion_observed: bool = controller.hang_route_moved
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "velocity": Vector2.ZERO})
	var route_arrived: bool = controller.movement_phase == "hang-settling"
	var profile_hang_settle_used: bool = is_equal_approx(controller.surface_remaining_seconds, 0.85)
	controller._process(1.11)
	var random_exit_requested: bool
	var climbing_down_state := true
	if selected_hang_plan == "climb-down":
		random_exit_requested = controller.movement_phase == "climb-down-requested" and bridge.requests.back() == "climb-down"
		bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "velocity": Vector2(0.0, 120.0)})
		climbing_down_state = controller.movement_phase == "climbing-down" and controller.policy_state == "Climb"
	else:
		random_exit_requested = controller.movement_phase == "detaching" and bridge.requests.back() == "detach"
		bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "airborne-falling", "surfaceKind": "monitor_edge"})
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "desktop_floor"})
	var landed: bool = controller.movement_phase == "idle" and controller.policy_state == "Cooldown"
	var landing_cooldown_blocks_action: bool = not controller._start_next_action()
	controller._process(6.1)
	var landing_cooldown_completed: bool = controller.policy_state == "Rest" and controller.cooldown_remaining_seconds == 0.0

	# Tall-monitor regression: active climb progress must keep the safety watchdog
	# alive beyond the old fixed 12-second journey limit. Only a genuinely stalled
	# solver may time out. This contract intentionally uses canonical desktopFeet
	# so it remains independent of monitor geometry/DPI/native placement.
	controller.cooldown_remaining_seconds = 0.0
	controller._set_policy_state("Rest", "tall-climb-watchdog-smoke")
	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "idle"
	var tall_climb_requested: bool = controller._start_climb()
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 1900.0), "velocity": Vector2(0.0, -120.0)})
	controller._process(6.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 1500.0), "velocity": Vector2(0.0, -120.0)})
	controller._process(6.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 1100.0), "velocity": Vector2(0.0, -120.0)})
	controller._process(6.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 700.0), "velocity": Vector2(0.0, -120.0)})
	var tall_climb_survives_fixed_timeout: bool = controller.movement_phase == "climbing"
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climb-ready", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 64.0), "velocity": Vector2.ZERO})
	var tall_climb_reaches_hang: bool = controller.movement_phase == "hanging-route" and controller.policy_state == "Hang"
	controller._stop_surface_behavior("tall-climb-watchdog-smoke-complete")

	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "idle"
	var stalled_climb_requested: bool = controller._start_climb()
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 900.0), "velocity": Vector2.ZERO})
	controller._process(controller.CLIMB_TIMEOUT_SECONDS + 0.1)
	var stalled_climb_stops: bool = controller.movement_phase == "idle" and bridge.requests.back() == "stop"

	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "idle"
	var tall_climb_down_requested: bool = controller._start_climb_down()
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 200.0), "velocity": Vector2(0.0, 120.0)})
	controller._process(6.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 650.0), "velocity": Vector2(0.0, 120.0)})
	controller._process(6.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 1100.0), "velocity": Vector2(0.0, 120.0)})
	controller._process(6.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "climbing", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 1550.0), "velocity": Vector2(0.0, 120.0)})
	var tall_climb_down_survives_fixed_timeout: bool = controller.movement_phase == "climbing-down"
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(64.0, 1800.0), "velocity": Vector2.ZERO})
	var tall_climb_down_lands: bool = controller.movement_phase == "idle" and controller.policy_state == "Cooldown"
	controller.cooldown_remaining_seconds = 0.0
	controller._set_policy_state("Rest", "tall-climb-watchdog-smoke-reset")

	# Wide-monitor regression: an active hang route may legitimately take longer
	# than the old fixed 20-second journey limit. Canonical X progress must keep
	# the safety watchdog alive; a genuinely stalled route must still stop.
	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "climbing"
	var long_hang_route_requested: bool = controller._start_hang_plan("edge-fall")
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(-1856.0, 667.0), "velocity": Vector2(84.0, 0.0)})
	controller._process(7.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(-1268.0, 667.0), "velocity": Vector2(84.0, 0.0)})
	controller._process(7.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(-680.0, 667.0), "velocity": Vector2(84.0, 0.0)})
	controller._process(7.1)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(-192.0, 667.0), "velocity": Vector2(84.0, 0.0)})
	var long_hang_route_survives_fixed_timeout: bool = controller.movement_phase == "hanging-route"
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(-176.0, 667.0), "velocity": Vector2.ZERO, "updateKind": "route-arrived"})
	var long_hang_route_arrives: bool = controller.movement_phase == "hang-settling"
	controller._stop_surface_behavior("long-hang-watchdog-smoke-complete")

	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "climbing"
	var stalled_hang_route_requested: bool = controller._start_hang_plan("edge-fall")
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "hanging", "surfaceKind": "monitor_edge", "desktopFeet": Vector2(-900.0, 667.0), "velocity": Vector2.ZERO})
	controller._process(controller.HANG_ROUTE_TIMEOUT_SECONDS + 0.1)
	var stalled_hang_route_stops: bool = controller.movement_phase == "idle" and bridge.requests.back() == "stop"

	# Passive hover contract: a stationary cursor must not stop a companion that
	# walks underneath it. Hover pauses only future scheduling.
	controller.last_surface_kind = "desktop_floor"
	controller.movement_phase = "walking"
	controller.walking = true
	controller.walk_remaining_seconds = 5.0
	controller.hover_menu_active = false
	var hover_walk_request_count := bridge.requests.size()
	bus.publish(&"character.hover_entered", {"source": "smoke-walk-hover"})
	controller._process(0.1)
	var hover_preserves_walk: bool = controller.walking \
		and controller.movement_phase == "walking" \
		and controller.hover_menu_active \
		and controller.walk_remaining_seconds < 5.0 \
		and bridge.requests.size() == hover_walk_request_count
	bus.publish(&"character.hover_exited", {"source": "smoke-walk-hover"})
	var hover_exit_preserves_walk: bool = controller.walking \
		and controller.movement_phase == "walking" \
		and controller.cooldown_remaining_seconds == 0.0 \
		and bridge.requests.size() == hover_walk_request_count
	controller.walking = false
	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "climbing"
	controller.hover_menu_active = false
	var hover_climb_request_count := bridge.requests.size()
	bus.publish(&"character.hover_entered", {"source": "smoke-climb-hover"})
	var hover_preserves_climb: bool = controller.movement_phase == "climbing" \
		and bridge.requests.size() == hover_climb_request_count
	controller.hover_menu_active = false
	controller.movement_phase = "hanging-route"
	var hover_hang_request_count := bridge.requests.size()
	bus.publish(&"character.hover_entered", {"source": "smoke-hang-hover"})
	var hover_preserves_hang: bool = controller.movement_phase == "hanging-route" \
		and bridge.requests.size() == hover_hang_request_count
	controller.hover_menu_active = false
	controller.movement_phase = "climbing"
	var middle_fall_route_requested: bool = controller._start_hang_plan("middle-fall") \
		and bridge.requests.back() == "hang-to-center" \
		and controller.hang_exit_plan == "middle-fall"
	controller._stop_surface_behavior("middle-fall-plan-smoke")
	controller.last_surface_kind = "monitor_edge"
	controller.movement_phase = "climbing"
	var edge_fall_route_requested: bool = controller._start_hang_plan("edge-fall") \
		and bridge.requests.back() == "hang-to-climb-down-edge" \
		and controller.hang_exit_plan == "edge-fall"
	controller._stop_surface_behavior("edge-fall-plan-smoke")
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "desktop_floor"})
	# Match native production ordering: the pointer may already be hovering,
	# drag-finished is published before Kernel returns the authoritative
	# climb-ready drag commit, and native hover is then re-armed under the same
	# pointer. None of those UI events may cancel the post-drag climb handshake.
	bus.publish(&"character.hover_entered", {"source": "smoke-edge-pre-drag"})
	var pre_drag_hover_active: bool = controller.hover_menu_active
	bus.publish(&"character.drag_started", {"source": "smoke-edge"})
	var drag_clears_stale_hover: bool = not controller.hover_menu_active
	bus.publish(&"character.drag_finished", {"source": "smoke-edge"})
	controller._process(0.05)
	var post_drag_waits_for_commit: bool = controller.movement_phase == "drag-edge-await"
	bus.publish(&"character.presentation_state", {"companionId": "default", "bodyId": "same-body", "movementState": "climb-ready", "surfaceKind": "monitor_edge"})
	var post_drag_hold: bool = controller.movement_phase == "drag-edge-hold" and controller.last_body_id == "same-body" and controller.policy_state == "EdgeInspect"
	bus.publish(&"character.hover_entered", {"source": "smoke-edge-drag-rearmed"})
	var post_drag_hover_preserves_hold: bool = controller.movement_phase == "drag-edge-hold" and not controller.hover_menu_active
	var post_drag_request_count := bridge.requests.size()
	controller._process(0.6)
	var post_drag_waits: bool = controller.movement_phase == "drag-edge-hold" and bridge.requests.size() == post_drag_request_count
	controller._process(0.2)
	var post_drag_climbs: bool = controller.movement_phase == "climb-requested" and bridge.requests.back() == "climb-up"
	controller.action_cycle_index = 2
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "desktop_floor"})
	controller.movement_phase = "idle"
	controller.cooldown_remaining_seconds = 0.0
	teleport_character_controller.start()
	var requests_before_teleport := bridge.requests.size()
	var teleport_fade_requested: bool = controller._start_next_action() \
		and controller.movement_phase == "teleport-fade-out" \
		and bridge.requests.size() == requests_before_teleport \
		and teleport_probe.order == ["requested"]
	await create_timer(0.2).timeout
	var teleport_requested_after_fade: bool = bridge.requests.size() == requests_before_teleport + 1 \
		and bridge.requests.back() == "teleport-current-monitor" \
		and controller.movement_phase == "teleport-awaiting-canonical" \
		and is_zero_approx(teleport_sprite.modulate.a) \
		and teleport_probe.order == ["requested", "ready"]
	bus.publish(&"character.presentation_state", {
		"schemaVersion": 1,
		"companionId": "default",
		"bodyId": 1,
		"sequence": 1,
		"revision": 1,
		"desktopFeet": Vector2(640.0, 888.0),
		"velocity": Vector2.ZERO,
		"movementState": "stationary",
		"attachmentState": "grounded",
		"facing": "unchanged",
		"updateKind": "teleport",
	})
	var teleport_canonical_applied: bool = controller.movement_phase == "idle" and controller.policy_state == "Rest"
	await create_timer(0.2).timeout
	var teleport_fade_completed: bool = is_equal_approx(teleport_sprite.modulate.a, 1.0) \
		and not teleport_character_controller.teleport_visual_pending \
		and teleport_probe.lifecycle_events == 0
	controller.action_cycle_index = 2
	controller.last_surface_kind = "desktop_floor"
	controller.movement_phase = "idle"
	controller.cooldown_remaining_seconds = 0.0
	var requests_before_teleport_cancel := bridge.requests.size()
	var teleport_cancel_started: bool = controller._start_next_action() \
		and controller.movement_phase == "teleport-fade-out"
	controller._on_drag_started({})
	var teleport_cancelled_safely: bool = controller.movement_phase == "idle" \
		and is_equal_approx(teleport_sprite.modulate.a, 1.0) \
		and not teleport_character_controller.teleport_visual_pending \
		and bridge.requests.size() == requests_before_teleport_cancel \
		and teleport_probe.lifecycle_events == 0
	controller.dragging = false
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "window_top"})
	var window_surface_suppressed: bool = not controller._start_walk() and bridge.requests.back() == "teleport-current-monitor"
	bus.publish(&"character.drag_started", {"source": "smoke-window"})
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "window_top"})
	bus.publish(&"character.drag_finished", {"source": "smoke-window"})
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "window_top"})
	var manual_window_cooldown: bool = controller.policy_state == "Cooldown" \
		and controller.cooldown_remaining_seconds == controller.MANUAL_COOLDOWN_SECONDS \
		and not controller._start_walk()
	controller.cooldown_remaining_seconds = 0.0
	controller._set_policy_state("Rest", "smoke-reset")
	context.set_enabled(false)
	var disable_stops: bool = not controller.walking and controller.movement_phase == "idle"
	var disabled_suppressed: bool = not controller._start_walk()
	context.set_enabled(true)
	bus.publish(&"character.physics_moved", {"companionId": "default", "movementState": "stationary", "surfaceKind": "desktop_floor"})
	controller._start_walk()
	bus.publish(&"character.drag_started", {"source": "smoke"})
	var drag_stops: bool = bridge.requests.back() == "stop" and not controller.walking

	var ok: bool = deterministic_profiles and no_adjacent_profile_repeat and profile_bounds \
		and starts_left and patrol_state and offline_think_deferred and offline_think_keeps_hang_route and physics_animation_visible \
		and finite_stop and starts_right and profile_patrol_requested \
		and random_hang_plans and climb_requested and climbing_state and random_route_requested and route_motion_observed and route_arrived and profile_hang_settle_used and random_exit_requested \
		and climbing_down_state and landed and landing_cooldown_blocks_action and landing_cooldown_completed \
		and tall_climb_requested and tall_climb_survives_fixed_timeout and tall_climb_reaches_hang and stalled_climb_requested and stalled_climb_stops \
		and tall_climb_down_requested and tall_climb_down_survives_fixed_timeout and tall_climb_down_lands \
		and long_hang_route_requested and long_hang_route_survives_fixed_timeout and long_hang_route_arrives and stalled_hang_route_requested and stalled_hang_route_stops \
		and hover_preserves_walk and hover_exit_preserves_walk and hover_preserves_climb and hover_preserves_hang and middle_fall_route_requested and edge_fall_route_requested \
		and pre_drag_hover_active and drag_clears_stale_hover and post_drag_waits_for_commit and post_drag_hold and post_drag_hover_preserves_hold and post_drag_waits and post_drag_climbs \
		and teleport_fade_requested and teleport_requested_after_fade and teleport_canonical_applied and teleport_fade_completed and teleport_cancel_started and teleport_cancelled_safely and window_surface_suppressed and manual_window_cooldown \
		and disable_stops and disabled_suppressed and drag_stops
	print("[G15.7] profiles=", deterministic_profiles and no_adjacent_profile_repeat and profile_bounds and profile_patrol_requested, " walk=", starts_left and starts_right, " animation_playback=", physics_animation_visible, " climb=", climb_requested and post_drag_climbs, " climb_watchdog=", tall_climb_requested and tall_climb_survives_fixed_timeout and tall_climb_reaches_hang and stalled_climb_requested and stalled_climb_stops and tall_climb_down_requested and tall_climb_down_survives_fixed_timeout and tall_climb_down_lands, " hang_watchdog=", long_hang_route_requested and long_hang_route_survives_fixed_timeout and long_hang_route_arrives and stalled_hang_route_requested and stalled_hang_route_stops, " hang_random=", random_hang_plans and random_route_requested and random_exit_requested, " plans=", middle_fall_route_requested and edge_fall_route_requested, " cooldown=", landed and landing_cooldown_completed and manual_window_cooldown, " teleport_visual=", teleport_fade_requested and teleport_requested_after_fade and teleport_canonical_applied and teleport_fade_completed and teleport_cancelled_safely, " current_monitor_only=", window_surface_suppressed, " suppression=", ok)
	animation_controller.stop()
	teleport_character_controller.stop()
	controller.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)
