extends SceneTree

const Auth = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const Device = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const Download = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")
const Library = preload("res://scripts/runtime_v3/services/cloud_library_service.gd")
const Progression = preload("res://scripts/runtime_v3/services/cloud_progression_service.gd")

func _initialize() -> void:
	var instances := [Auth.new(), Device.new(), Download.new(), Library.new(), Progression.new()]
	var ok := instances.size() == 5
	print("[CLOUD-SERVICES-PARSE] count=", instances.size(), " ok=", ok)
	for instance in instances:
		instance.free()
	quit(0 if ok else 1)
