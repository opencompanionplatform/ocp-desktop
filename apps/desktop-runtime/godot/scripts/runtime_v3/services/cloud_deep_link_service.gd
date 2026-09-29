extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudDeepLinkService

## Strict parser/dispatcher for OCP-owned desktop links.
## Unknown routes, fragments, extra query keys, and malformed package/version
## values are rejected before any Cloud or package operation is requested.

const STORE_PREFIX := "ocp://store/"
const CloudDownloadScript = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")


func handle_uri(uri: String) -> Dictionary:
	var projected := parse_uri(uri)
	if not bool(projected.get("ok", false)):
		return {"ok": false, "status": "invalid-deep-link"}
	var request := projected.get("request", {}) as Dictionary
	if is_instance_valid(event_bus):
		event_bus.publish(&"character_picker.open_requested", {})
		event_bus.publish(&"cloud.store.character_requested", request.duplicate(true))
	return {"ok": true, "status": "dispatched", "request": request.duplicate(true)}


static func parse_uri(uri: String) -> Dictionary:
	var value := uri.strip_edges()
	if value.length() > 2048 or not value.begins_with(STORE_PREFIX) or value.contains("#"):
		return {"ok": false}
	var tail := value.trim_prefix(STORE_PREFIX)
	if tail.count("?") != 1:
		return {"ok": false}
	var package_id := tail.get_slice("?", 0).uri_decode().strip_edges().to_lower()
	var query := tail.get_slice("?", 1)
	if query.count("&") != 0 or not query.begins_with("version="):
		return {"ok": false}
	var version := query.trim_prefix("version=").uri_decode().strip_edges()
	if not CloudDownloadScript.is_valid_package_id(package_id) \
	or not CloudDownloadScript.is_valid_version(version):
		return {"ok": false}
	return {
		"ok": true,
		"request": {
			"packageId": package_id,
			"version": version,
		},
	}


static func first_uri_argument(arguments: PackedStringArray) -> String:
	for raw in arguments:
		var value := str(raw).strip_edges()
		if value.begins_with("ocp://"):
			return value
	return ""
