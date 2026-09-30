extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3CharacterController
const CoordinateMapperScript = preload("res://scripts/runtime_v3/services/coordinate_mapper.gd")
const PresentationCoordinateResolverScript = preload("res://scripts/runtime_v3/services/presentation_coordinate_resolver.gd")
const CanonicalVisualBindingScript = preload("res://scripts/runtime_v3/services/canonical_visual_binding.gd")

var host: Control
var sprite: AnimatedSprite2D
var coordinate_mapper: RuntimeV3CoordinateMapper = CoordinateMapperScript.new()
var presentation_coordinate_resolver: RefCounted = PresentationCoordinateResolverScript.new()
var canonical_visual_binding: RuntimeV3CanonicalVisualBinding = CanonicalVisualBindingScript.new()
var pending_restore_desktop_position: Variant = null
var presentation_first_state_applied: bool = false
var native_surface_revealed: bool = false
var presentation_last_sequence: int = -1
var presentation_last_revision: int = -1
var presentation_canonical_seen: bool = false
const DRAG_COMMIT_HOLD_TIMEOUT_MS: int = 2000
const IDLE_RENDER_MAX_FPS: int = 30
const ACTIVE_RENDER_MAX_FPS: int = 60
const DRAG_EDGE_PREFETCH_DISTANCE: float = 176.0

var presentation_drag_commit_pending: bool = false
var presentation_drag_commit_started_ms: int = 0
var pending_drag_desktop_feet: Vector2 = Vector2.ZERO
var last_presentation_state: Dictionary = {}
var last_canonical_desktop_feet: Vector2 = Vector2.ZERO
var dragging: bool = false
var drag_mouse_origin: Vector2 = Vector2.ZERO
var drag_host_origin: Vector2 = Vector2.ZERO
var drag_finish_in_progress: bool = false
var drag_release_visual_deadline_ms: int = 0
var drag_release_started_us: int = 0
var drag_release_resolution_pending: bool = false
var drag_release_requested_feet: Vector2 = Vector2.ZERO
var predicted_drag_edge_animation: StringName = &""
var predicted_drag_edge: String = ""
var predicted_drag_edge_distance_px: float = INF
var pending_animation_prefetches: Dictionary = {}
var native_drag_visual_active: bool = false
var native_mouse_capture_active: bool = false
var physics_target_position: Vector2 = Vector2.ZERO
var physics_target_active: bool = false
var physics_last_sequence: int = -1
var physics_last_animation: StringName = &""
var physics_last_movement_state: String = "stationary"
var physics_last_velocity: Vector2 = Vector2.ZERO
var physics_last_facing: String = "unchanged"
var physics_last_logged_state: String = ""
var lifecycle_animation: StringName = &""
var last_stable_native_hitbox: Rect2 = Rect2()
# Native presentation must keep the same contact anchor while Kernel owns a
# wall/ledge attachment. Climb/hang sprites can have very different alpha
# bounds; publishing those per-frame anchors makes Win32 move the whole HWND
# instead of keeping the physics contact fixed.
var last_stable_native_anchor: Vector2 = Vector2(-1.0, -1.0)
# Alpha bounds must be stable across every frame of the active animation. Using
# only frame 0 clipped later/extreme frames (Bible hang's tail reaches ~46 px
# lower than frame 0) inside the fixed native HWND.
var native_animation_alpha_rect_cache: Dictionary = {}
# Debug/non-native presentation still smooths canonical targets on the render
# thread. At 120 Hz Physics, the old 14/s response lagged locomotion by roughly
# 70 ms and made the sprite visibly trail its authoritative feet position.
var physics_interpolation_rate: float = 30.0
var render_debug_enabled: bool = false
var render_debug_last_sequence: int = -1
var presentation_overlay_screen: int = -1
const PHYSICS_ARRIVAL_EPSILON: float = 0.5
const TELEPORT_FADE_OUT_SECONDS: float = 0.14
const TELEPORT_FADE_IN_SECONDS: float = 0.16
const PRESENTATION_SCALE_PRESETS: Array[float] = [0.25, 0.50, 0.75, 1.00, 1.25]
const BIBLE_CHARACTER_ID := "character.bible"
const BIBLE_DEFAULT_PRESENTATION_SCALE := 0.50
var teleport_visual_pending: bool = false
var teleport_visual_tween: Tween
var presentation_size_scale: float = 1.0
var pending_presentation_size_scale: float = -1.0
var runtime_frame_budget: int = 0


func bind_character(character_host: Control, character_sprite: AnimatedSprite2D) -> void:
	host = character_host
	sprite = character_sprite
	# Companion presentation must not be clipped by an intermediate Control.
	host.clip_contents = false
	var host_parent := host.get_parent()
	if host_parent is Control:
		(host_parent as Control).clip_contents = false
	coordinate_mapper.refresh()
	presentation_coordinate_resolver.call("configure", coordinate_mapper)
	render_debug_enabled = _env_flag("OCP_RENDER_DEBUG") or _env_flag("OCP_VISUAL_DEBUG")
	_render_log("bind-character", {
		"host_valid": is_instance_valid(host),
		"sprite_valid": is_instance_valid(sprite),
		"host_path": str(host.get_path()) if is_instance_valid(host) and host.is_inside_tree() else "(not-in-tree)",
		"sprite_path": str(sprite.get_path()) if is_instance_valid(sprite) and sprite.is_inside_tree() else "(not-in-tree)",
	})


func start() -> void:
	_render_log("controller-start", _render_snapshot())
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.subscribe(&"character.position_restore_requested", Callable(self, "_on_restore_requested"))
	event_bus.subscribe(&"character.presentation_state", Callable(self, "_on_presentation_state"))
	event_bus.subscribe(&"character.native_surface_ready", Callable(self, "_on_native_surface_ready"))
	event_bus.subscribe(&"character.physics_moved", Callable(self, "_on_physics_moved"))
	event_bus.subscribe(&"animation.finished", Callable(self, "_on_animation_finished"))
	event_bus.subscribe(&"animation.started", Callable(self, "_on_animation_started"))
	event_bus.subscribe(&"character.appear_requested", Callable(self, "_on_appear_requested"))
	event_bus.subscribe(&"character.disappear_requested", Callable(self, "_on_disappear_requested"))
	event_bus.subscribe(&"character.teleport_visual_requested", Callable(self, "_on_teleport_visual_requested"))
	event_bus.subscribe(&"character.teleport_visual_cancelled", Callable(self, "_on_teleport_visual_cancelled"))
	event_bus.subscribe(&"character.presentation_scale_requested", Callable(self, "_on_presentation_scale_requested"))
	event_bus.subscribe(&"character.drag_started", Callable(self, "_on_character_drag_started"))
	event_bus.subscribe(&"character.drag_probe", Callable(self, "_on_character_drag_probe"))
	event_bus.subscribe(&"character.drag_finished", Callable(self, "_on_character_drag_finished"))
	event_bus.subscribe(&"window.presentation_mode_applied", Callable(self, "_on_presentation_mode_applied"))
	event_bus.subscribe(&"window.hidden_to_tray", Callable(self, "_on_save_requested"))
	event_bus.subscribe(&"system.shutting_down", Callable(self, "_on_save_requested"))
	set_process(true)


func stop() -> void:
	_cancel_teleport_visual_transition()
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.unsubscribe(&"character.position_restore_requested", Callable(self, "_on_restore_requested"))
	event_bus.unsubscribe(&"character.presentation_state", Callable(self, "_on_presentation_state"))
	event_bus.unsubscribe(&"character.native_surface_ready", Callable(self, "_on_native_surface_ready"))
	event_bus.unsubscribe(&"character.physics_moved", Callable(self, "_on_physics_moved"))
	event_bus.unsubscribe(&"animation.finished", Callable(self, "_on_animation_finished"))
	event_bus.unsubscribe(&"animation.started", Callable(self, "_on_animation_started"))
	event_bus.unsubscribe(&"character.appear_requested", Callable(self, "_on_appear_requested"))
	event_bus.unsubscribe(&"character.disappear_requested", Callable(self, "_on_disappear_requested"))
	event_bus.unsubscribe(&"character.teleport_visual_requested", Callable(self, "_on_teleport_visual_requested"))
	event_bus.unsubscribe(&"character.teleport_visual_cancelled", Callable(self, "_on_teleport_visual_cancelled"))
	event_bus.unsubscribe(&"character.presentation_scale_requested", Callable(self, "_on_presentation_scale_requested"))
	event_bus.unsubscribe(&"character.drag_started", Callable(self, "_on_character_drag_started"))
	event_bus.unsubscribe(&"character.drag_probe", Callable(self, "_on_character_drag_probe"))
	event_bus.unsubscribe(&"character.drag_finished", Callable(self, "_on_character_drag_finished"))
	event_bus.unsubscribe(&"window.presentation_mode_applied", Callable(self, "_on_presentation_mode_applied"))
	event_bus.unsubscribe(&"window.hidden_to_tray", Callable(self, "_on_save_requested"))
	event_bus.unsubscribe(&"system.shutting_down", Callable(self, "_on_save_requested"))
	set_process(false)


func _sync_runtime_frame_budget() -> void:
	var active_render := dragging \
		or physics_target_active \
		or lifecycle_animation != &"" \
		or physics_last_movement_state != "stationary"
	var desired := ACTIVE_RENDER_MAX_FPS if active_render else IDLE_RENDER_MAX_FPS
	if runtime_frame_budget == desired:
		return
	runtime_frame_budget = desired
	Engine.max_fps = desired
	print("[RuntimeFrameBudget] max_fps=%d active=%s movement=%s" % [
		desired,
		active_render,
		physics_last_movement_state,
	])


