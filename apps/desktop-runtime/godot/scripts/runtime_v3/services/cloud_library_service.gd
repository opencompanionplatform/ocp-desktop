extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudLibraryService

const CloudHttpTransportScript = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

## Provider-neutral OCP Cloud library client.
## Access tokens are session-only and are never persisted into RuntimeContext/settings.

const DEFAULT_TIMEOUT_SECONDS := 20.0

var _http: HTTPRequest
var _catalog_http: HTTPRequest
var _session: Node
var _cached_library: Array[Dictionary] = []
var _cached_catalog: Array[Dictionary] = []
var _request_in_flight := false
var _catalog_in_flight := false
var _library_status := "signed-out"


func start() -> void:
	if not is_instance_valid(_http):
		_http = HTTPRequest.new()
		CloudHttpTransportScript.configure_https_proxy(_http)
		_http.name = "OCPCloudLibraryRequest"
		_http.timeout = DEFAULT_TIMEOUT_SECONDS
		add_child(_http)
		_http.request_completed.connect(_on_library_request_completed)
	if not is_instance_valid(_catalog_http):
		_catalog_http = HTTPRequest.new()
		CloudHttpTransportScript.configure_https_proxy(_catalog_http)
		_catalog_http.name = "OCPCloudCatalogRequest"
		_catalog_http.timeout = DEFAULT_TIMEOUT_SECONDS
		add_child(_catalog_http)
		_catalog_http.request_completed.connect(_on_catalog_request_completed)
	if is_instance_valid(event_bus):
		event_bus.subscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))


func stop() -> void:
	if is_instance_valid(event_bus):
		event_bus.unsubscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
	_cached_library.clear()
	_cached_catalog.clear()
	_request_in_flight = false
	_catalog_in_flight = false
	_library_status = "signed-out"


func bind_session(target: Node) -> void:
	_session = target
	# Runtime creates and starts services before cross-binding them. Bootstrap
	# from the current session as well as from future cloud.session.changed events
	# so a restored secure session cannot miss the initial Library refresh.
	if is_signed_in():
		_library_status = "idle"
		call_deferred("refresh_library")
	else:
		_library_status = "signed-out"


func is_signed_in() -> bool:
	return is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in"))


func _session_access_token() -> String:
	if not is_signed_in() or not _session.has_method("access_token"):
		return ""
	return str(_session.call("access_token"))


func cached_library() -> Array[Dictionary]:
	return _cached_library.duplicate(true)


func cached_catalog() -> Array[Dictionary]:
	return _cached_catalog.duplicate(true)


func library_snapshot() -> Dictionary:
	var catalog_by_id: Dictionary = {}
	for raw_catalog in _cached_catalog:
		var catalog: Dictionary = raw_catalog
		catalog_by_id[str(catalog.get("characterId", ""))] = catalog
	var items: Array[Dictionary] = []
	for raw_library in _cached_library:
		var library: Dictionary = raw_library
		if str(library.get("productType", "")) != "character":
			continue
		var product_id := str(library.get("productId", ""))
		var catalog: Dictionary = catalog_by_id.get(product_id, {}) if catalog_by_id.get(product_id, {}) is Dictionary else {}
		items.append({
			"productId": product_id,
			"productType": "character",
			"entitled": bool(library.get("entitled", false)),
			"source": str(library.get("source", "grant")),
			"grantedAt": str(library.get("grantedAt", "")),
			"revokedAt": str(library.get("revokedAt", "")) if library.get("revokedAt", null) != null else "",
			"name": str(catalog.get("name", "")),
			"latestVersion": str(catalog.get("latestVersion", "")),
			"thumbnailUrl": str(catalog.get("thumbnailUrl", "")),
			"availability": str(catalog.get("availability", "unknown")) if not catalog.is_empty() else "unknown",
		})
	return {"status": _library_status, "items": items}


