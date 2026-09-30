extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3NativeHostLifecycle
## Opt-in production adapter for one native companion host.
##
## Native owns HWND placement and top-level render-surface adoption. This service only exchanges the
## handoff/render lifecycle and never commits canonical physics positions.

const COMPANION_ID := "default"
const DEFAULT_CLIENT_SIZE := Vector2i(256, 256)

var window: Window
var bridge: Node
var coordinator: Node
var handoff_path := ""
var event_path := ""
var command_path := ""
var ui_command_path := ""
var bubble_path := ""
var host_token := ""
var started_at := 0
var ready_written := false
var attached := false
var exit_ready := false
var shutdown_requested := false
var native_dragging := false
var last_physics_sequence := -1
var last_native_event_sequence := -1
var last_bubble_sequence := 0
var latest_presentation_state: Dictionary = {}
var pending_bubble_payload: Dictionary = {}
var pending_native_hitbox: Rect2 = Rect2()
var pending_native_anchor: Vector2 = Vector2(0.5, 1.0)
var native_visibility_generation := 0
var native_visibility_desired := true
var chat_focus_active := false
var shell_companion_suppressed := false
var runtime_window_hidden := false
var presentation_suppressed_published := false
var shell_launch_hide_nonce := 0


func client_size() -> Vector2i:
	var configured := int(OS.get_environment("OCP_NATIVE_HOST_SIZE"))
	if configured <= 0 and context != null:
		var package_size: Vector2i = context.character.get("render_size", Vector2i.ZERO)
		configured = package_size.x
	if configured >= 128 and configured <= 768:
		return Vector2i(configured, configured)
	return DEFAULT_CLIENT_SIZE


func bind_window(target: Window) -> void:
	window = target


func bind_bridge(target: Node) -> void:
	bridge = target


func bind_coordinator(target: Node) -> void:
	coordinator = target


func start() -> void:
	event_bus.subscribe(&"character.presentation_state", Callable(self, "_on_presentation_state"))
	event_bus.subscribe(&"character.physics_moved", Callable(self, "_on_presentation_state"))
	event_bus.subscribe(&"bubble.requested", Callable(self, "_on_bubble_requested"))
	event_bus.subscribe(&"character.native_hitbox_changed", Callable(self, "_on_native_hitbox_changed"))
	event_bus.subscribe(&"character.native_anchor_changed", Callable(self, "_on_native_anchor_changed"))
	event_bus.subscribe(&"character.presentation_scale_applied", Callable(self, "_on_presentation_scale_applied"))
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.subscribe(&"theme.changed", Callable(self, "_on_theme_changed"))
	event_bus.subscribe(&"character.hover_entered", Callable(self, "_on_native_hover_entered"))
	event_bus.subscribe(&"character.hover_exited", Callable(self, "_on_native_hover_exited"))
	event_bus.subscribe(&"sound.master_changed", Callable(self, "_on_master_sound_changed"))
	event_bus.subscribe(&"sound.sfx_changed", Callable(self, "_on_sfx_changed"))
	event_bus.subscribe(&"window.hidden_to_tray", Callable(self, "_on_window_hidden"))
	event_bus.subscribe(&"window.restored", Callable(self, "_on_window_restored"))
	event_bus.subscribe(&"system.shutting_down", Callable(self, "_on_shutdown_requested"))
	set_process(false)


func stop() -> void:
	event_bus.unsubscribe(&"character.presentation_state", Callable(self, "_on_presentation_state"))
	event_bus.unsubscribe(&"character.physics_moved", Callable(self, "_on_presentation_state"))
	event_bus.unsubscribe(&"bubble.requested", Callable(self, "_on_bubble_requested"))
	event_bus.unsubscribe(&"character.native_hitbox_changed", Callable(self, "_on_native_hitbox_changed"))
	event_bus.unsubscribe(&"character.native_anchor_changed", Callable(self, "_on_native_anchor_changed"))
	event_bus.unsubscribe(&"character.presentation_scale_applied", Callable(self, "_on_presentation_scale_applied"))
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_loaded"))
	event_bus.unsubscribe(&"theme.changed", Callable(self, "_on_theme_changed"))
	event_bus.unsubscribe(&"character.hover_entered", Callable(self, "_on_native_hover_entered"))
	event_bus.unsubscribe(&"character.hover_exited", Callable(self, "_on_native_hover_exited"))
	event_bus.unsubscribe(&"sound.master_changed", Callable(self, "_on_master_sound_changed"))
	event_bus.unsubscribe(&"sound.sfx_changed", Callable(self, "_on_sfx_changed"))
	event_bus.unsubscribe(&"window.hidden_to_tray", Callable(self, "_on_window_hidden"))
	event_bus.unsubscribe(&"window.restored", Callable(self, "_on_window_restored"))
	event_bus.unsubscribe(&"system.shutting_down", Callable(self, "_on_shutdown_requested"))
	set_process(false)


