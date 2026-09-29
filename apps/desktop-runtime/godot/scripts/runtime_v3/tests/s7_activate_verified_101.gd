extends SceneTree

const Repository = preload("res://scripts/runtime/packages/installed_character_repository.gd")
const Installer = preload("res://scripts/runtime/packages/character_package_installer.gd")

func _initialize() -> void:
	var package_id := "character.sabai-sompoo"
	var version := "1.0.1"
	var exact: Dictionary = Repository.new().find_exact(package_id, version)
	if exact.is_empty():
		print("[S7-ACTIVATE] verified=false active=false")
		quit(2)
		return
	Installer.new().set_active(package_id, version)
	var active: Dictionary = Repository.new().get_active_candidate()
	var ok := str(active.get("packageId", "")) == package_id and str(active.get("version", "")) == version
	print("[S7-ACTIVATE] verified=true active=%s package=%s version=%s" % [str(ok).to_lower(), package_id, version])
	quit(0 if ok else 3)