func _on_session_changed(payload: Dictionary) -> void:
	if bool(payload.get("signed_in", false)):
		_library_status = "idle"
		call_deferred("refresh_library")
		return
	_cached_library.clear()
	_cached_catalog.clear()
	_library_status = "signed-out"
	if is_instance_valid(event_bus):
		event_bus.publish(&"cloud.library.updated", {"status": "sign-in-required", "items": []})


func refresh_catalog() -> Dictionary:
	if _catalog_in_flight:
		return {"ok": false, "status": "busy"}
	var base_url := _cloud_api_base_url()
	if not is_valid_cloud_api_url(base_url):
		return {"ok": false, "status": "not-configured"}
	if not is_instance_valid(_catalog_http):
		start()
	_catalog_in_flight = true
	if is_instance_valid(event_bus):
		event_bus.publish(&"cloud.catalog.updated", {
			"status": "loading",
			"items": cached_catalog(),
		})
	var error := _catalog_http.request(
		"%s/v1/catalog/characters" % base_url.trim_suffix("/"),
		PackedStringArray(["Accept: application/json"]),
		HTTPClient.METHOD_GET
	)
	if error != OK:
		_catalog_in_flight = false
		if is_instance_valid(event_bus):
			event_bus.publish(&"cloud.catalog.updated", {
				"status": "error",
				"items": cached_catalog(),
			})
		return {"ok": false, "status": "error", "error": error_string(error)}
	return {"ok": true, "status": "loading"}


func refresh_library() -> Dictionary:
	if _request_in_flight:
		return {"ok": false, "status": "busy"}
	if not is_signed_in():
		_library_status = "signed-out"
		event_bus.publish(&"cloud.library.updated", {
			"status": "sign-in-required",
			"items": [],
		})
		return {"ok": false, "status": "sign-in-required"}
	var base_url := _cloud_api_base_url()
	if not is_valid_cloud_api_url(base_url):
		_library_status = "not-configured"
		event_bus.publish(&"cloud.library.updated", {
			"status": "not-configured",
			"items": [],
		})
		return {"ok": false, "status": "not-configured"}
	if not is_instance_valid(_http):
		start()
	_request_in_flight = true
	_library_status = "loading"
	event_bus.publish(&"cloud.library.updated", {
		"status": "loading",
		"items": cached_library(),
	})
	var error := _http.request(
		"%s/v1/library" % base_url.trim_suffix("/"),
		[
			"Accept: application/json",
			"Authorization: Bearer %s" % _session_access_token(),
		],
		HTTPClient.METHOD_GET
	)
	if error != OK:
		_request_in_flight = false
		_library_status = "error"
		event_bus.publish(&"cloud.library.updated", {
			"status": "error",
			"items": cached_library(),
		})
		return {"ok": false, "status": "error", "error": error_string(error)}
	return {"ok": true, "status": "loading"}


func _cloud_api_base_url() -> String:
	if not is_instance_valid(context):
		return ""
	return str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()


func _on_library_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_request_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		var status := "sign-in-required" if response_code in [401, 403] else "error"
		_library_status = "signed-out" if status == "sign-in-required" else "error"
		if status == "sign-in-required" and is_instance_valid(_session) and _session.has_method("clear"):
			_session.call("clear")
		event_bus.publish(&"cloud.library.updated", {
			"status": status,
			"items": cached_library(),
		})
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var projection := project_library_payload(parsed)
	if not bool(projection.get("ok", false)):
		_library_status = "error"
		event_bus.publish(&"cloud.library.updated", {
			"status": "error",
			"items": cached_library(),
		})
		return
	_cached_library = projection.get("items", [])
	_library_status = "synced"
	event_bus.publish(&"cloud.library.updated", {
		"status": "synced",
		"items": cached_library(),
	})
	if not _catalog_in_flight:
		refresh_catalog()