func arm() -> void:
	handoff_path = OS.get_environment("OCP_NATIVE_HOST_HANDOFF_PATH")
	event_path = OS.get_environment("OCP_NATIVE_HOST_EVENT_PATH")
	command_path = OS.get_environment("OCP_NATIVE_HOST_COMMAND_PATH")
	ui_command_path = OS.get_environment("OCP_NATIVE_HOST_UI_COMMAND_PATH")
	bubble_path = OS.get_environment("OCP_NATIVE_HOST_BUBBLE_PATH")
	host_token = OS.get_environment("OCP_NATIVE_HOST_TOKEN")
	if handoff_path.is_empty() or host_token.is_empty() or not is_instance_valid(window):
		push_error("[NativeHostLifecycle] production native host environment is incomplete")
		return
	started_at = Time.get_ticks_msec()
	set_process(true)
	call_deferred("_write_godot_ready")
	if not pending_bubble_payload.is_empty():
		if not chat_focus_active:
			call_deferred("_on_bubble_requested", pending_bubble_payload.duplicate(true))
		else:
			pending_bubble_payload = {}
	if pending_native_hitbox.size != Vector2.ZERO:
		call_deferred("_on_native_hitbox_changed", {"normalized_hitbox": pending_native_hitbox})
	call_deferred("_on_native_anchor_changed", {"normalized_anchor": pending_native_anchor})
	call_deferred("_on_theme_changed", {
		"name": str(context.runtime_config.get("theme_preset", "solid")),
	})
	call_deferred("_send_sound_state")


func _process(_delta: float) -> void:
	var payload := _read_handoff()
	if payload.is_empty() or str(payload.get("token", "")) != host_token:
		_check_timeout()
		return
	var status := str(payload.get("status", ""))
	if status == "embedded" and not attached:
		_on_embedded()
	elif status == "detached" and attached and not exit_ready:
		_on_detached()
	elif status == "host-closed" and exit_ready:
		print("[NativeHostLifecycle] host-closed physics_committed=false")
		set_process(false)
		# Do not quit the SceneTree directly here. RuntimeApp owns service/controller
		# teardown while the tree is still alive; quitting first defers cleanup to
		# _exit_tree(), after child services may already have begun destruction.
		# That ordering left preview Threads/SpriteFrames alive at process exit.
		if is_instance_valid(event_bus):
			event_bus.publish(&"system.exit_ready", {})
		else:
			get_tree().quit(0)
	_process_native_event()
	_check_timeout()


func _write_godot_ready() -> void:
	if ready_written or not is_instance_valid(window):
		return
	var hwnd := int(DisplayServer.window_get_native_handle(
		DisplayServer.WINDOW_HANDLE,
		window.get_window_id()
	))
	if hwnd == 0:
		push_error("[NativeHostLifecycle] Godot HWND unavailable")
		get_tree().quit(81)
		return
	_write_status({
		"status": "godot-ready",
		"token": host_token,
		"godot_hwnd": hwnd,
		"companion_id": COMPANION_ID,
		"physics_committed": false,
	})
	ready_written = true
	# Do not toggle visibility on Godot's main window here. Godot 4 rejects changing
	# visibility for the main window after startup (and reports window.cpp:1017).
	# Godot remains the visible top-level transparent surface. The native adapter
	# adopts its HWND and becomes the sole placement/input authority without
	# changing the window into an opaque child.
	print("[NativeHostLifecycle] godot-ready companion=default physics_committed=false")


