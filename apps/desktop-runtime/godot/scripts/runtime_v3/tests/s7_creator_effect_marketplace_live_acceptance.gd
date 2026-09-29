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

func _request_json(method: int, url: String, access_token: String = "", body: Variant = null) -> Dictionary:
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
	var resume_store := OS.get_environment("OCP_CREATOR_E2E_RESUME_STORE").strip_edges() in ["1", "true", "yes", "on"]
	if package_path.is_empty() or package_id.is_empty() or version.is_empty() or display_name.is_empty() or publisher_id.is_empty() or expected_key_id.is_empty():
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
		_fail("publisher", "publisher membership missing", auth, device, download, 4)
		return
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
		_fail("publisher", "expected signing key is not active", auth, device, download, 4)
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

		var upload := await _request_json(
			HTTPClient.METHOD_POST,
			BASE_URL + "/v1/creator/uploads",
			token,
			{
				"publisherId": publisher_id,
				"packageId": package_id,
				"packageType": "effect-pack",
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
		submission_id = str(submission.get("submissionId", ""))
		var upload_url := str(upload_info.get("url", ""))
		if submission_id.is_empty() or not upload_url.begins_with("https://"):
			_fail("upload-authorize", "invalid upload authorization", auth, device, download, 6)
			return

		var uploaded := await _put_bytes(upload_url, package_bytes)
		if int(uploaded.get("status", 0)) < 200 or int(uploaded.get("status", 0)) >= 300:
			_fail("r2-upload", "HTTP %d" % int(uploaded.get("status", 0)), auth, device, download, 7)
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

	var catalog := await _request_json(HTTPClient.METHOD_GET, BASE_URL + "/v1/catalog/assets?type=effect_pack")
	if int(catalog.get("status", 0)) != 200:
		_fail("catalog", "HTTP %d" % int(catalog.get("status", 0)), auth, device, download, 12)
		return
	var catalog_item: Dictionary = {}
	var catalog_items: Variant = (catalog.get("payload", {}) as Dictionary).get("items", [])
	if catalog_items is Array:
		for item_value in catalog_items:
			if item_value is Dictionary and str((item_value as Dictionary).get("assetId", "")) == package_id:
				catalog_item = item_value as Dictionary
				break
	if catalog_item.is_empty() or str(catalog_item.get("latestVersion", "")) != version:
		_fail("catalog", "published asset missing", auth, device, download, 12)
		return


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
	if grant.is_empty():
		_fail("handoff", "grant missing", auth, device, download, 14)
		return

	# Free Effect Packs claim their canonical free-install entitlement when the
	# Store issues the handoff. Verify Library after that server-authoritative
	# transition instead of expecting an entitlement before the first install.
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
				if str(item.get("productType", "")) == "effect_pack" \
				and str(item.get("productId", "")) == package_id \
				and bool(item.get("entitled", false)) \
				and str(item.get("source", "")) == "free-install":
					library_ok = true
					break
	if not library_ok:
		_fail("library", "free-install entitlement missing after handoff", auth, device, download, 13)
		return

	print("[S7-CREATOR-E2E] handoff-shape packageIdOk=%s versionOk=%s grantOk=%s grantLength=%d" % [
		str(DownloadService.is_valid_package_id(package_id)).to_lower(),
		str(DownloadService.is_valid_version(version)).to_lower(),
		str(DownloadService.is_valid_install_grant(grant)).to_lower(),
		grant.length(),
	])
	var redeem: Dictionary = download.redeem_install_handoff(package_id, version, grant)
	if not bool(redeem.get("ok", false)):
		_fail("desktop-install", "handoff rejected: %s" % str(redeem.get("status", "")), auth, device, download, 15)
		return
	var final_status := ""
	var final_snapshot: Dictionary = {}
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		final_snapshot = download.public_snapshot()
		final_status = str(final_snapshot.get("status", ""))
		if final_status in ["installed", "error"]:
			break
		await create_timer(0.20).timeout
	var trust := final_snapshot.get("trust", {}) as Dictionary
	var trust_mode := str(trust.get("mode", "none"))
	var installed_ok := final_status == "installed" and trust_mode == "marketplace-staging"
	print("[S7-CREATOR-E2E] stage=desktop-install status=%s trust=%s publishers=%s ok=%s" % [
		final_status,
		trust_mode,
		str(trust.get("trustedPublishers", 0)),
		str(installed_ok).to_lower(),
	])
	if not installed_ok:
		var detail := str(final_snapshot.get("error", final_snapshot.get("message", "")))
		_fail("desktop-install", "%s %s" % [final_status, detail], auth, device, download, 15)
		return

	auth.stop()
	device.stop()
	download.stop()
	print("[S7-CREATOR-E2E] stage=complete ok=true package=%s@%s publisher=%s catalog=true library=true handoff=true install=true" % [package_id, version, publisher_id])
	quit(0)