func _process(delta: float) -> void:
	_sync_runtime_frame_budget()
	_try_apply_pending_presentation_scale()
	# Native overlay passthrough polygons can change while the pointer is moving.
	# Windows may then omit the final MouseButton release from Godot. Polling the
	# physical button while a drag is active gives the transaction a deterministic
	# release fallback without changing normal input behavior.
	if dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_finish_drag_commit(&"poll-release-fallback")

	if presentation_drag_commit_pending:
		var elapsed_ms: int = Time.get_ticks_msec() - presentation_drag_commit_started_ms
		if elapsed_ms < DRAG_COMMIT_HOLD_TIMEOUT_MS:
			return
		var timeout_bridge: Variant = _get_service(&"bridge_adapter")
		if native_mouse_capture_active 			and timeout_bridge != null 			and timeout_bridge.has_method("end_native_mouse_capture"):
			timeout_bridge.call("end_native_mouse_capture")
		native_mouse_capture_active = false
		canonical_visual_binding.cancel_drag_commit()
		presentation_drag_commit_pending = false
		presentation_drag_commit_started_ms = 0
		pending_drag_desktop_feet = Vector2.ZERO
		event_bus.publish(&"character.drag_commit_timeout", {
			"desktopFeet": pending_drag_desktop_feet,
			"elapsedMs": elapsed_ms,
		})

	if not physics_target_active or dragging or not is_instance_valid(host):
		return

	var weight: float = 1.0 - exp(-physics_interpolation_rate * delta)
	host.position = host.position.lerp(physics_target_position, weight)
	if host.position.distance_to(physics_target_position) <= PHYSICS_ARRIVAL_EPSILON:
		host.position = physics_target_position
		physics_target_active = false

	_update_position_context()
	event_bus.publish(&"click_through.refresh_requested", {})


func handle_input(event: InputEvent) -> void:
	if not is_instance_valid(host):
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mouse_position: Vector2 = host.get_viewport().get_mouse_position()
		if event.pressed and _hit_rect().has_point(mouse_position):
			_prepare_virtual_overlay_drag()
			mouse_position = host.get_viewport().get_mouse_position()
			canonical_visual_binding.cancel_drag_commit()
			presentation_drag_commit_pending = false
			dragging = true
			physics_target_active = false
			drag_mouse_origin = mouse_position
			drag_host_origin = host.position
			state_machine.transition(&"dragging", {})
			var bridge_adapter: Variant = _get_service(&"bridge_adapter")
			var native_handle: int = int(DisplayServer.window_get_native_handle(
				DisplayServer.WINDOW_HANDLE,
				host.get_window().get_window_id()
			))
			native_mouse_capture_active = (
				bridge_adapter != null
				and bridge_adapter.has_method("begin_native_mouse_capture")
				and bool(bridge_adapter.call(
					"begin_native_mouse_capture",
					native_handle
				))
			)
			print(
				"[drag-sync] begin capture=%s handle=%s host=%s"
				% [native_mouse_capture_active, native_handle, host.position]
			)
			event_bus.publish(&"character.drag_started", {})
			_play_drag_hold_visual()
			event_bus.publish(&"click_through.drag_capture_started", {})
			host.get_viewport().set_input_as_handled()
		elif not event.pressed and dragging:
			_finish_drag_commit(&"input-release")
			host.get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and dragging:
		var target: Vector2 = drag_host_origin + (host.get_viewport().get_mouse_position() - drag_mouse_origin)
		host.position = _clamp_to_virtual_viewport(target)
		_update_position_context()
		event_bus.publish(&"character.position_changed", {
			"position": host.position,
			"dragging": true,
		})
		host.get_viewport().set_input_as_handled()


func _finish_drag_commit(release_source: StringName) -> void:
	if not dragging or drag_finish_in_progress or not is_instance_valid(host):
		return

	drag_finish_in_progress = true
	dragging = false
	physics_target_active = false

	if _uses_debug_local_stage():
		_snap_to_monitor()

	_update_position_context()
	var local_feet := host.position + Vector2(
		host.size.x * 0.5,
		host.size.y
	)
	var desktop_feet: Vector2 = _local_to_desktop(local_feet)

	var bridge_adapter: Variant = _get_service(&"bridge_adapter")
	var capture_released: bool = false
	if native_mouse_capture_active 		and bridge_adapter != null 		and bridge_adapter.has_method("end_native_mouse_capture"):
		capture_released = bool(bridge_adapter.call("end_native_mouse_capture"))
	native_mouse_capture_active = false

	pending_drag_desktop_feet = desktop_feet
	canonical_visual_binding.begin_drag_commit(desktop_feet)
	presentation_drag_commit_pending = true
	presentation_drag_commit_started_ms = Time.get_ticks_msec()

	var committed: bool = false
	if bridge_adapter != null and bridge_adapter.has_method(
		"commit_companion_position"
	):
		committed = bool(bridge_adapter.call(
			"commit_companion_position",
			"default",
			desktop_feet
		))

	if not committed:
		canonical_visual_binding.cancel_drag_commit()
		presentation_drag_commit_pending = false
		presentation_drag_commit_started_ms = 0
		pending_drag_desktop_feet = Vector2.ZERO
		event_bus.publish(&"character.drag_commit_failed", {
			"position": desktop_feet,
			"releaseSource": release_source,
		})

	state_machine.transition(&"ready", {})
	print(
		"[drag-sync] finish source=%s desktop_feet=%s committed=%s capture_released=%s"
		% [release_source, desktop_feet, committed, capture_released]
	)
	drag_release_requested_feet = desktop_feet
	event_bus.publish(&"character.drag_finished", {
		"position": host.position,
		"desktopFeet": desktop_feet,
		"commitRequested": committed,
		"releaseSource": release_source,
	})
	_play_drag_release_visual()
	event_bus.publish(&"click_through.drag_capture_finished", {})
	event_bus.publish(&"click_through.refresh_requested", {})
	drag_finish_in_progress = false


func _on_character_drag_started(payload: Dictionary) -> void:
	if str(payload.get("source", "")) != "native-host":
		return
	native_drag_visual_active = true
	_play_drag_hold_visual()


func _on_character_drag_probe(payload: Dictionary) -> void:
	if str(payload.get("source", "")) != "native-host" or not native_drag_visual_active:
		return
	var desktop_feet: Vector2 = payload.get("desktopFeet", Vector2.ZERO)
	var prediction := _predict_drag_edge_animation(desktop_feet)
	if prediction.is_empty():
		predicted_drag_edge_animation = &""
		predicted_drag_edge = ""
		predicted_drag_edge_distance_px = INF
		return
	var animation_name: StringName = prediction.get("animation", &"")
	if animation_name == &"":
		return
	predicted_drag_edge_animation = animation_name
	predicted_drag_edge = str(prediction.get("edge", ""))
	predicted_drag_edge_distance_px = float(prediction.get("distancePx", 0.0))
	var drag_release_animation := _animation_for_role("drag.release", &"drag_release")
	if not _character_has_animation(drag_release_animation):
		# Characters without an authored Drag Release have a free second hot-cache
		# slot while Fall is warmed on drag start. Decode the predicted edge pose
		# now so releasing onto the wall never pays a 100+ ms first-frame decode.
		_schedule_animation_prefetch(
			animation_name,
			"drag-edge-probe:%s" % (predicted_drag_edge if not predicted_drag_edge.is_empty() else "unknown")
		)
	# Characters with Drag Hold/Release keep only the prediction until release;
	# their two-entry cache is already occupied by those transition clips.
	event_bus.publish(&"character.drag_edge_predicted", {
		"desktopFeet": desktop_feet,
		"animation": animation_name,
		"edge": predicted_drag_edge,
		"facing": str(prediction.get("facing", "unchanged")),
		"distancePx": predicted_drag_edge_distance_px,
	})


func _predict_drag_edge_animation(desktop_feet: Vector2) -> Dictionary:
	if not is_instance_valid(context) or not is_instance_valid(sprite) \
	or sprite.sprite_frames == null or desktop_feet == Vector2.ZERO:
		return {}
	var rects: Array = context.monitor.get("rects", [])
	var best_distance := INF
	var best_edge := ""
	var best_facing := "unchanged"
	for rect_value in rects:
		if not rect_value is Rect2 and not rect_value is Rect2i:
			continue
		var rect := Rect2(rect_value)
		if desktop_feet.y < rect.position.y or desktop_feet.y > rect.end.y:
			continue
		var left_distance := absf(desktop_feet.x - rect.position.x)
		if left_distance <= DRAG_EDGE_PREFETCH_DISTANCE and left_distance < best_distance:
			best_distance = left_distance
			best_edge = "left"
			best_facing = "right"
		var right_distance := absf(desktop_feet.x - rect.end.x)
		if right_distance <= DRAG_EDGE_PREFETCH_DISTANCE and right_distance < best_distance:
			best_distance = right_distance
			best_edge = "right"
			best_facing = "left"
	if best_edge.is_empty():
		return {}
	var previous_flip := sprite.flip_h if is_instance_valid(sprite) else false
	var animation_name := _resolve_movement_animation("climb-ready", Vector2.ZERO, best_facing)
	if is_instance_valid(sprite):
		sprite.flip_h = previous_flip
	if animation_name == &"":
		return {}
	return {
		"animation": animation_name,
		"edge": best_edge,
		"facing": best_facing,
		"distancePx": best_distance,
	}


func _on_character_drag_finished(payload: Dictionary) -> void:
	if str(payload.get("source", "")) != "native-host":
		return
	native_drag_visual_active = false
	drag_release_requested_feet = payload.get("desktopFeet", Vector2.ZERO)
	_play_drag_release_visual()


func _play_drag_hold_visual() -> void:
	drag_release_resolution_pending = false
	drag_release_started_us = 0
	drag_release_requested_feet = Vector2.ZERO
	predicted_drag_edge_animation = &""
	predicted_drag_edge = ""
	predicted_drag_edge_distance_px = INF
	_schedule_drag_release_prefetch()
	var drag_hold_animation := _animation_for_role("drag.hold", &"drag_hold")
	if not _character_has_animation(drag_hold_animation):
		return
	drag_release_visual_deadline_ms = 0
	physics_last_animation = drag_hold_animation
	event_bus.publish(&"animation.requested", {
		"name": drag_hold_animation,
		"source": "drag-interaction",
	})