func _on_embedded() -> void:
	if not is_instance_valid(bridge) or not bridge.call("attach_render_surface", COMPANION_ID, host_token):
		push_error("[NativeHostLifecycle] render host attach rejected")
		get_tree().quit(82)
		return
	if coordinator != null and not coordinator.accept_attached(COMPANION_ID):
		push_error("[NativeHostLifecycle] attach acknowledgement rejected")
		get_tree().quit(83)
		return
	var render_size := client_size()
	if not bridge.call("set_render_client_size", render_size.x, render_size.y):
		push_error("[NativeHostLifecycle] render host resize rejected")
		get_tree().quit(84)
		return
	attached = true
	started_at = 0
	print("[NativeHostLifecycle] surface-adopted companion=default client_size=(%d,%d) top_level=true physics_committed=false" % [render_size.x, render_size.y])
	# The first canonical physics update can arrive before the native HWND has
	# attached. Replay it now.  This first move is also the native host's reveal
	# gate, so the user never sees the temporary (0,0) Godot rectangle.
	var initial_state := _canonical_presentation_state(latest_presentation_state)
	if not initial_state.is_empty():
		print("[NativeHostLifecycle] startup-reposition canonical=true")
		_on_presentation_state(initial_state)
	else:
		print("[NativeHostLifecycle] startup-reposition canonical=false reason=no-cached-presentation")
	_write_update_health_marker("native-surface-adopted")
	# Theme selection can be loaded before the native command channel exists.
	# Replay it after the surface is embedded so restart cannot reset the native
	# hover menu to Solid while the application window keeps the saved preset.
	_on_theme_changed({
		"name": str(context.runtime_config.get("theme_preset", "solid")),
	})
	print("[NativeHostLifecycle] theme-replay after=native-surface-adopted name=%s" % str(context.runtime_config.get("theme_preset", "solid")))
	if chat_focus_active or runtime_window_hidden:
		_write_native_visibility_request(false)
	if OS.get_environment("OCP_NATIVE_SPIKE_SMOKE").strip_edges() in ["1", "true", "yes", "on"]:
		request_detach_for_shutdown()
	elif shutdown_requested:
		request_detach_for_shutdown()


func _on_shutdown_requested(_payload: Dictionary) -> void:
	if shutdown_requested or exit_ready:
		return
	shutdown_requested = true
	if attached:
		request_detach_for_shutdown()


func request_detach_for_shutdown() -> void:
	if handoff_path.is_empty() or host_token.is_empty():
		return
	_write_status({
		"status": "detach-request",
		"token": host_token,
		"companion_id": COMPANION_ID,
		"physics_committed": false,
	})
	print("[NativeHostLifecycle] shutdown-requested companion=default physics_committed=false")


func _on_detached() -> void:
	if not is_instance_valid(bridge) or not bridge.call("detach_render_surface", COMPANION_ID):
		push_error("[NativeHostLifecycle] render host detach rejected")
		get_tree().quit(85)
		return
	if coordinator != null and coordinator.state_name() != "detached":
		push_error("[NativeHostLifecycle] detach acknowledgement rejected")
		get_tree().quit(86)
		return
	exit_ready = true
	print("[NativeHostLifecycle] detached companion=default physics_committed=false")
	_write_status({
		"status": "godot-exit-ready",
		"token": host_token,
		"companion_id": COMPANION_ID,
		"physics_committed": false,
	})


func _on_presentation_state(payload: Dictionary) -> void:
	var canonical := _canonical_presentation_state(payload)
	if canonical.is_empty():
		return
	latest_presentation_state = canonical
	if not attached or native_dragging or command_path.is_empty():
		return
	var sequence := int(canonical.get("sequence", -1))
	if sequence >= 0 and sequence == last_physics_sequence:
		return
	if sequence >= 0:
		last_physics_sequence = sequence
	var feet: Vector2 = canonical.get("desktopFeet", Vector2.ZERO)
	if feet == Vector2.ZERO:
		return
	_write_command({
		"status": "move-request",
		"token": host_token,
		"companion_id": COMPANION_ID,
		"sequence": sequence,
		"desktop_feet": [feet.x, feet.y],
		"movement_state": str(canonical.get("movementState", "")),
		"attachment_state": str(canonical.get("attachmentState", "")),
		"surface_kind": str(canonical.get("surfaceKind", "")),
		"physics_committed": false,
	})


