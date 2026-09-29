extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3WindowController

const DEBUG_CANVAS_SIZE := Vector2i(1280, 800)

var window: Window
var presentation_mode: StringName = &"unbound"
var overlay_rect: Rect2i = Rect2i()
var mode_revision: int = 0


func bind_window(target: Window) -> void:
	window = target


func start() -> void:
	event_bus.subscribe(&"monitor.topology_changed", Callable(self, "_on_topology_changed"))
	event_bus.subscribe(&"window.overlay_screen_requested", Callable(self, "_on_overlay_screen_requested"))
	event_bus.subscribe(&"window.virtual_overlay_requested", Callable(self, "_on_virtual_overlay_requested"))
	event_bus.subscribe(&"window.hide_to_tray_requested", Callable(self, "_on_hide_requested"))
	event_bus.subscribe(&"window.restore_requested", Callable(self, "_on_restore_requested"))
	event_bus.subscribe(&"window.exit_requested", Callable(self, "_on_exit_requested"))


func stop() -> void:
	event_bus.unsubscribe(&"monitor.topology_changed", Callable(self, "_on_topology_changed"))
	event_bus.unsubscribe(&"window.overlay_screen_requested", Callable(self, "_on_overlay_screen_requested"))
	event_bus.unsubscribe(&"window.virtual_overlay_requested", Callable(self, "_on_virtual_overlay_requested"))
	event_bus.unsubscribe(&"window.hide_to_tray_requested", Callable(self, "_on_hide_requested"))
	event_bus.unsubscribe(&"window.restore_requested", Callable(self, "_on_restore_requested"))
	event_bus.unsubscribe(&"window.exit_requested", Callable(self, "_on_exit_requested"))


func apply_debug_window() -> void:
	if not is_instance_valid(window):
		return

	_set_overlay_enabled(false)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	window.borderless = false
	window.transparent = false
	window.always_on_top = false
	window.unresizable = false
	window.size = DEBUG_CANVAS_SIZE
	# Debug mode intentionally keeps a fixed logical presentation canvas.
	window.content_scale_size = DEBUG_CANVAS_SIZE

	presentation_mode = &"debug"
	overlay_rect = Rect2i()
	mode_revision += 1
	context.update_window({
		"presentation_mode": "debug",
		"overlay_rect": Rect2i(),
		"transparent": false,
		"always_on_top": false,
		"mode_revision": mode_revision,
	})
	call_deferred("_publish_presentation_mode")


func apply_overlay_window() -> void:
	if not is_instance_valid(window):
		return

	_set_overlay_enabled(true)

	var physical_virtual_rect: Rect2i = _physical_virtual_rect()
	if physical_virtual_rect.size == Vector2i.ZERO:
		return

	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	window.borderless = true
	window.transparent = true
	window.always_on_top = true
	window.unresizable = true
	window.position = physical_virtual_rect.position
	window.size = physical_virtual_rect.size
	window.content_scale_size = presentation_canvas_size(
		&"overlay",
		physical_virtual_rect
	)
	print(
		(
			"[presentation-geometry] physical_rect=%s "
			+ "window_position=%s window_size=%s content_scale=%s"
		) % [
			_physical_virtual_rect(),
			window.position,
			window.size,
			window.content_scale_size,
		]
	)

	presentation_mode = &"overlay"
	overlay_rect = physical_virtual_rect
	mode_revision += 1
	context.update_window({
		"presentation_mode": "overlay",
		"overlay_rect": physical_virtual_rect,
		"overlay_screen": -1,
		"overlay_scope": "virtual",
		"transparent": true,
		"always_on_top": true,
		"mode_revision": mode_revision,
	})
	call_deferred("_publish_presentation_mode")