func _play_drag_release_visual() -> void:
	drag_release_started_us = Time.get_ticks_usec()
	drag_release_resolution_pending = true
	var drag_hold_animation := _animation_for_role("drag.hold", &"drag_hold")
	var drag_release_animation := _animation_for_role("drag.release", &"drag_release")
	if _character_has_animation(drag_release_animation):
		# Own the visual transition until its one-shot finishes. Without this lock
		# the next airborne physics tick replaces Drag Release with Fall in the
		# same frame, making the authored release pose effectively invisible.
		physics_last_animation = drag_release_animation
		drag_release_visual_deadline_ms = Time.get_ticks_msec() + 350
		event_bus.publish(&"animation.requested", {
			"name": drag_release_animation,
			"source": "drag-interaction",
		})
		_schedule_predicted_drag_edge_prefetch()
		return
	if physics_last_animation == drag_hold_animation:
		physics_last_animation = &""
	drag_release_visual_deadline_ms = 0
	_schedule_predicted_drag_edge_prefetch()
	_apply_physics_animation(
		physics_last_movement_state,
		physics_last_velocity,
		physics_last_facing
	)


func _schedule_predicted_drag_edge_prefetch() -> void:
	if predicted_drag_edge_animation == &"":
		return
	_schedule_animation_prefetch(
		predicted_drag_edge_animation,
		"drag-edge-release:%s" % (predicted_drag_edge if not predicted_drag_edge.is_empty() else "unknown")
	)


func _schedule_drag_release_prefetch() -> void:
	var release_animation := _animation_for_role("drag.release", &"drag_release")
	if _character_has_animation(release_animation):
		_schedule_animation_prefetch(release_animation, "drag-start:release")
	elif _character_has_animation(&"fall"):
		_schedule_animation_prefetch(&"fall", "drag-start:fallback-fall")


func _schedule_canonical_animation_prefetch(
	movement_state: String,
	velocity: Vector2,
	facing: String
) -> void:
	if not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return
	var previous_flip := sprite.flip_h
	var candidate := _resolve_movement_animation(movement_state, velocity, facing)
	sprite.flip_h = previous_flip
	if candidate in [&"", &"idle", &"idle_neutral"]:
		return
	_schedule_animation_prefetch(candidate, "drag-release:%s" % movement_state)


func _schedule_animation_prefetch(animation_name: StringName, reason: String) -> void:
	if animation_name == &"" or not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return
	if sprite.sprite_frames.has_animation(animation_name):
		return
	var key := str(animation_name)
	if bool(pending_animation_prefetches.get(key, false)):
		return
	pending_animation_prefetches[key] = true
	var target_frames := sprite.sprite_frames
	call_deferred("_run_animation_prefetch", animation_name, reason, target_frames)


func _run_animation_prefetch(
	animation_name: StringName,
	reason: String,
	target_frames: SpriteFrames
) -> void:
	pending_animation_prefetches.erase(str(animation_name))
	if not is_instance_valid(sprite) or sprite.sprite_frames != target_frames:
		return
	var character_service: Variant = services.get("character_service") if is_instance_valid(services) else null
	if character_service == null or not character_service.has_method("prefetch_animation"):
		return
	character_service.call(
		"prefetch_animation",
		animation_name,
		target_frames,
		sprite.animation,
		reason
	)


func _on_character_loaded(payload: Dictionary) -> void:
	pending_animation_prefetches.clear()
	var frames: SpriteFrames = payload.get("frames")
	_render_log("character-loaded-received", {
		"payload_keys": payload.keys(),
		"frames_valid": frames != null,
		"sprite_valid": is_instance_valid(sprite),
		"host_valid": is_instance_valid(host),
	})

	if not is_instance_valid(sprite) or frames == null:
		_render_log("character-loaded-rejected", {
			"reason": "missing-sprite-or-frames",
		})
		return

	_reset_physics_visual_binding()
	native_animation_alpha_rect_cache.clear()
	presentation_size_scale = _load_presentation_size_scale()
	pending_presentation_size_scale = -1.0
	context.update_character({"presentation_scale": presentation_size_scale})
	sprite.sprite_frames = frames
	sprite.scale = Vector2.ONE * float(context.character.get("scale", 0.6))
	_fit_native_render_scale(frames)
	_sync_host_to_sprite_visual_bounds(frames)
	_publish_native_visual_hitbox(frames)
	_publish_native_surface_anchor(frames)
	event_bus.publish(&"character.presentation_scale_applied", {
		"scale": presentation_size_scale,
		"characterId": str(context.character.get("id", "")),
		"canonicalFeet": last_canonical_desktop_feet,
		"source": "character-load",
	})
	# The native host owns physical placement.  Keep only the character hidden
	# until it has received the first canonical move, avoiding a one-frame draw
	# at Godot's temporary startup rectangle.
	var native_enabled := bool(context.runtime_config.get("native_presentation_enabled", false))
	# Only the initial native startup waits for the host acknowledgement. Later
	# character swaps remain visible because the native surface is already ready.
	_set_character_surface_visible(not native_enabled or native_surface_revealed)

	_render_log("character-render-ready", {
		"animation_names": frames.get_animation_names(),
		"sprite_scale": sprite.scale,
		"sprite_visible": sprite.visible,
		"host_visible": host.visible if is_instance_valid(host) else false,
		"sprite_parent": str(sprite.get_parent().get_path()) if sprite.get_parent() != null else "(none)",
		"host_parent": str(host.get_parent().get_path()) if is_instance_valid(host) and host.get_parent() != null else "(none)",
	})

	if frames.has_animation(&"appear"):
		lifecycle_animation = &"appear"
		print("[PhysicsAnimation] lifecycle=appear")
		# Character packages can finish loading before AnimationController.start().
		# Defer one frame so the appear request cannot be dropped.
		call_deferred("_start_loaded_appear")
	else:
		event_bus.publish(&"animation.requested", {"name": "idle"})
	event_bus.publish(&"character.position_restore_requested", {})
	call_deferred("_render_deferred_probe", "after-character-loaded")


func _start_loaded_appear() -> void:
	if lifecycle_animation != &"appear" or not is_instance_valid(sprite):
		return
	if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(&"appear"):
		sprite.play(&"appear")
		print("[PhysicsAnimation] lifecycle-animation=appear source=character-load")
	event_bus.publish(&"animation.requested", {
		"name": "appear",
		"source": "character-load-deferred",
	})


func _sync_host_to_sprite_visual_bounds(frames: SpriteFrames) -> void:
	if not is_instance_valid(host) or not is_instance_valid(sprite) or frames == null:
		return

	var animation_names: PackedStringArray = frames.get_animation_names()
	if animation_names.is_empty():
		return

	var reference_animation: StringName = sprite.animation
	# Lifecycle disappear is visual-only. Its dissolve frames intentionally have
	# changing alpha bounds, so using them as the sprite anchor makes the visual
	# jump even though canonical desktop feet never moved. Keep the same stable
	# idle bounds used by the normal character pose.
	if lifecycle_animation == &"disappear" and frames.has_animation(&"idle"):
		reference_animation = &"idle"
	if reference_animation == &"":
		reference_animation = &"idle"
	if not frames.has_animation(reference_animation):
		reference_animation = &"idle" if frames.has_animation(&"idle") \
			else StringName(animation_names[0])

	if frames.get_frame_count(reference_animation) <= 0:
		return

	var texture: Texture2D = frames.get_frame_texture(reference_animation, 0)
	if texture == null:
		return

	var texture_size := Vector2(texture.get_size())
	var rendered_size := Vector2(
		texture_size.x * absf(sprite.scale.x),
		texture_size.y * absf(sprite.scale.y)
	)

	if rendered_size.x <= 0.0 or rendered_size.y <= 0.0:
		return

	# CompanionHost is the canonical presentation box. Its bottom edge is used
	# as "character feet" by drag commits and canonical physics projection.
	# Keeping a fixed 308x308 host while rendering (for example) a 512px frame
	# at scale 0.7 produces a 358.4px sprite, so ~25px of the sprite extends
	# below the canonical feet and visually sinks into the taskbar.
	#
	# Make the host match the rendered frame and re-center the sprite so the
	# host bottom, sprite-frame bottom, drag feet and physics feet share one
	# presentation anchor.
	var native_enabled := context != null \
		and bool(context.runtime_config.get("native_presentation_enabled", false))
	if native_enabled:
		# The native HWND is the canonical physical presentation box. Godot's
		# viewport can be larger than that box on a 96-DPI monitor when the main
		# window was created on a 192-DPI monitor (for example 768 logical px in
		# a 384 physical-px HWND). Use the actual viewport canvas here, otherwise
		# the sprite occupies only half of the native surface and its visible feet
		# appear above the taskbar although Native already landed at rcWork.bottom.
		var native_size := _native_canvas_size()
		host.size = native_size
		var alpha_rect := _animation_alpha_rect(frames, reference_animation)
		var scale_abs := Vector2(absf(sprite.scale.x), absf(sprite.scale.y))
		if alpha_rect.size != Vector2i.ZERO:
			var alpha_center := Vector2(alpha_rect.position) + Vector2(alpha_rect.size) * 0.5
			var alpha_bottom := float(alpha_rect.end.y)
			sprite.position = Vector2(
				native_size.x * 0.5 - (alpha_center.x - texture_size.x * 0.5) * scale_abs.x,
				native_size.y - (alpha_bottom - texture_size.y * 0.5) * scale_abs.y
			)
		else:
			sprite.position = Vector2(
				native_size.x * 0.5,
				native_size.y - rendered_size.y * 0.5
			)
	else:
		host.size = rendered_size
		sprite.position = rendered_size * 0.5

	_render_log("visual-bounds-synchronized", {
		"animation": str(reference_animation),
		"texture_size": texture_size,
		"sprite_scale": sprite.scale,
		"host_size": host.size,
		"sprite_position": sprite.position,
	})


func _on_animation_started(payload: Dictionary) -> void:
	if is_instance_valid(sprite) and sprite.sprite_frames != null:
		# Do not let a previous walk/climb facing mirror leak into authored
		# non-directional clips. Only the generic directional fallbacks keep the
		# Kernel-facing flip; explicit left/right artwork and all neutral/emotion
		# clips preserve the package's original asymmetric costume layout.
		var started := StringName(str(payload.get("name", "")))
		_apply_started_animation_facing(started)
		# AnimationController reapplies per-animation scale. Fit again before
		# positioning so a larger profile can never clip the head or feet inside
		# the fixed native render client.
		_fit_native_render_scale(sprite.sprite_frames)
		_sync_host_to_sprite_visual_bounds(sprite.sprite_frames)
		# Lifecycle disappear frames are often intentionally partial/dissolving
		# sprites. Publishing their alpha bounds as a new native anchor moves the
		# HWND while the animation is playing, even though canonical desktop feet
		# did not move. Keep the last idle anchor/hitbox for this visual-only
		# transition so disappear remains over the same desktop position.
		if lifecycle_animation == &"disappear":
			return
		_publish_native_visual_hitbox(sprite.sprite_frames)
		_publish_native_surface_anchor(sprite.sprite_frames)


