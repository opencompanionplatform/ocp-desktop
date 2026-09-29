extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudProgressionService

const CloudHttpTransportScript = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

## Hosted C4 sync coordinator. It transports queued EVENT_API facts and caches
## the canonical server projection; it never calculates XP locally.

const DEFAULT_TIMEOUT_SECONDS := 20.0
const MAX_BATCH_SIZE := 100

var _session: Node
var _queue: Node
var _sync_http: HTTPRequest
var _projection_http: HTTPRequest
var _sync_in_flight := false
var _projection_in_flight := false
var _sync_batch_ids: Array[String] = []
var _canonical_projection: Dictionary = {"revision": 0, "levelCap": 200, "companions": []}
var _projection_initialized := false
var _sync_status := "signed-out"


func bind_session(target: Node) -> void:
	_session = target
	# Runtime cross-binds after services start. A restored secure session may
	# therefore predate our cloud.session.changed subscription; bootstrap the
	# canonical cache/sync path from the current session as well.
	if is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in")):
		_sync_status = "idle"
		_load_cached_projection()
		call_deferred("sync_pending")
		call_deferred("refresh_projection")
	else:
		_sync_status = "signed-out"


func bind_queue(target: Node) -> void:
	_queue = target
	# Runtime wires the restored session before the native SQLite queue. If the
	# session was already signed in, bind_session() could not load the cached
	# canonical projection because _queue was still null. Bootstrap again here
	# so Character Manager can show EXP/Level immediately from local cache while
	# the deferred live Cloud sync/refresh scheduled by bind_session() continues.
	if is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in")):
		_sync_status = "idle"
		_load_cached_projection()


func start() -> void:
	if not is_instance_valid(_sync_http):
		_sync_http = HTTPRequest.new()
		CloudHttpTransportScript.configure_https_proxy(_sync_http)
		_sync_http.name = "OCPCloudProgressionSync"
		_sync_http.timeout = DEFAULT_TIMEOUT_SECONDS
		add_child(_sync_http)
		_sync_http.request_completed.connect(_on_sync_completed)
	if not is_instance_valid(_projection_http):
		_projection_http = HTTPRequest.new()
		CloudHttpTransportScript.configure_https_proxy(_projection_http)
		_projection_http.name = "OCPCloudProgressionProjection"
		_projection_http.timeout = DEFAULT_TIMEOUT_SECONDS
		add_child(_projection_http)
		_projection_http.request_completed.connect(_on_projection_completed)
	if is_instance_valid(event_bus):
		event_bus.subscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
		event_bus.subscribe(&"progression.queue.changed", Callable(self, "_on_queue_changed"))


func stop() -> void:
	if is_instance_valid(event_bus):
		event_bus.unsubscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
		event_bus.unsubscribe(&"progression.queue.changed", Callable(self, "_on_queue_changed"))
	_sync_in_flight = false
	_projection_in_flight = false
	_sync_batch_ids.clear()


func canonical_projection() -> Dictionary:
	return _canonical_projection.duplicate(true)


func sync_snapshot() -> Dictionary:
	return {
		"status": _sync_status,
		"progressionRevision": maxi(0, int(_canonical_projection.get("revision", 0))),
	}


func sync_pending() -> Dictionary:
	if _sync_in_flight:
		return {"ok": false, "status": "busy"}
	var readiness := _sync_readiness()
	if not bool(readiness.get("ok", false)):
		return readiness
	var pending_result: Variant = _queue.call("pending", MAX_BATCH_SIZE)
	if not (pending_result is Dictionary) or not bool((pending_result as Dictionary).get("ok", false)):
		return {"ok": false, "status": "queue-error"}
	var events: Array = (pending_result as Dictionary).get("events", [])
	if events.is_empty():
		_sync_status = "synced"
		return {"ok": true, "status": "idle", "count": 0}
	var device_id := str(_session.call("device_id"))
	var body := build_sync_payload(events, device_id)
	if not bool(body.get("ok", false)):
		return {"ok": false, "status": "invalid-local-batch"}
	_sync_batch_ids.clear()
	for raw_id in body.get("event_ids", []):
		_sync_batch_ids.append(str(raw_id))
	_sync_in_flight = true
	_sync_status = "syncing"
	var error := _sync_http.request(
		"%s/v1/progression/events" % _cloud_api_base_url().trim_suffix("/"),
		_auth_headers(true),
		HTTPClient.METHOD_POST,
		JSON.stringify(body.get("payload", {}))
	)
	if error != OK:
		_sync_in_flight = false
		_sync_batch_ids.clear()
		_sync_status = "error"
		return {"ok": false, "status": "network-error", "error": error_string(error)}
	event_bus.publish(&"cloud.progression.sync_state", {"status": "syncing", "count": events.size()})
	return {"ok": true, "status": "syncing", "count": events.size()}