func _process_native_event() -> void:
	if event_path.is_empty() or not FileAccess.file_exists(event_path):
		return
	var file := FileAccess.open(event_path, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary or str(parsed.get("token", "")) != host_token:
		return
	var sequence := int(parsed.get("sequence", -1))
	if sequence >= 0 and sequence == last_native_event_sequence:
		return
	if sequence >= 0:
		last_native_event_sequence = sequence
	var status := str(parsed.get("status", ""))
	if status == "drag-begin":
		native_dragging = true
		event_bus.publish(&"character.drag_started", {"source": "native-host"})
		print("[NativeHostLifecycle] drag-begin source=native-host physics_committed=false")
	elif status == "drag-probe":
		# Native host events are published through a latest-value handoff file.
		# A fast first WM_MOUSEMOVE can replace `drag-begin` before Runtime's next
		# process tick. Treat the first observed probe as an implicit begin so Drag
		# Hold/predictive preload cannot be skipped merely because that edge event
		# was coalesced by the transport.
		if not native_dragging:
			native_dragging = true
			event_bus.publish(&"character.drag_started", {
				"source": "native-host",
				"recoveredFromProbe": true,
			})
			print("[NativeHostLifecycle] drag-begin recovered=drag-probe physics_committed=false")
		var probe_feet := Vector2(
			float(parsed.get("desktop_feet_x", 0.0)),
			float(parsed.get("desktop_feet_y", 0.0))
		)
		event_bus.publish(&"character.drag_probe", {
			"source": "native-host",
			"desktopFeet": probe_feet,
		})
	elif status == "startup-repositioned":
		event_bus.publish(&"character.native_surface_ready", {
			"source": "native-startup-repositioned",
		})
		print("[NativeHostLifecycle] startup-character-revealed after=native-placement-ack")
	elif status == "drag-end":
		native_dragging = false
		var feet := Vector2(float(parsed.get("desktop_feet_x", 0.0)), float(parsed.get("desktop_feet_y", 0.0)))
		event_bus.publish(&"character.drag_finished", {
			"source": "native-host",
			"desktopFeet": feet,
		})
		var committed := false
		if is_instance_valid(bridge) and bridge.has_method("commit_companion_position"):
			committed = bool(bridge.call("commit_companion_position", COMPANION_ID, feet.x, feet.y))
		print("[NativeHostLifecycle] drag-end desktop_feet=%s committed=%s physics_committed=%s" % [feet, committed, committed])
	elif status == "hover-enter":
		event_bus.publish(&"character.hover_entered", {"source": "native-host"})
	elif status == "hover-leave":
		event_bus.publish(&"character.hover_exited", {"source": "native-host"})
	elif status == "menu-click":
		var menu_item := str(parsed.get("item", ""))
		print("[NativeHostLifecycle] menu-click item=%s" % menu_item)
		_handle_native_menu_item(menu_item)
	elif status == "submenu-click":
		var submenu_item := str(parsed.get("item", ""))
		if submenu_item in ["size-25", "size-50", "size-75", "size-100", "size-125"]:
			var presentation_scale: float = float({
				"size-25": 0.25,
				"size-50": 0.50,
				"size-75": 0.75,
				"size-100": 1.00,
				"size-125": 1.25,
			}.get(submenu_item, 0.0))
			event_bus.publish(&"character.presentation_scale_requested", {
				"scale": presentation_scale,
				"source": "native-size-submenu",
			})
		elif submenu_item in ["idle", "wave", "think", "sit"]:
			event_bus.publish(&"animation.requested", {"name": submenu_item, "source": "native-submenu"})
		elif submenu_item == "sound-master-toggle":
			event_bus.publish(&"sound.master_toggle_requested", {"source": "native-sound-submenu"})
		elif submenu_item == "sound-sfx-toggle":
			event_bus.publish(&"sound.sfx_toggle_requested", {"source": "native-sound-submenu"})
		event_bus.publish(&"native_menu.submenu_item_requested", {"item": submenu_item})
	elif status == "menu-submenu":
		event_bus.publish(&"native_menu.submenu_opened", {"source": "native-host"})
	elif status == "character-select":
		var selected := str(parsed.get("item", ""))
		if selected in ["character.meowsom", "character.scifi_woman", "character.bible"]:
			event_bus.publish(&"character_picker.native_select_requested", {
				"package_id": selected,
				"source": "native-picker",
			})


func _prehide_native_for_shell_launch(source: String) -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	shell_launch_hide_nonce += 1
	var nonce := shell_launch_hide_nonce
	# Native Hover-menu actions originate inside Runtime, so hide immediately
	# here instead of waiting for Electron -> file bridge -> Runtime round-trip.
	_write_native_visibility_request(false)
	print("[NativeHostLifecycle] shell-launch-prehide source=%s" % source)
	get_tree().create_timer(2.0).timeout.connect(func() -> void:
		if nonce != shell_launch_hide_nonce:
			return
		if chat_focus_active or shell_companion_suppressed or runtime_window_hidden:
			return
		# Launcher failed or never established ownership: recover visibility.
		_write_native_visibility_request(true)
		print("[NativeHostLifecycle] shell-launch-prehide-recovered source=%s" % source)
	)


func _handle_native_menu_item(item: String) -> void:
	match item:
		"chat":
			_prehide_native_for_shell_launch("chat")
			# Chat is an independent native window.
			event_bus.publish(&"chat_window.open_requested", {
				"source": "native-menu-chat",
			})
		"settings", "open-ocp":
			_prehide_native_for_shell_launch("settings")
			# `open-ocp` remains accepted for compatibility with an older native
			# host, while the production Hover menu now names the action Settings.
			event_bus.publish(&"application_window.open_requested", {
				"page": "settings",
				"source": "native-menu",
			})
		"wave":
			event_bus.publish(&"animation.requested", {"name": "wave", "source": "native-menu"})
		"bubble":
			event_bus.publish(&"bubble.requested", {"text": "Runtime V3 bubble test", "source": "native-menu"})
		"change-character":
			_prehide_native_for_shell_launch("characters")
			# Native hover UI only launches package management. The separate
			# Character Manager owns install, activation, and uninstall workflows.
			event_bus.publish(&"character_picker.open_requested", {"source": "native-menu"})
		"hide-to-tray":
			event_bus.publish(&"window.hide_to_tray_requested", {"source": "native-menu"})
		"exit":
			event_bus.publish(&"window.exit_requested", {"source": "native-menu"})


func _on_window_hidden(_payload: Dictionary) -> void:
	runtime_window_hidden = true
	# Write native visibility first. Presentation suppression can synchronously
	# release large effect atlases, so publishing it before the IPC write makes
	# the user wait for cleanup before the companion disappears.
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		_write_native_visibility_request(false)
	_publish_presentation_suppressed_state("window-hidden")


func _on_window_restored(_payload: Dictionary) -> void:
	runtime_window_hidden = false
	if chat_focus_active:
		_publish_presentation_suppressed_state("window-restored")
		return
	# Queue native restore/show before publishing unsuppression. Effect restore
	# may decode/rebuild large atlases; the native host should receive the visual
	# restore command immediately instead of waiting behind that work.
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		var visibility_generation := _next_native_visibility_generation(true)
		# Restore is one native command, not a visible-then-move sequence. The
		# native host keeps both HWNDs hidden, restores canonical placement, then
		# reveals them together. This prevents a one-frame flash at Windows'
		# temporary restore position.
		var restore_payload := _restore_request_payload()
		if not restore_payload.is_empty():
			restore_payload["visibility_generation"] = visibility_generation
			restore_payload["visibility_desired"] = true
			print("[NativeHostLifecycle] restore-request canonical=true visibility_generation=%d" % visibility_generation)
			_write_command(restore_payload)
		else:
			print("[NativeHostLifecycle] restore-request canonical=false reason=no-cached-presentation visibility_generation=%d" % visibility_generation)
			_write_ui_command({
				"status": "visibility-request",
				"token": host_token,
				"sequence": visibility_generation,
				"visible": true,
				"physics_committed": false,
			})
	_publish_presentation_suppressed_state("window-restored")


func set_chat_focus_active(active: bool) -> void:
	if chat_focus_active == active:
		return
	chat_focus_active = active
	shell_launch_hide_nonce += 1
	if active:
		pending_bubble_payload = {}
		# Hide first, then let subscribers do heavier presentation cleanup.
		if bool(context.runtime_config.get("native_presentation_enabled", false)):
			_write_native_visibility_request(false)
		_publish_presentation_suppressed_state("chat-focus")
		return
	if not runtime_window_hidden and not shell_companion_suppressed:
		# Chat never moves the native companion; closing Chat only needs to reveal
		# the already-committed native presentation. Avoid the full canonical
		# restore/reposition path here because it is materially slower and can race
		# with an in-flight AI turn or preview update.
		if bool(context.runtime_config.get("native_presentation_enabled", false)):
			_write_native_visibility_request(true)
		_publish_presentation_suppressed_state("chat-focus")
		print("[NativeHostLifecycle] chat-focus restore visibility-only=true")
	else:
		_publish_presentation_suppressed_state("chat-focus")


func set_shell_companion_suppressed(active: bool) -> void:
	if shell_companion_suppressed == active:
		return
	shell_companion_suppressed = active
	shell_launch_hide_nonce += 1
	if active:
		pending_bubble_payload = {}
		if bool(context.runtime_config.get("native_presentation_enabled", false)):
			_write_native_visibility_request(false)
		_publish_presentation_suppressed_state("character-manager")
		print("[NativeHostLifecycle] shell-safe-zone suppressed=true source=character-manager")
		return
	if not runtime_window_hidden and not chat_focus_active:
		print("[NativeHostLifecycle] shell-safe-zone suppressed=false source=character-manager")
		_on_window_restored({"source": "desktop-shell-character-manager"})
	else:
		_publish_presentation_suppressed_state("character-manager")


func _publish_presentation_suppressed_state(source: String) -> void:
	var suppressed := runtime_window_hidden or chat_focus_active or shell_companion_suppressed
	if presentation_suppressed_published == suppressed:
		return
	presentation_suppressed_published = suppressed
	if is_instance_valid(event_bus):
		event_bus.publish(&"companion.presentation_suppressed_changed", {
			"suppressed": suppressed,
			"source": source,
		})


func _write_native_visibility_request(visible: bool) -> void:
	var visibility_generation := _next_native_visibility_generation(visible)
	_write_ui_command({
		"status": "visibility-request",
		"token": host_token,
		"sequence": visibility_generation,
		"visible": visible,
		"physics_committed": false,
	})


func _next_native_visibility_generation(visible: bool) -> int:
	native_visibility_desired = visible
	native_visibility_generation = maxi(
		native_visibility_generation + 1,
		Time.get_ticks_msec()
	)
	return native_visibility_generation


func _restore_request_payload() -> Dictionary:
	var canonical := _canonical_presentation_state(latest_presentation_state)
	if canonical.is_empty():
		return {}
	var feet: Vector2 = canonical.get("desktopFeet", Vector2.ZERO)
	if feet == Vector2.ZERO:
		return {}
	return {
		"status": "restore-request",
		"token": host_token,
		"companion_id": COMPANION_ID,
		"sequence": Time.get_ticks_msec(),
		"desktop_feet": [feet.x, feet.y],
		"movement_state": str(canonical.get("movementState", "")),
		"attachment_state": str(canonical.get("attachmentState", "")),
		"surface_kind": str(canonical.get("surfaceKind", "")),
		"physics_committed": false,
	}


func _canonical_presentation_state(payload: Dictionary) -> Dictionary:
	if payload.is_empty():
		return {}
	var normalized := payload.duplicate(true)
	var feet_value: Variant = payload.get("desktopFeet", payload.get("desktop_feet", Vector2.ZERO))
	var feet := Vector2.ZERO
	if feet_value is Vector2:
		feet = feet_value
	elif feet_value is Array and feet_value.size() >= 2:
		feet = Vector2(float(feet_value[0]), float(feet_value[1]))
	if feet == Vector2.ZERO:
		return {}
	normalized["desktopFeet"] = feet
	normalized["movementState"] = str(payload.get("movementState", payload.get("movement_state", "stationary")))
	normalized["attachmentState"] = str(payload.get("attachmentState", payload.get("attachment_state", "grounded")))
	normalized["surfaceKind"] = str(payload.get("surfaceKind", payload.get("surface_kind", "desktop_floor")))
	return normalized


func _write_command(payload: Dictionary) -> void:
	# Movement/restore traffic uses a separate high-frequency command channel.
	# Carry visibility authority on that channel too so a Chat hide cannot be
	# lost while the companion is walking/climbing and the native host is busy
	# consuming move requests. The native host applies this generation before
	# processing the move itself.
	var enriched := payload.duplicate(true)
	enriched["visibility_generation"] = native_visibility_generation
	enriched["visibility_desired"] = native_visibility_desired
	_write_command_to(command_path, enriched)


func _write_ui_command(payload: Dictionary) -> void:
	# UI updates share a short-lived atomic file. Carry the persistent visibility
	# generation in every update so a delayed hitbox/theme write cannot revive a
	# stale hide after a later restore (or vice versa).
	var enriched := payload.duplicate(true)
	enriched["visibility_generation"] = native_visibility_generation
	enriched["visibility_desired"] = native_visibility_desired
	_write_command_to(ui_command_path if not ui_command_path.is_empty() else command_path, enriched)


func _write_command_to(path: String, payload: Dictionary) -> void:
	if path.is_empty():
		return
	var temporary_path := path + ".runtime.tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.close()
	DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(temporary_path, path)


func _on_bubble_requested(payload: Dictionary) -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if chat_focus_active:
		pending_bubble_payload = {}
		return
	if not bool(context.settings.get("show_bubbles", true)):
		pending_bubble_payload = {}
		return
	pending_bubble_payload = payload.duplicate(true)
	if bubble_path.is_empty() or host_token.is_empty():
		return
	last_bubble_sequence += 1
	var text := str(payload.get("text", "")).strip_edges()
	if text.is_empty():
		return
	var temporary_path := bubble_path + ".runtime.tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"status": "bubble-request",
		"token": host_token,
		"sequence": last_bubble_sequence,
		"text": text,
		"duration_ms": int(payload.get("durationMs", 4000)),
		"bubble_style": str(context.settings.get("bubble_style", "Rounded")),
		"font_family": str(context.settings.get("font_family", "Noto Sans Thai")),
		"text_scale": float(context.settings.get("text_scale", 1.15)),
	}))
	file.close()
	DirAccess.remove_absolute(bubble_path)
	DirAccess.rename_absolute(temporary_path, bubble_path)