func _apply_started_animation_facing(started: StringName) -> void:
	if not is_instance_valid(sprite):
		return
	if not _animation_allows_runtime_mirror(started):
		sprite.flip_h = false
	elif started in [
		&"walk_left", &"walk_right", &"hang_left", &"hang_right",
		&"climb_up_left", &"climb_up_right", &"climb_down_left", &"climb_down_right",
		&"climb_ready_left", &"climb_ready_right"
	]:
		sprite.flip_h = false
	elif started not in [&"walk", &"hang_traverse", &"climb_ready", &"climb_up", &"climb_down", &"climb_top"]:
		sprite.flip_h = false


func _fit_native_render_scale(frames: SpriteFrames) -> void:
	if context == null \
	or not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if frames == null:
		return
	# Keep the native presentation scale stable across animation changes.
	# Using the current animation's alpha bounds here made appear/sit/climb
	# resize the same character differently after restore or a menu action.
	# idle is the package's canonical visual-size reference; animation-specific
	# anchors and hitboxes are still published separately below.
	var reference_animation: StringName = &"idle" if frames.has_animation(&"idle") else sprite.animation
	if not frames.has_animation(reference_animation) \
		or frames.get_frame_count(reference_animation) <= 0:
		reference_animation = sprite.animation
	if not frames.has_animation(reference_animation) \
	or frames.get_frame_count(reference_animation) <= 0:
		return
	var texture: Texture2D = frames.get_frame_texture(reference_animation, 0)
	if texture == null:
		return
	var alpha_rect := _animation_alpha_rect(frames, reference_animation)
	if alpha_rect.size == Vector2i.ZERO:
		return
	# Read the declared idle profile instead of deriving a multiplier from the
	# current sprite scale. The latter already contains a DPI canvas adjustment
	# after a monitor crossing and would compound on every animation change.
	var profiles: Dictionary = context.character.get("visual_profiles", {})
	var idle_profile: Dictionary = profiles.get(str(reference_animation), {})
	var profile_ratio := clampf(float(idle_profile.get("scale", 1.0)), 0.25, 2.0)
	var physical_size := _native_render_size()
	var canvas_size := _native_canvas_size()
	var canvas_scale := canvas_size.x / maxf(physical_size.x, 1.0)
	# Keep a deterministic 32px margin on all sides. Generated sheets often have
	# content close to a frame edge and the previous 12px margin was too small
	# once an animation profile reapplied its scale.
	var safe_size := maxf(128.0, minf(physical_size.x, physical_size.y) - 64.0)
	var alpha_size := Vector2(alpha_rect.size)
	var fitted_base := minf(
		safe_size / maxf(alpha_size.x, 1.0),
		safe_size / maxf(alpha_size.y, 1.0)
	)
	# `physical_size` is the authored 384px native box. Scale it into the
	# active Godot canvas so the same physical-sized character is drawn on every
	# monitor, including a 768px logical canvas inside a 384px HWND.
	var target_scale := clampf(
		fitted_base * profile_ratio * canvas_scale * presentation_size_scale,
		0.0625,
		3.0
	)
	if not is_equal_approx(absf(sprite.scale.x), target_scale):
		sprite.scale = Vector2.ONE * target_scale
		_render_log("native-render-scale-fitted", {
			"alpha_size": alpha_size,
			"profile_ratio": profile_ratio,
			"canvas_scale": canvas_scale,
			"sprite_scale": sprite.scale,
			"presentation_size_scale": presentation_size_scale,
		})


func _on_presentation_scale_requested(payload: Dictionary) -> void:
	var requested := float(payload.get("scale", 0.0))
	if not _is_presentation_scale_allowed(requested):
		print("[CompanionSize] rejected scale=%.2f source=%s" % [requested, str(payload.get("source", "unknown"))])
		event_bus.publish(&"character.presentation_scale_rejected", {
			"scale": requested,
			"reason": "unsupported-preset",
		})
		return
	pending_presentation_size_scale = requested
	if not _presentation_scale_safe_to_apply():
		print("[CompanionSize] queued scale=%.2f state=%s dragging=%s" % [
			requested,
			physics_last_movement_state,
			dragging or native_mouse_capture_active,
		])
		event_bus.publish(&"character.presentation_scale_deferred", {
			"scale": requested,
			"movementState": physics_last_movement_state,
		})
		return
	_try_apply_pending_presentation_scale()


func _try_apply_pending_presentation_scale() -> void:
	if pending_presentation_size_scale < 0.0 or not _presentation_scale_safe_to_apply():
		return
	if not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return
	var applied := pending_presentation_size_scale
	pending_presentation_size_scale = -1.0
	presentation_size_scale = applied
	_fit_native_render_scale(sprite.sprite_frames)
	_sync_host_to_sprite_visual_bounds(sprite.sprite_frames)
	_publish_native_visual_hitbox(sprite.sprite_frames)
	_publish_native_surface_anchor(sprite.sprite_frames)
	context.update_character({"presentation_scale": presentation_size_scale})
	var settings_service: Variant = _get_service(&"settings_service")
	var character_id := str(context.character.get("id", ""))
	if settings_service != null and settings_service.has_method("save_character_presentation_scale"):
		settings_service.call("save_character_presentation_scale", character_id, presentation_size_scale)
	print("[CompanionSize] applied scale=%.2f character=%s canonical_feet=%s" % [
		presentation_size_scale,
		character_id,
		last_canonical_desktop_feet,
	])
	event_bus.publish(&"character.presentation_scale_applied", {
		"scale": presentation_size_scale,
		"characterId": character_id,
		"canonicalFeet": last_canonical_desktop_feet,
	})


func _presentation_scale_safe_to_apply() -> bool:
	return not dragging \
		and not native_mouse_capture_active \
		and not presentation_drag_commit_pending \
		and not teleport_visual_pending \
		and lifecycle_animation == &"" \
		and physics_last_animation != &"land" \
		and physics_last_animation != &"climb_top" \
		and physics_last_movement_state == "stationary"


func _load_presentation_size_scale() -> float:
	var settings_service: Variant = _get_service(&"settings_service")
	var character_id := str(context.character.get("id", "")).strip_edges()
	if settings_service != null and settings_service.has_method("load_character_presentation_scale"):
		var saved := float(settings_service.call("load_character_presentation_scale", character_id))
		if _is_presentation_scale_allowed(saved):
			return saved
	return BIBLE_DEFAULT_PRESENTATION_SCALE if character_id == BIBLE_CHARACTER_ID else 1.0


func _is_presentation_scale_allowed(scale: float) -> bool:
	for preset in PRESENTATION_SCALE_PRESETS:
		if is_equal_approx(scale, preset):
			return true
	return false


func _native_render_size() -> Vector2:
	var configured_size := int(OS.get_environment("OCP_NATIVE_HOST_SIZE"))
	if configured_size < 128 or configured_size > 768:
		configured_size = int(context.character.get("render_size", Vector2i(384, 384)).x)
	configured_size = clampi(configured_size, 128, 768)
	return Vector2(configured_size, configured_size)


func _native_canvas_size() -> Vector2:
	# The authored character canvas is desktop-logical and must not inherit the
	# outer Godot viewport's physical DPI size. Win32 owns that physical resize;
	# using it here made the sprite and hitbox oscillate between monitors.
	return _native_render_size()


func _drag_release_visual_active() -> bool:
	var release_animation := _animation_for_role("drag.release", &"drag_release")
	return physics_last_animation == release_animation \
		and drag_release_visual_deadline_ms > Time.get_ticks_msec()


func _native_hitbox_is_locked() -> bool:
	return physics_last_movement_state in ["climb-ready", "climbing", "hanging"] \
		or _drag_release_visual_active()


func _native_anchor_is_locked() -> bool:
	# `climb_top` and Drag Release are visual-only transitions. Keep the native
	# contact fixed until Physics selects the next canonical state; otherwise
	# animation-specific transparent bounds can move the HWND even though the
	# canonical desktop feet have not moved.
	# Climb/hang locomotion itself still publishes authored surfaceAnchor values.
	return physics_last_animation == &"climb_top" or _drag_release_visual_active()


func _texture_alpha_rect(texture: Texture2D) -> Rect2i:
	if texture == null:
		return Rect2i()
	# CharacterService stamps verified CPU-side alpha bounds on AtlasTexture
	# frames at load time. Prefer them so animation changes never need a GPU
	# texture readback while a large local LLM is competing for shared memory.
	if texture.has_meta(&"ocp_alpha_rect"):
		var cached_value: Variant = texture.get_meta(&"ocp_alpha_rect")
		if cached_value is Rect2i:
			return cached_value
	# Managed character frames are AtlasTexture instances. If an older package or
	# synthetic frame has no metadata, using the full authored frame is a safe
	# conservative fallback and avoids Texture2D.get_image() allocation spikes.
	if texture is AtlasTexture:
		var atlas_texture := texture as AtlasTexture
		return Rect2i(Vector2i.ZERO, Vector2i(atlas_texture.region.size))
	var image := texture.get_image()
	if image == null or image.is_empty():
		return Rect2i()
	var used := image.get_used_rect()
	if used.size == Vector2i.ZERO:
		return Rect2i()
	return used.grow(6).intersection(Rect2i(Vector2i.ZERO, image.get_size()))


func _animation_alpha_rect(frames: SpriteFrames, animation: StringName) -> Rect2i:
	var cache_key := str(animation)
	var cached: Variant = native_animation_alpha_rect_cache.get(cache_key, null)
	if cached is Rect2i:
		return cached
	if frames == null or animation.is_empty() or not frames.has_animation(animation):
		return Rect2i()
	var frame_count := frames.get_frame_count(animation)
	if frame_count <= 0:
		return Rect2i()
	var merged := Rect2i()
	for frame_index in range(frame_count):
		var texture: Texture2D = frames.get_frame_texture(animation, frame_index)
		var used := _texture_alpha_rect(texture)
		if used.size == Vector2i.ZERO:
			continue
		merged = used if merged.size == Vector2i.ZERO else merged.merge(used)
	native_animation_alpha_rect_cache[cache_key] = merged
	return merged


