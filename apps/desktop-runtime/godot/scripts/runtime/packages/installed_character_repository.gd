extends RefCounted
## InstalledCharacterRepository — queries installed .ocp character packages
## from user://packages/characters/ and reads the active character from
## user://runtime/state.json.
##
## Usage:
##   var repo := InstalledCharacterRepository.new()
##   var all  := repo.list_installed()          # Array[Dictionary]
##   var pkg  := repo.find_by_id("char.warin")  # Dictionary or {}
##   var act  := repo.get_active()              # Dictionary or {}
##   repo.uninstall("char.warin", "1.0.0")

class_name InstalledCharacterRepository

const BASE_DIR   := "user://packages/characters"
const STATE_FILE := "user://runtime/state.json"
const Verification = preload("res://scripts/runtime/packages/installed_package_verification.gd")


## Return Array of info dictionaries for every installed character package.
## Each dict: { packageId, version, path, manifest }
func list_installed(verified_package_info: Dictionary = {}) -> Array:
	var results: Array = []
	# A managed active package may already have completed full native verification
	# earlier in this Runtime session. Reuse only that exact immutable projection;
	# every other installed package still goes through find_exact() below.
	var reusable_id := str(verified_package_info.get("packageId", ""))
	var reusable_version := str(verified_package_info.get("version", ""))
	var reusable_path := str(verified_package_info.get("path", ""))
	var reusable_verification_value: Variant = verified_package_info.get("_verification", {})
	var reusable_verification: Dictionary = reusable_verification_value if reusable_verification_value is Dictionary else {}
	var reusable_managed := bool(reusable_verification.get("ok", false)) and bool(reusable_verification.get("managed", false))
	var id_dir := DirAccess.open(BASE_DIR)
	if id_dir == null:
		return results  # nothing installed yet

	id_dir.list_dir_begin()
	var pkg_id := id_dir.get_next()
	while pkg_id != "":
		if id_dir.current_is_dir() and not pkg_id.begins_with("."):
			var ver_path := BASE_DIR.path_join(pkg_id)
			var ver_dir  := DirAccess.open(ver_path)
			if ver_dir:
				ver_dir.list_dir_begin()
				var version := ver_dir.get_next()
				while version != "":
					if ver_dir.current_is_dir() and not version.begins_with("."):
						var exact_path := ver_path.path_join(version)
						var can_reuse := reusable_managed \
							and pkg_id == reusable_id \
							and version == reusable_version \
							and reusable_path == exact_path \
							and DirAccess.dir_exists_absolute(exact_path)
						var info: Dictionary = verified_package_info.duplicate(true) if can_reuse else find_exact(pkg_id, version)
						if not info.is_empty():
							results.append(info)
					version = ver_dir.get_next()
				ver_dir.list_dir_end()
		pkg_id = id_dir.get_next()
	id_dir.list_dir_end()
	return results


## Find the latest installed version of a package by ID.
## Returns {} if not found.
func find_by_id(package_id: String) -> Dictionary:
	var all := list_installed()
	var matches := all.filter(func(p): return p["packageId"] == package_id)
	if matches.is_empty():
		return {}
	# Return the last one (simple lexicographic version sort is fine for semver)
	matches.sort_custom(func(a, b): return a["version"] < b["version"])
	return matches[-1]


## Find an exact packageId + version pair. Returns {} if not found.
func find_exact(package_id: String, version: String) -> Dictionary:
	for component in [package_id, version]:
		if component.is_empty() or component.begins_with(".") or "/" in component or "\\" in component or ":" in component:
			return {}
	var path := BASE_DIR.path_join(package_id).path_join(version)
	if not DirAccess.dir_exists_absolute(path):
		return {}
	var verification: Dictionary = Verification.verify(path)
	if not bool(verification.get("ok", false)):
		return {}
	var manifest := _read_manifest(path)
	if bool(verification.get("managed", false)):
		var trusted_manifest: Variant = JSON.parse_string(str(verification.get("manifest_json", "")))
		if trusted_manifest is Dictionary:
			manifest = trusted_manifest
	return {
		"packageId": package_id,
		"version":   version,
		"path":      path,
		"manifest":  manifest,
		# Internal only: callers may reuse the verification snapshot within the
		# same projection/load operation instead of re-running the full archive +
		# filesystem verification immediately. Never project this dictionary to
		# Electron or persist it as package state.
		"_verification": verification,
	}


