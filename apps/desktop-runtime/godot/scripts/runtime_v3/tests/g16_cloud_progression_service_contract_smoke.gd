extends SceneTree

const ServiceScript = preload("res://scripts/runtime_v3/services/cloud_progression_service.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var event := {
		"id": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d18",
		"type": "ocp.companion.created",
		"version": "1.0",
		"source": "runtime",
		"time": "2026-08-26T10:00:00Z",
		"correlationId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d19",
		"contentType": "application/json",
		"data": {"companionId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d21", "characterId": "character.sabai"},
	}
	var payload_result: Dictionary = ServiceScript.build_sync_payload([event], "device-1")
	var payload: Dictionary = payload_result.get("payload", {})
	var no_authority: bool = bool(payload_result.get("ok", false)) \
		and payload.get("deviceId") == "device-1" \
		and not JSON.stringify(payload).contains("\"xp\"") \
		and not JSON.stringify(payload).contains("\"level\"")
	var forged := event.duplicate(true)
	forged["xp"] = 999999
	var forged_rejected: bool = not bool(ServiceScript.build_sync_payload([forged], "device-1").get("ok", true))
	var response := {
		"results": [
			{"eventId": str(event.get("id")), "status": "accepted"},
		],
		"progression": {
			"revision": 3,
			"companions": [{
				"companionId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d21",
				"characterId": "character.sabai",
				"relationship": {"level": 1, "xp": 0},
				"skills": [],
			}],
		},
	}
	var expected_ids: Array[String] = [str(event.get("id"))]
	var projected: Dictionary = ServiceScript.project_sync_response(response, expected_ids)
	var ack_ids: Array = projected.get("acknowledged_ids", [])
	var response_ok: bool = bool(projected.get("ok", false)) and ack_ids.size() == 1 \
		and int((projected.get("progression", {}) as Dictionary).get("revision", -1)) == 3
	var invalid_status_rejected: bool = not bool(ServiceScript.project_sync_response({
		"results": [{"eventId": str(event.get("id")), "status": "pending"}],
		"progression": response.get("progression"),
	}, expected_ids).get("ok", true))
	var foreign_id_rejected: bool = not bool(ServiceScript.project_sync_response({
		"results": [{"eventId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d20", "status": "accepted"}],
		"progression": response.get("progression"),
	}, expected_ids).get("ok", true))
	var duplicate_result_rejected: bool = not bool(ServiceScript.project_sync_response({
		"results": [
			{"eventId": str(event.get("id")), "status": "accepted"},
			{"eventId": str(event.get("id")), "status": "duplicate"},
		],
		"progression": response.get("progression"),
	}, expected_ids).get("ok", true))
	var smuggled := event.duplicate(true)
	smuggled["debug"] = true
	var unknown_field_rejected: bool = not bool(ServiceScript.build_sync_payload([smuggled], "device-1").get("ok", true))
	var ok: bool = no_authority and forged_rejected and response_ok and invalid_status_rejected \
		and foreign_id_rejected and duplicate_result_rejected and unknown_field_rejected
	print("[G16.5] no_authority=%s forged=%s response=%s invalid_status=%s foreign=%s duplicate=%s strict=%s" % [
		str(no_authority).to_lower(), str(forged_rejected).to_lower(), str(response_ok).to_lower(), str(invalid_status_rejected).to_lower(),
		str(foreign_id_rejected).to_lower(), str(duplicate_result_rejected).to_lower(), str(unknown_field_rejected).to_lower(),
	])
	quit(0 if ok else 1)
