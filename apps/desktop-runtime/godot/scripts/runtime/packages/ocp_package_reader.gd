extends RefCounted
class_name OcpPackageReader
## Opens an OCP ZIP and returns the parsed manifest and entry document.

const ZipPathUtil = preload("res://scripts/runtime/packages/ocp_zip_path_util.gd")

const ERR_OK := 0
const ERR_NO_FILE := 1
const ERR_ZIP_OPEN := 2
const ERR_NO_MANIFEST := 3
const ERR_BAD_MANIFEST := 4
const ERR_NO_ENTRY := 5
const ERR_BAD_ENTRY := 6


class ReadResult:
	var ok: bool = false
	var error_code: int = ERR_OK
	var error_message: String = ""
	var manifest: Dictionary = {}
	var entry: Dictionary = {}
	var zip: ZIPReader = null
	var source_path: String = ""
	var zip_files: PackedStringArray = PackedStringArray()
	var manifest_zip_path: String = ""
	var entry_zip_path: String = ""
	var temp_copy_path: String = ""

	func close() -> void:
		if zip != null:
			zip.close()
			zip = null

		if not temp_copy_path.is_empty() \
		and FileAccess.file_exists(temp_copy_path):
			DirAccess.remove_absolute(temp_copy_path)

		temp_copy_path = ""


func read(ocp_path: String) -> ReadResult:
	var result := ReadResult.new()
	result.source_path = ocp_path.replace("\\", "/")
	var open_path: String = result.source_path

	print("OcpPackageReader.read: path = '%s'" % open_path)

	if not FileAccess.file_exists(open_path):
		if not FileAccess.file_exists(ocp_path):
			return _fail(
				result,
				ERR_NO_FILE,
				"File not found: %s" % open_path
			)
		open_path = ocp_path

	var zip := ZIPReader.new()
	var open_error: Error = zip.open(open_path)

	if open_error != OK:
		var temp_path: String = (
			"user://tmp_ocp_import_%d_%d.zip"
			% [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
		)

		var copy_error: Error = _copy_file(open_path, temp_path)
		if copy_error != OK:
			return _fail(
				result,
				ERR_ZIP_OPEN,
				"Cannot copy package to user://: error %d" % copy_error
			)

		open_error = zip.open(temp_path)
		if open_error != OK:
			DirAccess.remove_absolute(temp_path)
			return _fail(
				result,
				ERR_ZIP_OPEN,
				"Cannot open ZIP: error %d" % open_error
			)

		result.temp_copy_path = temp_path

	result.zip = zip
	result.zip_files = zip.get_files()

	_print_zip_entries(result.zip_files)

	result.manifest_zip_path = ZipPathUtil.resolve(
		result.zip_files,
		"manifest.json"
	)

	if result.manifest_zip_path.is_empty():
		return _fail(
			result,
			ERR_NO_MANIFEST,
			"manifest.json missing in package"
		)

	var manifest_bytes: PackedByteArray = zip.read_file(
		result.manifest_zip_path
	)
	var manifest_value: Variant = JSON.parse_string(
		manifest_bytes.get_string_from_utf8()
	)

	if not manifest_value is Dictionary:
		return _fail(
			result,
			ERR_BAD_MANIFEST,
			"manifest.json is not a valid JSON object"
		)

	result.manifest = manifest_value

	var requested_entry: String = str(
		result.manifest.get("entry", "")
	).strip_edges()

	if requested_entry.is_empty():
		return _fail(
			result,
			ERR_NO_ENTRY,
			"manifest.json missing 'entry' field"
		)

	if not ZipPathUtil.is_safe_relative_path(requested_entry):
		return _fail(
			result,
			ERR_NO_ENTRY,
			"Unsafe manifest entry path: %s" % requested_entry
		)

	result.entry_zip_path = ZipPathUtil.resolve(
		result.zip_files,
		requested_entry
	)

	print("OcpPackageReader.read: manifest entry = '%s'" % requested_entry)
	print(
		"OcpPackageReader.read: normalized entry = '%s'"
		% ZipPathUtil.normalize(requested_entry)
	)
	print(
		"OcpPackageReader.read: resolved ZIP entry = '%s'"
		% result.entry_zip_path
	)

	if result.entry_zip_path.is_empty():
		return _fail(
			result,
			ERR_NO_ENTRY,
			"Entry file not found in ZIP: %s" % requested_entry
		)

	var entry_bytes: PackedByteArray = zip.read_file(
		result.entry_zip_path
	)
	var entry_value: Variant = JSON.parse_string(
		entry_bytes.get_string_from_utf8()
	)

	if not entry_value is Dictionary:
		return _fail(
			result,
			ERR_BAD_ENTRY,
			"Entry file is not a valid JSON object: %s"
			% requested_entry
		)

	result.entry = entry_value
	result.ok = true

	print("OcpPackageReader.read: package read OK")
	return result


func resolve_entry(zip: ZIPReader, requested_path: String) -> String:
	return ZipPathUtil.resolve_from_zip(zip, requested_path)


func read_entry(zip: ZIPReader, requested_path: String) -> PackedByteArray:
	return ZipPathUtil.read(zip, requested_path)


func _copy_file(source_path: String, destination_path: String) -> Error:
	var source := FileAccess.open(source_path, FileAccess.READ)
	if source == null:
		return FileAccess.get_open_error()

	var destination := FileAccess.open(
		destination_path,
		FileAccess.WRITE
	)
	if destination == null:
		var destination_error: Error = FileAccess.get_open_error()
		source.close()
		return destination_error

	while source.get_position() < source.get_length():
		var remaining: int = (
			source.get_length() - source.get_position()
		)
		var chunk_size: int = mini(65536, remaining)
		destination.store_buffer(
			source.get_buffer(chunk_size)
		)

	source.close()
	destination.close()
	return OK


func _print_zip_entries(files: PackedStringArray) -> void:
	print("OcpPackageReader.read: ZIP entries (%d):" % files.size())

	for actual_path in files:
		print(
			"  actual='%s' normalized='%s'"
			% [actual_path, ZipPathUtil.normalize(actual_path)]
		)


func _fail(
	result: ReadResult,
	code: int,
	message: String
) -> ReadResult:
	result.ok = false
	result.error_code = code
	result.error_message = message

	push_warning("OcpPackageReader: " + message)
	result.close()
	return result
