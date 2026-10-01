extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3AutonomousFloorWalkController

# Autonomous behavior stays on the monitor that owns the canonical Physics body.
# Runtime requests semantic intents only; Kernel resolves all surfaces and warp
# coordinates and gives user drag priority.

# A fixed seed selects a stable offset into these curated profiles. This is
# variation without PRNG, wall-clock entropy, or LLM control.
const BEHAVIOR_CYCLE_SEED := 1
const BEHAVIOR_PROFILES := [
	{"id": "patrol-right-long", "direction": "right", "walk_seconds": 13.0, "rest_seconds": 22.0, "hang_settle_seconds": 1.05, "teleport": false},
	{"id": "patrol-left-medium", "direction": "left", "walk_seconds": 11.0, "rest_seconds": 18.0, "hang_settle_seconds": 0.85, "teleport": false},
	{"id": "patrol-right-short", "direction": "right", "walk_seconds": 9.0, "rest_seconds": 16.0, "hang_settle_seconds": 1.25, "teleport": false},
	{"id": "teleport-left-reset", "direction": "left", "walk_seconds": 12.0, "rest_seconds": 20.0, "hang_settle_seconds": 1.0, "teleport": true},
]
# Direct test/manual calls retain a simple alternating fallback; autonomous
# scheduling always uses the profile cycle above.
const DIRECT_WALK_DURATION_SECONDS := 15.0
# Climbing is solver-driven. This value is a *stall watchdog window*, not a
# maximum journey duration. Active canonical Y progress refreshes the watchdog,
# so tall/portrait monitors can take longer than 12s while a genuinely stalled
# solver still escapes safely.
const CLIMB_TIMEOUT_SECONDS := 12.0
const CLIMB_PROGRESS_EPSILON := 0.5
# Once Kernel confirms the drag landed on a monitor edge, pause only long
# enough for the native anchor/hitbox handoff to settle. A multi-second hold
# looks like a stuck character because climb_ready is intentionally one frame.
const POST_DRAG_EDGE_HOLD_SECONDS := 0.75
const POST_DRAG_EDGE_CONFIRM_SECONDS := 1.0
# Hang traversal can exceed 20s on wide monitors at the current physics speed.
# Treat this as a no-progress watchdog window, never as a journey duration.
const HANG_ROUTE_TIMEOUT_SECONDS := 20.0
const HANG_ROUTE_PROGRESS_EPSILON := 0.5
const HANG_EXIT_PLANS := ["middle-fall", "edge-fall", "climb-down"]
const DETACH_TIMEOUT_SECONDS := 3.0
const TELEPORT_VISUAL_TIMEOUT_SECONDS := 1.0
const AUTONOMOUS_COOLDOWN_SECONDS := 6.0
const MANUAL_COOLDOWN_SECONDS := 8.0
const CHAT_RELEASE_COOLDOWN_SECONDS := 3.0
const HOVER_RELEASE_COOLDOWN_SECONDS := 2.0
const COMPANION_ID := "default"

var elapsed_seconds := 0.0
var walk_remaining_seconds := 0.0
var surface_remaining_seconds := 0.0
var rest_interval_seconds := 18.0
var active_hang_settle_seconds := 0.85
var active_profile_id := ""
var direction_index := 0
var action_cycle_index := 0
var walking := false
var last_walk_direction := "left"
var last_surface_kind := ""
var movement_phase := "idle"
var hang_route_moved := false
var hang_exit_plan := ""
var last_hang_exit_plan := ""
var behavior_rng := RandomNumberGenerator.new()
var dragging := false
var lifecycle_active := false
var ai_thinking := false
var last_body_id := ""
var last_movement_state := ""
var drag_release_state := ""
var drag_release_surface_kind := ""
var awaiting_post_drag_edge := false
var cooldown_remaining_seconds := 0.0
var policy_state := "Rest"
var pending_teleport_profile: Dictionary = {}
var chat_focus_active := false
var hover_menu_active := false
var climb_progress_y := 0.0
var climb_progress_y_valid := false
var hang_progress_x := 0.0
var hang_progress_x_valid := false
var embodiment_motion_scale := 1.0


