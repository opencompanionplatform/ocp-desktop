extends RefCounted
class_name CharacterPackageInstaller
## Extracts a validated character package using normalized safe ZIP paths.

const ZipPathUtil = preload("res://scripts/runtime/packages/ocp_zip_path_util.gd")

const BASE_DIR := "user://packages/characters"
const STAGING_DIR := "user://packages/.staging"
const STATE_FILE := "user://runtime/state.json"


class InstallResult:
	var ok: bool = false
	var error_message: String = ""
	var installed_path: String = ""
	var package_id: String = ""
	var version: String = ""


func install(read_result: Object) -> InstallResult:
	var result := InstallResult.new()

	if read_result == null \
	or not bool(read_result.get("ok")):
		return _fail(
			result,
			"Package has not been read successfully"
		)

	var manifest: Dictionary = read_result.manifest
	var zip: ZIPReader = read_result.zip

	if zip == null:
		return _fail(
			result,
			"ZIPReader is closed - cannot extract files"
		)

	var package_id: String = str(
		manifest.get("packageId", manifest.get("id", ""))
	).strip_edges()
	var version: String = str(
		manifest.get("version", "")
	).strip_edges()

	if package_id.is_empty() or version.is_empty():
		return _fail(
			result,
			"packageId or version missing from manifest"
		)

	if not _is_safe_segment(package_id) \
	or not _is_safe_segment(version):
		return _fail(
			result,
			"Unsafe package id or version"
		)

	result.package_id = package_id
	result.version = version

	DirAccess.make_dir_recursive_absolute(BASE_DIR)
	DirAccess.make_dir_recursive_absolute(STAGING_DIR)

	var stage_dir: String = (
		"%s/%s-%s-%d"
		% [
			STAGING_DIR,
			package_id,
			version,
			Time.get_ticks_usec(),
		]
	)
	var destination_dir: String = (
		"%s/%s/%s"
		% [BASE_DIR, package_id, version]
	)

	var make_stage_error: Error = (
		DirAccess.make_dir_recursive_absolute(stage_dir)
	)
	if make_stage_error != OK:
		return _fail(
			result,
			"Cannot create staging directory: error %d"
			% make_stage_error
		)

	var extraction_error: String = _extract_all(
		zip,
		stage_dir
	)
	if not extraction_error.is_empty():
		_remove_dir_recursive(stage_dir)
		return _fail(result, extraction_error)

	var manifest_path: String = stage_dir.path_join(
		"manifest.json"
	)
	var entry_relative: String = ZipPathUtil.normalize(
		str(manifest.get("entry", ""))
	)
	var entry_path: String = stage_dir.path_join(
		entry_relative
	)

	if not FileAccess.file_exists(manifest_path):
		_remove_dir_recursive(stage_dir)
		return _fail(
			result,
			"Staged package has no manifest.json"
		)

	if entry_relative.is_empty() \
	or not FileAccess.file_exists(entry_path):
		_remove_dir_recursive(stage_dir)
		return _fail(
			result,
			"Staged package entry is missing: %s"
			% entry_relative
		)

	if DirAccess.dir_exists_absolute(destination_dir):
		if not _remove_dir_recursive(destination_dir):
			_remove_dir_recursive(stage_dir)
			return _fail(
				result,
				"Cannot replace existing package directory"
			)

	var destination_parent: String = (
		destination_dir.get_base_dir()
	)
	var make_parent_error: Error = (
		DirAccess.make_dir_recursive_absolute(
			destination_parent
		)
	)
	if make_parent_error != OK:
		_remove_dir_recursive(stage_dir)
		return _fail(
			result,
			"Cannot create package destination: error %d"
			% make_parent_error
		)

	var rename_error: Error = DirAccess.rename_absolute(
		stage_dir,
		destination_dir
	)
	if rename_error != OK:
		_remove_dir_recursive(stage_dir)
		return _fail(
			result,
			"Cannot commit staged package: error %d"
			% rename_error
		)

	result.installed_path = destination_dir
	result.ok = true

	_save_active_state(package_id, version)

	print(
		"CharacterPackageInstaller: installed '%s@%s' -> %s"
		% [package_id, version, destination_dir]
	)
	return result


func set_active(package_id: String, version: String) -> void:
	_save_active_state(package_id, version)


func _extract_all(zip: ZIPReader, destination_root: String) -> String:
	var files: PackedStringArray = zip.get_files()

	for actual_zip_path in files:
		var normalized_path: String = ZipPathUtil.normalize(
			actual_zip_path
		)

		if normalized_path.is_empty():
			continue

		if actual_zip_path.ends_with("/") \
		or actual_zip_path.ends_with("\\"):
			continue

		if not ZipPathUtil.is_safe_relative_path(
			actual_zip_path
		):
			return (
				"Unsafe ZIP path rejected: %s"
				% actual_zip_path
			)

		var destination_file: String = (
			ZipPathUtil.destination_path(
				destination_root,
				actual_zip_path
			)
		)
		if destination_file.is_empty():
			return (
				"Cannot resolve extraction path: %s"
				% actual_zip_path
			)

		var parent_dir: String = (
			destination_file.get_base_dir()
		)
		var make_error: Error = (
			DirAccess.make_dir_recursive_absolute(
				parent_dir
			)
		)
		if make_error != OK:
			return (
				"Cannot create extraction directory '%s': error %d"
				% [parent_dir, make_error]
			)

		# Use the actual ZIP entry name returned by get_files().
		var data: PackedByteArray = zip.read_file(
			actual_zip_path
		)
		var output := FileAccess.open(
			destination_file,
			FileAccess.WRITE
		)
		if output == null:
			return (
				"Cannot write '%s': error %d"
				% [
					destination_file,
					FileAccess.get_open_error(),
				]
			)

		output.store_buffer(data)
		output.close()

	return ""


func _save_active_state(
	package_id: String,
	version: String
) -> void:
	var state: Dictionary = {
		"activeCharacter": {
			"packageId": package_id,
			"version": version,
		}
	}

	DirAccess.make_dir_recursive_absolute(
		"user://runtime"
	)

	var file := FileAccess.open(
		STATE_FILE,
		FileAccess.WRITE
	)
	if file == null:
		push_warning(
			"CharacterPackageInstaller: cannot write state file"
		)
		return

	file.store_string(JSON.stringify(state, "\t"))
	file.close()


func _is_safe_segment(value: String) -> bool:
	if value.is_empty() \
	or value == "." \
	or value == "..":
		return false

	return (
		not value.contains("/")
		and not value.contains("\\")
		and not value.contains(":")
	)


func _remove_dir_recursive(path: String) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		return not DirAccess.dir_exists_absolute(path)

	directory.list_dir_begin()
	var name: String = directory.get_next()

	while not name.is_empty():
		if name != "." and name != "..":
			var child_path: String = path.path_join(name)

			if directory.current_is_dir():
				if not _remove_dir_recursive(child_path):
					directory.list_dir_end()
					return false
			else:
				var remove_error: Error = (
					DirAccess.remove_absolute(child_path)
				)
				if remove_error != OK:
					directory.list_dir_end()
					return false

		name = directory.get_next()

	directory.list_dir_end()
	return DirAccess.remove_absolute(path) == OK


func _fail(
	result: InstallResult,
	message: String
) -> InstallResult:
	result.ok = false
	result.error_message = message
	push_warning("CharacterPackageInstaller: " + message)
	return result
