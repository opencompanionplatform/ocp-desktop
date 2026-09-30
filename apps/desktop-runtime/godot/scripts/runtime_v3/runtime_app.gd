extends Node
class_name RuntimeV3App

const BootstrapScript = preload("res://scripts/runtime_v3/core/runtime_bootstrap.gd")
const RuntimeModeAuthorityScript = preload("res://scripts/runtime_v3/services/runtime_mode_authority.gd")
const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const StateMachineScript = preload("res://scripts/runtime_v3/core/runtime_state_machine.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServicesScript = preload("res://scripts/runtime_v3/core/runtime_services.gd")
const EventTracerScript = preload("res://scripts/runtime_v3/core/runtime_event_tracer.gd")
const SingleInstanceGuardScript = preload("res://scripts/runtime_v3/core/runtime_single_instance_guard.gd")

const CharacterServiceScript = preload("res://scripts/runtime_v3/services/character_service.gd")
const PackageServiceScript = preload("res://scripts/runtime_v3/services/package_service.gd")
const EffectPackServiceScript = preload("res://scripts/runtime_v3/services/effect_pack_service.gd")
const RegistryServiceScript = preload("res://scripts/runtime_v3/services/registry_service.gd")
const SettingsServiceScript = preload("res://scripts/runtime_v3/services/settings_service.gd")
const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const TTSServiceScript = preload("res://scripts/runtime_v3/services/tts_service.gd")
const MemoryServiceScript = preload("res://scripts/runtime_v3/services/memory_service.gd")
const CredentialServiceScript = preload("res://scripts/runtime_v3/services/credential_service.gd")
const CloudSessionServiceScript = preload("res://scripts/runtime_v3/services/cloud_session_service.gd")
const CloudAuthServiceScript = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const CloudDeviceServiceScript = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const CloudLibraryServiceScript = preload("res://scripts/runtime_v3/services/cloud_library_service.gd")
const CloudDownloadServiceScript = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")
const CloudDeepLinkServiceScript = preload("res://scripts/runtime_v3/services/cloud_deep_link_service.gd")
const ProgressionQueueServiceScript = preload("res://scripts/runtime_v3/services/progression_queue_service.gd")
const CloudProgressionServiceScript = preload("res://scripts/runtime_v3/services/cloud_progression_service.gd")
const ProgressionEventServiceScript = preload("res://scripts/runtime_v3/services/progression_event_service.gd")
const CloudOperationsServiceScript = preload("res://scripts/runtime_v3/services/cloud_operations_service.gd")
const BridgeAdapterScript = preload("res://scripts/runtime_v3/services/runtime_bridge_adapter.gd")
const TrayServiceScript = preload("res://scripts/runtime_v3/services/tray_service.gd")
const MonitorWindowServiceScript = preload("res://scripts/runtime_v3/services/monitor_window_service.gd")
const WorldDebugServiceScript = preload("res://scripts/runtime_v3/services/world_debug_service.gd")
const NativePresentationCoordinatorScript = preload("res://scripts/runtime_v3/services/native_presentation_coordinator.gd")
const NativeHostLifecycleScript = preload("res://scripts/runtime_v3/services/native_host_lifecycle.gd")
const UpdateServiceScript = preload("res://scripts/runtime_v3/services/update_service.gd")
const ResourceMonitorServiceScript = preload("res://scripts/runtime_v3/services/resource_monitor_service.gd")
const ThemeServiceScript = preload("res://scripts/runtime_v3/services/theme_service.gd")
const LocalizationServiceScript = preload("res://scripts/runtime_v3/services/localization_service.gd")
const StartupRegistrationServiceScript = preload("res://scripts/runtime_v3/services/startup_registration_service.gd")
const DesktopShellFunctionalAdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")

const CharacterControllerScript = preload("res://scripts/runtime_v3/controllers/character_controller.gd")
const AnimationControllerScript = preload("res://scripts/runtime_v3/controllers/animation_controller.gd")
const BubbleControllerScript = preload("res://scripts/runtime_v3/controllers/bubble_controller.gd")
const HoverControllerScript = preload("res://scripts/runtime_v3/controllers/hover_controller.gd")
const WindowControllerScript = preload("res://scripts/runtime_v3/controllers/window_controller.gd")
const MultiMonitorControllerScript = preload("res://scripts/runtime_v3/controllers/multi_monitor_controller.gd")
const InputControllerScript = preload("res://scripts/runtime_v3/controllers/input_controller.gd")
const ContextMenuControllerScript = preload("res://scripts/runtime_v3/controllers/context_menu_controller.gd")
const QuickPanelControllerScript = preload("res://scripts/runtime_v3/controllers/quick_panel_controller.gd")
const CharacterPickerControllerScript = preload("res://scripts/runtime_v3/controllers/character_picker_controller.gd")
const ClickThroughControllerScript = preload("res://scripts/runtime_v3/controllers/click_through_controller.gd")
const SoundControllerScript = preload("res://scripts/runtime_v3/controllers/sound_controller.gd")
const EffectControllerScript = preload("res://scripts/runtime_v3/controllers/effect_controller.gd")
const ChatSessionOrchestratorScript = preload("res://scripts/runtime_v3/controllers/chat_session_orchestrator.gd")
const ProactiveLocalLLMCompanionControllerScript = preload("res://scripts/runtime_v3/controllers/proactive_local_llm_companion_controller.gd")
const NotificationControllerScript = preload("res://scripts/runtime_v3/controllers/notification_controller.gd")
const ProgressionCelebrationControllerScript = preload("res://scripts/runtime_v3/controllers/progression_celebration_controller.gd")
const DraggablePanelControllerScript = preload("res://scripts/runtime_v3/controllers/draggable_panel_controller.gd")
const PerMonitorWindowControllerScript = preload("res://scripts/runtime_v3/controllers/per_monitor_window_controller.gd")
const HybridPresentationControllerScript = preload("res://scripts/runtime_v3/controllers/hybrid_presentation_controller.gd")
const ApplicationWindowControllerScript = preload("res://scripts/runtime_v3/controllers/application_window_controller.gd")
const OfflinePresenceControllerScript = preload("res://scripts/runtime_v3/controllers/offline_presence_controller.gd")
const AutonomousFloorWalkControllerScript = preload("res://scripts/runtime_v3/controllers/autonomous_floor_walk_controller.gd")

const SDKScript = preload("res://scripts/runtime_v3/sdk/runtime_sdk.gd")

var bootstrap: Node
var context: Node
var state_machine: Node
var event_bus: Node
var services: Node
var sdk: Node
var event_tracer: Node
var single_instance_guard: Node
var controllers: Array = []
var duplicate_instance: bool = false
# Use the preloaded script as the construction authority. Avoid a global # class-name type dependency during the first project scan.
var runtime_mode_authority: RefCounted = RuntimeModeAuthorityScript.new()
var shutting_down: bool = false
var startup_visibility_controller: Node
var startup_character_recovery_attempted: bool = false


func _enter_tree() -> void:
	startup_visibility_controller = get_node_or_null(
		"RuntimeServices/StartupVisibilityController"
	)
	if is_instance_valid(startup_visibility_controller):
		# Godot does not permit changing visibility of its main window.  Native
		# startup gating therefore happens at the character surface level.
		startup_visibility_controller.begin_startup(get_window())

	single_instance_guard = SingleInstanceGuardScript.new()
	single_instance_guard.name = "RuntimeSingleInstanceGuard"
	add_child(single_instance_guard)

	if not single_instance_guard.acquire():
		duplicate_instance = true
		call_deferred("_quit_duplicate_instance")


func _ready() -> void:
	if duplicate_instance:
		return

	single_instance_guard.duplicate_launch_received.connect(_on_duplicate_launch_received)
	_create_core()
	_create_services()
	_create_controllers()
	_create_sdk()
	_bind_ui()
	_connect_app_events()
	%DesktopWorldDebugOverlay.bind_service(services.world_debug)
	if is_instance_valid(%WorldDebugButton):
		%WorldDebugButton.pressed.connect(func():
			event_bus.publish(&"desktop_world.debug_toggle_requested", {})
		)

	services.settings_service.load_settings()
	# Services are created before persisted settings are loaded. Re-select and
	# probe the saved provider now so Chat does not remain on the bootstrap
	# Offline adapter until the user visits AI & Voice.
	if is_instance_valid(services.ai_service):
		services.ai_service.reload_provider()
		# Only the explicitly local provider is probed automatically. Cloud
		# endpoints remain user-initiated through Connect/Test to avoid surprise
		# credentialed traffic or metered requests during startup.
		if str(context.settings.get("ai_provider_id", "offline")) == "ollama":
			services.ai_service.test_connection()
	_controller("MultiMonitorController").refresh()

	# RC28.2: one session authority decides the presentation mode.
	# OCP_PRESENTATION_MODE=overlay overrides stale user settings and any
	# diagnostic launcher profile. Without an explicit override, saved
	# preference is used and defaults to overlay.
	var start_overlay: bool = runtime_mode_authority.resolve_start_overlay(
		context.settings
	)
	var requested_mode: String = runtime_mode_authority.requested_mode()
	var native_requested: bool = runtime_mode_authority.is_native_companion_requested()
	var native_enabled: bool = runtime_mode_authority.is_native_companion_enabled()
	context.update_runtime_config({
		"overlay_enabled": start_overlay,
		"presentation_mode": "native-companion" if native_enabled else ("overlay" if start_overlay else "debug"),
		"presentation_requested_mode": requested_mode if not requested_mode.is_empty() else ("overlay" if start_overlay else "debug"),
		"presentation_fallback_reason": "native-host-adapter-not-production-enabled" if native_requested else "",
		"native_presentation_enabled": native_enabled,
		"presentation_mode_forced": runtime_mode_authority.is_session_forced(),
		"hybrid_monitor_requested": runtime_mode_authority.is_hybrid_monitor_requested(),
	})
	var effective_mode := "native-companion" if native_enabled else ("overlay" if start_overlay else "debug")
	print(
		"[RuntimeV3] presentation authority: mode=%s forced=%s requested=%s"
		% [
			effective_mode,
			runtime_mode_authority.is_session_forced(),
			runtime_mode_authority.requested_mode(),
		]
	)
	if native_requested:
		if native_enabled:
			print("[RuntimeV3] native companion production opt-in enabled")
		else:
			print(
				"[RuntimeV3] native companion requested — safe fallback to overlay; "
				+ "production host adapter is not enabled"
			)
	if native_enabled:
		_apply_native_ui_state()
		_controller("WindowController").apply_native_companion_window()
	elif start_overlay:
		_apply_overlay_ui_state()
		_controller("WindowController").apply_overlay_window()
	else:
		_apply_debug_ui_state()
		_controller("WindowController").apply_debug_window()

	if runtime_mode_authority.is_hybrid_monitor_requested():
		var hybrid_active: bool = _controller(
			"HybridPresentationController"
		).activate_isolated()
		print(
			"[RuntimeV3] hybrid monitor gate: isolated-presentation-root active=",
			hybrid_active
		)
		if (
			hybrid_active
			and runtime_mode_authority.is_hybrid_monitor_window_probe_requested()
		):
			var probe_active: bool = _controller(
				"PerMonitorWindowController"
			).enable_hybrid_probe()
			var probe_screen := int(
				context.runtime_config.get("hybrid_monitor_probe_screen", -1)
			)
			print(
				"[RuntimeV3] hybrid monitor gate: native-window-probe active=%s screen=%d"
				% [probe_active, probe_screen]
			)

	event_bus.publish(&"click_through.refresh_requested", {})
	_bind_rust_bridge_if_present()
	if native_enabled and is_instance_valid(services.native_host_lifecycle):
		services.native_host_lifecycle.bind_window(get_window())
		services.native_host_lifecycle.bind_bridge(services.bridge_adapter.bridge)
		services.native_host_lifecycle.bind_coordinator(services.native_presentation)
		services.native_presentation.request(
			"default",
			OS.get_environment("OCP_NATIVE_HOST_TOKEN")
		)
		services.native_host_lifecycle.arm()
	await bootstrap.start_system()
	event_bus.publish(&"character.load_active_requested", {})
	if not native_enabled:
		_write_update_health_marker("runtime-ready")
	print("[RuntimeV3] Phase 6.1 ready — single instance, clean tests, headless monitor skip")
	# Warm Desktop Shell only after the native companion has been requested. The
	# async delay keeps Electron/preview preparation off the critical character
	# startup path while making the first Chat click a reveal of an already-ready
	# hidden window instead of a Chromium cold start.
	call_deferred("_warm_desktop_shell_after_startup")
	if OS.get_environment("OCP_CONTROL_CENTER_MAXIMIZE_SMOKE").strip_edges() in ["1", "true", "yes", "on"]:
		call_deferred("_run_control_center_maximize_smoke")


func _warm_desktop_shell_after_startup() -> void:
	if OS.get_environment("OCP_DESKTOP_SHELL_ENABLED") != "1":
		return
	var warm_started_at := Time.get_ticks_msec()
	await get_tree().create_timer(0.65).timeout
	if shutting_down:
		return
	var launcher_script := load("res://scripts/runtime_v3/services/desktop_shell_launcher.gd")
	if launcher_script == null:
		return
	var launcher: Variant = launcher_script.new()
	if launcher == null or not launcher.has_method("try_warm"):
		if launcher is Object and is_instance_valid(launcher):
			launcher.free()
		return
	var shell_started_at := Time.get_ticks_msec()
	var shell_launched := bool(launcher.call("try_warm", &"chat"))
	if launcher is Object and is_instance_valid(launcher):
		launcher.free()
	print("[DesktopShellWarmup] shell_launch=%s elapsed_ms=%d" % [shell_launched, Time.get_ticks_msec() - shell_started_at])
	if not shell_launched:
		return
	# Package activation is asynchronous. Retry a bounded number of times while
	# Electron warms independently; each attempt only asks the adapter to queue
	# the three Chat clips and never blocks native character rendering.
	for attempt in range(10):
		if shutting_down:
			return
		await get_tree().create_timer(0.25 if attempt == 0 else 0.15).timeout
		if shutting_down:
			return
		var adapter: Node = services.desktop_shell_adapter if is_instance_valid(services) else null
		if is_instance_valid(adapter) and adapter.has_method("warm_chat_preview") and bool(adapter.call("warm_chat_preview")):
			print("[DesktopShellWarmup] preview_queue=ready attempt=%d total_ms=%d" % [attempt + 1, Time.get_ticks_msec() - warm_started_at])
			return
	print("[DesktopShellWarmup] preview_queue=deferred total_ms=%d" % [Time.get_ticks_msec() - warm_started_at])


func _run_control_center_maximize_smoke() -> void:
	# Integration-only probe for the production native-companion path. Wait until
	# the native host has adopted the main Godot HWND, then maximize the real
	# Control Center and verify its viewport still renders non-black pixels.
	var lifecycle: Node = services.native_host_lifecycle if is_instance_valid(services) else null
	for _index in range(180):
		if is_instance_valid(lifecycle) and bool(lifecycle.get("attached")):
			break
		await get_tree().process_frame
	var app := get_node_or_null("ApplicationWindow") as Window
	if not is_instance_valid(app):
		print("[P3.4.10] native_control_center_max rendered=false reason=no-window")
		event_bus.publish(&"system.shutting_down", {})
		return
	app.show()
	app.grab_focus()
	for _index in range(4):
		await get_tree().process_frame
	var bar := app.get_node_or_null("OcpTitleBar")
	if not is_instance_valid(bar):
		print("[P3.4.10] native_control_center_max rendered=false reason=no-titlebar")
		event_bus.publish(&"system.shutting_down", {})
		return
	await bar.call("_toggle_maximize")
	for _index in range(8):
		await get_tree().process_frame
	var image := app.get_texture().get_image()
	var center := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
	var sample := image.get_pixel(mini(320, image.get_width() - 1), mini(120, image.get_height() - 1))
	var rendered := center.a > 0.5 and (center.r + center.g + center.b) > 0.03 and sample.a > 0.5 and (sample.r + sample.g + sample.b) > 0.03
	print("[P3.4.10] native_control_center_max rendered=", rendered, " size=", app.size, " center=", center, " sample=", sample)
	event_bus.publish(&"system.shutting_down", {})


func _unhandled_input(event: InputEvent) -> void:
	for controller in controllers:
		if controller.has_method("handle_input"):
			controller.handle_input(event)


func _exit_tree() -> void:
	if duplicate_instance:
		return
	_shutdown_runtime()


func _quit_duplicate_instance() -> void:
	await get_tree().process_frame
	get_tree().quit(0)


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


func _on_duplicate_launch_received() -> void:
	if event_bus != null and is_instance_valid(event_bus):
		# A second launcher invocation is treated as an activation request for
		# the existing Runtime. Bring the companion back if it was hidden and
		# ensure the Desktop Shell is alive so protocol/install relays can reuse
		# this Runtime instead of creating a duplicate process tree.
		event_bus.publish(&"window.restore_requested", {})
		var shell_started := false
		if OS.get_environment("OCP_DESKTOP_SHELL_ENABLED") == "1":
			var launcher_script := load("res://scripts/runtime_v3/services/desktop_shell_launcher.gd")
			if launcher_script != null:
				var launcher: Variant = launcher_script.new()
				if launcher != null and launcher.has_method("try_open"):
					shell_started = bool(launcher.call("try_open", &"characters"))
				if launcher is Object and is_instance_valid(launcher):
					launcher.free()
		if not shell_started:
			event_bus.publish(&"application_window.open_requested", {
				"page": "settings",
				"source": "duplicate-launch",
			})
		event_bus.publish(&"notification.requested", {
			"text": "OCP is already running — reconnecting the existing desktop session",
			"duration": 2.5,
		})


func _on_system_exit_ready(_payload: Dictionary) -> void:
	if shutting_down:
		return
	call_deferred("_graceful_shutdown_and_quit")


func _graceful_shutdown_and_quit() -> void:
	if shutting_down:
		return
	_shutdown_runtime()
	# Give deferred frees/resource releases scheduled by service stop() handlers
	# two frames to settle before SceneTree destruction. This is especially
	# important for DesktopShell preview Threads/SpriteFrames and HTTP resources.
	await get_tree().process_frame
	await get_tree().process_frame
	print("[RuntimeV3] graceful shutdown cleanup complete")
	get_tree().quit(0)


func _shutdown_runtime() -> void:
	if shutting_down:
		return
	shutting_down = true

	if event_bus != null and is_instance_valid(event_bus):
		event_bus.publish(&"system.shutting_down", {})

	for controller in controllers:
		if is_instance_valid(controller) and controller.has_method("stop"):
			controller.stop()
	controllers.clear()

	if services != null and is_instance_valid(services):
		for service in services.get_children():
			if is_instance_valid(service) and service.has_method("stop"):
				service.stop()

	if event_tracer != null and is_instance_valid(event_tracer):
		event_tracer.shutdown()

	if event_bus != null and is_instance_valid(event_bus):
		event_bus.clear()

	if bootstrap != null and is_instance_valid(bootstrap):
		bootstrap.stop_system()

	if single_instance_guard != null and is_instance_valid(single_instance_guard):
		single_instance_guard.release()


func _create_core() -> void:
	context = _attach(ContextScript, %RuntimeContext)
	state_machine = _attach(StateMachineScript, %RuntimeStateMachine)
	event_bus = _attach(EventBusScript, %RuntimeEventBus)
	event_tracer = EventTracerScript.new()
	event_tracer.name = "RuntimeEventTracer"
	%RuntimeEventBus.add_child(event_tracer)
	event_tracer.configure(event_bus)
	event_tracer.set_enabled(bool(context.runtime_config.get("debug_enabled", false)))
	services = _attach(ServicesScript, %RuntimeServices)
	bootstrap = _attach(BootstrapScript, %RuntimeBootstrap)
	bootstrap.configure(self, context, event_bus, state_machine)

	context.update_runtime_config({
		"overlay_enabled": true,
		"click_through_enabled": true,
		"debug_enabled": false,
		"performance_overlay_enabled": false,
		"native_dialog_open": false,
	})


func _create_services() -> void:
	var definitions: Array = [
		[&"character", CharacterServiceScript],
		[&"package", PackageServiceScript],
		[&"effect_pack", EffectPackServiceScript],
		[&"registry", RegistryServiceScript],
		[&"settings", SettingsServiceScript],
		[&"ai", AIServiceScript],
		[&"tts", TTSServiceScript],
		[&"memory", MemoryServiceScript],
		[&"credentials", CredentialServiceScript],
		[&"cloud_session", CloudSessionServiceScript],
		[&"cloud_auth", CloudAuthServiceScript],
		[&"cloud_device", CloudDeviceServiceScript],
		[&"cloud_library", CloudLibraryServiceScript],
		[&"cloud_download", CloudDownloadServiceScript],
		[&"cloud_deep_link", CloudDeepLinkServiceScript],
		[&"progression_queue", ProgressionQueueServiceScript],
		[&"cloud_progression", CloudProgressionServiceScript],
		[&"progression_events", ProgressionEventServiceScript],
		[&"cloud_operations", CloudOperationsServiceScript],
		[&"bridge", BridgeAdapterScript],
		[&"tray", TrayServiceScript],
		[&"monitor_windows", MonitorWindowServiceScript],
		[&"world_debug", WorldDebugServiceScript],
		[&"native_presentation", NativePresentationCoordinatorScript],
		[&"native_host_lifecycle", NativeHostLifecycleScript],
		[&"update", UpdateServiceScript],
		[&"resource_monitor", ResourceMonitorServiceScript],
		[&"theme", ThemeServiceScript],
		[&"localization", LocalizationServiceScript],
		[&"startup_registration", StartupRegistrationServiceScript],
		[&"desktop_shell_adapter", DesktopShellFunctionalAdapterScript],
	]

	for definition in definitions:
		var service_name: StringName = definition[0]
		var script: Script = definition[1]
		var service: Node = script.new()
		service.name = String(service_name).capitalize() + "Service"
		%RuntimeServices.add_child(service)
		service.configure(context, event_bus)
		service.start()
		services.register_service(service_name, service)

	if is_instance_valid(services.desktop_shell_adapter) and services.desktop_shell_adapter.has_method("bind_services"):
		services.desktop_shell_adapter.call("bind_services", services)

	if is_instance_valid(services.cloud_auth_service) and is_instance_valid(services.cloud_session_service):
		services.cloud_auth_service.bind_session(services.cloud_session_service)
	if is_instance_valid(services.cloud_device_service) and is_instance_valid(services.cloud_session_service):
		services.cloud_device_service.bind_session(services.cloud_session_service)
	if is_instance_valid(services.cloud_library_service) and is_instance_valid(services.cloud_session_service):
		services.cloud_library_service.bind_session(services.cloud_session_service)
	if is_instance_valid(services.cloud_download_service):
		if is_instance_valid(services.cloud_session_service):
			services.cloud_download_service.bind_session(services.cloud_session_service)
		if is_instance_valid(services.cloud_device_service):
			services.cloud_download_service.bind_device_service(services.cloud_device_service)
		if is_instance_valid(services.package_service):
			services.cloud_download_service.bind_package_service(services.package_service)
		if is_instance_valid(services.effect_pack_service):
			services.cloud_download_service.bind_effect_pack_service(services.effect_pack_service)
	if is_instance_valid(services.effect_pack_service) and is_instance_valid(services.cloud_progression_service):
		services.effect_pack_service.bind_progression_service(services.cloud_progression_service)
	if is_instance_valid(services.cloud_progression_service):
		# Bind the local cache before the restored session so bind_session() can
		# project cached EXP/Level immediately, even before the network refresh.
		if is_instance_valid(services.progression_queue_service):
			services.cloud_progression_service.bind_queue(services.progression_queue_service)
		if is_instance_valid(services.cloud_session_service):
			services.cloud_progression_service.bind_session(services.cloud_session_service)
	if is_instance_valid(services.progression_event_service):
		if is_instance_valid(services.cloud_session_service):
			services.progression_event_service.bind_session(services.cloud_session_service)
		if is_instance_valid(services.progression_queue_service):
			services.progression_event_service.bind_queue(services.progression_queue_service)
		if is_instance_valid(services.cloud_progression_service):
			services.progression_event_service.bind_progression(services.cloud_progression_service)
	if is_instance_valid(services.cloud_operations_service):
		if is_instance_valid(services.cloud_session_service):
			services.cloud_operations_service.bind_session(services.cloud_session_service)
		if is_instance_valid(services.cloud_device_service):
			services.cloud_operations_service.bind_device_service(services.cloud_device_service)
		if is_instance_valid(services.package_service):
			services.cloud_operations_service.bind_package_service(services.package_service)
		if is_instance_valid(services.cloud_progression_service):
			services.cloud_operations_service.bind_progression_service(services.cloud_progression_service)


func _create_controllers() -> void:
	var definitions: Array = [
		["CharacterController", CharacterControllerScript],
		["AnimationController", AnimationControllerScript],
		["BubbleController", BubbleControllerScript],
		["HoverController", HoverControllerScript],
		["WindowController", WindowControllerScript],
		["MultiMonitorController", MultiMonitorControllerScript],
		["InputController", InputControllerScript],
		["ContextMenuController", ContextMenuControllerScript],
		["QuickPanelController", QuickPanelControllerScript],
		["CharacterPickerController", CharacterPickerControllerScript],
		["ClickThroughController", ClickThroughControllerScript],
		["SoundController", SoundControllerScript],
		["EffectController", EffectControllerScript],
		["ChatSessionOrchestrator", ChatSessionOrchestratorScript],
		["ProactiveLocalLLMCompanionController", ProactiveLocalLLMCompanionControllerScript],
		["NotificationController", NotificationControllerScript],
		["ProgressionCelebrationController", ProgressionCelebrationControllerScript],
		["CharacterPickerDragController", DraggablePanelControllerScript],
		["QuickPanelDragController", DraggablePanelControllerScript],
		["PerMonitorWindowController", PerMonitorWindowControllerScript],
		["HybridPresentationController", HybridPresentationControllerScript],
		["ApplicationWindowController", ApplicationWindowControllerScript],
		["OfflinePresenceController", OfflinePresenceControllerScript],
		["AutonomousFloorWalkController", AutonomousFloorWalkControllerScript],
	]

	for definition in definitions:
		var controller: Node = definition[1].new()
		controller.name = definition[0]
		%Controllers.add_child(controller)
		controller.configure(context, event_bus, services, state_machine)
		controller.start()
		controllers.append(controller)


func _create_sdk() -> void:
	sdk = _attach(SDKScript, %RuntimeSDK)
	sdk.configure(context, event_bus, services)


func _bind_ui() -> void:
	_apply_brand_icons()
	var desktop_shell_enabled := OS.get_environment("OCP_DESKTOP_SHELL_ENABLED") == "1"
	_controller("CharacterController").bind_character(%CompanionHost, %CompanionSprite)
	_controller("AnimationController").bind_sprite(%CompanionSprite)
	_controller("BubbleController").bind_ui(%CompanionHost, %BubblePanel, %BubbleLabel)
	_controller("HoverController").bind(%CompanionHost, %HoverMenu)
	_controller("HybridPresentationController").bind(
		%RuntimeUI,
		%CompanionLayer,
		%BubbleLayer,
		%HoverMenu
	)
	_controller("WindowController").bind_window(get_window())
	_controller("ContextMenuController").bind_menu(%ContextMenu)
	_controller("QuickPanelController").bind_panel(%QuickPanel, %AnimationList)
	_controller("QuickPanelDragController").bind_panel(
		%QuickPanel,
		%QuickPanelDragHandle
	)
	_controller("ClickThroughController").bind(
		get_window(),
		%CompanionHost,
		%HoverMenu,
		%QuickPanel,
		null if desktop_shell_enabled else %CharacterPicker,
		%BubblePanel,
		%NotificationPanel
	)
	_controller("SoundController").bind_player(%SoundPlayer)
	_controller("EffectController").bind_effect_layer(%CompanionHost, %CompanionSprite)
	if is_instance_valid(services.desktop_shell_adapter) and services.desktop_shell_adapter.has_method("bind_effect_controller"):
		services.desktop_shell_adapter.call("bind_effect_controller", _controller("EffectController"))
	_controller("ProgressionCelebrationController").bind_character(%CompanionHost, %CompanionSprite)
	_controller("NotificationController").bind_ui(%NotificationPanel, %NotificationLabel)

	%OpenQuickPanelButton.pressed.connect(func(): event_bus.publish(&"quick_panel.open_requested", {}))
	%CloseQuickPanelButton.pressed.connect(func(): event_bus.publish(&"quick_panel.close_requested", {}))
	%HoverMuteAllButton.pressed.connect(_toggle_hover_master_sound)
	%HoverSfxButton.pressed.connect(_toggle_hover_sfx)
	%HoverVoiceButton.pressed.connect(func(): event_bus.publish(&"application_window.open_requested", {"page": "settings", "source": "hover-voice"}))
	%BubbleTestButton.pressed.connect(func(): event_bus.publish(&"bubble.requested", {"text": "Runtime V3 bubble test"}))
	%WaveButton.pressed.connect(func(): event_bus.publish(&"animation.requested", {"name": "wave"}))
	%ChangeCharacterButton.pressed.connect(func(): event_bus.publish(&"character_picker.open_requested", {}))
	%HoverExitButton.pressed.connect(func(): event_bus.publish(&"window.exit_requested", {}))
	%HideToTrayButton.pressed.connect(func(): event_bus.publish(&"window.hide_to_tray_requested", {}))
	%OverlayModeButton.pressed.connect(_toggle_overlay_mode)

	%DebugOverlay.configure(context, state_machine)
	%DebugOverlay.visible = false
	%PerformanceOverlay.visible = false

	if desktop_shell_enabled:
		return

	_controller("CharacterPickerController").bind_picker(
		%CharacterPicker,
		%CharacterList,
		get_node_or_null("RuntimeUI/PackageFileDialog") as FileDialog,
		%PickerStatusLabel
	)
	var character_manager := %CharacterManagerWindow as Window
	if is_instance_valid(character_manager):
		_controller("CharacterPickerController").bind_preview(
			character_manager.find_child("PreviewSprite", true, false) as AnimatedSprite2D,
			character_manager.find_child("AnimationCatalog", true, false) as Container,
			character_manager.find_child("AnimationSearch", true, false) as LineEdit,
			character_manager.find_child("AnimationCategory", true, false) as OptionButton,
			character_manager.find_child("PreviewStatusLabel", true, false) as Label,
			character_manager.find_child("PreviewPlayButton", true, false) as Button,
			character_manager.find_child("PreviewLoopToggle", true, false) as CheckButton,
			character_manager.find_child("PreviewSpeed", true, false) as OptionButton,
			character_manager.find_child("ApplyCharacterButton", true, false) as Button,
			character_manager.find_child("ExploreCharacterStoreButton", true, false) as Button
		)
	_controller("ApplicationWindowController").bind_window(
		%ApplicationWindow,
		%ApplicationTabs,
		%ShowBubblesToggle,
		%UpdateChannelOption,
		%SettingsStatusLabel,
		%CurrentVersionLabel,
		%UpdateChannelLabel,
		%UpdateReadinessLabel,
		%CheckUpdatesButton,
		%ChatInput,
		%SendChatButton,
		%ChatTranscript,
		%ChatMessages,
		%ChatStatus,
		%VoiceChatButton,
		%OfflinePresenceToggle,
		%InstallUpdateButton,
		%OfflineBotStatusLabel,
		%ResourceCpuLabel,
		%ResourceMemoryLabel,
		%ResourceStatusLabel,
		%ThemePresetOption
	)
	%InstallPackageButton.pressed.connect(func(): _controller("CharacterPickerController").open_install_dialog())
	%CharacterManagerWindow.close_requested.connect(func(): event_bus.publish(&"character_picker.close_requested", {}))
	%ApplicationWindow.close_requested.connect(func(): event_bus.publish(&"application_window.close_requested", {}))
	%SaveSettingsButton.pressed.connect(func(): _controller("ApplicationWindowController").save_settings())
	%CheckUpdatesButton.pressed.connect(func(): _controller("ApplicationWindowController").check_update_readiness())
	%InstallUpdateButton.pressed.connect(func(): _controller("ApplicationWindowController")._on_install_update_pressed())


func _apply_brand_icons() -> void:
	# ResourceLoader is required for assets stored inside the exported PCK.
	var branded_texture := load("res://assets/icons/ocp.svg") as Texture2D
	if branded_texture != null:
		var packed_image := branded_texture.get_image()
		DisplayServer.window_set_icon(packed_image)
		for window_name in ["ApplicationWindow", "ChatWindow", "CharacterManagerWindow"]:
			var app_window := get_node_or_null(window_name)
			if is_instance_valid(app_window) and app_window.has_method("set_icon"):
				app_window.call("set_icon", packed_image)
		return
	# Development fallback when the imported SVG texture is not ready yet.
	var icon_image := Image.new()
	var icon_path := ProjectSettings.globalize_path("res://assets/icons/ocp.svg")
	if icon_image.load(icon_path) != OK or icon_image.is_empty():
		return
	DisplayServer.window_set_icon(icon_image)
	for window_name in ["ApplicationWindow", "ChatWindow", "CharacterManagerWindow"]:
		var app_window := get_node_or_null(window_name)
		if is_instance_valid(app_window) and app_window.has_method("set_icon"):
			app_window.call("set_icon", icon_image)


func _connect_app_events() -> void:
	event_bus.subscribe(&"character.load_active_requested", Callable(self, "_load_active_character"))
	event_bus.subscribe(&"character.changed", Callable(self, "_on_character_changed"))
	event_bus.subscribe(&"character.display_name_changed", Callable(self, "_on_character_display_name_changed"))
	event_bus.subscribe(&"debug.toggle_requested", func(_payload):
		%DebugOverlay.visible = not %DebugOverlay.visible
		event_tracer.set_enabled(%DebugOverlay.visible)
	)
	event_bus.subscribe(&"performance.toggle_requested", func(_payload): %PerformanceOverlay.visible = not %PerformanceOverlay.visible)
	event_bus.subscribe(&"performance_baseline.updated", func(payload): %PerformanceOverlay.apply_snapshot(payload))
	event_bus.subscribe(&"package.install_failed", func(payload): %StatusLabel.text = "Install failed: " + str(payload.get("error", "")))
	event_bus.subscribe(&"package.installed", func(payload): %StatusLabel.text = "Installed: %s@%s" % [payload.get("packageId", ""), payload.get("version", "")])
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_startup_character_ready"))
	event_bus.subscribe(&"character.load_failed", Callable(self, "_on_startup_character_failed"))
	event_bus.subscribe(&"desktop_world.event_received", func(data):
		services.world_debug.consume_event(str(data.get("type", "")), data.get("payload", {}))
	)
	event_bus.subscribe(&"desktop_world.connection_changed", func(data):
		services.world_debug.set_connection_state(bool(data.get("connected", false)))
	)
	event_bus.subscribe(&"desktop_world.debug_toggle_requested", func(_data):
		%DesktopWorldDebugOverlay.visible = not %DesktopWorldDebugOverlay.visible
	)
	event_bus.subscribe(&"system.exit_ready", Callable(self, "_on_system_exit_ready"))



func _on_startup_character_ready(_payload: Dictionary) -> void:
	# Startup readiness is one-shot. Later character activations also publish
	# character.loaded and must not re-enter the startup visibility lifecycle.
	if is_instance_valid(startup_visibility_controller) \
	and startup_visibility_controller.is_revealed():
		return
	if is_instance_valid(%StartupLayer):
		%StartupLayer.visible = false
	await _reveal_runtime_window()


func _on_startup_character_failed(payload: Dictionary) -> void:
	# A failed package activation after startup is a normal runtime error, not a
	# startup failure. Do not replace an already-visible character in that case.
	if is_instance_valid(startup_visibility_controller) \
	and startup_visibility_controller.is_revealed():
		return

	# A persisted Store character can remain on disk after it is unpublished,
	# revoked, or becomes invalid for the current trust root. Before exposing the
	# procedural emergency fallback, make one deterministic recovery attempt to
	# the embedded Bible. This also rewrites activeCharacter so the next launch
	# does not repeat the same rejected package.
	var reason := str(payload.get("error", "Unknown error")).strip_edges()
	if not startup_character_recovery_attempted \
	and is_instance_valid(services.package_service) \
	and is_instance_valid(services.character_service):
		startup_character_recovery_attempted = true
		var rejected: Dictionary = services.package_service.get_active_candidate()
		var rejected_id := str(rejected.get("packageId", "")).strip_edges()
		if rejected_id != PackageServiceScript.EMBEDDED_STARTER_ID:
			var recovery: Dictionary = services.package_service.recover_to_embedded_starter()
			if bool(recovery.get("ok", false)):
				var recovered: Dictionary = services.package_service.get_active_candidate()
				if str(recovered.get("packageId", "")) == PackageServiceScript.EMBEDDED_STARTER_ID:
					print("[CharacterTrustRecovery] rejected=%s fallback=embedded-bible reason=%s" % [
						rejected_id if not rejected_id.is_empty() else "unknown",
						reason,
					])
					if is_instance_valid(%StatusLabel):
						%StatusLabel.text = "Active character unavailable — recovering Bible"
					var recovered_result: Dictionary = services.character_service.load_active_character(recovered)
					if bool(recovered_result.get("ok", false)):
						return
					# CharacterService publishes character.load_failed itself. The nested
					# callback sees startup_character_recovery_attempted=true and owns the
					# final emergency fallback, so avoid publishing it twice here.
					return
			else:
				push_warning("[CharacterTrustRecovery] embedded Bible recovery failed: %s" % str(recovery.get("error", "unknown error")))

	# Production trust is fail-closed. Only reach the procedural emergency
	# character after the embedded starter is unavailable or itself rejected.
	var fallback_frames: SpriteFrames = services.character_service.build_fallback_frames() \
		if is_instance_valid(services.character_service) else null
	if fallback_frames != null:
		print("[CharacterTrustFallback] active-package-rejected fallback=emergency reason=%s" % reason)
		if is_instance_valid(%StatusLabel):
			%StatusLabel.text = "Active character unavailable — using emergency fallback"
		event_bus.publish(&"character.loaded", {
			"ok": true,
			"frames": fallback_frames,
			"fallback": true,
			"trustRejected": true,
		})
		return

	if is_instance_valid(%StartupStatusLabel):
		%StartupStatusLabel.text = "Character load failed: " + reason
	await get_tree().create_timer(1.5).timeout
	if is_instance_valid(%StartupLayer):
		%StartupLayer.visible = false
	await _reveal_runtime_window()


func _reveal_runtime_window() -> void:
	if is_instance_valid(startup_visibility_controller):
		await startup_visibility_controller.reveal_when_ready()


func _load_active_character(_payload: Dictionary) -> void:
	# Startup resolves only the persisted candidate here. CharacterService owns
	# the single native trust verification immediately before any managed asset
	# is read/decoded; using get_active() here would verify the same 60+ file
	# Store projection twice back-to-back on the main thread.
	var active: Dictionary = services.package_service.get_active_candidate()
	var result: Dictionary

	if active.is_empty():
		var starter_result: Dictionary = services.package_service.ensure_embedded_starter()
		if bool(starter_result.get("ok", false)):
			active = services.package_service.get_active_candidate()
			if str(starter_result.get("status", "")) != "active-preserved":
				print("[RuntimeV3] embedded-starter status=%s package=%s@%s" % [
					str(starter_result.get("status", "ready")),
					str(starter_result.get("packageId", "character.bible")),
					str(starter_result.get("version", "1.0.0")),
				])
		else:
			push_warning("[RuntimeV3] embedded Bible unavailable: %s" % str(starter_result.get("error", "unknown error")))

	if active.is_empty():
		# Emergency-only presentation. Normal clean/offline installs should have
		# activated the embedded Bible above before this branch is reachable.
		var frames: SpriteFrames = services.character_service.build_fallback_frames()
		result = {"ok": frames != null, "frames": frames, "fallback": true}
		if frames != null:
			event_bus.publish(&"character.loaded", result)
		%StatusLabel.text = "Emergency fallback — embedded Bible could not be loaded"
	else:
		result = services.character_service.load_active_character(active)
		%StatusLabel.text = "Loaded: %s" % context.character.get("name", "Character") if result.get("ok", false) else str(result.get("error", "Load failed"))

	if is_instance_valid(services.effect_pack_service):
		var effect_starter: Dictionary = services.effect_pack_service.ensure_embedded_starter()
		if not bool(effect_starter.get("ok", false)):
			push_warning("[RuntimeV3] starter effect pack unavailable: %s" % str(effect_starter.get("error", "unknown error")))
	_sync_chat_companion_identity()
	event_bus.publish(&"click_through.refresh_requested", {})


func _effective_companion_display_name() -> String:
	if not is_instance_valid(context):
		return "Companion"
	var package_name := str(context.character.get("name", "Companion")).strip_edges()
	if package_name.is_empty():
		package_name = "Companion"
	var character_id := str(context.character.get("id", "")).strip_edges()
	var aliases_value: Variant = context.settings.get("character_aliases", {})
	if aliases_value is Dictionary and not character_id.is_empty():
		var alias := str((aliases_value as Dictionary).get(character_id, "")).strip_edges()
		if not alias.is_empty():
			return alias
	return package_name


func _sync_chat_companion_identity() -> void:
	var application_window := get_node_or_null("ApplicationWindow")
	if is_instance_valid(application_window) and application_window.has_method("set_chat_companion_identity"):
		application_window.call("set_chat_companion_identity", _effective_companion_display_name())


func _on_character_display_name_changed(_payload: Dictionary) -> void:
	_sync_chat_companion_identity()


func _on_character_changed(_payload: Dictionary) -> void:
	event_bus.publish(&"character.load_active_requested", {})



func _apply_debug_ui_state() -> void:
	%Background.visible = true
	%StatusBar.visible = true
	%OverlayModeButton.text = "Return to Desktop Overlay"
	%OverlayModeButton.tooltip_text = "Use the transparent desktop companion overlay"


func _apply_overlay_ui_state() -> void:
	%Background.visible = false
	%StatusBar.visible = false
	%OverlayModeButton.text = "Open Debug Window"
	%OverlayModeButton.tooltip_text = "Return to a normal application window for debugging"


func _apply_native_ui_state() -> void:
	# G12.5 native host is character-only. The old overlay UI is a full-canvas
	# Godot layer and would cover the 256x256 native client, stealing drag input.
	_apply_overlay_ui_state()
	# Startup/status UI belongs to the Godot application window, not the
	# adopted native render surface. Leaving it visible during handoff produces
	# a dark panel or startup text over the first character frame.
	if is_instance_valid(%StartupLayer):
		%StartupLayer.visible = false
	for node in [%BubblePanel, %HoverMenu, %ContextMenu, %QuickPanel, %NotificationPanel]:
		if is_instance_valid(node):
			node.visible = false
	var character_manager := get_node_or_null("CharacterManagerWindow") as Window
	if is_instance_valid(character_manager):
		character_manager.hide()


func _toggle_hover_master_sound() -> void:
	event_bus.publish(&"sound.master_toggle_requested", {})
	var bus_index := AudioServer.get_bus_index("Master")
	var muted := AudioServer.is_bus_mute(bus_index) if bus_index >= 0 else false
	%HoverMuteAllButton.text = "Unmute All" if muted else "Mute All"
	%HoverSoundButton.text = "🔇 Sound" if muted else "🔊 Sound"


func _toggle_hover_sfx() -> void:
	event_bus.publish(&"sound.sfx_toggle_requested", {})
	var enabled := bool(context.settings.get("sfx_enabled", true))
	%HoverSfxButton.text = "SFX: On" if enabled else "SFX: Off"


func _toggle_overlay_mode() -> void:
	var enabled: bool = not bool(context.runtime_config.get("overlay_enabled", false))
	context.update_runtime_config({"overlay_enabled": enabled})
	if not runtime_mode_authority.is_session_forced():
		services.settings_service.save_settings({"startInOverlay": enabled})
	if enabled:
		_apply_overlay_ui_state()
		_controller("MultiMonitorController").refresh()
		_controller("WindowController").apply_overlay_window()
	else:
		_apply_debug_ui_state()
		_controller("WindowController").apply_debug_window()
	event_bus.publish(&"click_through.refresh_requested", {})


func _bind_rust_bridge_if_present() -> void:
	var bridge: Node = get_node_or_null("OcpRuntimeBridge")
	if bridge == null:
		bridge = get_tree().root.find_child("OcpRuntimeBridge", true, false)
	if bridge != null:
		services.bridge_adapter.bind_bridge(bridge)
		if is_instance_valid(services.ai_service) and services.ai_service.has_method("bind_bridge"):
			services.ai_service.call("bind_bridge", bridge)
		if is_instance_valid(services.tts_service):
			services.tts_service.bind_bridge(bridge)
		if is_instance_valid(services.credential_service):
			services.credential_service.bind_bridge(bridge)
		if is_instance_valid(services.cloud_auth_service):
			services.cloud_auth_service.bind_bridge(bridge)
		if is_instance_valid(services.cloud_device_service):
			services.cloud_device_service.bind_bridge(bridge)
		if is_instance_valid(services.cloud_download_service):
			services.cloud_download_service.bind_bridge(bridge)
		if is_instance_valid(services.progression_queue_service):
			services.progression_queue_service.bind_bridge(bridge)
		if is_instance_valid(services.progression_event_service):
			services.progression_event_service.bind_bridge(bridge)
		if is_instance_valid(services.cloud_operations_service):
			services.cloud_operations_service.bind_bridge(bridge)
		if is_instance_valid(services.resource_monitor_service):
			services.resource_monitor_service.bind_bridge(bridge)


func _controller(node_name: String) -> Node:
	return %Controllers.get_node(node_name)


func _attach(script: Script, placeholder: Node) -> Node:
	placeholder.set_script(script)
	return placeholder