func start() -> void:
	if event_bus == null:
		return
	event_bus.subscribe(&"character.drag_started", _on_drag_started)
	event_bus.subscribe(&"character.drag_finished", _on_drag_finished)
	event_bus.subscribe(&"character.appear_requested", _on_lifecycle_requested)
	event_bus.subscribe(&"character.disappear_requested", _on_lifecycle_requested)
	event_bus.subscribe(&"ai.thinking_started", _on_ai_thinking_started)
	event_bus.subscribe(&"ai.thinking_finished", _on_ai_thinking_finished)
	event_bus.subscribe(&"animation.finished", _on_animation_finished)
	event_bus.subscribe(&"animation.requested", _on_animation_requested)
	event_bus.subscribe(&"character.teleport_visual_ready", _on_teleport_visual_ready)
	event_bus.subscribe(&"character.presentation_state", _on_physics_moved)
	event_bus.subscribe(&"character.physics_moved", _on_physics_moved)
	event_bus.subscribe(&"character.hover_entered", _on_hover_entered)
	event_bus.subscribe(&"character.hover_exited", _on_hover_exited)
	event_bus.subscribe(&"embodiment.state_changed", _on_embodiment_state_changed)
	if context != null and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)
	_sync_chat_focus()
	behavior_rng.randomize()
	set_process(true)


func stop() -> void:
	_stop_movement("controller-stop")
	set_process(false)
	if context != null and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)
	if event_bus != null:
		event_bus.unsubscribe(&"character.drag_started", _on_drag_started)
		event_bus.unsubscribe(&"character.drag_finished", _on_drag_finished)
		event_bus.unsubscribe(&"character.appear_requested", _on_lifecycle_requested)
		event_bus.unsubscribe(&"character.disappear_requested", _on_lifecycle_requested)
		event_bus.unsubscribe(&"ai.thinking_started", _on_ai_thinking_started)
		event_bus.unsubscribe(&"ai.thinking_finished", _on_ai_thinking_finished)
		event_bus.unsubscribe(&"animation.finished", _on_animation_finished)
		event_bus.unsubscribe(&"animation.requested", _on_animation_requested)
		event_bus.unsubscribe(&"character.teleport_visual_ready", _on_teleport_visual_ready)
		event_bus.unsubscribe(&"character.presentation_state", _on_physics_moved)
		event_bus.unsubscribe(&"character.physics_moved", _on_physics_moved)
		event_bus.unsubscribe(&"character.hover_entered", _on_hover_entered)
		event_bus.unsubscribe(&"character.hover_exited", _on_hover_exited)
		event_bus.unsubscribe(&"embodiment.state_changed", _on_embodiment_state_changed)


func _process(delta: float) -> void:
	if not _is_allowed():
		elapsed_seconds = 0.0
		_stop_movement("suppressed")
		return
	if movement_phase == "idle" and cooldown_remaining_seconds > 0.0:
		cooldown_remaining_seconds = maxf(0.0, cooldown_remaining_seconds - delta)
		if cooldown_remaining_seconds <= 0.0:
			_set_policy_state("Rest", "cooldown-complete")
		return
	if walking:
		walk_remaining_seconds -= delta
		if walk_remaining_seconds <= 0.0:
			_stop_walk("duration-complete")
			movement_phase = "walk-awaiting-edge"
			surface_remaining_seconds = 1.0
		return
	if movement_phase == "walk-awaiting-edge":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("walk-ended-without-edge")
			_enter_cooldown("patrol-complete", AUTONOMOUS_COOLDOWN_SECONDS)
		return
	if movement_phase == "climb-requested":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("climb-not-started")
		return
	if movement_phase == "climbing":
		# Do not infer completion from elapsed time. The kernel owns the climb
		# solver and publishes `climb-ready` when the character actually reaches
		# the top. The timeout below is only a safety escape for a genuinely
		# stalled physics command.
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("climb-timeout")
		return
	if movement_phase == "drag-edge-await":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			awaiting_post_drag_edge = false
			movement_phase = "idle"
			_enter_cooldown("manual-drag-unconfirmed", MANUAL_COOLDOWN_SECONDS)
		return
	if movement_phase == "drag-edge-hold":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			if _start_climb():
				return
			_stop_surface_behavior("drag-edge-climb-rejected")
		return
	if movement_phase == "hanging-route":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("hang-route-timeout")
		return
	if movement_phase == "climb-down-routing":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("climb-down-route-timeout")
		return
	if movement_phase in ["climb-down-requested", "climbing-down"]:
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("climb-down-timeout")
		return
	if movement_phase == "hang-settling":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			if hang_exit_plan == "climb-down":
				if not _start_climb_down() and _request("detach"):
					movement_phase = "detaching"
					surface_remaining_seconds = DETACH_TIMEOUT_SECONDS
					_set_policy_state("FallRecovery", "climb-down-unavailable")
			elif hang_exit_plan in ["middle-fall", "edge-fall"]:
				if _request("detach"):
					movement_phase = "detaching"
					surface_remaining_seconds = DETACH_TIMEOUT_SECONDS
					_set_policy_state("FallRecovery", "hang-exit:%s" % hang_exit_plan)
					print("[AutonomousSurface] hang exit=%s -> fall monitor=current" % hang_exit_plan)
				else:
					_stop_surface_behavior("hang-fall-rejected")
			else:
				_stop_surface_behavior("hang-exit-plan-missing")
		return
	if movement_phase == "detaching":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_stop_surface_behavior("detach-timeout")
		return
	if movement_phase == "teleport-fade-out" or movement_phase == "teleport-awaiting-canonical":
		surface_remaining_seconds -= delta
		if surface_remaining_seconds <= 0.0:
			_cancel_teleport_visual("teleport-visual-timeout")
			_enter_cooldown("teleport-visual-timeout", AUTONOMOUS_COOLDOWN_SECONDS)
		return
	if movement_phase == "falling":
		return
	elapsed_seconds += delta
	if elapsed_seconds >= rest_interval_seconds:
		elapsed_seconds = 0.0
		_start_next_action()