func _publish_native_visual_hitbox(frames: SpriteFrames) -> void:
	if context == null \
	or not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if lifecycle_animation == &"disappear":
		return
	if _native_hitbox_is_locked() and last_stable_native_hitbox.size.x > 0.0 \
	and last_stable_native_hitbox.size.y > 0.0:
		event_bus.publish(&"character.native_hitbox_changed", {
			"normalized_hitbox": last_stable_native_hitbox,
			"animation": "locked-climb-hitbox",
		})
		return
	if frames == null or not is_instance_valid(sprite) or not is_instance_valid(host):
		return
	var animation := sprite.animation
	if not frames.has_animation(animation) or frames.get_frame_count(animation) <= 0:
		animation = &"idle"
	if not frames.has_animation(animation) or frames.get_frame_count(animation) <= 0:
		return
	var texture: Texture2D = frames.get_frame_texture(animation, 0)
	if texture == null:
		return
	var used := _animation_alpha_rect(frames, animation)
	if used.size == Vector2i.ZERO:
		return
	var frame_size := Vector2(texture.get_size())
	var scale_abs := Vector2(absf(sprite.scale.x), absf(sprite.scale.y))
	var visual := Rect2(
		sprite.position + (Vector2(used.position) - frame_size * 0.5) * scale_abs,
		Vector2(used.size) * scale_abs
	)
	var host_size := Vector2(host.size)
	if host_size.x <= 0.0 or host_size.y <= 0.0:
		return
	visual = visual.intersection(Rect2(Vector2.ZERO, host_size))
	if visual.size.x <= 0.0 or visual.size.y <= 0.0:
		return
	var normalized := Rect2(
		visual.position / host_size,
		visual.size / host_size
	)
	if not _native_hitbox_is_locked():
		last_stable_native_hitbox = normalized
	event_bus.publish(&"character.native_hitbox_changed", {
		"normalized_hitbox": normalized,
		"animation": str(animation),
	})


func _publish_native_surface_anchor(frames: SpriteFrames) -> void:
	if context == null \
	or not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if lifecycle_animation == &"disappear":
		return
	if frames == null or not is_instance_valid(sprite) or not is_instance_valid(host):
		return
	var animation := sprite.animation
	if not frames.has_animation(animation) or frames.get_frame_count(animation) <= 0:
		animation = &"idle"
	if not frames.has_animation(animation) or frames.get_frame_count(animation) <= 0:
		return
	var texture: Texture2D = frames.get_frame_texture(animation, 0)
	if texture == null:
		return
	var frame_size := Vector2(texture.get_size())
	var used := _animation_alpha_rect(frames, animation)
	if frame_size.x <= 0.0 or frame_size.y <= 0.0 or used.size == Vector2i.ZERO:
		return
	var frame_anchor := Vector2(
		float(used.position.x) + float(used.size.x) * 0.5,
		float(used.end.y)
	)
	var profiles: Dictionary = context.character.get("visual_profiles", {})
	var profile: Dictionary = profiles.get(str(animation), {})
	var configured: Variant = profile.get("surfaceAnchor", profile.get("anchor", null))
	if configured is Array and configured.size() == 2:
		frame_anchor = Vector2(
			clampf(float(configured[0]), 0.0, 1.0) * frame_size.x,
			clampf(float(configured[1]), 0.0, 1.0) * frame_size.y
		)
	var scale_abs := Vector2(absf(sprite.scale.x), absf(sprite.scale.y))
	var local_anchor := sprite.position + (frame_anchor - frame_size * 0.5) * scale_abs
	var host_size := Vector2(host.size)
	if host_size.x <= 0.0 or host_size.y <= 0.0:
		return
	var normalized := Vector2(
		clampf(local_anchor.x / host_size.x, 0.0, 1.0),
		clampf(local_anchor.y / host_size.y, 0.0, 1.0)
	)
	var candidate_normalized := normalized
	if _native_anchor_is_locked() and last_stable_native_anchor.x >= 0.0:
		normalized = last_stable_native_anchor
		var prevented_delta := (candidate_normalized - normalized) * host_size
		event_bus.publish(&"character.anchor_continuity_measured", {
			"animation": str(animation),
			"reason": "drag-release" if _drag_release_visual_active() else "climb-top",
			"preventedDeltaPx": prevented_delta.length(),
			"candidateAnchor": candidate_normalized,
			"lockedAnchor": normalized,
		})
	else:
		last_stable_native_anchor = normalized
	event_bus.publish(&"character.native_anchor_changed", {
		"normalized_anchor": normalized,
		"animation": str(animation),
	})


func _on_restore_requested(_payload: Dictionary) -> void:
	_render_log("restore-requested", _render_snapshot())
	if not is_instance_valid(host):
		_render_log("restore-rejected", {"reason": "invalid-host"})
		return

	var settings_service: Variant = _get_service(&"settings_service")
	if settings_service == null or not settings_service.has_method(
		"load_character_desktop_position"
	):
		return

	var saved_value: Variant = settings_service.call(
		"load_character_desktop_position"
	)
	if not saved_value is Dictionary:
		return

	var saved: Dictionary = saved_value
	if saved.is_empty():
		_render_log("restore-skipped", {"reason": "empty-saved-position"})
		return

	var desktop_position: Vector2 = saved.get("position", Vector2.ZERO)
	coordinate_mapper.refresh()
	if not coordinate_mapper.contains_desktop_point(desktop_position, 8.0):
		_render_log("restore-skipped", {
			"reason": "saved-position-outside-current-topology",
			"desktop_position": desktop_position,
			"coordinate_map": coordinate_mapper.describe(),
		})
		pending_restore_desktop_position = null
		return

	pending_restore_desktop_position = desktop_position
	_render_log("restore-cached", {
		"desktop_position": desktop_position,
		"reason": "wait-for-canonical-presentation",
		"viewport_size": host.get_viewport_rect().size,
		"overlay_enabled": context.runtime_config.get("overlay_enabled", false),
	})


func _on_presentation_state(payload: Dictionary) -> void:
	var accepted: Dictionary = accept_canonical_presentation(payload)
	_apply_presentation_state(accepted, "canonical")


func _on_physics_moved(payload: Dictionary) -> void:
	var accepted: Dictionary = accept_legacy_presentation(payload)
	_apply_presentation_state(accepted, "legacy")


func _on_presentation_mode_applied(payload: Dictionary) -> void:
	var overlay_enabled: bool = bool(payload.get(
		"overlayEnabled",
		str(payload.get("mode", "debug")) == "overlay"
	))
	context.runtime_config["overlay_enabled"] = overlay_enabled
	context.update_window({
		"overlay_enabled": overlay_enabled,
		"presentation_mode": payload.get("mode", "debug"),
	})

	if not overlay_enabled:
		presentation_overlay_screen = -1
		presentation_coordinate_resolver.call("clear_overlay_screen")
	coordinate_mapper.refresh()
	presentation_coordinate_resolver.call("configure", coordinate_mapper)
	if is_instance_valid(host):
		host.visible = true
		host.modulate.a = 1.0
	if is_instance_valid(sprite):
		sprite.visible = true
		sprite.modulate.a = 1.0
	_render_log("presentation-mode-canvas", {
		"mode": payload.get("mode", "debug"),
		"overlay_enabled": overlay_enabled,
		"viewport_size": host.get_viewport_rect().size if is_instance_valid(host) else Vector2.ZERO,
		"window_size": payload.get("windowSize", Vector2i.ZERO),
		"content_scale_size": payload.get("contentScaleSize", Vector2i.ZERO),
	})
	if last_presentation_state.is_empty() or not is_instance_valid(host):
		return

	# Window geometry changes invalidate every previous local coordinate. Reapply
	# the last canonical desktop state immediately instead of waiting for the
	# next physics tick; this prevents the companion disappearing when switching
	# between Debug Window and Overlay.
	var replay: Dictionary = last_presentation_state.duplicate(true)
	replay["snap"] = true
	_apply_presentation_state(replay, "mode-reproject")
	_render_log("presentation-mode-reprojected", {
		"mode": payload.get("mode", "unknown"),
		"revision": payload.get("revision", -1),
		"desktop_feet": last_canonical_desktop_feet,
		"host_position": host.position,
	})


