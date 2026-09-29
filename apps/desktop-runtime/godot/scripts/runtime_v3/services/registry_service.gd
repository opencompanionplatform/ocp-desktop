extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3RegistryService

var local_registry_root: String = "user://packages"


func character_registry_path() -> String:
	return local_registry_root.path_join("characters")


func ensure_registry() -> bool:
	var error: Error = DirAccess.make_dir_recursive_absolute(character_registry_path())
	return error == OK