func _behavior_profile(cycle_index: int) -> Dictionary:
	var profile_index := posmod(BEHAVIOR_CYCLE_SEED + max(cycle_index, 0), BEHAVIOR_PROFILES.size())
	var profile: Dictionary = BEHAVIOR_PROFILES[profile_index].duplicate(true)
	var soul := _soul_behavior_profile()
	if not soul.is_empty():
		var target_walk := clampf(float(soul.get("walkSeconds", profile.get("walk_seconds", 11.0))), 9.0, 13.0)
		var target_rest := clampf(float(soul.get("restSeconds", profile.get("rest_seconds", 18.0))), 16.0, 24.0)
		var target_hang := clampf(float(soul.get("hangSettleSeconds", profile.get("hang_settle_seconds", 1.0))), 0.85, 1.25)
		profile["walk_seconds"] = lerpf(float(profile.get("walk_seconds", target_walk)), target_walk, 0.55)
		profile["rest_seconds"] = lerpf(float(profile.get("rest_seconds", target_rest)), target_rest, 0.55)
		profile["hang_settle_seconds"] = lerpf(float(profile.get("hang_settle_seconds", target_hang)), target_hang, 0.55)

	# Embodiment adjusts only the cadence of the *next* autonomous route. It
	# never changes Kernel Physics velocity or mutates an active walk/climb/hang,
	# preserving deterministic contact/multi-monitor authority.
	var motion_scale := clampf(embodiment_motion_scale, 0.85, 1.15)
	profile["walk_seconds"] = clampf(float(profile.get("walk_seconds", 11.0)) * motion_scale, 7.5, 15.0)
	profile["rest_seconds"] = clampf(float(profile.get("rest_seconds", 18.0)) / motion_scale, 12.0, 30.0)
	profile["hang_settle_seconds"] = clampf(float(profile.get("hang_settle_seconds", 1.0)) / motion_scale, 0.70, 1.50)
	return profile


func _soul_behavior_profile() -> Dictionary:
	if context == null:
		return {}
	var soul_value: Variant = context.character.get("soul_profile", {})
	if not (soul_value is Dictionary):
		return {}
	var behavior_value: Variant = (soul_value as Dictionary).get("behavior", {})
	return behavior_value if behavior_value is Dictionary else {}


func _activate_behavior_profile(profile: Dictionary) -> void:
	active_profile_id = str(profile.get("id", "default"))
	rest_interval_seconds = float(profile.get("rest_seconds", rest_interval_seconds))
	active_hang_settle_seconds = float(profile.get("hang_settle_seconds", active_hang_settle_seconds))


func _start_next_action() -> bool:
	# Hover pauses only the scheduling of a new autonomous action. It never
	# interrupts a walk/climb/hang already owned by Physics.
	if not _is_allowed() or hover_menu_active or cooldown_remaining_seconds > 0.0 or last_surface_kind != "desktop_floor":
		return false
	var profile := _behavior_profile(action_cycle_index)
	if bool(profile.get("teleport", false)):
		pending_teleport_profile = profile.duplicate(true)
		movement_phase = "teleport-fade-out"
		surface_remaining_seconds = TELEPORT_VISUAL_TIMEOUT_SECONDS
		_set_policy_state("TeleportTransition", "fade-out-requested")
		event_bus.publish(&"character.teleport_visual_requested", {"companionId": COMPANION_ID})
		print("[AutonomousSurface] teleport visual requested monitor=current")
		return true
	if not _start_walk(profile):
		return false
	action_cycle_index += 1
	return true


