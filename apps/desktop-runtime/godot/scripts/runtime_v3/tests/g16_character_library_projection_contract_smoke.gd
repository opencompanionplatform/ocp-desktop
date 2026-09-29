extends SceneTree

const ProjectionScript = preload("res://scripts/runtime_v3/services/character_library_projection.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var installed := [
		{"packageId": "character.local", "version": "1.0.0", "manifest": {"name": "Local Hero"}},
		{"packageId": "character.owned", "version": "1.0.0", "manifest": {"name": "Owned Hero"}},
		{"packageId": "character.legacy", "version": "2.0.0", "manifest": {"name": "Legacy"}},
	]
	var library := [
		{"productId": "character.owned", "productType": "character", "entitled": true, "source": "purchase", "revokedAt": null},
		{"productId": "character.cloud", "productType": "character", "entitled": true, "source": "grant", "revokedAt": null},
	]
	var catalog := [
		{"characterId": "character.owned", "name": "Owned Hero", "latestVersion": "1.2.0", "publisher": {"displayName": "OCP Official"}},
		{"characterId": "character.cloud", "name": "Cloud Hero", "latestVersion": "3.0.0", "publisher": {"displayName": "OCP Official"}},
	]
	var origins := {
		ProjectionScript.origin_key("character.local", "1.0.0"): "local-import",
		ProjectionScript.origin_key("character.owned", "1.0.0"): "cloud",
	}
	var entries: Array[Dictionary] = ProjectionScript.compose(
		installed,
		library,
		catalog,
		{"packageId": "character.owned", "version": "1.0.0"},
		origins
	)
	var by_id := {}
	for entry in entries:
		by_id[entry.get("package_id")] = entry
	var local: Dictionary = by_id.get("character.local", {})
	var owned: Dictionary = by_id.get("character.owned", {})
	var cloud: Dictionary = by_id.get("character.cloud", {})
	var legacy: Dictionary = by_id.get("character.legacy", {})
	var ok: bool = entries.size() == 4 \
		and local.get("origin") == "local-import" \
		and not bool(local.get("owned")) \
		and local.get("secondary_action") == "Edit" \
		and owned.get("origin") == "cloud" \
		and bool(owned.get("owned")) \
		and bool(owned.get("active")) \
		and owned.get("update_state") == "update-available" \
		and owned.get("secondary_action") == "Details" \
		and bool(cloud.get("owned")) \
		and not bool(cloud.get("installed")) \
		and ProjectionScript.status_labels(cloud).has("Not Installed") \
		and legacy.get("origin") == "unknown" \
		and not ProjectionScript.status_labels(legacy).has("Local")
	print("[G16.3] entries=%d local=%s owned_active=%s cloud_not_installed=%s legacy_unknown=%s" % [
		entries.size(), str(local.get("origin")), str(owned.get("active")),
		str(not bool(cloud.get("installed"))), str(legacy.get("origin")),
	])
	quit(0 if ok else 1)
