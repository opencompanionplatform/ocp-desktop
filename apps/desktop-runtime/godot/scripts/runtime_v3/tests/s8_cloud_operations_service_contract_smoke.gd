extends SceneTree

const ServiceScript = preload("res://scripts/runtime_v3/services/cloud_operations_service.gd")
const DeviceServiceScript = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var device_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d18"
	var session_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d19"
	var companion_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d20"
	var result: Dictionary = ServiceScript.build_heartbeat_payload(
		device_id,
		session_id,
		"0.1.0-local.27",
		{"packageId": "character.sabai-sompoo", "version": "1.0.1"},
		companion_id
	)
	var payload: Dictionary = result.get("payload", {})
	var encoded := JSON.stringify(payload)
	var strict_facts: bool = bool(result.get("ok", false)) \
		and payload.get("deviceId") == device_id \
		and payload.get("sessionId") == session_id \
		and payload.get("runtimeVersion") == "0.1.0-local.27" \
		and (payload.get("activeCharacter", {}) as Dictionary).get("packageId") == "character.sabai-sompoo" \
		and payload.get("companionId") == companion_id \
		and not encoded.contains("\"xp\"") \
		and not encoded.contains("\"level\"") \
		and not encoded.contains("entitlement")
	var empty_character: Dictionary = ServiceScript.build_heartbeat_payload(
		device_id,
		session_id,
		"0.1.0",
		{}
	)
	var empty_payload: Dictionary = empty_character.get("payload", {})
	var nullable_character: bool = bool(empty_character.get("ok", false)) and empty_payload.get("activeCharacter") == null
	var invalid_rejected: bool = not bool(ServiceScript.build_heartbeat_payload("", session_id, "0.1.0", {}).get("ok", true)) \
		and not bool(ServiceScript.build_heartbeat_payload(device_id, "", "0.1.0", {}).get("ok", true)) \
		and not bool(ServiceScript.build_heartbeat_payload(device_id, session_id, "", {}).get("ok", true)) \
		and not bool(ServiceScript.build_heartbeat_payload(device_id, session_id, "0.1.0", {"packageId": "character.bible"}).get("ok", true))
	var projected: Dictionary = ServiceScript.project_heartbeat_response({
		"decision": "accepted",
		"serverTime": "2026-09-10T07:00:00Z",
		"sessionId": session_id,
		"deviceId": device_id,
	})
	var projection_ok: bool = bool(projected.get("ok", false)) \
		and projected.get("sessionId") == session_id \
		and projected.get("deviceId") == device_id
	var refusal_rejected: bool = not bool(ServiceScript.project_heartbeat_response({"decision": "device-revoked"}).get("ok", true))
	var performance_budget: bool = ServiceScript.HEARTBEAT_INTERVAL_SECONDS >= 300.0 \
		and ServiceScript.DEFAULT_TIMEOUT_SECONDS <= 20.0
	var previous_runtime_version := OS.get_environment("OCP_RUNTIME_VERSION")
	OS.set_environment("OCP_RUNTIME_VERSION", "0.1.0-local.28")
	var device_service := DeviceServiceScript.new()
	var launcher_version_preferred: bool = device_service.runtime_version() == "0.1.0-local.28"
	device_service.free()
	OS.set_environment("OCP_RUNTIME_VERSION", previous_runtime_version)
	var ok: bool = strict_facts and nullable_character and invalid_rejected and projection_ok and refusal_rejected \
		and performance_budget and launcher_version_preferred
	print("[S8-RUNTIME-OPS] strict=%s nullable=%s invalid=%s response=%s refusal=%s budget=%s version=%s" % [
		str(strict_facts).to_lower(), str(nullable_character).to_lower(), str(invalid_rejected).to_lower(),
		str(projection_ok).to_lower(), str(refusal_rejected).to_lower(), str(performance_budget).to_lower(),
		str(launcher_version_preferred).to_lower(),
	])
	quit(0 if ok else 1)