func refresh_projection() -> Dictionary:
	if _projection_in_flight:
		return {"ok": false, "status": "busy"}
	var readiness := _sync_readiness(false)
	if not bool(readiness.get("ok", false)):
		return readiness
	_projection_in_flight = true
	var error := _projection_http.request(
		"%s/v1/progression" % _cloud_api_base_url().trim_suffix("/"),
		_auth_headers(false),
		HTTPClient.METHOD_GET
	)
	if error != OK:
		_projection_in_flight = false
		return {"ok": false, "status": "network-error", "error": error_string(error)}
	return {"ok": true, "status": "loading"}


func _sync_readiness(require_device: bool = true) -> Dictionary:
	if not is_instance_valid(_session) or not _session.has_method("is_signed_in") or not bool(_session.call("is_signed_in")):
		return {"ok": false, "status": "sign-in-required"}
	if require_device and (not _session.has_method("device_id") or str(_session.call("device_id")).strip_edges().is_empty()):
		return {"ok": false, "status": "device-registration-required"}
	if not is_instance_valid(_queue):
		return {"ok": false, "status": "queue-unavailable"}
	if not is_valid_cloud_api_url(_cloud_api_base_url()):
		return {"ok": false, "status": "not-configured"}
	return {"ok": true}


func _auth_headers(json_body: bool) -> PackedStringArray:
	var headers := PackedStringArray([
		"Accept: application/json",
		"Authorization: Bearer %s" % str(_session.call("access_token")),
	])
	if json_body:
		headers.append("Content-Type: application/json")
	return headers


func _cloud_api_base_url() -> String:
	if not is_instance_valid(context):
		return ""
	return str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()


func _on_session_changed(payload: Dictionary) -> void:
	if bool(payload.get("signed_in", false)):
		_sync_status = "idle"
		_load_cached_projection()
		call_deferred("sync_pending")
		call_deferred("refresh_projection")
		return
	_canonical_projection = {"revision": 0, "levelCap": 200, "companions": []}
	_projection_initialized = false
	_sync_status = "signed-out"
	_sync_batch_ids.clear()
	event_bus.publish(&"cloud.progression.updated", canonical_projection())


func _on_queue_changed(_payload: Dictionary) -> void:
	call_deferred("sync_pending")


func _on_sync_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_sync_in_flight = false
	var expected_ids: Array[String] = _sync_batch_ids.duplicate()
	_sync_batch_ids.clear()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_handle_auth_failure(response_code)
		_sync_status = "error"
		event_bus.publish(&"cloud.progression.sync_state", {"status": "error", "http_status": response_code})
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var projection_result := project_sync_response(parsed, expected_ids)
	if not bool(projection_result.get("ok", false)):
		_sync_status = "error"
		event_bus.publish(&"cloud.progression.sync_state", {"status": "invalid-response"})
		return
	var acknowledged_ids: Array[String] = projection_result.get("acknowledged_ids", [])
	if not acknowledged_ids.is_empty():
		var ack_result: Variant = _queue.call("acknowledge", acknowledged_ids)
		if not (ack_result is Dictionary) or not bool((ack_result as Dictionary).get("ok", false)):
			_sync_status = "error"
			event_bus.publish(&"cloud.progression.sync_state", {"status": "ack-error"})
			return
	_apply_canonical_projection((projection_result.get("progression", {}) as Dictionary), "sync")
	_cache_canonical_projection()
	_sync_status = "synced"
	event_bus.publish(&"cloud.progression.updated", canonical_projection())
	event_bus.publish(&"cloud.progression.sync_state", {
		"status": "synced",
		"acknowledged": acknowledged_ids.size(),
	})
	call_deferred("sync_pending")


func _on_projection_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	_projection_in_flight = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		_handle_auth_failure(response_code)
		_sync_status = "error"
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var projection := project_progression_projection(parsed)
	if not bool(projection.get("ok", false)):
		_sync_status = "error"
		return
	_apply_canonical_projection((projection.get("progression", {}) as Dictionary), "refresh")
	_cache_canonical_projection()
	_sync_status = "synced"
	event_bus.publish(&"cloud.progression.updated", canonical_projection())


