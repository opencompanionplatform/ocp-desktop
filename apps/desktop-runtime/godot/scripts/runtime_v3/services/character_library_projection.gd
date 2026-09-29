extends RefCounted
class_name RuntimeV3CharacterLibraryProjection

## Pure projection used by Character Manager. Ownership is accepted only from
## the Cloud Library input; local manifests and install paths never grant it.


static func origin_key(package_id: String, version: String) -> String:
	return "%s@%s" % [package_id, version]


static func compose(
	installed: Array,
	library: Array,
	catalog: Array,
	active: Dictionary,
	origins: Dictionary
) -> Array[Dictionary]:
	var owned_by_id := _owned_index(library)
	var catalog_by_id := _catalog_index(catalog)
	var results: Array[Dictionary] = []
	var installed_ids := {}

	for raw_package in installed:
		if not (raw_package is Dictionary):
			continue
		var package := raw_package as Dictionary
		var package_id := str(package.get("packageId", ""))
		var version := str(package.get("version", ""))
		if package_id.is_empty() or version.is_empty():
			continue
		installed_ids[package_id] = true
		var manifest: Dictionary = package.get("manifest", {}) if package.get("manifest", {}) is Dictionary else {}
		var catalog_item: Dictionary = catalog_by_id.get(package_id, {})
		var library_item: Dictionary = owned_by_id.get(package_id, {})
		var origin := _origin_for(origins, package_id, version)
		var is_active := str(active.get("packageId", "")) == package_id \
			and str(active.get("version", "")) == version
		var latest_version := str(catalog_item.get("latestVersion", ""))
		results.append(_entry(
			package_id,
			version,
			latest_version,
			manifest,
			catalog_item,
			library_item,
			origin,
			true,
			is_active,
			package
		))

	for package_id_value in owned_by_id.keys():
		var package_id := str(package_id_value)
		if bool(installed_ids.get(package_id, false)):
			continue
		var catalog_item: Dictionary = catalog_by_id.get(package_id, {})
		var library_item: Dictionary = owned_by_id[package_id]
		var latest_version := str(catalog_item.get("latestVersion", ""))
		results.append(_entry(
			package_id,
			latest_version,
			latest_version,
			{},
			catalog_item,
			library_item,
			"cloud",
			false,
			false,
			{}
		))

	results.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if bool(left.get("active", false)) != bool(right.get("active", false)):
			return bool(left.get("active", false))
		return str(left.get("display_name", "")).naturalnocasecmp_to(
			str(right.get("display_name", ""))
		) < 0
	)
	return results


static func _entry(
	package_id: String,
	version: String,
	latest_version: String,
	manifest: Dictionary,
	catalog_item: Dictionary,
	library_item: Dictionary,
	origin: String,
	installed: bool,
	active: bool,
	package: Dictionary
) -> Dictionary:
	var owned := not library_item.is_empty()
	var display_name := str(catalog_item.get("name", manifest.get("name", ""))).strip_edges()
	if display_name.is_empty():
		display_name = package_id.trim_prefix("character.").replace("_", " ").capitalize()
	var publisher_value: Variant = catalog_item.get("publisher", manifest.get("publisher", {}))
	var publisher := ""
	if publisher_value is Dictionary:
		publisher = str((publisher_value as Dictionary).get(
			"displayName",
			(publisher_value as Dictionary).get("id", "")
		))
	var update_state := "unknown"
	if installed and not latest_version.is_empty():
		update_state = "update-available" if _version_compare(version, latest_version) < 0 else "current"
	var secondary_action := "Edit" if origin == "local-import" else "Details"
	return {
		"package_id": package_id,
		"version": version,
		"latest_version": latest_version,
		"display_name": display_name,
		"publisher": publisher,
		"origin": origin,
		"owned": owned,
		"installed": installed,
		"active": active,
		"update_state": update_state,
		"secondary_action": secondary_action,
		"package": package.duplicate(true),
		"manifest": manifest.duplicate(true),
		"catalog": catalog_item.duplicate(true),
		"library": library_item.duplicate(true),
	}


static func status_labels(entry: Dictionary) -> Array[String]:
	var labels: Array[String] = []
	match str(entry.get("origin", "unknown")):
		"bundled": labels.append("Bundled")
		"local-import": labels.append("Local")
		"cloud":
			if not bool(entry.get("owned", false)):
				labels.append("Cloud")
	if bool(entry.get("owned", false)):
		labels.append("Owned")
	if bool(entry.get("installed", false)):
		labels.append("Installed")
	else:
		labels.append("Not Installed")
	if bool(entry.get("active", false)):
		labels.append("Active")
	if str(entry.get("update_state", "unknown")) == "update-available":
		labels.append("Update Available")
	return labels


static func _origin_for(origins: Dictionary, package_id: String, version: String) -> String:
	var value := str(origins.get(origin_key(package_id, version), origins.get(package_id, "unknown")))
	return value if value in ["bundled", "local-import", "cloud"] else "unknown"


static func _owned_index(library: Array) -> Dictionary:
	var result := {}
	for raw_item in library:
		if not (raw_item is Dictionary):
			continue
		var item := raw_item as Dictionary
		var package_id := str(item.get("productId", ""))
		if str(item.get("productType", "")) != "character" \
		or package_id.is_empty() \
		or not bool(item.get("entitled", false)) \
		or item.get("revokedAt", null) != null:
			continue
		result[package_id] = item.duplicate(true)
	return result


static func _catalog_index(catalog: Array) -> Dictionary:
	var result := {}
	for raw_item in catalog:
		if not (raw_item is Dictionary):
			continue
		var item := raw_item as Dictionary
		var package_id := str(item.get("characterId", ""))
		if not package_id.is_empty():
			result[package_id] = item.duplicate(true)
	return result


static func _version_compare(left: String, right: String) -> int:
	var left_core := left.get_slice("-", 0).split(".")
	var right_core := right.get_slice("-", 0).split(".")
	for index in range(maxi(left_core.size(), right_core.size())):
		var left_value := int(left_core[index]) if index < left_core.size() and str(left_core[index]).is_valid_int() else 0
		var right_value := int(right_core[index]) if index < right_core.size() and str(right_core[index]).is_valid_int() else 0
		if left_value < right_value:
			return -1
		if left_value > right_value:
			return 1
	return 0