func _on_catalog_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_catalog_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		if is_instance_valid(event_bus):
			event_bus.publish(&"cloud.catalog.updated", {
				"status": "error",
				"items": cached_catalog(),
			})
		return
	var projection := project_catalog_payload(JSON.parse_string(body.get_string_from_utf8()))
	if not bool(projection.get("ok", false)):
		if is_instance_valid(event_bus):
			event_bus.publish(&"cloud.catalog.updated", {
				"status": "error",
				"items": cached_catalog(),
			})
		return
	_cached_catalog = projection.get("items", [])
	if is_instance_valid(event_bus):
		event_bus.publish(&"cloud.catalog.updated", {
			"status": "synced",
			"items": cached_catalog(),
		})


static func is_valid_cloud_api_url(value: String) -> bool:
	var uri := value.strip_edges()
	if uri in ["http://127.0.0.1:54321/functions/v1/cloud-api", "http://localhost:54321/functions/v1/cloud-api"]:
		return true
	if not uri.begins_with("https://") or uri.contains(" "):
		return false
	var host_and_path := uri.trim_prefix("https://")
	var host := host_and_path.get_slice("/", 0)
	return not host.is_empty() and host.contains(".") and not host.begins_with(".")


static func project_catalog_payload(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false, "items": []}
	var row := payload as Dictionary
	if not row.has("items") or not (row.get("items") is Array):
		return {"ok": false, "items": []}
	var items: Array[Dictionary] = []
	for raw_item in row.get("items"):
		if not (raw_item is Dictionary):
			return {"ok": false, "items": []}
		var item := raw_item as Dictionary
		if not item.has("characterId") or not item.has("name") or not item.has("publisher") \
		or not item.has("latestVersion") or not item.has("thumbnailUrl") or not item.has("availability"):
			return {"ok": false, "items": []}
		if not (item.get("publisher") is Dictionary):
			return {"ok": false, "items": []}
		var publisher := item.get("publisher") as Dictionary
		if str(item.get("characterId", "")).is_empty() or str(item.get("name", "")).is_empty() \
		or str(item.get("latestVersion", "")).is_empty() or str(publisher.get("publisherId", "")).is_empty() \
		or str(publisher.get("displayName", "")).is_empty() \
		or str(item.get("availability", "")) not in ["free", "entitlement-required"]:
			return {"ok": false, "items": []}
		items.append({
			"characterId": str(item.get("characterId")),
			"name": str(item.get("name")),
			"publisher": {
				"publisherId": str(publisher.get("publisherId")),
				"displayName": str(publisher.get("displayName")),
			},
			"latestVersion": str(item.get("latestVersion")),
			"thumbnailUrl": str(item.get("thumbnailUrl", "")),
			"availability": str(item.get("availability")),
		})
	return {"ok": true, "items": items}


static func project_library_payload(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false, "items": []}
	var raw_items: Variant = (payload as Dictionary).get("items", null)
	if not (raw_items is Array):
		return {"ok": false, "items": []}
	var items: Array[Dictionary] = []
	for raw_item in raw_items:
		if not (raw_item is Dictionary):
			return {"ok": false, "items": []}
		var item := raw_item as Dictionary
		var product_id := str(item.get("productId", ""))
		var product_type := str(item.get("productType", ""))
		var source := str(item.get("source", ""))
		var granted_at := str(item.get("grantedAt", ""))
		var revoked_at: Variant = item.get("revokedAt", null)
		if product_id.is_empty() or product_type.is_empty() or granted_at.is_empty():
			return {"ok": false, "items": []}
		if source not in ["free-install", "grant", "purchase"]:
			return {"ok": false, "items": []}
		if revoked_at != null and not (revoked_at is String):
			return {"ok": false, "items": []}
		items.append({
			"productId": product_id,
			"productType": product_type,
			"entitled": bool(item.get("entitled", false)),
			"source": source,
			"grantedAt": granted_at,
			"revokedAt": revoked_at,
		})
	return {"ok": true, "items": items}
