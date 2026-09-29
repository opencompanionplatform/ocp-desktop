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

func _request_upload_url(submission_id: String, token: String) -> Dictionary:
	for attempt in range(1, 4):
		var request := HTTPRequest.new()
		CloudHttpTransport.configure_https_proxy(request)
		request.timeout = 30.0
		request.use_threads = true
		root.add_child(request)
		var headers := PackedStringArray([
			"Accept: application/json",
			"Authorization: Bearer %s" % token,
			"Content-Type: application/json",
		])
		var err := request.request(
			BASE_URL + "/v1/creator/submissions/%s/upload" % submission_id.uri_encode(),
			headers,
			HTTPClient.METHOD_POST,
			"{}"
		)
		if err != OK:
			request.queue_free()
			print("[S7-CREATOR-UPLOAD-RESUME] renew attempt=%d transport=%s" % [attempt, error_string(err)])
			await create_timer(0.5).timeout
			continue
		var completed: Array = await request.request_completed
		request.queue_free()
		if completed.size() < 4 or int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
			print("[S7-CREATOR-UPLOAD-RESUME] renew attempt=%d result=%s" % [attempt, str(completed[0] if completed.size() > 0 else -1)])
			await create_timer(0.5).timeout
			continue
		var status := int(completed[1])
		var text := (completed[3] as PackedByteArray).get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		return {"status": status, "payload": parsed if parsed is Dictionary else {}, "text": text}
	return {"status": 0, "payload": {}, "text": "transport-failed-after-retries"}

func _stop(auth: Node, code: int, stage: String, detail: String) -> void:
	print("[S7-CREATOR-UPLOAD-RESUME] stage=%s ok=%s detail=%s" % [stage, str(code == 0).to_lower(), detail.replace("\n", " ").substr(0, 500)])
	if is_instance_valid(auth): auth.call("stop")
	quit(code)

func _run() -> void:
	var submission_id := OS.get_environment("OCP_CREATOR_E2E_SUBMISSION_ID").strip_edges().to_lower()
	var package_path := OS.get_environment("OCP_CREATOR_E2E_PACKAGE_PATH").strip_edges()
	var electron_exe := OS.get_environment("OCP_CREATOR_E2E_ELECTRON_EXE").strip_edges()
	var helper_script := OS.get_environment("OCP_CREATOR_E2E_ELECTRON_UPLOAD_HELPER").strip_edges()
	if submission_id.is_empty() or package_path.is_empty() or electron_exe.is_empty() or helper_script.is_empty():
		_stop(null, 2, "config", "missing submission/package/electron/helper")
		return
	if not FileAccess.file_exists(package_path) or not FileAccess.file_exists(electron_exe) or not FileAccess.file_exists(helper_script):
		_stop(null, 2, "config", "required file missing")
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

	var renewed := await _request_upload_url(submission_id, session.access_token())
	if int(renewed.get("status", 0)) != 200:
		_stop(auth, 4, "renew", "HTTP %d body=%s" % [int(renewed.get("status", 0)), str(renewed.get("text", ""))])
		return
	var upload := (renewed.get("payload", {}) as Dictionary).get("upload", {}) as Dictionary
	var upload_url := str(upload.get("url", ""))
	if not upload_url.begins_with("https://"):
		_stop(auth, 4, "renew", "presigned URL missing")
		return

	var request_path := OS.get_user_data_dir().path_join("creator-e2e-presigned-upload.json")
	var request_file := FileAccess.open(request_path, FileAccess.WRITE)
	if request_file == null:
		_stop(auth, 5, "upload", "request file write failed")
		return
	request_file.store_string(JSON.stringify({"url": upload_url}))
	request_file.close()
	var output: Array = []
	var exit_code := OS.execute(electron_exe, [helper_script, request_path, package_path], output, true)
	if FileAccess.file_exists(request_path): DirAccess.remove_absolute(request_path)
	for line in output:
		var text := str(line).strip_edges()
		if not text.is_empty(): print("[S7-CREATOR-UPLOAD-RESUME] helper ", text.substr(0, 400))
	if exit_code != 0:
		_stop(auth, 5, "upload", "Electron helper exit=%d" % exit_code)
		return

	_stop(auth, 0, "uploaded", "submission=%s" % submission_id)