func _start_walk(profile: Dictionary = {}) -> bool:
	if not _is_allowed() or walking or last_surface_kind != "desktop_floor":
		return false
	var selected_profile := profile
	var action := ""
	if selected_profile.is_empty():
		action = "walk-left" if direction_index % 2 == 0 else "walk-right"
		selected_profile = {
			"id": "direct-%s" % action,
			"walk_seconds": DIRECT_WALK_DURATION_SECONDS,
			"rest_seconds": rest_interval_seconds,
			"hang_settle_seconds": active_hang_settle_seconds,
		}
	else:
		action = "walk-%s" % str(selected_profile.get("direction", "left"))
	last_walk_direction = "left" if action == "walk-left" else "right"
	if not _request(action):
		return false
	if profile.is_empty():
		direction_index += 1
	_activate_behavior_profile(selected_profile)
	walking = true
	walk_remaining_seconds = float(selected_profile.get("walk_seconds", DIRECT_WALK_DURATION_SECONDS))
	_set_policy_state("Patrol", "walk-started:%s" % active_profile_id)
	print("[AutonomousFloorWalk] started action=%s profile=%s monitor=current edge=stop-at-edge" % [action, active_profile_id])
	return true


func _start_climb() -> bool:
	if not _is_allowed() or walking \
	or not (movement_phase == "idle" or movement_phase == "walk-awaiting-edge" or movement_phase == "drag-edge-hold") \
	or not (last_surface_kind == "desktop_floor" or last_surface_kind == "monitor_edge"):
		return false
	if movement_phase == "drag-edge-hold" and last_movement_state != "climb-ready":
		return false
	if not _request("climb-up"):
		print("[AutonomousSurface] climb-up unavailable on current monitor")
		return false
	movement_phase = "climb-requested"
	surface_remaining_seconds = CLIMB_TIMEOUT_SECONDS
	climb_progress_y = 0.0
	climb_progress_y_valid = false
	_set_policy_state("Climb", "climb-requested")
	print("[AutonomousSurface] requested climb-up monitor=current")
	return true


func _stop_surface_behavior(reason: String) -> void:
	_request("stop")
	movement_phase = "idle"
	surface_remaining_seconds = 0.0
	climb_progress_y = 0.0
	climb_progress_y_valid = false
	hang_progress_x = 0.0
	hang_progress_x_valid = false
	hang_route_moved = false
	hang_exit_plan = ""
	awaiting_post_drag_edge = false
	elapsed_seconds = 0.0
	if cooldown_remaining_seconds <= 0.0:
		_set_policy_state("Rest", "stopped:%s" % reason)
	print("[AutonomousSurface] stopped reason=%s" % reason)


func _stop_movement(reason: String) -> void:
	if movement_phase == "teleport-fade-out" or movement_phase == "teleport-awaiting-canonical":
		_cancel_teleport_visual(reason)
		return
	if walking:
		_stop_walk(reason)
	if movement_phase != "idle":
		_stop_surface_behavior(reason)


func _stop_walk(reason: String) -> void:
	if not walking:
		return
	_request("stop")
	walking = false
	walk_remaining_seconds = 0.0
	print("[AutonomousFloorWalk] stopped reason=%s" % reason)


func _on_ai_thinking_started(_payload: Dictionary = {}) -> void:
	ai_thinking = true
	elapsed_seconds = 0.0
	_stop_movement("ai-thinking")
	_set_policy_state("Rest", "ai-thinking")


func _on_ai_thinking_finished(_payload: Dictionary = {}) -> void:
	ai_thinking = false
	elapsed_seconds = 0.0


func _is_allowed() -> bool:
	# Hover is presentation/UI state, not movement ownership. A companion may
	# walk underneath a stationary cursor; merely entering the hitbox must not
	# cancel canonical locomotion. Explicit drag/click/menu actions remain the
	# user-intent paths that can interrupt autonomous behavior.
	return not ai_thinking \
		and not chat_focus_active \
		and context != null \
		and bool(context.settings.get("offline_presence_enabled", true)) \
		and not dragging \
		and not lifecycle_active \
		and not bool(context.window.get("hidden_to_tray", false))


func _request(action: String) -> bool:
	if services == null or not is_instance_valid(services.bridge_adapter):
		return false
	if not services.bridge_adapter.has_method("request_companion_movement"):
		return false
	return bool(services.bridge_adapter.call("request_companion_movement", COMPANION_ID, action))