func _apply_presentation_state(state: Dictionary, source: String) -> void:
	if not is_instance_valid(host):
		return
	if not bool(state.get("accepted", false)):
		event_bus.publish(&"character.presentation_state_ignored", {
			"source": source,
			"reason": state.get("reason", "rejected"),
			"sequence": state.get("sequence", -1),
			"revision": state.get("revision", -1),
		})
		return

	last_presentation_state = state.duplicate(true)
	last_canonical_desktop_feet = state.get("desktopFeet", Vector2.ZERO)

	var sequence: int = int(state.get("sequence", -1))
	physics_last_sequence = sequence
	render_debug_last_sequence = sequence
	var movement_state: String = str(state.get("movementState", "stationary"))
	var update_kind: String = str(state.get("updateKind", "continuous"))
	var feet_desktop: Vector2 = state.get("desktopFeet", Vector2.ZERO)
	if drag_release_resolution_pending and update_kind == "drag-commit":
		var release_latency_ms := 0.0
		if drag_release_started_us > 0:
			release_latency_ms = float(Time.get_ticks_usec() - drag_release_started_us) / 1000.0
		var snap_distance_px := 0.0
		if drag_release_requested_feet != Vector2.ZERO:
			snap_distance_px = drag_release_requested_feet.distance_to(feet_desktop)
		event_bus.publish(&"character.drag_release_resolved", {
			"latencyMs": release_latency_ms,
			"requestedFeet": drag_release_requested_feet,
			"resolvedFeet": feet_desktop,
			"snapDistancePx": snap_distance_px,
			"movementState": movement_state,
			"attachmentState": str(state.get("attachmentState", "")),
			"surfaceKind": str(state.get("surfaceKind", "")),
			"sequence": sequence,
		})
		drag_release_resolution_pending = false
	if update_kind != "continuous" or movement_state != physics_last_logged_state:
		print(
			"[PhysicsAnimation] canonical movement_state=%s update=%s sequence=%d" % [
				movement_state,
				update_kind,
				sequence,
			]
		)
		physics_last_logged_state = movement_state

	var overlay_enabled: bool = bool(
		context.runtime_config.get("overlay_enabled", false)
	)
	var native_enabled := bool(context.runtime_config.get("native_presentation_enabled", false))
	# Moving the top-level HWND across monitors can change Godot's logical
	# viewport without changing the physical native client size. Re-fit only
	# when that canvas changes; this keeps the visual feet locked to the native
	# work-area landing point on mixed-DPI monitor layouts.
	if native_enabled and is_instance_valid(sprite) and sprite.sprite_frames != null:
		var expected_native_canvas := _native_canvas_size()
		if not host.size.is_equal_approx(expected_native_canvas):
			_fit_native_render_scale(sprite.sprite_frames)
			_sync_host_to_sprite_visual_bounds(sprite.sprite_frames)
			if lifecycle_animation != &"disappear":
				_publish_native_visual_hitbox(sprite.sprite_frames)
				_publish_native_surface_anchor(sprite.sprite_frames)
	if overlay_enabled:
		_ensure_overlay_screen_for_desktop_point(feet_desktop)
	var viewport_size: Vector2 = host.get_viewport_rect().size
	var feet_local: Vector2 = presentation_coordinate_resolver.call(
		"desktop_point_to_local",
		feet_desktop,
		viewport_size,
		overlay_enabled
	)
	var target: Vector2 = Vector2.ZERO if native_enabled else presentation_coordinate_resolver.call(
		"desktop_feet_to_host_position",
		feet_desktop,
		host.size,
		viewport_size,
		overlay_enabled
	)
	if update_kind != "continuous":
		var target_screen: Dictionary = coordinate_mapper.screen_for_desktop_point(
			feet_desktop
		)
		print(
			(
				"[presentation-placement] desktop_feet=%s local_feet=%s target=%s "
				+ "host_size=%s viewport=%s screen=%s visible=%s"
			) % [
				feet_desktop,
				feet_local,
				target,
				host.size,
				viewport_size,
				int(target_screen.get("screen", -1)),
				presentation_coordinate_resolver.overlay_canvas_contains_host(
					target,
					host.size,
					viewport_size
				),
			]
		)
	# A wall attachment is anchored at the physics edge, while the visual host
	# has a real width. Keep the complete sprite inside the active presentation
	# viewport so a side hang cannot clip the body to only feet/tail.
	if movement_state == "climb-ready" or movement_state == "hanging":
		target.x = clampf(target.x, 0.0, maxf(0.0, viewport_size.x - host.size.x))
		target.y = clampf(target.y, 0.0, maxf(0.0, viewport_size.y - host.size.y))

	_render_log("presentation-state", {
		"source": source,
		"sequence": sequence,
		"revision": state.get("revision", -1),
		"update_kind": update_kind,
		"movement_state": movement_state,
		"desktop_feet": feet_desktop,
		"local_feet": feet_local,
		"target": target,
		"host_before": host.position,
		"overlay_enabled": overlay_enabled,
		"resolver_screen": presentation_coordinate_resolver.get("active_debug_screen"),
	})

	presentation_first_state_applied = true
	pending_restore_desktop_position = null
	if bool(state.get("snap", false)):
		physics_target_active = false
		if not dragging:
			host.position = target
			_update_position_context()
			_save_canonical_position()
			event_bus.publish(&"click_through.refresh_requested", {})
	else:
		physics_target_position = target
		physics_target_active = not dragging

	var facing: String = str(state.get("facing", "unchanged"))
	if drag_release_visual_deadline_ms > Time.get_ticks_msec():
		_schedule_canonical_animation_prefetch(
			movement_state,
			state.get("velocity", Vector2.ZERO),
			facing
		)
	_apply_physics_animation(
		movement_state,
		state.get("velocity", Vector2.ZERO),
		facing
	)
	if update_kind == "teleport":
		_finish_teleport_visual_after_canonical()
	event_bus.publish(&"character.presentation_applied", {
		"source": source,
		"sequence": sequence,
		"revision": state.get("revision", -1),
		"updateKind": update_kind,
	})


func _ensure_overlay_screen_for_desktop_point(desktop_point: Vector2) -> void:
	var descriptor: Dictionary = coordinate_mapper.screen_for_desktop_point(
		desktop_point
	)
	if descriptor.is_empty():
		return
	var screen_index: int = int(descriptor.get("screen", -1))
	var changed: bool = bool(
		presentation_coordinate_resolver.call(
			"set_overlay_screen",
			descriptor
		)
	)
	if not changed and screen_index == presentation_overlay_screen:
		return
	presentation_overlay_screen = screen_index
	var physical: Rect2 = descriptor.get("physical", Rect2())
	event_bus.publish(&"window.overlay_screen_requested", {
		"screen": screen_index,
		"physicalRect": Rect2i(
			Vector2i(physical.position),
			Vector2i(physical.size)
		),
	})


func _prepare_virtual_overlay_drag() -> void:
	if not bool(context.runtime_config.get("overlay_enabled", false)):
		return
	if str(context.window.get("overlay_scope", "virtual")) != "monitor":
		return
	presentation_coordinate_resolver.call("clear_overlay_screen")
	presentation_overlay_screen = -1
	event_bus.publish(&"window.virtual_overlay_requested", {})
	if last_canonical_desktop_feet == Vector2.ZERO:
		return
	var viewport_size: Vector2 = host.get_viewport_rect().size
	host.position = presentation_coordinate_resolver.desktop_feet_to_host_position(
		last_canonical_desktop_feet,
		host.size,
		viewport_size,
		true
	)
	physics_target_active = false
	_update_position_context()


func _apply_physics_animation(
	movement_state: String,
	velocity: Vector2,
	facing: String = "unchanged"
) -> void:
	if not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return
	# Lifecycle animations own the first visual frame. Physics publishes the
	# initial stationary state immediately after character loading; do not let
	# that state replace appear before its non-looping animation finishes.
	if lifecycle_animation != &"":
		return
	if native_drag_visual_active:
		return
	var drag_release_animation := _animation_for_role("drag.release", &"drag_release")
	if physics_last_animation == drag_release_animation and _character_has_animation(drag_release_animation):
		# Drag Release is an optional one-shot transition. Let it finish before
		# physics selects Fall/Land/Idle so the release pose is visible instead of
		# being replaced by the very next solver tick. The short deadline is a
		# fail-safe in case a renderer never reports animation.finished.
		if Time.get_ticks_msec() < drag_release_visual_deadline_ms:
			return
		physics_last_animation = &""
		drag_release_visual_deadline_ms = 0

	var previous_state: String = physics_last_movement_state
	physics_last_movement_state = movement_state
	physics_last_velocity = velocity
	physics_last_facing = facing
	# Warm the deterministic next transition while the current motion still has
	# useful dwell time. With the two-entry bounded cache this keeps only the
	# active clip plus its most likely successor: Fall -> Land and Climb -> Hang.
	if movement_state == "airborne-falling" and _character_has_animation(&"land"):
		_schedule_animation_prefetch(&"land", "motion:fall-to-land")
	elif movement_state == "climbing":
		var hang_animation := _animation_for_role("hang.neutral", &"hang")
		if _character_has_animation(hang_animation):
			_schedule_animation_prefetch(hang_animation, "motion:climb-to-hang")
	var transient: StringName = &""
	if previous_state == "airborne-falling" \
	and movement_state != "airborne-rising" \
	and movement_state != "airborne-falling" \
	and _character_has_animation(&"land"):
		transient = &"land"
	elif previous_state == "hanging" \
	and movement_state != "hanging" \
	and movement_state != "airborne-rising" \
	and movement_state != "airborne-falling" \
	and velocity.y <= 0.001 \
	and _character_has_animation(&"climb_top"):
		transient = &"climb_top"
	if transient != &"":
		physics_last_animation = transient
		print(
			"[PhysicsAnimation] transition=%s animation=%s previous_state=%s movement_state=%s" % [
				transient,
				transient,
				previous_state,
				movement_state,
			]
		)
		event_bus.publish(&"animation.requested", {
			"name": transient,
			"source": "physics-transition",
		})
		return

	var selected: StringName = _resolve_movement_animation(
		movement_state,
		velocity,
		facing
	)
	if selected == &"" or selected == physics_last_animation:
		return

	physics_last_animation = selected
	print(
		"[PhysicsAnimation] state=%s animation=%s facing=%s velocity=(%.1f,%.1f)" % [
			movement_state,
			selected,
			facing,
			velocity.x,
			velocity.y,
		]
	)
	_render_log("animation-selected", {
		"movement_state": movement_state,
		"velocity": velocity,
		"selected": selected,
		"current_animation": sprite.animation,
		"sprite_visible": sprite.visible,
	})
	event_bus.publish(&"animation.requested", {
		"name": selected,
		"source": "physics",
	})


func _character_has_animation(animation_name: StringName) -> bool:
	if is_instance_valid(context):
		var advertised: Variant = context.character.get("animations", PackedStringArray())
		if advertised is PackedStringArray and advertised.has(str(animation_name)):
			return true
		if advertised is Array and str(animation_name) in advertised:
			return true
	return is_instance_valid(sprite) \
		and sprite.sprite_frames != null \
		and sprite.sprite_frames.has_animation(animation_name)


func _animation_for_role(role: String, fallback: StringName) -> StringName:
	if is_instance_valid(context):
		var entry_value: Variant = context.package.get("entry", {})
		if entry_value is Dictionary:
			var roles_value: Variant = entry_value.get("animationRoles", {})
			if roles_value is Dictionary:
				var mapped := StringName(str(roles_value.get(role, "")))
				if mapped != &"" and _character_has_animation(mapped):
					return mapped
	return fallback


