extends SceneTree

const SessionService = preload("res://scripts/runtime_v3/services/cloud_session_service.gd")
const AuthService = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const DeviceService = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const DownloadService = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")
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

class FakePackageService:
	extends Node
	func is_installed_exact(_package_id: String, _version: String) -> bool:
		return false

class FakeEffectPackService:
	extends Node
	func is_installed_exact(_package_id: String, _version: String) -> bool:
		return false

func _initialize() -> void:
	call_deferred("_run")

func _desktop_request_json(method: int, url: String, access_token: String = "", body: Variant = null, status_only: bool = false) -> Dictionary:
	var electron_exe := OS.get_environment("OCP_CREATOR_E2E_ELECTRON_EXE").strip_edges()
	var helper_script := OS.get_environment("OCP_CREATOR_E2E_ELECTRON_REQUEST_HELPER").strip_edges()
	if electron_exe.is_empty() or helper_script.is_empty():
		return {"status": 0, "payload": {}, "text": "", "error": "desktop-request-helper-unconfigured"}
	if not FileAccess.file_exists(electron_exe) or not FileAccess.file_exists(helper_script):
		return {"status": 0, "payload": {}, "text": "", "error": "desktop-request-helper-missing"}
	var method_name := "GET" if method == HTTPClient.METHOD_GET else "POST" if method == HTTPClient.METHOD_POST else ""
	if method_name.is_empty():
		return {"status": 0, "payload": {}, "text": "", "error": "desktop-request-method-unsupported"}
	var nonce := "%d-%d" % [Time.get_ticks_usec(), randi()]
	var request_path := OS.get_user_data_dir().path_join("creator-e2e-cloud-request-%s.json" % nonce)
	var response_path := OS.get_user_data_dir().path_join("creator-e2e-cloud-response-%s.json" % nonce)
	var request_file := FileAccess.open(request_path, FileAccess.WRITE)
	if request_file == null:
		return {"status": 0, "payload": {}, "text": "", "error": "desktop-request-write-failed"}
	request_file.store_string(JSON.stringify({
		"url": url,
		"method": method_name,
		"accessToken": access_token,
		"body": body,
		"statusOnly": status_only,
	}))
	request_file.close()
	var output: Array = []
	var exit_code := OS.execute(electron_exe, [helper_script, request_path, response_path], output, true)
	if FileAccess.file_exists(request_path):
		DirAccess.remove_absolute(request_path)
	for line in output:
		var output_text := str(line).strip_edges()
		if not output_text.is_empty():
			print("[S7-CREATOR-E2E] desktop-request ", output_text.substr(0, 300))
	if exit_code != 0 or not FileAccess.file_exists(response_path):
		if FileAccess.file_exists(response_path):
			DirAccess.remove_absolute(response_path)
		return {"status": 0, "payload": {}, "text": "", "error": "desktop-request-helper-failed:%d" % exit_code}
	var response_file := FileAccess.open(response_path, FileAccess.READ)
	if response_file == null:
		DirAccess.remove_absolute(response_path)
		return {"status": 0, "payload": {}, "text": "", "error": "desktop-response-read-failed"}
	var response_text := response_file.get_as_text()
	response_file.close()
	DirAccess.remove_absolute(response_path)
	var envelope: Variant = JSON.parse_string(response_text)
	if not (envelope is Dictionary):
		return {"status": 0, "payload": {}, "text": response_text, "error": "desktop-response-invalid"}
	var response := envelope as Dictionary
	var body_text := str(response.get("bodyText", ""))
	if status_only:
		return {
			"status": int(response.get("status", 0)),
			"payload": {},
			"text": "",
			"error": "",
		}
	var parsed: Variant = JSON.parse_string(body_text) if not body_text.is_empty() else null
	return {
		"status": int(response.get("status", 0)),
		"payload": parsed if parsed is Dictionary else {},
		"text": body_text,
		"error": "",
	}

