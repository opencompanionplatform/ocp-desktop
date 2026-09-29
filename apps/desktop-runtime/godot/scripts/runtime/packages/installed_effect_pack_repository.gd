extends RefCounted
class_name InstalledEffectPackRepository

const BASE_DIR := "user://packages/effects"


func list_installed() -> Array:
	var results: Array = []
	var root := DirAccess.open(BASE_DIR)
	if root == null:
		return results
	root.list_dir_begin()
	var package_id := root.get_next()
	while not package_id.is_empty():
		if root.current_is_dir() and not package_id.begins_with("."):
			var versions := DirAccess.open(BASE_DIR.path_join(package_id))
			if versions != null:
				versions.list_dir_begin()
				var version := versions.get_next()
				while not version.is_empty():
					if versions.current_is_dir() and not version.begins_with("."):
						var item := find_exact(package_id, version)
						if not item.is_empty():
							results.append(item)
					version = versions.get_next()
				versions.list_dir_end()
		package_id = root.get_next()
	root.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("packageId", "")) + "@" + str(a.get("version", "")) < str(b.get("packageId", "")) + "@" + str(b.get("version", ""))
	)
	return results


func find_exact(package_id: String, version: String) -> Dictionary:
	if not _safe_segment(package_id) or not _safe_segment(version):
		return {}
	var path := BASE_DIR.path_join(package_id).path_join(version)
	if not DirAccess.dir_exists_absolute(path):
		return {}
	var manifest := _read_json(path.path_join("manifest.json"))
	if str(manifest.get("type", "")) != "effect-pack":
		return {}
	var entry_path := str(manifest.get("entry", ""))
	if entry_path.is_empty() or not FileAccess.file_exists(path.path_join(entry_path)):
		return {}
	var verification := _verify_managed(path)
	if not bool(verification.get("ok", false)):
		return {}
	if bool(verification.get("managed", false)):
		var trusted_manifest: Variant = JSON.parse_string(str(verification.get("manifest_json", "")))
		if trusted_manifest is Dictionary:
			manifest = trusted_manifest
	var entry := _read_json(path.path_join(str(manifest.get("entry", entry_path))))
	if entry.is_empty():
		return {}
	return {
		"packageId": package_id,
		"version": version,
		"path": path,
		"manifest": manifest,
		"entry": entry,
		"_verification": verification,
	}


func uninstall(package_id: String, version: String) -> bool:
	var item := find_exact(package_id, version)
	if item.is_empty():
		return false
	return _remove_dir_recursive(str(item.get("path", "")))


func _verify_managed(path: String) -> Dictionary:
	if ClassDB.class_has_method(&"OcpRuntimeBridge", &"verify_installed_cloud_package"):
		var value: Variant = ClassDB.class_call_static(
			&"OcpRuntimeBridge",
			&"verify_installed_cloud_package",
			ProjectSettings.globalize_path(path)
		)
		if value is Dictionary:
			return value
	# Local/manual starter packs are data-only and are validated again by the
	# EffectPackService before use. Store-managed packs must pass native trust.
	return {"ok": true, "managed": false}


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return value if value is Dictionary else {}


func _safe_segment(value: String) -> bool:
	return not value.is_empty() and not value.begins_with(".") and not value.contains("/") and not value.contains("\\") and not value.contains(":")


func _remove_dir_recursive(path: String) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		return false
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name not in [".", ".."]:
			var child := path.path_join(name)
			if directory.current_is_dir():
				_remove_dir_recursive(child)
			else:
				DirAccess.remove_absolute(child)
		name = directory.get_next()
	directory.list_dir_end()
	return DirAccess.remove_absolute(path) == OK