func apply_native_companion_window() -> void:
	if not is_instance_valid(window):
		return

	# The native host owns the outer HWND placement. Godot keeps only a small
	# transparent render client; no virtual-desktop geometry is applied here.
	_set_overlay_enabled(false)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	window.borderless = true
	window.transparent = true
	window.always_on_top = true
	window.unresizable = true
	var configured_size := int(OS.get_environment("OCP_NATIVE_HOST_SIZE"))
	if configured_size < 128 or configured_size > 768:
		configured_size = int(context.character.get("render_size", Vector2i(256, 256)).x)
	var canvas_policy := native_canvas_policy(configured_size)
	configured_size = int(canvas_policy.get("size", Vector2i(256, 256)).x)
	# The Win32 host keeps one fixed physical HWND size across monitors. Godot
	# can still change the root viewport's logical size when that top-level HWND
	# crosses a DPI boundary unless content scaling is explicitly enabled.
	# Keep the authored companion canvas stable and let Godot map it onto the
	# externally-owned client rect. This prevents 384 -> 768 viewport growth,
	# half-sized rendering, displaced hitboxes and feet floating above rcWork.
	window.content_scale_mode = int(canvas_policy.get(
		"mode", Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	))
	window.content_scale_aspect = int(canvas_policy.get(
		"aspect", Window.CONTENT_SCALE_ASPECT_IGNORE
	))
	window.size = Vector2i(configured_size, configured_size)
	window.content_scale_size = Vector2i(configured_size, configured_size)
	window.position = Vector2i(0, 0)
	_enforce_transparent_render_surface()

	presentation_mode = &"native-companion"
	overlay_rect = Rect2i()
	mode_revision += 1
	context.update_window({
		"presentation_mode": "native-companion",
		"overlay_rect": Rect2i(),
		"overlay_screen": -1,
		"overlay_scope": "native-host",
		"transparent": true,
		"always_on_top": true,
		"mode_revision": mode_revision,
	})
	print("[presentation-geometry] native-companion render_client=(%d,%d) native_host_owner=true" % [configured_size, configured_size])
	call_deferred("_publish_presentation_mode")


func native_canvas_policy(configured_size: int) -> Dictionary:
	var safe_size := clampi(configured_size, 128, 768)
	return {
		"mode": Window.CONTENT_SCALE_MODE_CANVAS_ITEMS,
		# The native host can be transiently non-square during WM_DPICHANGED.
		# IGNORE fills that surface instead of exposing opaque letterbox bars;
		# the controller restores the square PMv2 extent in the same handoff.
		"aspect": Window.CONTENT_SCALE_ASPECT_IGNORE,
		"size": Vector2i(safe_size, safe_size),
	}


func _enforce_transparent_render_surface() -> void:
	# Native adoption/restore can recreate the Windows swap-chain surface. Keep
	# both Godot's viewport and renderer clear color transparent so the surface
	# cannot fall back to a solid chroma/pink client background.
	var viewport := get_viewport()
	if viewport != null:
		viewport.transparent_bg = true
	RenderingServer.set_default_clear_color(Color(0.0, 0.0, 0.0, 0.0))


func apply_monitor_overlay(screen_index: int, rect: Rect2i) -> void:
	if not is_instance_valid(window) or rect.size == Vector2i.ZERO:
		return
	_set_overlay_enabled(true)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	window.borderless = true
	window.transparent = true
	window.always_on_top = true
	window.unresizable = true
	window.position = rect.position
	window.size = rect.size
	window.content_scale_size = rect.size
	presentation_mode = &"overlay"
	overlay_rect = rect
	mode_revision += 1
	context.update_window({
		"presentation_mode": "overlay",
		"overlay_rect": rect,
		"overlay_screen": screen_index,
		"overlay_scope": "monitor",
		"mode_revision": mode_revision,
	})
	print(
		"[presentation-geometry] scope=monitor screen=%d rect=%s viewport=%s"
		% [screen_index, rect, window.content_scale_size]
	)
	call_deferred("_publish_presentation_mode")


func presentation_canvas_size(
	mode: StringName,
	physical_overlay_rect: Rect2i
) -> Vector2i:
	if mode == &"overlay" and physical_overlay_rect.size != Vector2i.ZERO:
		return physical_overlay_rect.size
	return DEBUG_CANVAS_SIZE


func _set_overlay_enabled(enabled: bool) -> void:
	if context == null:
		return
	context.runtime_config["overlay_enabled"] = enabled
	context.update_window({
		"overlay_enabled": enabled,
	})