func _request_json(method: int, url: String, access_token: String = "", body: Variant = null) -> Dictionary:
	if not OS.get_environment("OCP_CREATOR_E2E_ELECTRON_REQUEST_HELPER").strip_edges().is_empty():
		return _desktop_request_json(method, url, access_token, body)
	var request := HTTPRequest.new()
	CloudHttpTransport.configure_https_proxy(request)
	request.timeout = 30.0
	request.use_threads = true
	root.add_child(request)
	var headers := PackedStringArray(["Accept: application/json"])
	if not access_token.is_empty():
		headers.append("Authorization: Bearer %s" % access_token)
	var body_text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		body_text = JSON.stringify(body)
	var error := request.request(url, headers, method, body_text)
	if error != OK:
		request.queue_free()
		return {"status": 0, "payload": {}, "text": "", "error": error_string(error)}
	var completed: Array = await request.request_completed
	request.queue_free()
	if completed.size() < 4:
		return {"status": 0, "payload": {}, "text": "", "error": "invalid-http-result"}
	var result := int(completed[0])
	var status := int(completed[1]) if result == HTTPRequest.RESULT_SUCCESS else 0
	var response_body: PackedByteArray = completed[3]
	var text := response_body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	return {
		"status": status,
		"payload": parsed if parsed is Dictionary else {},
		"text": text,
		"error": "" if status > 0 else "request-failed",
	}

func _put_bytes(url: String, bytes: PackedByteArray) -> Dictionary:
	var request := HTTPRequest.new()
	CloudHttpTransport.configure_https_proxy(request)
	request.timeout = 60.0
	request.use_threads = true
	root.add_child(request)
	var error := request.request_raw(
		url,
		PackedStringArray(["Content-Type: application/octet-stream"]),
		HTTPClient.METHOD_PUT,
		bytes
	)
	if error != OK:
		request.queue_free()
		return {"status": 0, "error": error_string(error)}
	var completed: Array = await request.request_completed
	request.queue_free()
	if completed.size() < 2:
		return {"status": 0, "error": "invalid-http-result"}
	var result := int(completed[0])
	return {
		"status": int(completed[1]) if result == HTTPRequest.RESULT_SUCCESS else 0,
		"error": "" if result == HTTPRequest.RESULT_SUCCESS else "request-failed",
	}

func _put_file_with_desktop_network(url: String, package_path: String) -> Dictionary:
	var electron_exe := OS.get_environment("OCP_CREATOR_E2E_ELECTRON_EXE").strip_edges()
	var helper_script := OS.get_environment("OCP_CREATOR_E2E_ELECTRON_UPLOAD_HELPER").strip_edges()
	if electron_exe.is_empty() or helper_script.is_empty():
		return {"status": 0, "error": "desktop-upload-helper-unconfigured"}
	if not FileAccess.file_exists(electron_exe) or not FileAccess.file_exists(helper_script):
		return {"status": 0, "error": "desktop-upload-helper-missing"}
	var request_path := OS.get_user_data_dir().path_join("creator-e2e-presigned-upload.json")
	var request_file := FileAccess.open(request_path, FileAccess.WRITE)
	if request_file == null:
		return {"status": 0, "error": "desktop-upload-request-write-failed"}
	request_file.store_string(JSON.stringify({"url": url}))
	request_file.close()
	var output: Array = []
	var exit_code := OS.execute(electron_exe, [helper_script, request_path, package_path], output, true)
	if FileAccess.file_exists(request_path):
		DirAccess.remove_absolute(request_path)
	for line in output:
		var text := str(line).strip_edges()
		if not text.is_empty():
			print("[S7-CREATOR-E2E] desktop-upload ", text.substr(0, 300))
	return {
		"status": 200 if exit_code == 0 else 0,
		"error": "" if exit_code == 0 else "desktop-upload-helper-failed:%d" % exit_code,
	}