func _on_native_hitbox_changed(payload: Dictionary) -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	var hitbox: Rect2 = payload.get("normalized_hitbox", Rect2())
	if hitbox.size.x <= 0.0 or hitbox.size.y <= 0.0:
		return
	pending_native_hitbox = hitbox
	if ui_command_path.is_empty() or host_token.is_empty():
		return
	_write_ui_command({
		"status": "hitbox-request",
		"token": host_token,
		"sequence": Time.get_ticks_msec(),
		"normalized_hitbox": [
			hitbox.position.x,
			hitbox.position.y,
			hitbox.size.x,
			hitbox.size.y,
		],
		"physics_committed": false,
	})


func _on_native_anchor_changed(payload: Dictionary) -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	var anchor: Vector2 = payload.get("normalized_anchor", Vector2(0.5, 1.0))
	anchor = Vector2(clampf(anchor.x, 0.0, 1.0), clampf(anchor.y, 0.0, 1.0))
	pending_native_anchor = anchor
	if ui_command_path.is_empty() or host_token.is_empty():
		return
	_write_ui_command({
		"status": "anchor-request",
		"token": host_token,
		"sequence": Time.get_ticks_msec(),
		"normalized_anchor": [anchor.x, anchor.y],
		"physics_committed": false,
	})


func _on_presentation_scale_applied(payload: Dictionary) -> void:
	_send_presentation_geometry_state(float(payload.get(
		"scale",
		context.character.get("presentation_scale", 1.0)
	)))


