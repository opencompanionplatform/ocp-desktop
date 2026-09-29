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
				if callback is Callable and (callback as Callable).is_valid(): (callback as Callable).call(payload.duplicate(true))

func _initialize() -> void:
	call_deferred("_run")

func _request(method: int, url: String, token: String, body: Variant = null) -> Dictionary:
	var request := HTTPRequest.new()
	CloudHttpTransport.configure_https_proxy(request)
	request.timeout = 30.0
	request.use_threads = true
	root.add_child(request)
	var headers := PackedStringArray(["Accept: application/json", "Authorization: Bearer %s" % token])
	var text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		text = JSON.stringify(body)
	var err := request.request(url, headers, method, text)
	if err != OK:
		request.queue_free()
		return {"status": 0, "payload": {}, "text": error_string(err)}
	var completed: Array = await request.request_completed
	request.queue_free()
	if completed.size() < 4: return {"status": 0, "payload": {}, "text": "invalid-http-result"}
	var result := int(completed[0])
	var status := int(completed[1]) if result == HTTPRequest.RESULT_SUCCESS else 0
	var response_text := (completed[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(response_text)
	return {"status": status, "payload": parsed if parsed is Dictionary else {}, "text": response_text}

func _stop(auth: Node, code: int, stage: String, detail: String) -> void:
	print("[S7-CREATOR-PUBLISH-RESUME] stage=%s ok=%s detail=%s" % [stage, str(code == 0).to_lower(), detail.replace("\n", " ").substr(0, 500)])
	if is_instance_valid(auth): auth.call("stop")
	quit(code)

func _run() -> void:
	var submission_id := OS.get_environment("OCP_CREATOR_E2E_SUBMISSION_ID").strip_edges().to_lower()
	var display_name := OS.get_environment("OCP_CREATOR_E2E_NAME").strip_edges()
	var package_id := OS.get_environment("OCP_CREATOR_E2E_PACKAGE_ID").strip_edges().to_lower()
	var version := OS.get_environment("OCP_CREATOR_E2E_VERSION").strip_edges()
	if submission_id.is_empty() or display_name.is_empty() or package_id.is_empty() or version.is_empty():
		_stop(null, 2, "config", "missing submission/name/package/version")
		return

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
	for _step in range(400):
		if session.is_signed_in(): break
		await create_timer(0.05).timeout
	if not session.is_signed_in():
		_stop(auth, 3, "auth", "secure session unavailable")
		return
	var token := session.access_token()

	var publication := await _request(
		HTTPClient.METHOD_POST,
		BASE_URL + "/v1/moderation/submissions/%s/publish" % submission_id.uri_encode(),
		token,
		{"name": display_name, "availability": "free"}
	)
	var result := ((publication.get("payload", {}) as Dictionary).get("result", {}) as Dictionary)
	var publication_status := str(result.get("status", result.get("decision", "")))
	if int(publication.get("status", 0)) not in [200, 201] or publication_status != "published":
		_stop(auth, 4, "publish", "HTTP %d status=%s body=%s" % [int(publication.get("status", 0)), publication_status, str(publication.get("text", ""))])
		return
	if str(result.get("packageId", package_id)) != package_id or str(result.get("version", version)) != version:
		_stop(auth, 5, "identity", "published result identity mismatch")
		return

	_stop(auth, 0, "published", "submission=%s package=%s@%s" % [submission_id, package_id, version])