func _request_status(url: String, access_token: String = "") -> int:
	if not OS.get_environment("OCP_CREATOR_E2E_ELECTRON_REQUEST_HELPER").strip_edges().is_empty():
		return int(_desktop_request_json(HTTPClient.METHOD_GET, url, access_token, null, true).get("status", 0))
	var request := HTTPRequest.new()
	CloudHttpTransport.configure_https_proxy(request)
	request.timeout = 30.0
	request.use_threads = true
	root.add_child(request)
	var headers := PackedStringArray(["Accept: */*"])
	if not access_token.is_empty():
		headers.append("Authorization: Bearer %s" % access_token)
	var error := request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		request.queue_free()
		return 0
	var completed: Array = await request.request_completed
	request.queue_free()
	if completed.size() < 2 or int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
		return 0
	return int(completed[1])

func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

func _fail(stage: String, detail: String, auth: Node, device: Node, download: Node, code: int) -> void:
	print("[S7-CREATOR-E2E] stage=%s ok=false detail=%s" % [stage, detail.replace("\n", " ").substr(0, 500)])
	if is_instance_valid(auth): auth.call("stop")
	if is_instance_valid(device): device.call("stop")
	if is_instance_valid(download): download.call("stop")
	quit(code)

func _run() -> void:
	var package_path := OS.get_environment("OCP_CREATOR_E2E_PACKAGE_PATH").strip_edges()
	var package_id := OS.get_environment("OCP_CREATOR_E2E_PACKAGE_ID").strip_edges().to_lower()
	var version := OS.get_environment("OCP_CREATOR_E2E_VERSION").strip_edges()
	var display_name := OS.get_environment("OCP_CREATOR_E2E_NAME").strip_edges()
	var publisher_id := OS.get_environment("OCP_CREATOR_E2E_PUBLISHER").strip_edges().to_lower()
	var expected_key_id := OS.get_environment("OCP_CREATOR_E2E_KEY_ID").strip_edges()
	var public_key_hex := OS.get_environment("OCP_CREATOR_E2E_PUBLIC_KEY_HEX").strip_edges().to_lower()
	var handoff_output_path := OS.get_environment("OCP_CREATOR_E2E_HANDOFF_PATH").strip_edges()
	var resume_store := OS.get_environment("OCP_CREATOR_E2E_RESUME_STORE").strip_edges() in ["1", "true", "yes", "on"]
	var resume_upload := OS.get_environment("OCP_CREATOR_E2E_RESUME_UPLOAD").strip_edges() in ["1", "true", "yes", "on"]
	if package_path.is_empty() or package_id.is_empty() or version.is_empty() or display_name.is_empty() or publisher_id.is_empty() or expected_key_id.is_empty() or public_key_hex.is_empty():
		print("[S7-CREATOR-E2E] stage=config ok=false detail=missing-required-environment")
		quit(2)
		return
	if not FileAccess.file_exists(package_path):
		print("[S7-CREATOR-E2E] stage=config ok=false detail=package-file-missing")
		quit(2)
		return

	var file := FileAccess.open(package_path, FileAccess.READ)
	if file == null:
		print("[S7-CREATOR-E2E] stage=config ok=false detail=package-open-failed")
		quit(2)
		return
	var package_bytes := file.get_buffer(file.get_length())
	file.close()
	var archive_sha256 := _sha256_hex(package_bytes)

	var context := LiveContext.new()
	var bus := LiveBus.new()
	var bridge := OcpRuntimeBridge.new()
	var session := SessionService.new()
	var auth := AuthService.new()
	var device := DeviceService.new()
	var download := DownloadService.new()
	var package_service := FakePackageService.new()
	var effect_service := FakeEffectPackService.new()
	for node in [context, bus, bridge, session, auth, device, download, package_service, effect_service]:
		root.add_child(node)

	session.configure(context, bus)
	auth.configure(context, bus)
	device.configure(context, bus)
	download.configure(context, bus)
	auth.bind_session(session)
	auth.bind_bridge(bridge)
	device.bind_session(session)
	device.bind_bridge(bridge)
	download.bind_session(session)
	download.bind_device_service(device)
	download.bind_bridge(bridge)
	download.bind_package_service(package_service)
	download.bind_effect_pack_service(effect_service)
	device.start()
	download.start()
	auth.start()

	var session_ready := false
	for _step in range(400):
		if session.is_signed_in() and not session.device_id().is_empty():
			session_ready = true
			break
		await create_timer(0.05).timeout
	if not session_ready:
		_fail("auth", "secure Runtime session/device unavailable", auth, device, download, 3)
		return
	var token := session.access_token()

	var publishers := await _request_json(HTTPClient.METHOD_GET, BASE_URL + "/v1/creator/publishers", token)
	if int(publishers.get("status", 0)) != 200:
		_fail("publisher", "publisher list HTTP %d" % int(publishers.get("status", 0)), auth, device, download, 4)
		return
	var matching_publisher: Dictionary = {}
	var publisher_items: Variant = (publishers.get("payload", {}) as Dictionary).get("items", [])
	if publisher_items is Array:
		for item_value in publisher_items:
			if item_value is Dictionary and str((item_value as Dictionary).get("publisherId", "")) == publisher_id:
				matching_publisher = item_value as Dictionary
				break
	if matching_publisher.is_empty():
		var onboard := await _request_json(
			HTTPClient.METHOD_POST,
			BASE_URL + "/v1/creator/publishers",
			token,
			{"publisherId": publisher_id, "displayName": "Preview E2E", "keyId": expected_key_id, "publicKeyHex": public_key_hex}
		)
		if int(onboard.get("status", 0)) not in [200, 201]:
			_fail("publisher", "onboarding HTTP %d: %s" % [int(onboard.get("status", 0)), str(onboard.get("text", ""))], auth, device, download, 4)
			return
		matching_publisher = ((onboard.get("payload", {}) as Dictionary).get("creator", {}) as Dictionary)
	var key_active := false
	var publisher_keys: Variant = matching_publisher.get("keys", [])
	if publisher_keys is Array:
		for key_value in publisher_keys:
			if key_value is Dictionary \
			and str((key_value as Dictionary).get("keyId", "")) == expected_key_id \
			and str((key_value as Dictionary).get("status", "")) == "active":
				key_active = true
				break
	if not key_active:
		var key_enroll := await _request_json(
			HTTPClient.METHOD_POST,
			BASE_URL + "/v1/creator/keys",
			token,
			{"publisherId": publisher_id, "keyId": expected_key_id, "publicKeyHex": public_key_hex}
		)
		if int(key_enroll.get("status", 0)) not in [200, 201]:
			_fail("publisher", "key enrollment HTTP %d: %s" % [int(key_enroll.get("status", 0)), str(key_enroll.get("text", ""))], auth, device, download, 4)
			return

	var submission_id := ""
	if not resume_store:
		var identity_url := BASE_URL + "/v1/creator/identity?packageId=%s&displayName=%s&publisherId=%s" % [
			package_id.uri_encode(), display_name.uri_encode(), publisher_id.uri_encode()
		]
		var identity := await _request_json(HTTPClient.METHOD_GET, identity_url, token)
		if int(identity.get("status", 0)) != 200:
			_fail("identity", "identity HTTP %d" % int(identity.get("status", 0)), auth, device, download, 5)
			return
		var identity_row := ((identity.get("payload", {}) as Dictionary).get("identity", {}) as Dictionary)
		var decision := str(identity_row.get("decision", ""))
		if decision in ["available", "reserved-by-you", "owned-submission"]:
			var reserved := await _request_json(
				HTTPClient.METHOD_POST,
				BASE_URL + "/v1/creator/identity/reservations",
				token,
				{"packageId": package_id, "displayName": display_name, "publisherId": publisher_id}
			)
			if int(reserved.get("status", 0)) not in [200, 201]:
				_fail("identity", "reservation HTTP %d" % int(reserved.get("status", 0)), auth, device, download, 5)
				return
			identity_row = ((reserved.get("payload", {}) as Dictionary).get("identity", {}) as Dictionary)
			decision = str(identity_row.get("decision", ""))
		if decision not in ["reserved-by-you", "owned-published"]:
			_fail("identity", "not publishable: %s" % decision, auth, device, download, 5)
			return

		var upload: Dictionary
		if resume_upload:
			var submissions := await _request_json(
				HTTPClient.METHOD_GET,
				BASE_URL + "/v1/creator/submissions?publisherId=%s" % publisher_id.uri_encode(),
				token
			)
			if int(submissions.get("status", 0)) != 200:
				_fail("upload-resume", "submission list HTTP %d" % int(submissions.get("status", 0)), auth, device, download, 6)
				return
			var pending_submission: Dictionary = {}
			var submission_items: Variant = (submissions.get("payload", {}) as Dictionary).get("items", [])
			if submission_items is Array:
				for item_value in submission_items:
					if item_value is Dictionary:
						var item := item_value as Dictionary
						if str(item.get("packageId", "")) == package_id \
						and str(item.get("version", "")) == version \
						and str(item.get("status", "")) == "upload-authorized":
							pending_submission = item
							break
			if pending_submission.is_empty():
				_fail("upload-resume", "no matching upload-authorized submission", auth, device, download, 6)
				return
			submission_id = str(pending_submission.get("submissionId", ""))
			upload = await _request_json(
				HTTPClient.METHOD_POST,
				BASE_URL + "/v1/creator/submissions/%s/upload" % submission_id.uri_encode(),
				token,
				{}
			)
			if int(upload.get("status", 0)) != 200:
				_fail("upload-resume", "renew HTTP %d: %s" % [int(upload.get("status", 0)), str(upload.get("text", ""))], auth, device, download, 6)
				return
		else:
			upload = await _request_json(
				HTTPClient.METHOD_POST,
				BASE_URL + "/v1/creator/uploads",
				token,
				{
					"publisherId": publisher_id,
					"packageId": package_id,
					"packageType": "character",
					"version": version,
					"fileName": "%s-v%s.ocp" % [package_id.replace(".", "-"), version],
					"sizeBytes": package_bytes.size(),
					"archiveSha256": archive_sha256,
				}
			)
			if int(upload.get("status", 0)) != 201:
				_fail("upload-authorize", "HTTP %d: %s" % [int(upload.get("status", 0)), str(upload.get("text", ""))], auth, device, download, 6)
				return
		var upload_payload := upload.get("payload", {}) as Dictionary
		var submission := upload_payload.get("submission", {}) as Dictionary
		var upload_info := upload_payload.get("upload", {}) as Dictionary
		if submission_id.is_empty():
			submission_id = str(submission.get("submissionId", ""))
		var upload_url := str(upload_info.get("url", ""))
		if submission_id.is_empty() or not upload_url.begins_with("https://"):
			_fail("upload-authorize", "invalid upload authorization", auth, device, download, 6)
			return

		var uploaded: Dictionary
		if not OS.get_environment("OCP_CREATOR_E2E_ELECTRON_UPLOAD_HELPER").strip_edges().is_empty():
			uploaded = _put_file_with_desktop_network(upload_url, package_path)
		else:
			uploaded = await _put_bytes(upload_url, package_bytes)
		if int(uploaded.get("status", 0)) < 200 or int(uploaded.get("status", 0)) >= 300:
			_fail("r2-upload", "HTTP %d error=%s" % [int(uploaded.get("status", 0)), str(uploaded.get("error", ""))], auth, device, download, 7)
			return

		var completed := await _request_json(HTTPClient.METHOD_POST, BASE_URL + "/v1/creator/submissions/%s/complete" % submission_id.uri_encode(), token, {})
		if int(completed.get("status", 0)) not in [200, 201]:
			_fail("complete", "HTTP %d" % int(completed.get("status", 0)), auth, device, download, 8)
			return
		var validated := await _request_json(HTTPClient.METHOD_POST, BASE_URL + "/v1/creator/submissions/%s/validate" % submission_id.uri_encode(), token, {})
		var validated_submission := ((validated.get("payload", {}) as Dictionary).get("submission", {}) as Dictionary)
		if int(validated.get("status", 0)) not in [200, 201] or str(validated_submission.get("status", "")) != "validated":
			_fail("validate", "HTTP %d status=%s body=%s" % [int(validated.get("status", 0)), str(validated_submission.get("status", "")), str(validated.get("text", ""))], auth, device, download, 9)
			return
		var review := await _request_json(HTTPClient.METHOD_POST, BASE_URL + "/v1/creator/submissions/%s/review" % submission_id.uri_encode(), token, {})
		var review_submission := ((review.get("payload", {}) as Dictionary).get("submission", {}) as Dictionary)
		if int(review.get("status", 0)) not in [200, 201] or str(review_submission.get("status", "")) != "review-ready":
			_fail("review", "HTTP %d status=%s" % [int(review.get("status", 0)), str(review_submission.get("status", ""))], auth, device, download, 10)
			return
		var publication := await _request_json(
			HTTPClient.METHOD_POST,
			BASE_URL + "/v1/moderation/submissions/%s/publish" % submission_id.uri_encode(),
			token,
			{"name": display_name, "availability": "free"}
		)
		var publication_result := ((publication.get("payload", {}) as Dictionary).get("result", {}) as Dictionary)
		var publication_status := str(publication_result.get("status", publication_result.get("decision", "")))
		if int(publication.get("status", 0)) not in [200, 201] or publication_status != "published":
			_fail("publish", "HTTP %d status=%s body=%s" % [int(publication.get("status", 0)), publication_status, str(publication.get("text", ""))], auth, device, download, 11)
			return
		print("[S7-CREATOR-E2E] stage=published ok=true submission=%s package=%s@%s" % [submission_id, package_id, version])

	var catalog := await _request_json(HTTPClient.METHOD_GET, BASE_URL + "/v1/catalog/characters")
	if int(catalog.get("status", 0)) != 200:
		_fail("catalog", "HTTP %d" % int(catalog.get("status", 0)), auth, device, download, 12)
		return
	var catalog_item: Dictionary = {}
	var catalog_items: Variant = (catalog.get("payload", {}) as Dictionary).get("items", [])
	if catalog_items is Array:
		for item_value in catalog_items:
			if item_value is Dictionary and str((item_value as Dictionary).get("characterId", "")) == package_id:
				catalog_item = item_value as Dictionary
				break
	if catalog_item.is_empty() or str(catalog_item.get("latestVersion", "")) != version:
		_fail("catalog", "published character missing", auth, device, download, 12)
		return
	var thumbnail_url := str(catalog_item.get("thumbnailUrl", ""))
	if thumbnail_url.is_empty() or await _request_status(thumbnail_url) != 200:
		_fail("thumbnail", "published card thumbnail is unavailable", auth, device, download, 12)
		return

	var preview_base := BASE_URL + "/v1/catalog/characters/%s/versions/%s/preview/" % [package_id.uri_encode(), version.uri_encode()]
	var preview := await _request_json(HTTPClient.METHOD_GET, preview_base + "manifest.json")
	var preview_manifest := preview.get("payload", {}) as Dictionary
	if int(preview.get("status", 0)) != 200:
		_fail("preview", "manifest HTTP %d: %s" % [int(preview.get("status", 0)), str(preview.get("text", ""))], auth, device, download, 12)
		return
	var descriptions := preview_manifest.get("descriptions", {}) as Dictionary
	var animations: Variant = preview_manifest.get("animations", [])
	if str(preview_manifest.get("name", "")) != display_name \
	or str(descriptions.get("en", "")).strip_edges().is_empty() \
	or str(descriptions.get("th", "")).strip_edges().is_empty() \
	or not (animations is Array) \
	or (animations as Array).is_empty():
		_fail("preview", "name/localized descriptions/animations are incomplete", auth, device, download, 12)
		return
	var first_animation := (animations as Array)[0] as Dictionary
	var first_sheet := str(first_animation.get("sheet", ""))
	var first_thumbnail := str(first_animation.get("thumbnail", ""))
	if first_sheet.is_empty() or first_thumbnail.is_empty():
		_fail("preview", "first animation media mapping is incomplete", auth, device, download, 12)
		return
	if await _request_status(preview_base + first_sheet.uri_encode()) != 200 \
	or await _request_status(preview_base + first_thumbnail.uri_encode()) != 200:
		_fail("preview", "published animation media is unavailable", auth, device, download, 12)
		return
	print("[S7-CREATOR-CHAR-PREVIEW] stage=preview ok=true name=%s animations=%d localized=en,th thumbnail=true" % [
		str(preview_manifest.get("name", "")),
		(animations as Array).size(),
	])

	var handoff := await _request_json(
		HTTPClient.METHOD_POST,
		BASE_URL + "/v1/downloads/handoff",
		token,
		{"packageId": package_id, "version": version}
	)
	if int(handoff.get("status", 0)) not in [200, 201]:
		_fail("handoff", "HTTP %d: %s" % [int(handoff.get("status", 0)), str(handoff.get("text", ""))], auth, device, download, 14)
		return
	var handoff_payload := handoff.get("payload", {}) as Dictionary
	var handoff_info := handoff_payload.get("handoff", {}) as Dictionary
	var grant := str(handoff_info.get("grant", ""))
	if not DownloadService.is_valid_install_grant(grant):
		_fail("handoff", "install grant is missing or malformed", auth, device, download, 14)
		return
	if not handoff_output_path.is_empty():
		var handoff_file := FileAccess.open(handoff_output_path, FileAccess.WRITE)
		if handoff_file == null:
			_fail("handoff", "could not write handoff output", auth, device, download, 14)
			return
		handoff_file.store_string(JSON.stringify({"packageId": package_id, "version": version, "grant": grant}))
		handoff_file.close()

	# A free character receives its canonical Library entitlement when the
	# authenticated Store handoff is issued. This proves the signed-in path and
	# remains server-authoritative; an anonymous request is covered separately.
	var library := await _request_json(HTTPClient.METHOD_GET, BASE_URL + "/v1/library", token)
	if int(library.get("status", 0)) != 200:
		_fail("library", "HTTP %d" % int(library.get("status", 0)), auth, device, download, 13)
		return
	var library_ok := false
	var library_items: Variant = (library.get("payload", {}) as Dictionary).get("items", [])
	if library_items is Array:
		for item_value in library_items:
			if item_value is Dictionary:
				var item := item_value as Dictionary
				if str(item.get("productType", "")) == "character" \
				and str(item.get("productId", "")) == package_id \
				and bool(item.get("entitled", false)) \
				and str(item.get("source", "")) == "free-install":
					library_ok = true
					break
	if not library_ok:
		_fail("library", "free-install character entitlement missing after handoff", auth, device, download, 13)
		return

	auth.stop()
	device.stop()
	download.stop()
	print("[S7-CREATOR-CHAR-PREVIEW] stage=complete ok=true package=%s@%s publisher=%s catalog=true preview=true localized=true library=true handoff=true" % [package_id, version, publisher_id])
	quit(0)
