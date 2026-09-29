extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudDeviceService

const CloudHttpTransportScript = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

## Registers one random installation UUID with OCP Cloud after authentication.
## No hardware fingerprint is collected.

const CloudAuthScript = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const DEVICE_FILE := "user://runtime/cloud-device.json"
const DEFAULT_RUNTIME_VERSION := "0.1.0"
const DEFAULT_TIMEOUT_SECONDS := 20.0

var _session: Node
var _bridge: Node
var _request: HTTPRequest
var _request_in_flight := false


func bind_session(target: Node) -> void:
	_session = target
	# Cross-binding happens after service start. If authentication was restored
	# during startup, bootstrap device registration now instead of depending on
	# an event that may already have fired.
	if is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in")):
		if not _session.has_method("device_id") or str(_session.call("device_id")).strip_edges().is_empty():
			call_deferred("ensure_registered")


func bind_bridge(target: Node) -> void:
	_bridge = target
	# A restored session can ask for device registration before the native bridge
	# is available to mint the installation UUID. Retry once bridge binding
	# completes so startup cannot remain stuck in device-registration-required.
	if is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in")):
		if not _session.has_method("device_id") or str(_session.call("device_id")).strip_edges().is_empty():
			call_deferred("ensure_registered")


func start() -> void:
	_request = HTTPRequest.new()
	CloudHttpTransportScript.configure_https_proxy(_request)
	_request.name = "CloudDeviceHttpRequest"
	_request.timeout = DEFAULT_TIMEOUT_SECONDS
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)
	if is_instance_valid(event_bus):
		event_bus.subscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))


func stop() -> void:
	if is_instance_valid(event_bus):
		event_bus.unsubscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
	if is_instance_valid(_request) and _request.request_completed.is_connected(_on_request_completed):
		_request.request_completed.disconnect(_on_request_completed)
	_request_in_flight = false


func ensure_registered() -> Dictionary:
	if _request_in_flight:
		return {"ok": false, "status": "busy"}
	if not is_instance_valid(_session) or not _session.has_method("is_signed_in") or not bool(_session.call("is_signed_in")):
		return {"ok": false, "status": "sign-in-required"}
	if _session.has_method("device_id") and not str(_session.call("device_id")).strip_edges().is_empty():
		return {"ok": true, "status": "registered", "deviceId": str(_session.call("device_id"))}
	var base_url := _cloud_api_base_url()
	if not CloudAuthScript.is_valid_cloud_api_url(base_url):
		return {"ok": false, "status": "not-configured"}
	var installation_id := _load_or_create_installation_id()
	if installation_id.is_empty():
		return {"ok": false, "status": "installation-id-unavailable"}
	if not is_instance_valid(_request):
		return {"ok": false, "status": "unavailable"}
	_request_in_flight = true
	_publish("registering")
	var headers := PackedStringArray([
		"Accept: application/json",
		"Content-Type: application/json",
		"Authorization: Bearer %s" % str(_session.call("access_token")),
	])
	var error := _request.request(
		base_url.rstrip("/") + "/v1/devices/register",
		headers,
		HTTPClient.METHOD_POST,
		JSON.stringify({
			"installationId": installation_id,
			"platform": "windows",
			"runtimeVersion": _runtime_version(),
		})
	)
	if error != OK:
		_request_in_flight = false
		_publish("error")
		return {"ok": false, "status": "request-failed"}
	return {"ok": true, "status": "loading"}


func installation_id() -> String:
	return _read_installation_id()


func ensure_installation_id() -> String:
	return _load_or_create_installation_id()


func runtime_version() -> String:
	return _runtime_version()


func _on_session_changed(payload: Dictionary) -> void:
	if bool(payload.get("signed_in", false)) and str(payload.get("device_id", "")).is_empty():
		call_deferred("ensure_registered")


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_request_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		if response_code in [401, 403] and is_instance_valid(_session) and _session.has_method("clear"):
			_session.call("clear")
		_publish("error", {"responseCode": response_code})
		return
	var projected := project_device_payload(JSON.parse_string(body.get_string_from_utf8()))
	if not bool(projected.get("ok", false)):
		_publish("error")
		return
	var device := projected.get("device", {}) as Dictionary
	if not is_instance_valid(_session) or not _session.has_method("set_device_id") \
	or not bool(_session.call("set_device_id", str(device.get("deviceId", "")))):
		_publish("error")
		return
	_publish("registered", {"deviceId": str(device.get("deviceId", ""))})


func _load_or_create_installation_id() -> String:
	var current := _read_installation_id()
	if not current.is_empty():
		return current
	if not is_instance_valid(_bridge) or not _bridge.has_method("new_uuid_v7"):
		return ""
	var generated := str(_bridge.call("new_uuid_v7")).strip_edges().to_lower()
	if generated.is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://runtime"))
	var file := FileAccess.open(DEVICE_FILE, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify({"installationId": generated}))
	file.close()
	return generated


func _read_installation_id() -> String:
	if not FileAccess.file_exists(DEVICE_FILE):
		return ""
	var file := FileAccess.open(DEVICE_FILE, FileAccess.READ)
	if file == null:
		return ""
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return ""
	return str((parsed as Dictionary).get("installationId", "")).strip_edges().to_lower()


func _runtime_version() -> String:
	# Packaged Runtime receives the release version from the native launcher,
	# sourced from signed/validated BUILD-INFO.json. The Godot project itself is
	# shared by dev/local/RC builds, so ProjectSettings alone cannot identify the
	# installed release in Operations telemetry.
	var launcher_version := OS.get_environment("OCP_RUNTIME_VERSION").strip_edges()
	if not launcher_version.is_empty():
		return launcher_version
	var configured := str(ProjectSettings.get_setting("application/config/version", DEFAULT_RUNTIME_VERSION)).strip_edges()
	return configured if not configured.is_empty() else DEFAULT_RUNTIME_VERSION


func _cloud_api_base_url() -> String:
	if not is_instance_valid(context):
		return ""
	return str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()


func _publish(status: String, extra: Dictionary = {}) -> void:
	if not is_instance_valid(event_bus):
		return
	var payload := {"status": status}
	payload.merge(extra, true)
	event_bus.publish(&"cloud.device.updated", payload)


static func project_device_payload(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false}
	var row := payload as Dictionary
	var expected := ["deviceId", "installationId", "platform", "runtimeVersion", "lastSeenAt", "revokedAt"]
	if row.size() != expected.size():
		return {"ok": false}
	for key in expected:
		if not row.has(key):
			return {"ok": false}
	if str(row.get("deviceId", "")).is_empty() or str(row.get("installationId", "")).is_empty() \
	or str(row.get("platform", "")) != "windows" or str(row.get("runtimeVersion", "")).is_empty() \
	or str(row.get("lastSeenAt", "")).is_empty():
		return {"ok": false}
	var revoked: Variant = row.get("revokedAt")
	if revoked != null and not (revoked is String):
		return {"ok": false}
	return {"ok": true, "device": row.duplicate(true)}