func _on_character_loaded(_payload: Dictionary) -> void:
	# CharacterController restores the per-character scale while processing the
	# same event. Replay on the next frame so the native menu mirrors the final
	# Runtime-owned value regardless of subscriber registration order.
	call_deferred("_replay_presentation_scale")


func _replay_presentation_scale() -> void:
	_send_presentation_geometry_state(float(context.character.get("presentation_scale", 1.0)))


func _send_presentation_geometry_state(scale: float) -> void:
	if pending_native_hitbox.size.x <= 0.0 or pending_native_hitbox.size.y <= 0.0:
		_send_presentation_scale_state(scale)
		return
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if ui_command_path.is_empty() or host_token.is_empty():
		return
	if scale not in [0.25, 0.50, 0.75, 1.00, 1.25]:
		return
	var anchor := Vector2(
		clampf(pending_native_anchor.x, 0.0, 1.0),
		clampf(pending_native_anchor.y, 0.0, 1.0)
	)
	_write_ui_command({
		"status": "presentation-geometry-state",
		"token": host_token,
		"sequence": Time.get_ticks_msec(),
		"scale": scale,
		"normalized_hitbox": [
			pending_native_hitbox.position.x,
			pending_native_hitbox.position.y,
			pending_native_hitbox.size.x,
			pending_native_hitbox.size.y,
		],
		"normalized_anchor": [anchor.x, anchor.y],
		"physics_committed": false,
	})


