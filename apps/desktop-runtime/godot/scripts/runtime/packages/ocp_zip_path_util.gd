extends RefCounted
class_name OcpZipPathUtil
## Shared ZIP path handling for OCP Reader, Validator and Installer.
##
## ZIP files created on Windows may expose entries as:
##   assets\character.json
## while manifest paths use:
##   assets/character.json
##
## All package-layer code must resolve manifest paths through this utility and
## use the actual ZIP entry returned by resolve() when calling read_file().

static func normalize(path: String) -> String:
	var normalized: String = path.strip_edges().replace("\\", "/")

	while normalized.begins_with("./"):
		normalized = normalized.trim_prefix("./")

	while normalized.begins_with("/"):
		normalized = normalized.trim_prefix("/")

	while normalized.contains("//"):
		normalized = normalized.replace("//", "/")

	return normalized


static func resolve(
	files: PackedStringArray,
	requested_path: String,
	case_insensitive_fallback: bool = true
) -> String:
	var requested_normalized: String = normalize(requested_path)

	if requested_normalized.is_empty():
		return ""

	for actual_path in files:
		if normalize(actual_path) == requested_normalized:
			return actual_path

	if not case_insensitive_fallback:
		return ""

	var requested_lower: String = requested_normalized.to_lower()

	for actual_path in files:
		if normalize(actual_path).to_lower() == requested_lower:
			push_warning(
				"OcpZipPathUtil: ZIP entry case mismatch: requested '%s', actual '%s'"
				% [requested_path, actual_path]
			)
			return actual_path

	return ""


static func exists(zip: ZIPReader, requested_path: String) -> bool:
	return not resolve_from_zip(zip, requested_path).is_empty()


static func resolve_from_zip(zip: ZIPReader, requested_path: String) -> String:
	if zip == null:
		return ""
	return resolve(zip.get_files(), requested_path)


static func read(zip: ZIPReader, requested_path: String) -> PackedByteArray:
	var actual_path: String = resolve_from_zip(zip, requested_path)
	if actual_path.is_empty():
		return PackedByteArray()
	return zip.read_file(actual_path)


static func is_safe_relative_path(path: String) -> bool:
	var normalized: String = normalize(path)

	if normalized.is_empty():
		return false

	if path.begins_with("/") or path.begins_with("\\"):
		return false

	# Reject Windows drive paths, URI-like paths and traversal.
	if normalized.length() >= 2 and normalized[1] == ":":
		return false

	for segment in normalized.split("/", false):
		if segment == ".." or segment == ".":
			return false
		if segment.contains(":"):
			return false

	return true


static func destination_path(root: String, zip_path: String) -> String:
	if not is_safe_relative_path(zip_path):
		return ""

	return root.path_join(normalize(zip_path))


static func list_normalized(files: PackedStringArray) -> PackedStringArray:
	var result := PackedStringArray()

	for file_path in files:
		result.append(normalize(file_path))

	return result
