extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudAuthService

const CloudHttpTransportScript = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

## Provider-neutral hosted Cloud authentication client.
## Desktop only knows OCP Cloud API. Refresh tokens are persisted only through
## the native OS-keystore bridge; access tokens remain in CloudSession memory.

const DEFAULT_TIMEOUT_SECONDS := 20.0
const AUTH_HANDOFF_PATTERN := "^[A-Za-z0-9_-]{32,256}$"

var _session: Node
var _bridge: Node
var _request: HTTPRequest
var _operation := ""


func bind_session(target: Node) -> void:
	_session = target


func bind_bridge(target: Node) -> void:
	_bridge = target


func start() -> void:
	_request = HTTPRequest.new()
	CloudHttpTransportScript.configure_https_proxy(_request)
	_request.name = "CloudAuthHttpRequest"
	_request.timeout = DEFAULT_TIMEOUT_SECONDS
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)
	call_deferred("restore_session")


func stop() -> void:
	if is_instance_valid(_request) and _request.request_completed.is_connected(_on_request_completed):
		_request.request_completed.disconnect(_on_request_completed)
	_operation = ""


func sign_in_with_password(email: String, password: String) -> Dictionary:
	var canonical_email := email.strip_edges().to_lower()
	if canonical_email.is_empty() or not canonical_email.contains("@") or password.length() < 6:
		return {"ok": false, "status": "invalid-credentials"}
	return _begin_auth_request("password", "/v1/auth/password", {
		"email": canonical_email,
		"password": password,
	})


func redeem_handoff(grant: String) -> Dictionary:
	var canonical_grant := grant.strip_edges()
	var pattern := RegEx.new()
	if pattern.compile(AUTH_HANDOFF_PATTERN) != OK or pattern.search(canonical_grant) == null:
		return {"ok": false, "status": "invalid-handoff"}
	return _begin_auth_request("handoff", "/v1/auth/desktop-handoff/redeem", {"grant": canonical_grant})


func restore_session() -> Dictionary:
	if not is_instance_valid(_bridge) or not _bridge.has_method("load_cloud_refresh_token"):
		return {"ok": false, "status": "secure-store-unavailable"}
	var secret: Variant = _bridge.call("load_cloud_refresh_token")
	if not (secret is Dictionary) or not bool((secret as Dictionary).get("ok", false)):
		return {"ok": true, "status": "signed-out"}
	var refresh_token := str((secret as Dictionary).get("refresh_token", ""))
	if refresh_token.is_empty():
		return {"ok": true, "status": "signed-out"}
	return _begin_auth_request("refresh", "/v1/auth/refresh", {
		"refreshToken": refresh_token,
	})


func sign_out() -> void:
	if is_instance_valid(_bridge) and _bridge.has_method("delete_cloud_refresh_token"):
		_bridge.call("delete_cloud_refresh_token")
	if is_instance_valid(_session) and _session.has_method("clear"):
		_session.call("clear")
	_publish_state("signed-out")


func is_busy() -> bool:
	return not _operation.is_empty()


func _begin_auth_request(operation: String, path: String, body: Dictionary) -> Dictionary:
	if is_busy():
		return {"ok": false, "status": "busy"}
	var base_url := _cloud_api_base_url()
	if not is_valid_cloud_api_url(base_url):
		return {"ok": false, "status": "not-configured"}
	if not is_instance_valid(_request):
		return {"ok": false, "status": "unavailable"}
	_operation = operation
	_publish_state("signing-in" if operation in ["password", "handoff"] else "restoring")
	var error := _request.request(
		base_url.rstrip("/") + path,
		PackedStringArray(["Accept: application/json", "Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		_operation = ""
		_publish_state("error")
		return {"ok": false, "status": "request-failed"}
	return {"ok": true, "status": "loading"}


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	var operation := _operation
	_operation = ""
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		if operation == "refresh" and response_code in [400, 401, 403]:
			if is_instance_valid(_bridge) and _bridge.has_method("delete_cloud_refresh_token"):
				_bridge.call("delete_cloud_refresh_token")
			if is_instance_valid(_session) and _session.has_method("clear"):
				_session.call("clear")
		_publish_state("authentication-failed" if response_code in [400, 401, 403] else "error")
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var projected := project_auth_payload(parsed)
	if not bool(projected.get("ok", false)):
		_publish_state("error")
		return
	var auth := projected.get("auth", {}) as Dictionary
	var refresh_token := str(auth.get("refreshToken", ""))
	var stored := false
	if is_instance_valid(_bridge) and _bridge.has_method("store_cloud_refresh_token"):
		var store_result: Variant = _bridge.call("store_cloud_refresh_token", refresh_token)
		stored = store_result is Dictionary and bool((store_result as Dictionary).get("ok", false))
	if not is_instance_valid(_session) or not _session.has_method("establish"):
		_publish_state("error")
		return
	var user := auth.get("user", {}) as Dictionary
	var session_result: Variant = _session.call(
		"establish",
		str(auth.get("accessToken", "")),
		str(user.get("userId", "")),
		"",
		str(user.get("email", ""))
	)
	if not (session_result is Dictionary) or not bool((session_result as Dictionary).get("ok", false)):
		_publish_state("error")
		return
	_publish_state("signed-in" if stored else "signed-in-session-only", {
		"email": str((auth.get("user", {}) as Dictionary).get("email", "")),
	})


func _publish_state(status: String, extra: Dictionary = {}) -> void:
	if not is_instance_valid(event_bus):
		return
	var payload := {"status": status}
	payload.merge(extra, true)
	# No access/refresh token is ever published.
	event_bus.publish(&"cloud.auth.updated", payload)


func _cloud_api_base_url() -> String:
	if not is_instance_valid(context):
		return ""
	return str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()


static func is_valid_cloud_api_url(value: String) -> bool:
	var url := value.strip_edges().to_lower()
	return url.begins_with("https://") or url.begins_with("http://127.0.0.1") or url.begins_with("http://localhost")


static func project_auth_payload(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false}
	var row := payload as Dictionary
	var expected := ["accessToken", "refreshToken", "expiresIn", "user"]
	if row.size() != expected.size():
		return {"ok": false}
	for key in expected:
		if not row.has(key):
			return {"ok": false}
	if not (row.get("user") is Dictionary):
		return {"ok": false}
	var user := row.get("user") as Dictionary
	if user.size() != 2 or not user.has("userId") or not user.has("email"):
		return {"ok": false}
	var access_token := str(row.get("accessToken", ""))
	var refresh_token := str(row.get("refreshToken", ""))
	var user_id := str(user.get("userId", ""))
	var email := str(user.get("email", "")).strip_edges().to_lower()
	var expires_in := int(row.get("expiresIn", 0))
	if access_token.is_empty() or refresh_token.is_empty() or user_id.is_empty() \
	or email.is_empty() or not email.contains("@") or expires_in <= 0:
		return {"ok": false}
	return {
		"ok": true,
		"auth": {
			"accessToken": access_token,
			"refreshToken": refresh_token,
			"expiresIn": expires_in,
			"user": {"userId": user_id, "email": email},
		},
	}