func _on_teleport_visual_ready(payload: Dictionary = {}) -> void:
	if movement_phase != "teleport-fade-out":
		return
	if str(payload.get("companionId", COMPANION_ID)) != COMPANION_ID \
	or not _is_allowed() or last_surface_kind != "desktop_floor":
		_cancel_teleport_visual("teleport-visual-not-allowed")
		return
	if not _request("teleport-current-monitor"):
		_cancel_teleport_visual("teleport-request-rejected")
		return
	_activate_behavior_profile(pending_teleport_profile)
	pending_teleport_profile.clear()
	action_cycle_index += 1
	movement_phase = "teleport-awaiting-canonical"
	surface_remaining_seconds = TELEPORT_VISUAL_TIMEOUT_SECONDS
	print("[AutonomousSurface] teleport requested profile=%s monitor=current" % active_profile_id)


func _cancel_teleport_visual(reason: String) -> void:
	if movement_phase == "teleport-fade-out" or movement_phase == "teleport-awaiting-canonical":
		event_bus.publish(&"character.teleport_visual_cancelled", {
			"companionId": COMPANION_ID,
			"reason": reason,
		})
	pending_teleport_profile.clear()
	movement_phase = "idle"
	surface_remaining_seconds = 0.0
	elapsed_seconds = 0.0
	if cooldown_remaining_seconds <= 0.0:
		_set_policy_state("Rest", "teleport-cancelled:%s" % reason)
	print("[AutonomousSurface] teleport visual cancelled reason=%s" % reason)


func _on_physics_moved(payload: Dictionary) -> void:
	var companion_id := str(payload.get("companionId", COMPANION_ID))
	if companion_id != COMPANION_ID:
		return
	var body_id := str(payload.get("bodyId", ""))
	if not body_id.is_empty():
		last_body_id = body_id
	var reported_surface_kind := str(payload.get("surfaceKind", ""))
	if not reported_surface_kind.is_empty():
		last_surface_kind = reported_surface_kind
	var state := str(payload.get("movementState", payload.get("state", "")))
	last_movement_state = state
	if dragging:
		drag_release_state = state
		drag_release_surface_kind = last_surface_kind
		return
	if not _is_autonomous_surface(last_surface_kind):
		awaiting_post_drag_edge = false
		if movement_phase == "drag-edge-await":
			movement_phase = "idle"
			_enter_cooldown("manual-drag", MANUAL_COOLDOWN_SECONDS)
		elif walking or movement_phase != "idle":
			_stop_movement("non-monitor-surface")
		if cooldown_remaining_seconds <= 0.0:
			_set_policy_state("Rest", "non-monitor-surface:%s" % last_surface_kind)
		return
	if awaiting_post_drag_edge:
		if state == "climb-ready" and last_surface_kind == "monitor_edge":
			_begin_drag_edge_hold()
		elif not state.is_empty() and (state != "climb-ready" or last_surface_kind != "monitor_edge"):
			awaiting_post_drag_edge = false
			if movement_phase == "drag-edge-await":
				movement_phase = "idle"
				_enter_cooldown("manual-drag", MANUAL_COOLDOWN_SECONDS)
	if not _is_allowed():
		return
	if movement_phase == "teleport-awaiting-canonical" \
	and str(payload.get("updateKind", "")) == "teleport":
		movement_phase = "idle"
		surface_remaining_seconds = 0.0
		elapsed_seconds = 0.0
		_set_policy_state("Rest", "teleport-applied")
		print("[AutonomousSurface] teleport canonical monitor=current")
		return
	match state:
		"climbing":
			if last_surface_kind != "monitor_edge":
				_stop_surface_behavior("non-monitor-climb-surface")
			elif movement_phase == "climb-requested":
				movement_phase = "climbing"
				surface_remaining_seconds = CLIMB_TIMEOUT_SECONDS
				_prime_climb_stall_watchdog(payload)
				_set_policy_state("Climb", "physics-climbing")
				print("[AutonomousSurface] climbing monitor=current")
			elif movement_phase == "climbing":
				_refresh_climb_stall_watchdog(payload, -1)
			elif movement_phase == "climb-down-requested":
				movement_phase = "climbing-down"
				surface_remaining_seconds = CLIMB_TIMEOUT_SECONDS
				_prime_climb_stall_watchdog(payload)
				_set_policy_state("Climb", "physics-climbing-down")
				print("[AutonomousSurface] climbing-down monitor=current")
			elif movement_phase == "climbing-down":
				_refresh_climb_stall_watchdog(payload, 1)
		"climb-ready":
			# The kernel publishes climb-ready when the climb solver has reached
			# the attached surface/top pose. AutonomousSurface must explicitly
			# advance to the hang phase; otherwise the controller waits for a
			# hanging event that the physics solver does not emit automatically.
			# Ignore the zero-velocity climb-ready snapshot emitted by the initial
			# AttachVertical command. A real upward movement must be observed first,
			# otherwise the subsequent hold command would cancel ClimbUp in the queue.
			if movement_phase == "climbing":
				_begin_hang()
		"hanging":
			if last_surface_kind != "monitor_edge":
				_stop_surface_behavior("non-monitor-hang-surface")
			elif movement_phase == "climbing":
				_begin_hang()
			elif movement_phase == "hanging-route":
				_refresh_hang_route_stall_watchdog(payload)
				if absf(_horizontal_velocity(payload)) > 0.001:
					hang_route_moved = true
				elif hang_route_moved or str(payload.get("updateKind", "")) == "route-arrived":
					movement_phase = "hang-settling"
					surface_remaining_seconds = active_hang_settle_seconds
					print("[AutonomousSurface] hanging-route-arrived monitor=current")
			elif movement_phase == "climb-down-routing":
				_refresh_hang_route_stall_watchdog(payload)
				if absf(_horizontal_velocity(payload)) > 0.001:
					hang_route_moved = true
				elif hang_route_moved or str(payload.get("updateKind", "")) == "route-arrived":
					_start_climb_down()
		"airborne-falling":
			if movement_phase in ["climb-requested", "climbing", "hanging-route", "hang-settling", "climb-down-routing", "climb-down-requested", "climbing-down", "detaching"]:
				movement_phase = "falling"
				surface_remaining_seconds = 0.0
				_set_policy_state("FallRecovery", "physics-falling")
				print("[AutonomousSurface] falling monitor=current")
		"stationary":
			if movement_phase == "climbing-down":
				movement_phase = "idle"
				surface_remaining_seconds = 0.0
				hang_exit_plan = ""
				_enter_cooldown("climb-down-landed", AUTONOMOUS_COOLDOWN_SECONDS)
				print("[AutonomousSurface] climb-down landed monitor=current")
				return
			if movement_phase in ["detaching", "falling"]:
				movement_phase = "idle"
				surface_remaining_seconds = 0.0
				hang_exit_plan = ""
				_enter_cooldown("landed", AUTONOMOUS_COOLDOWN_SECONDS)
				print("[AutonomousSurface] landed monitor=current")
				return
			if walking:
				# Stationary while an autonomous walk is active is the authoritative
				# edge-stop signal. Only now may we start climbing; this prevents a
				# three-second walk from climbing whichever wall happens to be nearest.
				_stop_walk("edge-reached")
				movement_phase = "idle"
				if _start_climb():
					return
			if movement_phase == "walk-awaiting-edge":
				movement_phase = "idle"
				if _start_climb():
					return