func _apply_canonical_projection(next_projection: Dictionary, source: String, allow_level_up: bool = true) -> void:
	var previous := _canonical_projection.duplicate(true)
	var should_compare := _projection_initialized and allow_level_up
	_canonical_projection = next_projection.duplicate(true)
	_projection_initialized = true
	if should_compare:
		_publish_level_up_events(previous, _canonical_projection, source)


func _publish_level_up_events(previous: Dictionary, current: Dictionary, source: String) -> void:
	var previous_by_id: Dictionary = {}
	var previous_companions: Variant = previous.get("companions", [])
	if previous_companions is Array:
		for raw_previous in previous_companions:
			if not (raw_previous is Dictionary):
				continue
			var previous_companion := raw_previous as Dictionary
			var previous_id := str(previous_companion.get("companionId", "")).strip_edges()
			if not previous_id.is_empty():
				previous_by_id[previous_id] = previous_companion

	var current_companions: Variant = current.get("companions", [])
	if not (current_companions is Array):
		return
	for raw_current in current_companions:
		if not (raw_current is Dictionary):
			continue
		var companion := raw_current as Dictionary
		var companion_id := str(companion.get("companionId", "")).strip_edges()
		if companion_id.is_empty() or not previous_by_id.has(companion_id):
			continue
		var old_companion: Dictionary = previous_by_id[companion_id]
		var old_relationship: Variant = old_companion.get("relationship", {})
		var new_relationship: Variant = companion.get("relationship", {})
		if not (old_relationship is Dictionary) or not (new_relationship is Dictionary):
			continue
		var old_level := maxi(1, int((old_relationship as Dictionary).get("level", 1)))
		var new_level := maxi(1, int((new_relationship as Dictionary).get("level", 1)))
		if new_level <= old_level:
			continue
		var relationship := new_relationship as Dictionary
		event_bus.publish(&"progression.level_up", {
			"companionId": companion_id,
			"characterId": str(companion.get("characterId", "")).strip_edges(),
			"fromLevel": old_level,
			"toLevel": new_level,
			"xp": maxi(0, int(relationship.get("xp", 0))),
			"bondRank": str(relationship.get("bondRank", "stranger")),
			"source": source,
		})


func _session_user_id() -> String:
	if not is_instance_valid(_session) or not _session.has_method("snapshot"):
		return ""
	var snapshot: Variant = _session.call("snapshot")
	if not (snapshot is Dictionary):
		return ""
	return str((snapshot as Dictionary).get("user_id", "")).strip_edges()


func _cache_canonical_projection() -> void:
	var user_id := _session_user_id()
	if user_id.is_empty() or not is_instance_valid(_queue) or not _queue.has_method("cache_projection"):
		return
	var result: Variant = _queue.call("cache_projection", user_id, _canonical_projection)
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		event_bus.publish(&"cloud.progression.cache_state", {"status": "write-error"})


func _load_cached_projection() -> bool:
	var user_id := _session_user_id()
	if user_id.is_empty() or not is_instance_valid(_queue) or not _queue.has_method("cached_projection"):
		return false
	var result: Variant = _queue.call("cached_projection", user_id)
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		return false
	if not bool((result as Dictionary).get("cached", false)):
		return false
	var projected := project_progression_projection((result as Dictionary).get("progression", {}))
	if not bool(projected.get("ok", false)):
		return false
	_apply_canonical_projection((projected.get("progression", {}) as Dictionary), "cache", false)
	event_bus.publish(&"cloud.progression.updated", canonical_projection())
	event_bus.publish(&"cloud.progression.cache_state", {"status": "loaded"})
	return true


func _handle_auth_failure(response_code: int) -> void:
	if response_code in [401, 403] and is_instance_valid(_session) and _session.has_method("clear"):
		_session.call("clear")


static func is_valid_cloud_api_url(value: String) -> bool:
	var uri := value.strip_edges()
	if uri in ["http://127.0.0.1:54321/functions/v1/cloud-api", "http://localhost:54321/functions/v1/cloud-api"]:
		return true
	if not uri.begins_with("https://") or uri.contains(" "):
		return false
	var host := uri.trim_prefix("https://").get_slice("/", 0)
	return not host.is_empty() and host.contains(".") and not host.begins_with(".")