func _animation_allows_runtime_mirror(animation_name: StringName) -> bool:
	# Backward compatibility: packages authored before mirrorSafe existed keep
	# the previous Runtime behavior. New packages may explicitly opt out for
	# text, logos, vehicle markings, or asymmetric costumes.
	if not is_instance_valid(context):
		return true
	var profiles_value: Variant = context.character.get("visual_profiles", {})
	if not (profiles_value is Dictionary):
		return true
	var profiles: Dictionary = profiles_value
	var profile_value: Variant = profiles.get(str(animation_name), profiles.get("default", {}))
	if not (profile_value is Dictionary):
		return true
	var profile: Dictionary = profile_value
	if profile.has("mirrorSafe"):
		return bool(profile.get("mirrorSafe", true))
	# mirrorPolicy=none is the legacy/portable way to say the artwork is already
	# authored in the intended orientation. Keep supporting it for character/2
	# and older character/3 packages.
	return str(profile.get("mirrorPolicy", "")).strip_edges().to_lower() != "none"


func _resolve_movement_animation(
	movement_state: String,
	velocity: Vector2,
	facing: String = "unchanged"
) -> StringName:
	var candidates: Array[StringName] = []
	match movement_state:
		"sitting":
			candidates = [&"sit", &"idle", &"idle_neutral"]
		"walking":
			if velocity.x < 0.0:
				candidates = [&"walk_left", &"walk", &"idle"]
			else:
				candidates = [&"walk_right", &"walk", &"idle"]
		"airborne-rising":
			candidates = [&"jump", &"airborne", &"surprised", &"idle"]
		"airborne-falling":
			candidates = [&"fall", &"airborne", &"surprised", &"idle"]
		"climbing":
			# Prefer authored directional wall art when supplied. This is required
			# for text/logos/asymmetric costumes because mirroring a generic sheet
			# would reverse those details. Legacy packages keep the generic climb
			# fallback and therefore preserve their existing behavior unchanged.
			if velocity.y < 0.0:
				if facing == "left":
					candidates = [_animation_for_role("climb.up.left", &""), &"climb_up_left", &"climb_up", &"climb", &"climbing", &"walk", &"idle"]
				elif facing == "right":
					candidates = [_animation_for_role("climb.up.right", &""), &"climb_up_right", &"climb_up", &"climb", &"climbing", &"walk", &"idle"]
				else:
					candidates = [&"climb_up", &"climb", &"climbing", &"walk", &"idle"]
			else:
				if facing == "left":
					candidates = [_animation_for_role("climb.down.left", &""), &"climb_down_left", &"climb_down", &"climb", &"climbing", &"walk", &"idle"]
				elif facing == "right":
					candidates = [_animation_for_role("climb.down.right", &""), &"climb_down_right", &"climb_down", &"climb", &"climbing", &"walk", &"idle"]
				else:
					candidates = [&"climb_down", &"climb", &"climbing", &"walk", &"idle"]
		"hanging":
			if velocity.x < -0.001:
				candidates = [_animation_for_role("hang.left", &"hang_left"), &"hang_left", &"hang_traverse", &"hang", &"hanging", &"climb", &"idle"]
			elif velocity.x > 0.001:
				candidates = [_animation_for_role("hang.right", &"hang_right"), &"hang_right", &"hang_traverse", &"hang", &"hanging", &"climb", &"idle"]
			else:
				candidates = [_animation_for_role("hang.neutral", &"hang"), &"hang", &"hanging", &"climb", &"idle"]
		"climb-ready":
			# Ready means attached and waiting at the wall. Directional packages
			# derive a one-frame ready pose from their authored climb-up sheet so
			# text/logos never need mirroring even before vertical motion begins.
			if facing == "left":
				candidates = [_animation_for_role("climb.ready.left", &""), &"climb_ready_left", &"climb_ready", &"climb_up", &"climb", &"climbing", &"idle"]
			elif facing == "right":
				candidates = [_animation_for_role("climb.ready.right", &""), &"climb_ready_right", &"climb_ready", &"climb_up", &"climb", &"climbing", &"idle"]
			else:
				candidates = [&"climb_ready", &"climb_up", &"climb", &"climbing", &"idle"]
		_:
			candidates = [&"idle", &"idle_neutral"]

	for candidate in candidates:
		if not _character_has_animation(candidate):
			continue
		if candidate in [
			&"walk_left", &"walk_right", &"hang_left", &"hang_right",
			&"climb_up_left", &"climb_up_right", &"climb_down_left", &"climb_down_right",
			&"climb_ready_left", &"climb_ready_right"
		]:
			# Explicit directional artwork already encodes its facing. Mirroring it
			# would also reverse text/logos and swap asymmetric costume details.
			sprite.flip_h = false
		elif not _animation_allows_runtime_mirror(candidate):
			# New mirrorSafe=false metadata (or legacy mirrorPolicy=none) forbids
			# runtime mirroring even for a generic semantic animation.
			sprite.flip_h = false
		elif candidate in [&"walk", &"hang_traverse"]:
			# Generic one-direction locomotion clips may be mirrored as a fallback.
			sprite.flip_h = velocity.x < 0.0
		elif candidate in [&"idle", &"idle_neutral", &"sit", &"jump", &"fall", &"hang", &"hanging", &"surprised"]:
			# Neutral/non-directional authored clips must preserve their original
			# left/right costume layout regardless of the last Kernel facing.
			sprite.flip_h = false
		elif facing == "left":
			sprite.flip_h = true
		elif facing == "right":
			sprite.flip_h = false
		return candidate

	for animation_name in sprite.sprite_frames.get_animation_names():
		if sprite.sprite_frames.get_animation_loop(animation_name):
			return animation_name

	return &""


func _on_animation_finished(payload: Dictionary) -> void:
	var finished: StringName = StringName(payload.get("name", ""))
	if finished == &"appear":
		lifecycle_animation = &""
		event_bus.publish(&"animation.requested", {"name": "idle", "source": "lifecycle-transition"})
		return
	if finished == &"disappear":
		lifecycle_animation = &""
		return
	var drag_release_animation := _animation_for_role("drag.release", &"drag_release")
	if finished != &"land" and finished != &"climb_top" and finished != drag_release_animation:
		return
	if physics_last_animation != finished:
		return
	if finished == drag_release_animation:
		drag_release_visual_deadline_ms = 0
	physics_last_animation = &""
	_apply_physics_animation(
		physics_last_movement_state,
		physics_last_velocity,
		physics_last_facing
	)


func _on_appear_requested(_payload: Dictionary) -> void:
	_cancel_teleport_visual_transition()
	if not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return
	var native_enabled := bool(context.runtime_config.get("native_presentation_enabled", false)) if is_instance_valid(context) else false
	if not native_enabled or native_surface_revealed:
		sprite.visible = true
	if _character_has_animation(&"appear"):
		lifecycle_animation = &"appear"
		print("[PhysicsAnimation] lifecycle=appear")
		event_bus.publish(&"animation.requested", {"name": "appear", "source": "lifecycle"})
	else:
		event_bus.publish(&"animation.requested", {"name": "idle", "source": "lifecycle"})


func _on_native_surface_ready(_payload: Dictionary) -> void:
	native_surface_revealed = true
	_set_character_surface_visible(true)
	_render_log("native-surface-revealed", _render_snapshot())


func _set_character_surface_visible(visible: bool) -> void:
	if is_instance_valid(host):
		host.visible = visible
		host.modulate.a = 1.0 if visible else 0.0
	if is_instance_valid(sprite):
		sprite.visible = visible
		sprite.modulate.a = 1.0 if visible else 0.0


func _on_disappear_requested(_payload: Dictionary) -> void:
	_cancel_teleport_visual_transition()
	if not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return
	if _character_has_animation(&"disappear"):
		lifecycle_animation = &"disappear"
		print("[PhysicsAnimation] lifecycle=disappear")
		event_bus.publish(&"animation.requested", {"name": "disappear", "source": "lifecycle"})