## Return the active character info from user://runtime/state.json.
## Returns {} if no state file or no active character recorded.
func get_active() -> Dictionary:
	var candidate := get_active_candidate()
	if candidate.is_empty():
		return {}
	return find_exact(str(candidate.get("packageId", "")), str(candidate.get("version", "")))


## Resolve only the persisted active identity/path. This method deliberately
## does NOT establish package trust. It exists for the startup handoff into
## CharacterService, which immediately performs the native Store verification
## exactly once before reading/decoding character assets.
func get_active_candidate() -> Dictionary:
	if not FileAccess.file_exists(STATE_FILE):
		return {}
	var text := FileAccess.get_file_as_string(STATE_FILE)
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return {}
	var active = parsed.get("activeCharacter", null)
	if not active is Dictionary:
		return {}
	var pkg_id := str(active.get("packageId", ""))
	var version := str(active.get("version", ""))
	for component in [pkg_id, version]:
		if component.is_empty() or component.begins_with(".") or "/" in component or "\\" in component or ":" in component:
			return {}
	var path := BASE_DIR.path_join(pkg_id).path_join(version)
	if not DirAccess.dir_exists_absolute(path):
		return {}
	return {
		"packageId": pkg_id,
		"version": version,
		"path": path,
		"manifest": _read_manifest(path),
	}


## Uninstall a specific packageId@version by deleting its directory.
## Returns true on success.
func uninstall(package_id: String, version: String) -> bool:
	var pkg_dir := BASE_DIR.path_join(package_id).path_join(version)
	if not DirAccess.dir_exists_absolute(pkg_dir):
		push_warning("InstalledCharacterRepository: not installed: %s@%s" % [package_id, version])
		return false
	# Capture active identity before deletion. get_active() resolves the package
	# directory, so calling it after removal would return an empty dictionary and
	# leave stale activeCharacter state behind.
	var active := get_active()
	var ok := _remove_dir_recursive(pkg_dir)
	# If the active character was this one, clear the state
	if ok and active.get("packageId", "") == package_id and active.get("version", "") == version:
		if FileAccess.file_exists(STATE_FILE):
			DirAccess.remove_absolute(STATE_FILE)
	return ok


# ── private ──────────────────────────────────────────────────────────────────

func _read_manifest(pkg_path: String) -> Dictionary:
	var mf := pkg_path.path_join("manifest.json")
	if not FileAccess.file_exists(mf):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(mf))
	return parsed if parsed is Dictionary else {}


func _remove_dir_recursive(path: String) -> bool:
	var da := DirAccess.open(path)
	if da == null:
		push_warning("InstalledCharacterRepository: cannot open for removal: %s" % path)
		return false
	var ok := true
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		if name != "." and name != "..":
			var full := path.path_join(name)
			if da.current_is_dir():
				if not _remove_dir_recursive(full):
					ok = false
			else:
				var file_error := DirAccess.remove_absolute(full)
				if file_error != OK:
					push_warning("InstalledCharacterRepository: failed to remove file %s (error=%s)" % [full, file_error])
					ok = false
		name = da.get_next()
	da.list_dir_end()
	if not ok:
		return false
	var dir_error := DirAccess.remove_absolute(path)
	if dir_error != OK:
		push_warning("InstalledCharacterRepository: failed to remove directory %s (error=%s)" % [path, dir_error])
		return false
	return true