static func build_sync_payload(events: Array, device_id: String) -> Dictionary:
	var canonical_device_id := device_id.strip_edges()
	if canonical_device_id.is_empty() or events.is_empty() or events.size() > MAX_BATCH_SIZE:
		return {"ok": false}
	var projected_events: Array[Dictionary] = []
	var event_ids: Array[String] = []
	var seen_ids: Dictionary = {}
	var allowed_keys := ["id", "type", "version", "source", "time", "correlationId", "contentType", "data"]
	for raw_event in events:
		if not (raw_event is Dictionary):
			return {"ok": false}
		var event := raw_event as Dictionary
		if event.size() != allowed_keys.size():
			return {"ok": false}
		for required in allowed_keys:
			if not event.has(required):
				return {"ok": false}
		if not (event.get("data") is Dictionary):
			return {"ok": false}
		var event_id := str(event.get("id", "")).strip_edges()
		if event_id.is_empty() or seen_ids.has(event_id):
			return {"ok": false}
		seen_ids[event_id] = true
		event_ids.append(event_id)
		projected_events.append(event.duplicate(true))
	return {
		"ok": true,
		"event_ids": event_ids,
		"payload": {
			"deviceId": canonical_device_id,
			"events": projected_events,
		},
	}


static func project_sync_response(payload: Variant, expected_event_ids: Array[String] = []) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false}
	var raw_results: Variant = (payload as Dictionary).get("results", null)
	var raw_progression: Variant = (payload as Dictionary).get("progression", null)
	if not (raw_results is Array) or not (raw_progression is Dictionary):
		return {"ok": false}
	var acknowledged_ids: Array[String] = []
	var expected: Dictionary = {}
	for expected_id in expected_event_ids:
		expected[str(expected_id)] = true
	var seen_results: Dictionary = {}
	for raw_result in raw_results:
		if not (raw_result is Dictionary):
			return {"ok": false}
		var result := raw_result as Dictionary
		var event_id := str(result.get("eventId", "")).strip_edges()
		var status := str(result.get("status", ""))
		if event_id.is_empty() or status not in ["accepted", "duplicate", "rejected", "rate-limited"]:
			return {"ok": false}
		if seen_results.has(event_id):
			return {"ok": false}
		if not expected.is_empty() and not expected.has(event_id):
			return {"ok": false}
		seen_results[event_id] = true
		acknowledged_ids.append(event_id)
	var projection := project_progression_projection(raw_progression)
	if not bool(projection.get("ok", false)):
		return {"ok": false}
	return {
		"ok": true,
		"acknowledged_ids": acknowledged_ids,
		"progression": projection.get("progression", {}),
	}


static func project_progression_projection(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false}
	var source := payload as Dictionary
	var revision: Variant = source.get("revision", null)
	var level_cap := clampi(int(source.get("levelCap", 200)), 1, 200)
	var companions: Variant = source.get("companions", null)
	if not (revision is int or revision is float) or int(revision) < 0 or not (companions is Array):
		return {"ok": false}
	var projected_companions: Array[Dictionary] = []
	for raw_companion in companions:
		if not (raw_companion is Dictionary):
			return {"ok": false}
		var companion := raw_companion as Dictionary
		var relationship_value: Variant = companion.get("relationship", null)
		var skills: Variant = companion.get("skills", null)
		if str(companion.get("companionId", "")).is_empty() or str(companion.get("characterId", "")).is_empty() \
			or not (relationship_value is Dictionary) or not (skills is Array):
			return {"ok": false}
		var relationship := relationship_value as Dictionary
		var level := clampi(int(relationship.get("level", 1)), 1, level_cap)
		var xp := maxi(0, int(relationship.get("xp", 0)))
		var current_level_xp := maxi(0, int(relationship.get("currentLevelXp", 0)))
		var next_level_value: Variant = relationship.get("nextLevelXp", null)
		var next_level_xp: Variant = null if next_level_value == null else maxi(0, int(next_level_value))
		var progress_permille := clampi(int(relationship.get("progressPermille", 0)), 0, 1000)
		var bond_rank := str(relationship.get("bondRank", _bond_rank_for_level(level)))
		if bond_rank not in ["stranger", "friend", "close-friend", "partner", "best-companion"]:
			return {"ok": false}
		projected_companions.append({
			"companionId": str(companion.get("companionId")),
			"characterId": str(companion.get("characterId")),
			"relationship": {
				"level": level,
				"xp": xp,
				"bondRank": bond_rank,
				"currentLevelXp": current_level_xp,
				"nextLevelXp": next_level_xp,
				"progressPermille": progress_permille,
			},
			"skills": (skills as Array).duplicate(true),
		})
	return {
		"ok": true,
		"progression": {
			"revision": int(revision),
			"levelCap": level_cap,
			"companions": projected_companions,
		},
	}


static func _bond_rank_for_level(level: int) -> String:
	if level >= 80:
		return "best-companion"
	if level >= 40:
		return "partner"
	if level >= 15:
		return "close-friend"
	if level >= 5:
		return "friend"
	return "stranger"