func _on_teleport_visual_requested(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default" or teleport_visual_pending:
		return
	teleport_visual_pending = true
	# Teleport presentation stays entirely in Runtime. The EffectController owns
	# the portal layer while this controller owns character alpha. Kernel is only
	# released after the fade-out is complete.
	event_bus.publish(&"effect.requested", {"name": "teleport_out", "source": "teleport-transition"})
	if not is_instance_valid(sprite) or not is_inside_tree():
		_finish_teleport_fade_out()
		return
	_clear_teleport_visual_tween()
	teleport_visual_tween = create_tween()
	teleport_visual_tween.set_trans(Tween.TRANS_SINE)
	teleport_visual_tween.set_ease(Tween.EASE_IN)
	teleport_visual_tween.tween_property(sprite, "modulate:a", 0.0, TELEPORT_FADE_OUT_SECONDS)
	teleport_visual_tween.finished.connect(_finish_teleport_fade_out, CONNECT_ONE_SHOT)
	print("[TeleportVisual] fade-out started")


func _finish_teleport_fade_out() -> void:
	if not teleport_visual_pending:
		return
	if is_instance_valid(sprite):
		sprite.modulate.a = 0.0
	_clear_teleport_visual_tween()
	event_bus.publish(&"character.teleport_visual_ready", {"companionId": "default"})
	print("[TeleportVisual] fade-out complete")


func _finish_teleport_visual_after_canonical() -> void:
	if not teleport_visual_pending:
		return
	teleport_visual_pending = false
	event_bus.publish(&"effect.requested", {"name": "teleport_in", "source": "teleport-transition"})
	if not is_instance_valid(sprite) or not is_inside_tree():
		_finish_teleport_fade_in()
		return
	_clear_teleport_visual_tween()
	teleport_visual_tween = create_tween()
	teleport_visual_tween.set_trans(Tween.TRANS_SINE)
	teleport_visual_tween.set_ease(Tween.EASE_OUT)
	teleport_visual_tween.tween_property(sprite, "modulate:a", 1.0, TELEPORT_FADE_IN_SECONDS)
	teleport_visual_tween.finished.connect(_finish_teleport_fade_in, CONNECT_ONE_SHOT)
	print("[TeleportVisual] fade-in started canonical=teleport")


func _on_teleport_visual_cancelled(payload: Dictionary) -> void:
	if str(payload.get("companionId", "default")) != "default":
		return
	_cancel_teleport_visual_transition()


func _cancel_teleport_visual_transition() -> void:
	teleport_visual_pending = false
	_clear_teleport_visual_tween()
	if is_instance_valid(sprite):
		sprite.modulate.a = 1.0


func _finish_teleport_fade_in() -> void:
	if is_instance_valid(sprite):
		sprite.modulate.a = 1.0
	_clear_teleport_visual_tween()
	event_bus.publish(&"animation.requested", {"name": "idle", "source": "teleport-transition"})
	print("[TeleportVisual] fade-in complete -> idle")


func _clear_teleport_visual_tween() -> void:
	if is_instance_valid(teleport_visual_tween):
		teleport_visual_tween.kill()
	teleport_visual_tween = null


func _reset_physics_visual_binding() -> void:
	canonical_visual_binding.reset()
	physics_target_active = false
	physics_last_movement_state = "stationary"
	physics_last_velocity = Vector2.ZERO
	physics_last_facing = "unchanged"
	physics_last_logged_state = ""
	presentation_last_sequence = -1
	presentation_last_revision = -1
	presentation_canonical_seen = false
	presentation_drag_commit_pending = false
	presentation_drag_commit_started_ms = 0
	pending_drag_desktop_feet = Vector2.ZERO
	drag_finish_in_progress = false
	presentation_first_state_applied = false
	pending_restore_desktop_position = null
	last_presentation_state.clear()
	last_canonical_desktop_feet = Vector2.ZERO
	physics_last_sequence = -1
	physics_last_animation = &""
	drag_release_visual_deadline_ms = 0
	native_drag_visual_active = false
	last_stable_native_anchor = Vector2(-1.0, -1.0)


func accept_canonical_presentation(payload: Dictionary) -> Dictionary:
	var accepted: Dictionary = canonical_visual_binding.accept_canonical(payload)
	presentation_last_sequence = canonical_visual_binding.last_sequence
	presentation_last_revision = canonical_visual_binding.last_revision
	presentation_canonical_seen = canonical_visual_binding.canonical_seen
	presentation_drag_commit_pending = canonical_visual_binding.pending_drag_commit

	if bool(accepted.get("accepted", false)) and not presentation_drag_commit_pending:
		presentation_drag_commit_started_ms = 0
		pending_drag_desktop_feet = Vector2.ZERO

	return accepted


func accept_legacy_presentation(payload: Dictionary) -> Dictionary:
	var accepted: Dictionary = canonical_visual_binding.accept_legacy(payload)
	presentation_last_sequence = canonical_visual_binding.last_sequence
	presentation_last_revision = canonical_visual_binding.last_revision
	presentation_canonical_seen = canonical_visual_binding.canonical_seen
	return accepted


func _rejected_presentation(reason: String, payload: Dictionary) -> Dictionary:
	return {
		"accepted": false,
		"reason": reason,
		"sequence": int(payload.get("sequence", -1)),
		"revision": int(payload.get("revision", -1)),
	}


func _on_save_requested(_payload: Dictionary) -> void:
	_save_position()


func _save_position() -> void:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return
	# In native-companion mode the Godot host is deliberately kept at the
	# local origin; the native HWND owns the real desktop position. Reading
	# host.position here would therefore save the origin instead of the last
	# canonical feet position when Hide to Tray starts its disappear animation.
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		if last_canonical_desktop_feet != Vector2.ZERO:
			_save_desktop_feet(last_canonical_desktop_feet)
		return
	# User-driven drag positions are authoritative only after conversion through
	# the presentation resolver. Never persist a clamped Debug Window preview.
	var local_feet := host.position + Vector2(host.size.x * 0.5, host.size.y)
	_save_desktop_feet(_local_to_desktop(local_feet))


func _save_canonical_position() -> void:
	if last_presentation_state.is_empty():
		return
	_save_desktop_feet(last_canonical_desktop_feet)


func _save_desktop_feet(desktop_feet: Vector2) -> void:
	var settings_service: Variant = _get_service(&"settings_service")
	if settings_service == null or not settings_service.has_method(
		"save_character_desktop_position"
	):
		return

	var monitor_index: int = _monitor_index_for_desktop_point(desktop_feet)
	var scales: Array = context.monitor.get("scales", [])
	var screen_scale: float = (
		float(scales[monitor_index])
		if monitor_index >= 0 and monitor_index < scales.size()
		else 1.0
	)
	settings_service.call(
		"save_character_desktop_position",
		desktop_feet,
		monitor_index,
		screen_scale
	)


func _get_service(property_name: StringName) -> Variant:
	if services == null or not is_instance_valid(services):
		return null

	for property_info: Dictionary in services.get_property_list():
		if StringName(property_info.get("name", "")) == property_name:
			return services.get(property_name)

	return null


func _update_position_context() -> void:
	var desktop_feet: Vector2 = last_canonical_desktop_feet
	if dragging or last_presentation_state.is_empty():
		desktop_feet = _local_to_desktop(
			host.position + Vector2(host.size.x * 0.5, host.size.y)
		)
	context.update_character({
		"position": host.position,
		"desktop_position": desktop_feet,
		"presentation_mode": context.window.get("presentation_mode", "debug"),
	})


func _hit_rect() -> Rect2:
	# Use the host rectangle until V3 has a generated alpha/input mask.
	# Package hitbox coordinates are sprite-frame local and cannot be applied
	# directly to a centered AnimatedSprite2D without an origin conversion.
	return Rect2(host.position, host.size).grow(8.0)


func _clamp_to_virtual_viewport(target: Vector2) -> Vector2:
	var viewport_size: Vector2 = host.get_viewport_rect().size
	var host_size: Vector2 = host.size
	var max_position: Vector2 = Vector2(
		maxf(0.0, viewport_size.x - host_size.x),
		maxf(0.0, viewport_size.y - host_size.y)
	)
	return Vector2(
		clampf(target.x, 0.0, max_position.x),
		clampf(target.y, 0.0, max_position.y)
	)


func _snap_to_monitor() -> void:
	host.position = _snap_local_position(host.position)


func _snap_local_position(target: Vector2) -> Vector2:
	var rects: Array = context.monitor.get("local_rects", [])
	if rects.is_empty():
		return _clamp_to_virtual_viewport(target)

	var center: Vector2 = target + host.size * 0.5
	for rect_value in rects:
		var rect: Rect2 = rect_value
		if rect.has_point(center):
			return Vector2(
				clampf(target.x, rect.position.x, rect.end.x - host.size.x),
				clampf(target.y, rect.position.y, rect.end.y - host.size.y)
			)

	var nearest_rect: Rect2 = rects[0]
	var nearest_distance: float = INF
	for rect_value in rects:
		var rect: Rect2 = rect_value
		var closest := Vector2(
			clampf(center.x, rect.position.x, rect.end.x),
			clampf(center.y, rect.position.y, rect.end.y)
		)
		var distance: float = center.distance_squared_to(closest)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_rect = rect

	return Vector2(
		clampf(target.x, nearest_rect.position.x, nearest_rect.end.x - host.size.x),
		clampf(target.y, nearest_rect.position.y, nearest_rect.end.y - host.size.y)
	)



func _uses_debug_local_stage() -> bool:
	return not bool(context.runtime_config.get("overlay_enabled", false))


func _local_to_desktop(local_position: Vector2) -> Vector2:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return local_position
	return presentation_coordinate_resolver.call(
		"local_point_to_desktop",
		local_position,
		host.get_viewport_rect().size,
		bool(context.runtime_config.get("overlay_enabled", false))
	)


func _desktop_to_local(desktop_position: Vector2) -> Vector2:
	if not is_instance_valid(host):
		return desktop_position
	return presentation_coordinate_resolver.call(
		"desktop_point_to_local",
		desktop_position,
		host.get_viewport_rect().size,
		bool(context.runtime_config.get("overlay_enabled", false))
	)
func _monitor_index_for_desktop_point(point: Vector2) -> int:
	var rects: Array = context.monitor.get("rects", [])
	for index in range(rects.size()):
		if Rect2(rects[index]).has_point(point):
			return index

	var nearest_index: int = 0
	var nearest_distance: float = INF
	for index in range(rects.size()):
		var rect := Rect2(rects[index])
		var closest := Vector2(
			clampf(point.x, rect.position.x, rect.end.x),
			clampf(point.y, rect.position.y, rect.end.y)
		)
		var distance := point.distance_squared_to(closest)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = index
	return nearest_index


func _render_deferred_probe(reason: String) -> void:
	if not render_debug_enabled:
		return
	await get_tree().process_frame
	_render_log("deferred-probe", {
		"reason": reason,
		"snapshot": _render_snapshot(),
	})


func _render_snapshot() -> Dictionary:
	var result: Dictionary = {
		"sequence": render_debug_last_sequence,
		"host_valid": is_instance_valid(host),
		"sprite_valid": is_instance_valid(sprite),
		"overlay_enabled": context.runtime_config.get("overlay_enabled", false) if context != null else null,
	}
	if is_instance_valid(host):
		result.merge({
			"host_position": host.position,
			"host_global_position": host.global_position,
			"host_size": host.size,
			"host_visible": host.visible,
			"host_modulate_alpha": host.modulate.a,
			"host_inside_tree": host.is_inside_tree(),
			"host_process_mode": host.process_mode,
			"host_z_index": host.z_index,
			"viewport_size": host.get_viewport_rect().size,
			"host_rect": Rect2(host.position, host.size),
		}, true)
	if is_instance_valid(sprite):
		result.merge({
			"sprite_visible": sprite.visible,
			"sprite_modulate_alpha": sprite.modulate.a,
			"sprite_position": sprite.position,
			"sprite_global_position": sprite.global_position,
			"sprite_scale": sprite.scale,
			"sprite_centered": sprite.centered,
			"sprite_offset": sprite.offset,
			"sprite_flip_h": sprite.flip_h,
			"sprite_animation": sprite.animation,
			"sprite_frame": sprite.frame,
			"sprite_playing": sprite.is_playing(),
			"sprite_z_index": sprite.z_index,
			"sprite_inside_tree": sprite.is_inside_tree(),
			"frames_valid": sprite.sprite_frames != null,
		}, true)
	return result


func _render_log(phase: String, data: Dictionary = {}) -> void:
	if not render_debug_enabled:
		return
	print("[render-debug] phase=", phase, " data=", JSON.stringify(data))


func _env_flag(name: String) -> bool:
	var value: String = OS.get_environment(name).strip_edges().to_lower()
	return value in ["1", "true", "yes", "on"]
