extends RefCounted
class_name EffectPackInstaller
## Extracts a validated data-only effect pack to its isolated repository.

const ZipPathUtil = preload("res://scripts/runtime/packages/ocp_zip_path_util.gd")

const BASE_DIR := "user://packages/effects"
const STAGING_DIR := "user://packages/.staging-effects"


class InstallResult:
	var ok := false
	var error_message := ""
	var installed_path := ""
	var package_id := ""
	var version := ""


func install(read_result: Object) -> InstallResult:
	var result := InstallResult.new()
	if read_result == null or not bool(read_result.get("ok")):
		return _fail(result, "Package has not been read successfully")
	var manifest: Dictionary = read_result.manifest
	if str(manifest.get("type", "")) != "effect-pack":
		return _fail(result, "Not an effect-pack package")
	var zip: ZIPReader = read_result.zip
	if zip == null:
		return _fail(result, "ZIPReader is closed - cannot extract files")

	var package_id := str(manifest.get("packageId", manifest.get("id", ""))).strip_edges()
	var version := str(manifest.get("version", "")).strip_edges()
	if not _safe_segment(package_id) or not _safe_segment(version):
		return _fail(result, "Unsafe effect-pack id or version")
	result.package_id = package_id
	result.version = version

	DirAccess.make_dir_recursive_absolute(BASE_DIR)
	DirAccess.make_dir_recursive_absolute(STAGING_DIR)
	var stage := "%s/%s-%s-%d" % [STAGING_DIR, package_id, version, Time.get_ticks_usec()]
	var destination := BASE_DIR.path_join(package_id).path_join(version)
	if DirAccess.make_dir_recursive_absolute(stage) != OK:
		return _fail(result, "Cannot create effect-pack staging directory")
	var extraction_error := _extract_all(zip, stage)
	if not extraction_error.is_empty():
		_remove_dir_recursive(stage)
		return _fail(result, extraction_error)

	var entry := ZipPathUtil.normalize(str(manifest.get("entry", "")))
	if not FileAccess.file_exists(stage.path_join("manifest.json")) or entry.is_empty() or not FileAccess.file_exists(stage.path_join(entry)):
		_remove_dir_recursive(stage)
		return _fail(result, "Staged effect-pack entry is missing")
	if DirAccess.dir_exists_absolute(destination) and not _remove_dir_recursive(destination):
		_remove_dir_recursive(stage)
		return _fail(result, "Cannot replace existing effect-pack directory")
	DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
	var rename_error := DirAccess.rename_absolute(stage, destination)
	if rename_error != OK:
		_remove_dir_recursive(stage)
		return _fail(result, "Cannot commit staged effect-pack: error %d" % rename_error)
	result.installed_path = destination
	result.ok = true
	return result


func _extract_all(zip: ZIPReader, destination_root: String) -> String:
	for actual_path in zip.get_files():
		if actual_path.ends_with("/") or actual_path.ends_with("\\"):
			continue
		if not ZipPathUtil.is_safe_relative_path(actual_path):
			return "Unsafe ZIP path rejected: %s" % actual_path
		var destination := ZipPathUtil.destination_path(destination_root, actual_path)
		if destination.is_empty():
			return "Cannot resolve effect-pack extraction path"
		DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		var output := FileAccess.open(destination, FileAccess.WRITE)
		if output == null:
			return "Cannot write effect-pack member: %s" % actual_path
		output.store_buffer(zip.read_file(actual_path))
		output.close()
	return ""


func _safe_segment(value: String) -> bool:
	return not value.is_empty() and value not in [".", ".."] and not value.contains("/") and not value.contains("\\") and not value.contains(":")


func _remove_dir_recursive(path: String) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		return not DirAccess.dir_exists_absolute(path)
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name not in [".", ".."]:
			var child := path.path_join(name)
			if directory.current_is_dir():
				if not _remove_dir_recursive(child):
					directory.list_dir_end()
					return false
			elif DirAccess.remove_absolute(child) != OK:
				directory.list_dir_end()
				return false
		name = directory.get_next()
	directory.list_dir_end()
	return DirAccess.remove_absolute(path) == OK


func _fail(result: InstallResult, message: String) -> InstallResult:
	result.ok = false
	result.error_message = message
	push_warning("EffectPackInstaller: " + message)
	return result
