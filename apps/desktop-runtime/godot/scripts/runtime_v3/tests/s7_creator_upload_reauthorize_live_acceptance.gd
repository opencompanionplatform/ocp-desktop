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
	var status := int(completed[1]) if int(completed[0]) == HTTPRequest.RESULT_SUCCESS else 0
	var response_text := (completed[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(response_text)
	return {"status": status, "payload": parsed if parsed is Dictionary else {}, "text": response_text}

func _stop(auth: Node, code: int, stage: String, detail: String) -> void:
	print("[S7-CREATOR-UPLOAD-REAUTH] stage=%s ok=%s detail=%s" % [stage, str(code == 0).to_lower(), detail.replace("\n", " ").substr(0, 500)])
	if is_instance_valid(auth): auth.call("stop")
	quit(code)

func _run() -> void:
	var package_id := OS.get_environment("OCP_CREATOR_E2E_PACKAGE_ID").strip_edges().to_lower()
	var version := OS.get_environment("OCP_CREATOR_E2E_VERSION").strip_edges()
	var publisher_id := OS.get_environment("OCP_CREATOR_E2E_PUBLISHER").strip_edges().to_lower()
	var output_path := OS.get_environment("OCP_CREATOR_E2E_UPLOAD_AUTH_PATH").strip_edges()
	if package_id.is_empty() or version.is_empty() or publisher_id.is_empty() or output_path.is_empty():
		_stop(null, 2, "config", "missing package/version/publisher/output")
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

	var list_url := BASE_URL + "/v1/creator/submissions?publisherId=%s" % publisher_id.uri_encode()
	var listed := await _request(HTTPClient.METHOD_GET, list_url, token)
	if int(listed.get("status", 0)) != 200:
		_stop(auth, 4, "list", "HTTP %d" % int(listed.get("status", 0)))
		return
	var target: Dictionary = {}
	var items: Variant = (listed.get("payload", {}) as Dictionary).get("items", [])
	if items is Array:
		for item_value in items:
			if item_value is Dictionary:
				var item := item_value as Dictionary
				if str(item.get("packageId", "")) == package_id and str(item.get("version", "")) == version:
					target = item
					break
	if target.is_empty():
		_stop(auth, 5, "lookup", "submission not found")
		return
	if str(target.get("status", "")) != "upload-authorized":
		_stop(auth, 5, "lookup", "submission state=%s" % str(target.get("status", "")))
		return
	var submission_id := str(target.get("submissionId", ""))
	var renewed := await _request(HTTPClient.METHOD_POST, BASE_URL + "/v1/creator/submissions/%s/upload" % submission_id.uri_encode(), token, {})
	if int(renewed.get("status", 0)) != 200:
		_stop(auth, 6, "reauthorize", "HTTP %d: %s" % [int(renewed.get("status", 0)), str(renewed.get("text", ""))])
		return
	var upload := ((renewed.get("payload", {}) as Dictionary).get("upload", {}) as Dictionary)
	var url := str(upload.get("url", ""))
	var expires_at := str(upload.get("expiresAt", ""))
	if submission_id.is_empty() or not url.begins_with("https://") or expires_at.is_empty():
		_stop(auth, 6, "reauthorize", "invalid renewed upload authorization")
		return
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	if output == null:
		_stop(auth, 7, "write", "cannot write transient upload authorization")
		return
	output.store_string(JSON.stringify({"submissionId": submission_id, "url": url, "expiresAt": expires_at}))
	output.close()
	_stop(auth, 0, "ready", "submission=%s" % submission_id)
