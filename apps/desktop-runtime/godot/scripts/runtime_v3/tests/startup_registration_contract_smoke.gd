extends SceneTree

const StartupService := preload("res://scripts/runtime_v3/services/startup_registration_service.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var service = StartupService.new()
	get_root().add_child(service)
	var command := service.startup_command()
	var ok := OS.get_name() != "Windows" or (not command.is_empty() and command.to_lower().contains("start_g12_real_character_native_runtime.ps1"))
	print("[P3.4.7] startup_registration command_ready=", not command.is_empty(), " windows=", OS.get_name() == "Windows")
	service.queue_free()
	await process_frame
	quit(0 if ok else 1)