func _climb_progress_y_from_payload(payload: Dictionary) -> Variant:
	var feet_value: Variant = payload.get("desktopFeet", payload.get("position", null))
	if feet_value is Vector2:
		var feet: Vector2 = feet_value
		return feet.y
	if feet_value is Dictionary and feet_value.has("y"):
		return float(feet_value.get("y", 0.0))
	if feet_value is Array and feet_value.size() >= 2:
		return float(feet_value[1])
	return null


func _prime_climb_stall_watchdog(payload: Dictionary) -> void:
	climb_progress_y_valid = false
	var current_y_value: Variant = _climb_progress_y_from_payload(payload)
	if current_y_value == null:
		return
	climb_progress_y = float(current_y_value)
	climb_progress_y_valid = true


func _refresh_climb_stall_watchdog(payload: Dictionary, direction: int) -> void:
	var current_y_value: Variant = _climb_progress_y_from_payload(payload)
	if current_y_value == null:
		return
	var current_y := float(current_y_value)
	if not climb_progress_y_valid:
		climb_progress_y = current_y
		climb_progress_y_valid = true
		return
	var progressed := current_y < climb_progress_y - CLIMB_PROGRESS_EPSILON \
		if direction < 0 else current_y > climb_progress_y + CLIMB_PROGRESS_EPSILON
	if not progressed:
		return
	climb_progress_y = current_y
	surface_remaining_seconds = CLIMB_TIMEOUT_SECONDS


