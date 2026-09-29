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
		if not subscribers.has(key):
			subscribers[key] = []
		(subscribers[key] as Array).append(callback)
	func unsubscribe(topic: StringName, callback: Callable) -> void:
		var key := String(topic)
		if subscribers.has(key):
			(subscribers[key] as Array).erase(callback)
	func publish(topic: StringName, payload: Dictionary) -> void:
		var key := String(topic)
		if subscribers.has(key):
			for callback in (subscribers[key] as Array).duplicate():
				if callback is Callable and (callback as Callable).is_valid():
					(callback as Callable).call(payload.duplicate(true))

func _initialize() -> void:
	call_deferred("_run")

func _request_json(path: String, access_token: String) -> Dictionary:
	var request := HTTPRequest.new()
	CloudHttpTransport.configure_https_proxy(request)
	request.timeout = 20.0
	request.use_threads = true
	root.add_child(request)
	var error := request.request(
		BASE_URL + path,
		PackedStringArray([
			"Accept: application/json",
			"Authorization: Bearer %s" % access_token,
		]),
		HTTPClient.METHOD_GET
	)
	if error != OK:
		request.queue_free()
		return {"status": 0, "payload": {}, "error": error_string(error)}
	var completed: Array = await request.request_completed
	request.queue_free()
	if completed.size() < 4:
		return {"status": 0, "payload": {}, "error": "invalid-http-result"}
	var result := int(completed[0])
	var status := int(completed[1]) if result == HTTPRequest.RESULT_SUCCESS else 0
	var body: PackedByteArray = completed[3]
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	return {
		"status": status,
		"payload": parsed if parsed is Dictionary else {},
		"error": "" if status > 0 else "request-failed",
	}

func _run() -> void:
	var context := LiveContext.new()
	var bus := LiveBus.new()
	var bridge := OcpRuntimeBridge.new()
	var session := SessionService.new()
	var auth := AuthService.new()
	for node in [context, bus, bridge, session, auth]:
		root.add_child(node)

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
		print("[S7-CREATOR-LIVE] session=false result=SESSION_NOT_READY")
		auth.stop()
		quit(2)
		return

	var expected_publisher := OS.get_environment("OCP_EXPECT_CREATOR_PUBLISHER").strip_edges().to_lower()
	var expected_key_id := OS.get_environment("OCP_EXPECT_CREATOR_KEY_ID").strip_edges()
	var token := session.access_token()
	var profile_result: Dictionary = await _request_json("/v1/creator/profile", token)
	var publishers_result: Dictionary = await _request_json("/v1/creator/publishers", token)
	var submissions_path := "/v1/creator/submissions"
	if not expected_publisher.is_empty():
		submissions_path += "?publisherId=" + expected_publisher.uri_encode()
	var submissions_result: Dictionary = await _request_json(submissions_path, token)

	var profile_payload := profile_result.get("payload", {}) as Dictionary
	var profile_value: Variant = profile_payload.get("creator", {})
	var profile: Dictionary = profile_value if profile_value is Dictionary else {}
	var publisher_id := str(profile.get("publisherId", ""))
	var active_key_ids: Array[String] = []
	var keys_value: Variant = profile.get("keys", [])
	if keys_value is Array:
		for key_value in keys_value:
			if key_value is Dictionary and str((key_value as Dictionary).get("status", "")) == "active":
				var key_id := str((key_value as Dictionary).get("keyId", ""))
				if not key_id.is_empty():
					active_key_ids.append(key_id)

	var publisher_ids: Array[String] = []
	var publishers_payload := publishers_result.get("payload", {}) as Dictionary
	var publisher_items: Variant = publishers_payload.get("items", [])
	if publisher_items is Array:
		for item_value in publisher_items:
			if item_value is Dictionary:
				var item := item_value as Dictionary
				var item_id := str(item.get("publisherId", item.get("id", "")))
				if not item_id.is_empty():
					publisher_ids.append(item_id)
				if not expected_publisher.is_empty() and item_id == expected_publisher:
					active_key_ids.clear()
					var selected_keys: Variant = item.get("keys", [])
					if selected_keys is Array:
						for key_value in selected_keys:
							if key_value is Dictionary and str((key_value as Dictionary).get("status", "")) == "active":
								var key_id := str((key_value as Dictionary).get("keyId", ""))
								if not key_id.is_empty():
									active_key_ids.append(key_id)

	var submission_statuses: Array[String] = []
	var submissions_payload := submissions_result.get("payload", {}) as Dictionary
	var submission_items: Variant = submissions_payload.get("items", [])
	if submission_items is Array:
		for item_value in submission_items:
			if item_value is Dictionary:
				var status := str((item_value as Dictionary).get("status", ""))
				if not status.is_empty():
					submission_statuses.append(status)

	var expected_ok := (expected_publisher.is_empty() or expected_publisher in publisher_ids or publisher_id == expected_publisher) \
		and (expected_key_id.is_empty() or expected_key_id in active_key_ids)
	var ok := int(profile_result.get("status", 0)) == 200 \
		and int(publishers_result.get("status", 0)) == 200 \
		and int(submissions_result.get("status", 0)) == 200 \
		and not publisher_id.is_empty() \
		and expected_ok

	print("[S7-CREATOR-LIVE] session=true profile_http=%d publishers_http=%d submissions_http=%d publisher=%s activeKeys=%d publisherMemberships=%s submissionCount=%d statuses=%s expectedOk=%s ok=%s" % [
		int(profile_result.get("status", 0)),
		int(publishers_result.get("status", 0)),
		int(submissions_result.get("status", 0)),
		publisher_id if not publisher_id.is_empty() else "none",
		active_key_ids.size(),
		str(publisher_ids),
		(submission_items as Array).size() if submission_items is Array else 0,
		str(submission_statuses),
		str(expected_ok).to_lower(),
		str(ok).to_lower(),
	])
	auth.stop()
	quit(0 if ok else 3)
