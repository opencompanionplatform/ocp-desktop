extends SceneTree

const CloudLibraryServiceScript = preload("res://scripts/runtime_v3/services/cloud_library_service.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid_payload := {
		"items": [{
			"productId": "character.sabai",
			"productType": "character",
			"entitled": true,
			"source": "free-install",
			"grantedAt": "2026-08-26T10:00:00Z",
			"revokedAt": null,
			"storage_object_key": "must-not-project",
		}]
	}
	var projected: Dictionary = CloudLibraryServiceScript.project_library_payload(valid_payload)
	var projected_items: Array = projected.get("items", [])
	var projected_item: Dictionary = projected_items[0] if not projected_items.is_empty() else {}
	var projection_ok: bool = bool(projected.get("ok", false)) \
		and projected_items.size() == 1 \
		and projected_item.get("productId") == "character.sabai" \
		and not projected_item.has("storage_object_key")
	var invalid_payload_rejected: bool = not bool(CloudLibraryServiceScript.project_library_payload({
		"items": [{
			"productId": "character.sabai",
			"productType": "character",
			"entitled": true,
			"source": "forged",
			"grantedAt": "2026-08-26T10:00:00Z",
			"revokedAt": null,
		}]
	}).get("ok", true))
	var catalog_payload := {
		"items": [{
			"characterId": "character.sabai",
			"name": "Sabai",
			"publisher": {"publisherId": "publisher.ocp", "displayName": "OCP"},
			"latestVersion": "1.2.0",
			"thumbnailUrl": "https://cdn.example/sabai.webp",
			"availability": "free",
			"storageObjectKey": "must-not-project",
		}],
		"nextCursor": null,
	}
	var catalog_projection: Dictionary = CloudLibraryServiceScript.project_catalog_payload(catalog_payload)
	var catalog_items: Array = catalog_projection.get("items", [])
	var catalog_item: Dictionary = catalog_items[0] if not catalog_items.is_empty() else {}
	var catalog_ok: bool = bool(catalog_projection.get("ok", false)) \
		and catalog_item.get("latestVersion") == "1.2.0" \
		and not catalog_item.has("storageObjectKey") \
		and not bool(CloudLibraryServiceScript.project_catalog_payload({"items": [{"characterId": "character.sabai"}]}).get("ok", true))
	var url_policy_ok: bool = CloudLibraryServiceScript.is_valid_cloud_api_url("https://api.ocp.example/functions/v1/cloud-api") \
		and CloudLibraryServiceScript.is_valid_cloud_api_url("http://127.0.0.1:54321/functions/v1/cloud-api") \
		and not CloudLibraryServiceScript.is_valid_cloud_api_url("http://api.ocp.example") \
		and not CloudLibraryServiceScript.is_valid_cloud_api_url("https://")

	var ok: bool = projection_ok and invalid_payload_rejected and catalog_ok and url_policy_ok
	print("[G16.2] projection=%s invalid_rejected=%s catalog=%s url_policy=%s" % [
		str(projection_ok).to_lower(), str(invalid_payload_rejected).to_lower(), str(catalog_ok).to_lower(), str(url_policy_ok).to_lower(),
	])
	quit(0 if ok else 1)
