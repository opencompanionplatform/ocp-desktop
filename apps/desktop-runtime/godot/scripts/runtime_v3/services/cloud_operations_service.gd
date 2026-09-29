extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudOperationsService

const CloudHttpTransportScript = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

## Lightweight product-operations heartbeat. This is deliberately non-authoritative:
## Runtime reports only presence/version/active-character facts. XP, level, entitlement,
## security decisions, and commerce state remain server-owned.

# Five minutes keeps online/device/version visibility useful without turning
# every active desktop into a high-write telemetry stream. Character/session
# changes still schedule an immediate heartbeat.
const HEARTBEAT_INTERVAL_SECONDS := 300.0
const INITIAL_HEARTBEAT_DELAY_SECONDS := 10.0
const DEFAULT_TIMEOUT_SECONDS := 15.0

var _session: Node
var _device_service: Node
var _package_service: Node
var _progression_service: Node
var _bridge: Node
var _request: HTTPRequest
var _request_in_flight := false
var _elapsed := 0.0
var _next_delay := INITIAL_HEARTBEAT_DELAY_SECONDS
var _session_id := ""
var _last_status := "signed-out"


func bind_session(target: Node) -> void:
	_session = target
	_schedule_soon()


func bind_device_service(target: Node) -> void:
	_device_service = target
	_schedule_soon()


func bind_package_service(target: Node) -> void:
	_package_service = target
	_schedule_soon()


func bind_progression_service(target: Node) -> void:
	_progression_service = target
	_schedule_soon()


func bind_bridge(target: Node) -> void:
	_bridge = target
	_ensure_session_id()
	_schedule_soon()


func start() -> void:
	_request = HTTPRequest.new()
	CloudHttpTransportScript.configure_https_proxy(_request)
	_request.name = "OCPCloudOperationsHeartbeat"
	_request.timeout = DEFAULT_TIMEOUT_SECONDS
	_request.use_threads = true
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)
	if is_instance_valid(event_bus):
		event_bus.subscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
		event_bus.subscribe(&"cloud.device.updated", Callable(self, "_on_device_updated"))
		event_bus.subscribe(&"character.changed", Callable(self, "_on_character_changed"))
		event_bus.subscribe(&"cloud.progression.updated", Callable(self, "_on_progression_updated"))
	set_process(true)


func stop() -> void:
	set_process(false)
	if is_instance_valid(event_bus):
		event_bus.unsubscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
		event_bus.unsubscribe(&"cloud.device.updated", Callable(self, "_on_device_updated"))
		event_bus.unsubscribe(&"character.changed", Callable(self, "_on_character_changed"))
		event_bus.unsubscribe(&"cloud.progression.updated", Callable(self, "_on_progression_updated"))
	if is_instance_valid(_request) and _request.request_completed.is_connected(_on_request_completed):
		_request.request_completed.disconnect(_on_request_completed)
	_request_in_flight = false


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < _next_delay:
		return
	_elapsed = 0.0
	_next_delay = HEARTBEAT_INTERVAL_SECONDS
	send_heartbeat()


func send_heartbeat() -> Dictionary:
	if _request_in_flight:
		return {"ok": false, "status": "busy"}
	if not _is_signed_in():
		_last_status = "signed-out"
		return {"ok": false, "status": _last_status}
	var device_id := _device_id()
	if device_id.is_empty():
		_last_status = "device-registration-required"
		if is_instance_valid(_device_service) and _device_service.has_method("ensure_registered"):
			_device_service.call_deferred("ensure_registered")
		return {"ok": false, "status": _last_status}
	if not _ensure_session_id():
		_last_status = "session-id-unavailable"
		return {"ok": false, "status": _last_status}
	var base_url := _cloud_api_base_url()
	if base_url.is_empty() or not base_url.begins_with("https://"):
		_last_status = "not-configured"
		return {"ok": false, "status": _last_status}
	if not is_instance_valid(_request):
		_last_status = "unavailable"
		return {"ok": false, "status": _last_status}

	var active_character := _active_character()
	var payload := build_heartbeat_payload(
		device_id,
		_session_id,
		_runtime_version(),
		active_character,
		_canonical_companion_id(active_character)
	)
	if not bool(payload.get("ok", false)):
		_last_status = "invalid-local-state"
		return {"ok": false, "status": _last_status}

	_request_in_flight = true
	_last_status = "sending"
	_publish(_last_status)
	var error := _request.request(
		base_url.rstrip("/") + "/v1/operations/heartbeat",
		PackedStringArray([
			"Accept: application/json",
			"Content-Type: application/json",
			"Authorization: Bearer %s" % str(_session.call("access_token")),
		]),
		HTTPClient.METHOD_POST,
		JSON.stringify(payload.get("payload", {}))
	)
	if error != OK:
		_request_in_flight = false
		_last_status = "network-error"
		_publish(_last_status)
		return {"ok": false, "status": _last_status, "error": error_string(error)}
	return {"ok": true, "status": "sending"}