func _hang_progress_x_from_payload(payload: Dictionary) -> Variant:
	var feet_value: Variant = payload.get("desktopFeet", payload.get("position", null))
	if feet_value is Vector2:
		var feet: Vector2 = feet_value
		return feet.x
	if feet_value is Dictionary and feet_value.has("x"):
		return float(feet_value.get("x", 0.0))
	if feet_value is Array and feet_value.size() >= 1:
		return float(feet_value[0])
	return null


func _refresh_hang_route_stall_watchdog(payload: Dictionary) -> void:
	var current_x_value: Variant = _hang_progress_x_from_payload(payload)
	if current_x_value == null:
		return
	var current_x := float(current_x_value)
	if not hang_progress_x_valid:
		hang_progress_x = current_x
		hang_progress_x_valid = true
		return
	if absf(current_x - hang_progress_x) <= HANG_ROUTE_PROGRESS_EPSILON:
		return
	hang_progress_x = current_x
	surface_remaining_seconds = HANG_ROUTE_TIMEOUT_SECONDS


func _horizontal_velocity(payload: Dictionary) -> float:
	var velocity: Variant = payload.get("velocity", Vector2.ZERO)
	if velocity is Vector2:
		return velocity.x
	if velocity is Dictionary:
		return float(velocity.get("x", 0.0))
	return 0.0


func _begin_hang() -> bool:
	return _start_hang_plan(_choose_hang_exit_plan())


func _choose_hang_exit_plan() -> String:
	var candidates: Array = HANG_EXIT_PLANS.duplicate()
	# Randomize the route outcome, but avoid an immediate repeat so the companion
	# feels varied rather than getting stuck in the same trick several times.
	if not last_hang_exit_plan.is_empty() and candidates.size() > 1:
		candidates.erase(last_hang_exit_plan)
	var plan := str(candidates[behavior_rng.randi_range(0, candidates.size() - 1)])
	last_hang_exit_plan = plan
	return plan


func _start_hang_plan(plan: String) -> bool:
	if last_surface_kind != "monitor_edge" or plan not in HANG_EXIT_PLANS:
		return false
	var action := "hang-to-center" if plan == "middle-fall" else "hang-to-climb-down-edge"
	if not _request(action):
		return false
	hang_exit_plan = plan
	hang_route_moved = false
	climb_progress_y = 0.0
	climb_progress_y_valid = false
	hang_progress_x = 0.0
	hang_progress_x_valid = false
	movement_phase = "hanging-route"
	surface_remaining_seconds = HANG_ROUTE_TIMEOUT_SECONDS
	_set_policy_state("Hang", "route:%s" % action)
	print("[AutonomousSurface] hanging-route action=%s exit=%s monitor=current" % [action, plan])
	return true


func _start_climb_down() -> bool:
	if last_surface_kind != "monitor_edge":
		return false
	if not _request("climb-down"):
		_stop_surface_behavior("climb-down-rejected")
		return false
	movement_phase = "climb-down-requested"
	surface_remaining_seconds = CLIMB_TIMEOUT_SECONDS
	climb_progress_y = 0.0
	climb_progress_y_valid = false
	_set_policy_state("Climb", "climb-down-requested")
	print("[AutonomousSurface] climb-down requested monitor=current")
	return true


func _on_drag_started(_payload: Dictionary) -> void:
	dragging = true
	elapsed_seconds = 0.0
	drag_release_state = ""
	drag_release_surface_kind = ""
	awaiting_post_drag_edge = false
	# Native drag capture hides the hover menu immediately, but a matching
	# hover-exited event is not guaranteed before drag-finished. Keeping the old
	# hover flag here makes _process() suppress the post-drag edge handshake
	# before Kernel can publish its authoritative climb-ready commit.
	hover_menu_active = false
	_stop_movement("drag")
	_set_policy_state("Rest", "user-drag")


func _on_drag_finished(_payload: Dictionary) -> void:
	dragging = false
	elapsed_seconds = 0.0
	awaiting_post_drag_edge = true
	if drag_release_state == "climb-ready" and drag_release_surface_kind == "monitor_edge":
		_begin_drag_edge_hold()
	elif movement_phase == "idle":
		movement_phase = "drag-edge-await"
		surface_remaining_seconds = POST_DRAG_EDGE_CONFIRM_SECONDS


func _on_hover_entered(_payload: Dictionary) -> void:
	# Hover is not user intent. The character may simply move underneath a
	# stationary cursor, so entering the hitbox must never stop locomotion.
	# Native hover UI can still open; only starting a *new* autonomous action is
	# paused while the pointer remains over the character.
	if dragging or awaiting_post_drag_edge or movement_phase in ["drag-edge-await", "drag-edge-hold"]:
		return
	if hover_menu_active:
		return
	hover_menu_active = true
	elapsed_seconds = 0.0
	print("[AutonomousSurface] hover-menu passive phase=%s" % movement_phase)