func _send_presentation_scale_state(scale: float) -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if ui_command_path.is_empty() or host_token.is_empty():
		return
	if scale not in [0.25, 0.50, 0.75, 1.00, 1.25]:
		return
	_write_ui_command({
		"status": "presentation-scale-state",
		"token": host_token,
		"sequence": Time.get_ticks_msec(),
		"scale": scale,
		"physics_committed": false,
	})


func _on_theme_changed(payload: Dictionary) -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if ui_command_path.is_empty() or host_token.is_empty():
		return
	var name := str(payload.get("name", "solid")).to_lower()
	if name not in ["solid", "glass", "liquid"]:
		name = "solid"
	_write_ui_command({
		"status": "theme-request",
		"token": host_token,
		"sequence": Time.get_ticks_msec(),
		"theme": name,
		"font_family": str(payload.get("font_family", context.settings.get("font_family", "Noto Sans Thai"))),
		"language": str(payload.get("language", context.settings.get("language", "en"))).strip_edges().to_lower(),
		"text_scale": float(payload.get("text_scale", context.settings.get("text_scale", 1.15))),
		"bubble_style": str(payload.get("bubble_style", context.settings.get("bubble_style", "Rounded"))),
		"reduced_motion": bool(context.settings.get("reduce_motion", false)),
		"presentation_scale": float(context.character.get("presentation_scale", 1.0)),
		"physics_committed": false,
	})