func _physical_virtual_rect() -> Rect2i:
	var count: int = DisplayServer.get_screen_count()
	if count <= 0:
		return Rect2i()

	var result := Rect2i(
		DisplayServer.screen_get_position(0),
		DisplayServer.screen_get_size(0)
	)
	for index in range(1, count):
		result = result.merge(Rect2i(
			DisplayServer.screen_get_position(index),
			DisplayServer.screen_get_size(index)
		))
	return result


func _publish_presentation_mode() -> void:
	event_bus.publish(&"window.presentation_mode_applied", {
		"mode": String(presentation_mode),
		"overlayEnabled": presentation_mode == &"overlay",
		"overlayRect": overlay_rect,
		"revision": mode_revision,
		"windowPosition": window.position if is_instance_valid(window) else Vector2i.ZERO,
		"windowSize": window.size if is_instance_valid(window) else Vector2i.ZERO,
		"contentScaleSize": window.content_scale_size if is_instance_valid(window) else Vector2i.ZERO,
	})


func hide_to_tray() -> void:
	if not is_instance_valid(window):
		return

	event_bus.publish(&"quick_panel.close_requested", {})
	event_bus.publish(&"character_picker.close_requested", {})
	event_bus.publish(&"character.position_save_requested", {})
	event_bus.publish(&"character.disappear_requested", {})
	# Let the one-shot disappear animation render before minimizing the main
	# window. If the scene is shutting down, the short delay is harmless.
	await get_tree().create_timer(0.35).timeout

	# In native-companion mode the Win32 host owns visibility. Minimizing the
	# embedded Godot child breaks tray restore because it is no longer an
	# independent top-level window. Keep the render child alive and let
	# NativeHostLifecycle hide the host after this event is published.
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	context.update_window({"hidden_to_tray": true})
	state_machine.transition(&"hidden_to_tray", {}, true)
	event_bus.publish(&"window.hidden_to_tray", {})


func restore() -> void:
	if not is_instance_valid(window):
		return

	var native_enabled := bool(context.runtime_config.get("native_presentation_enabled", false))
	if not native_enabled:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if native_enabled:
		# Native Host already owns the controller HWND and its canonical desktop
		# placement. Reapplying the startup profile here resets Godot's render
		# HWND to (0,0), which is visible for a frame before native reconciliation.
		# Restore only needs the transparent renderer contract, not a new position.
		_enforce_transparent_render_surface()
	elif bool(context.runtime_config.get("overlay_enabled", false)):
		apply_overlay_window()
	else:
		apply_debug_window()

	# Godot 4.7 deprecates move_to_foreground().
	window.grab_focus()
	context.update_window({"hidden_to_tray": false})
	state_machine.transition(&"ready", {}, true)
	event_bus.publish(&"character.appear_requested", {})
	event_bus.publish(&"window.restored", {})


func _on_hide_requested(_payload: Dictionary) -> void:
	hide_to_tray()


func _on_restore_requested(_payload: Dictionary) -> void:
	restore()


func _on_exit_requested(_payload: Dictionary) -> void:
	event_bus.publish(&"system.shutting_down", {})
	# The native host keeps synchronizing the adopted Godot HWND while it owns
	# presentation. Destroying that HWND immediately races Win32 SetWindowPos
	# calls and can terminate Godot with 0xC0000005. NativeHostLifecycle turns
	# system.shutting_down into the existing detach/exit-ready handshake and
	# quits the SceneTree only after the host acknowledges host-closed.
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	get_tree().quit()


func _on_topology_changed(_payload: Dictionary) -> void:
	if bool(context.runtime_config.get("overlay_enabled", false)) \
	and not bool(context.window.get("hidden_to_tray", false)):
		apply_overlay_window()


func _on_overlay_screen_requested(payload: Dictionary) -> void:
	apply_monitor_overlay(
		int(payload.get("screen", -1)),
		payload.get("physicalRect", Rect2i())
	)


func _on_virtual_overlay_requested(_payload: Dictionary) -> void:
	apply_overlay_window()
	context.update_window({
		"overlay_screen": -1,
		"overlay_scope": "virtual",
	})