func _on_hover_exited(_payload: Dictionary) -> void:
	if not hover_menu_active:
		return
	hover_menu_active = false
	# If an action is already in progress, keep its Physics route untouched.
	# Cooldown is useful only when the companion is resting, to avoid instantly
	# starting a new patrol the moment the pointer leaves.
	if movement_phase == "idle" and not walking:
		_enter_cooldown("hover-menu-released", HOVER_RELEASE_COOLDOWN_SECONDS)
	else:
		print("[AutonomousSurface] hover-menu released active phase=%s" % movement_phase)


func _begin_drag_edge_hold() -> void:
	if dragging or not _is_allowed() or last_surface_kind != "monitor_edge" \
	or last_movement_state != "climb-ready":
		return
	awaiting_post_drag_edge = false
	movement_phase = "drag-edge-hold"
	surface_remaining_seconds = POST_DRAG_EDGE_HOLD_SECONDS
	_set_policy_state("EdgeInspect", "drag-edge-confirmed")
	print("[AutonomousSurface] drag-edge-hold seconds=%.1f monitor=current body=%s" % [POST_DRAG_EDGE_HOLD_SECONDS, last_body_id])


func _on_lifecycle_requested(_payload: Dictionary) -> void:
	lifecycle_active = true
	elapsed_seconds = 0.0
	_stop_movement("lifecycle")
	_set_policy_state("Rest", "lifecycle")


func _on_animation_requested(payload: Dictionary) -> void:
	# An actual AI thinking event is handled by _on_ai_thinking_started. Offline
	# Presence's cosmetic think/speak must never cancel an in-flight Physics route.
	var name := str(payload.get("name", ""))
	var source := str(payload.get("source", ""))
	if source == "offline-presence" and _has_active_autonomous_motion():
		print("[AutonomousSurface] deferred presentation animation=%s during physics movement" % name)
		return
	if name in ["think", "speak"] and source not in ["physics", "physics-transition"]:
		print("[AutonomousSurface] presentation animation=%s -> stop movement monitor=current" % name)
		_stop_movement("presentation-animation:%s" % name)


func _has_active_autonomous_motion() -> bool:
	return walking or movement_phase in [
		"walk-awaiting-edge",
		"climb-requested",
		"climbing",
		"drag-edge-await",
		"drag-edge-hold",
		"hanging-route",
		"hang-settling",
		"climb-down-routing",
		"climb-down-requested",
		"climbing-down",
		"detaching",
		"falling",
		"teleport-fade-out",
		"teleport-awaiting-canonical",
	]


func _on_animation_finished(payload: Dictionary) -> void:
	if str(payload.get("name", "")) in ["appear", "disappear"]:
		lifecycle_active = false


func _on_embodiment_state_changed(payload: Dictionary) -> void:
	if str(payload.get("source", "")) != "embodiment-v1":
		return
	embodiment_motion_scale = clampf(float(payload.get("motionScale", 1.0)), 0.85, 1.15)


func _on_context_changed(section: StringName) -> void:
	if section == &"runtime_config":
		_sync_chat_focus()
	if section in [&"settings", &"window", &"runtime_config"]:
		if not _is_allowed():
			_stop_movement("context-change")


func _sync_chat_focus() -> void:
	var requested := bool(context.runtime_config.get("chat_focus_active", false)) if context != null else false
	if requested == chat_focus_active:
		return
	chat_focus_active = requested
	elapsed_seconds = 0.0
	if chat_focus_active:
		_stop_movement("chat-focus")
		_set_policy_state("Rest", "chat-focus")
	else:
		_enter_cooldown("chat-focus-released", CHAT_RELEASE_COOLDOWN_SECONDS)


func _enter_cooldown(reason: String, duration_seconds: float) -> void:
	cooldown_remaining_seconds = maxf(cooldown_remaining_seconds, duration_seconds)
	elapsed_seconds = 0.0
	_set_policy_state("Cooldown", reason)


func _set_policy_state(next_state: String, reason: String) -> void:
	if policy_state == next_state:
		return
	policy_state = next_state
	print("[AutonomousPolicy] state=%s reason=%s" % [policy_state, reason])


func _is_autonomous_surface(surface_kind: String) -> bool:
	return surface_kind in ["desktop_floor", "monitor_edge"]
