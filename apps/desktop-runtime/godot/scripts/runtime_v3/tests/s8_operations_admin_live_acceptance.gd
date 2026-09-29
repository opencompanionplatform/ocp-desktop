extends SceneTree

const SessionService = preload("res://scripts/runtime_v3/services/cloud_session_service.gd")
const AuthService = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const CloudHttpTransport = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

const BASE_URL := "https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api"

class LiveContext:
	extends Node
	var settings := {"ocp_cloud_api_url": BASE_URL}

class LiveBus:
	extends Node
	var subscribers: Dictionary = {}
	func subscribe(topic: StringName, callback: Callable) -> void:
		var key := String(topic)
		if not subscribers.has(key): subscribers[key] = []
		(subscribers[key] as Array).append(callback)
	func unsubscribe(topic: StringName, callback: Callable) -> void:
		var key := String(topic)
		if subscribers.has(key): (subscribers[key] as Array).erase(callback)
	func publish(topic: StringName, payload: Dictionary) -> void:
		var key := String(topic)
		if subscribers.has(key):
			for callback in (subscribers[key] as Array).duplicate():
				if callback is Callable and (callback as Callable).is_valid():
					(callback as Callable).call(payload.duplicate(true))

var _done := false
var _status := 0
var _body := PackedByteArray()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var context := LiveContext.new()
	var bus := LiveBus.new()
	var bridge := OcpRuntimeBridge.new()
	var session := SessionService.new()
	var auth := AuthService.new()
	for node in [context, bus, bridge, session, auth]: root.add_child(node)

	session.configure(context, bus)
	auth.configure(context, bus)
	auth.bind_session(session)
	auth.bind_bridge(bridge)
	auth.start()

	var session_ready := false
	for _step in range(400):
		if session.is_signed_in():
			session_ready = true
			break
		await create_timer(0.05).timeout
	if not session_ready:
		print("[S8-ADMIN-LIVE] session=false result=SESSION_NOT_READY")
		auth.stop()
		quit(2)
		return

	var request := HTTPRequest.new()
	CloudHttpTransport.configure_https_proxy(request)
	request.timeout = 20.0
	request.use_threads = true
	root.add_child(request)
	request.request_completed.connect(_on_completed)
	var error := request.request(
		BASE_URL + "/v1/admin/operations/summary",
		PackedStringArray([
			"Accept: application/json",
			"Authorization: Bearer %s" % session.access_token(),
		]),
		HTTPClient.METHOD_GET
	)
	if error != OK:
		print("[S8-ADMIN-LIVE] session=true request=false error=%s" % error_string(error))
		auth.stop()
		quit(3)
		return

	for _step in range(500):
		if _done: break
		await create_timer(0.05).timeout
	if not _done:
		print("[S8-ADMIN-LIVE] session=true result=TIMEOUT")
		auth.stop()
		quit(4)
		return

	if _status != 200:
		print("[S8-ADMIN-LIVE] session=true http=%d admin=false" % _status)
		auth.stop()
		quit(5)
		return

	var parsed: Variant = JSON.parse_string(_body.get_string_from_utf8())
	if not (parsed is Dictionary):
		print("[S8-ADMIN-LIVE] session=true http=200 projection=false")
		auth.stop()
		quit(6)
		return
	var snapshot := parsed as Dictionary
	var users := snapshot.get("users", {}) as Dictionary
	var devices := snapshot.get("devices", {}) as Dictionary
	var characters := snapshot.get("characters", {}) as Dictionary
	var progression := snapshot.get("progression", {}) as Dictionary
	var security := snapshot.get("security", {}) as Dictionary
	var current := characters.get("currentlyActive", []) as Array
	var versions := devices.get("versions", []) as Array
	var recent_users := snapshot.get("recentUsers", []) as Array
	var generated_at := str(snapshot.get("generatedAt", ""))
	var version_labels: Array[String] = []
	for entry in versions:
		if entry is Dictionary:
			var label := str((entry as Dictionary).get("version", (entry as Dictionary).get("runtimeVersion", ""))).strip_edges()
			if not label.is_empty():
				version_labels.append(label)
	var expected_runtime_version := OS.get_environment("OCP_EXPECT_RUNTIME_VERSION").strip_edges()
	var expected_version_ok := expected_runtime_version.is_empty() or expected_runtime_version in version_labels
	var ok := not generated_at.is_empty() and users.has("total") and devices.has("total") and progression.has("companions") and security.has("events24h") and expected_version_ok
	print("[S8-ADMIN-LIVE] http=200 admin=true generated=true users=%s devices=%s activeCharacters=%d versions=%s recentUsers=%d security24h=%s expectedVersion=%s expectedVersionOk=%s ok=%s" % [
		str(users.get("total", 0)),
		str(devices.get("total", 0)),
		current.size(),
		str(version_labels),
		recent_users.size(),
		str(security.get("events24h", 0)),
		expected_runtime_version if not expected_runtime_version.is_empty() else "none",
		str(expected_version_ok).to_lower(),
		str(ok).to_lower(),
	])
	auth.stop()
	quit(0 if ok else 7)

func _on_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_done = true
	_status = response_code if result == HTTPRequest.RESULT_SUCCESS else 0
	_body = body