func _on_master_sound_changed(_payload: Dictionary = {}) -> void:
	_send_sound_state()


func _on_sfx_changed(_payload: Dictionary = {}) -> void:
	_send_sound_state()


func _send_sound_state() -> void:
	if not bool(context.runtime_config.get("native_presentation_enabled", false)):
		return
	if ui_command_path.is_empty() or host_token.is_empty():
		return
	_write_ui_command({
		"status": "sound-state",
		"token": host_token,
		"sequence": Time.get_ticks_msec(),
		"master_muted": bool(context.settings.get("master_sound_muted", false)),
		"sfx_enabled": bool(context.settings.get("sfx_enabled", true)),
		"physics_committed": false,
	})


func _on_native_hover_entered(_payload: Dictionary) -> void:
	# Re-assert Runtime-owned size state whenever the native Hover menu opens.
	# Character swaps can replace the companion between two native UI polls; this
	# prevents the menu highlight from keeping the previous character's scale.
	_send_presentation_geometry_state(float(context.character.get("presentation_scale", 1.0)))
	# Native host owns the visible menu in production. The Godot menu remains
	# hidden, but the same Runtime hover event is still emitted for controllers
	# and future menu models.
	print("[NativeHostLifecycle] hover-enter source=native-host menu=runtime")


func _on_native_hover_exited(_payload: Dictionary) -> void:
	print("[NativeHostLifecycle] hover-leave source=native-host menu=runtime")


func _read_handoff() -> Dictionary:
	if not FileAccess.file_exists(handoff_path):
		return {}
	var file := FileAccess.open(handoff_path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _write_status(payload: Dictionary) -> void:
	var temporary_path := handoff_path + ".runtime.tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload))
		file.close()
		DirAccess.remove_absolute(handoff_path)
		DirAccess.rename_absolute(temporary_path, handoff_path)


func _write_update_health_marker(phase: String) -> void:
	var path := OS.get_environment("OCP_UPDATE_HEALTH_FILE")
	if path.is_empty():
		return
	var version := str(OS.get_environment("OCP_UPDATE_EXPECTED_VERSION"))
	var build_info_path := OS.get_executable_path().get_base_dir().path_join("BUILD-INFO.json")
	if FileAccess.file_exists(build_info_path):
		var build_file := FileAccess.open(build_info_path, FileAccess.READ)
		if build_file != null:
			var parsed = JSON.parse_string(build_file.get_as_text())
			if parsed is Dictionary and not str(parsed.get("version", "")).is_empty():
				version = str(parsed.get("version"))
	if version.is_empty():
		version = str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	var parent := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(parent)
	var temporary := path + ".runtime.tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"state": "ready",
		"version": version,
		"phase": phase,
		"pid": OS.get_process_id(),
		"updatedAt": Time.get_datetime_string_from_system(true),
	}))
	file.close()
	DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(temporary, path)
	print("[RuntimeV3] update health marker ready version=%s phase=%s" % [version, phase])


func _check_timeout() -> void:
	if attached or started_at <= 0:
		return
	if Time.get_ticks_msec() - started_at > 30_000:
		push_error("[NativeHostLifecycle] handoff timeout")
		get_tree().quit(87)