func snapshot() -> Dictionary:
	return {
		"status": _last_status,
		"sessionId": _session_id,
		"intervalSeconds": int(HEARTBEAT_INTERVAL_SECONDS),
		"inFlight": _request_in_flight,
	}


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_request_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_last_status = "error"
		_publish(_last_status, {"responseCode": response_code})
		return
	var projected := project_heartbeat_response(JSON.parse_string(body.get_string_from_utf8()))
	if not bool(projected.get("ok", false)):
		_last_status = "invalid-response"
		_publish(_last_status)
		return
	_last_status = "accepted"
	_publish(_last_status, {"serverTime": str(projected.get("serverTime", ""))})


func _on_session_changed(payload: Dictionary) -> void:
	if not bool(payload.get("signed_in", false)):
		_last_status = "signed-out"
		return
	_schedule_soon()


func _on_device_updated(payload: Dictionary) -> void:
	if str(payload.get("status", "")) == "registered":
		_schedule_soon()


func _on_character_changed(_payload: Dictionary) -> void:
	_schedule_soon()


func _on_progression_updated(_payload: Dictionary) -> void:
	# The first presence heartbeat can happen before Cloud has created the
	# companion. Re-send when the canonical projection arrives so Operations
	# can join presence to server-owned progression without trusting local XP.
	_schedule_soon()


func _schedule_soon() -> void:
	_elapsed = 0.0
	_next_delay = 1.0 if is_instance_valid(_request) else INITIAL_HEARTBEAT_DELAY_SECONDS


func _ensure_session_id() -> bool:
	if not _session_id.is_empty():
		return true
	if not is_instance_valid(_bridge) or not _bridge.has_method("new_uuid_v7"):
		return false
	_session_id = str(_bridge.call("new_uuid_v7")).strip_edges().to_lower()
	return not _session_id.is_empty()


func _is_signed_in() -> bool:
	return is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in"))


func _device_id() -> String:
	if not _is_signed_in() or not _session.has_method("device_id"):
		return ""
	return str(_session.call("device_id")).strip_edges().to_lower()


func _runtime_version() -> String:
	if is_instance_valid(_device_service) and _device_service.has_method("runtime_version"):
		return str(_device_service.call("runtime_version")).strip_edges()
	return str(ProjectSettings.get_setting("application/config/version", "0.1.0")).strip_edges()


func _active_character() -> Dictionary:
	if not is_instance_valid(_package_service) or not _package_service.has_method("get_active_candidate"):
		return {}
	var value: Variant = _package_service.call("get_active_candidate")
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func _canonical_companion_id(active_character: Dictionary) -> String:
	var package_id := str(active_character.get("packageId", "")).strip_edges()
	if package_id.is_empty() or not is_instance_valid(_progression_service) or not _progression_service.has_method("canonical_projection"):
		return ""
	var projection: Variant = _progression_service.call("canonical_projection")
	if not (projection is Dictionary):
		return ""
	var companions: Variant = (projection as Dictionary).get("companions", [])
	if not (companions is Array):
		return ""
	for value in companions:
		if value is Dictionary and str((value as Dictionary).get("characterId", "")) == package_id:
			return str((value as Dictionary).get("companionId", "")).strip_edges().to_lower()
	return ""


func _cloud_api_base_url() -> String:
	if not is_instance_valid(context):
		return ""
	return str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()


func _publish(status: String, extra: Dictionary = {}) -> void:
	if not is_instance_valid(event_bus):
		return
	var payload := {"status": status}
	payload.merge(extra, true)
	event_bus.publish(&"cloud.operations.heartbeat_state", payload)


static func build_heartbeat_payload(device_id: String, session_id: String, runtime_version: String, active_character: Dictionary, companion_id: String = "") -> Dictionary:
	if device_id.strip_edges().is_empty() or session_id.strip_edges().is_empty() or runtime_version.strip_edges().is_empty():
		return {"ok": false}
	var active: Variant = null
	if not active_character.is_empty():
		var package_id := str(active_character.get("packageId", active_character.get("package_id", ""))).strip_edges()
		var version := str(active_character.get("version", "")).strip_edges()
		if package_id.is_empty() or version.is_empty():
			return {"ok": false}
		active = {"packageId": package_id, "version": version}
	var canonical_companion_id := companion_id.strip_edges().to_lower()
	var payload := {
		"deviceId": device_id.strip_edges().to_lower(),
		"sessionId": session_id.strip_edges().to_lower(),
		"runtimeVersion": runtime_version.strip_edges(),
		"activeCharacter": active,
		"companionId": null if canonical_companion_id.is_empty() else canonical_companion_id,
	}
	return {"ok": true, "payload": payload}


static func project_heartbeat_response(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {"ok": false}
	var row := value as Dictionary
	if str(row.get("decision", "")) != "accepted":
		return {"ok": false}
	var server_time := str(row.get("serverTime", "")).strip_edges()
	var session_id := str(row.get("sessionId", "")).strip_edges().to_lower()
	var device_id := str(row.get("deviceId", "")).strip_edges().to_lower()
	if server_time.is_empty() or session_id.is_empty() or device_id.is_empty():
		return {"ok": false}
	return {"ok": true, "serverTime": server_time, "sessionId": session_id, "deviceId": device_id}
