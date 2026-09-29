extends SceneTree

const AuthScript = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const DeviceScript = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const DownloadScript = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")

class FakeBus:
	extends Node
	var published: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})
	func subscribe(_topic: StringName, _callable: Callable) -> void:
		pass
	func unsubscribe(_topic: StringName, _callable: Callable) -> void:
		pass

class FakeSession:
	extends Node
	var token := ""
	var user := ""
	var device := ""
	func establish(access_token: String, user_id: String, device_id: String = "", _email: String = "") -> Dictionary:
		token = access_token
		user = user_id
		device = device_id
		return {"ok": true}
	func clear() -> void:
		token = ""
		user = ""
		device = ""
	func is_signed_in() -> bool:
		return not token.is_empty() and not user.is_empty()
	func access_token() -> String:
		return token
	func device_id() -> String:
		return device
	func set_device_id(value: String) -> bool:
		device = value
		return not device.is_empty()

class FakeBridge:
	extends Node
	var refresh := ""
	func store_cloud_refresh_token(value: String) -> Dictionary:
		refresh = value
		return {"ok": true}
	func load_cloud_refresh_token() -> Dictionary:
		return {"ok": true, "refresh_token": refresh} if not refresh.is_empty() else {"ok": false}
	func delete_cloud_refresh_token() -> Dictionary:
		refresh = ""
		return {"ok": true}
	func new_uuid_v7() -> String:
		return "018f9f25-6a5d-7f31-8d5f-b3904c3b6b12"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var auth_payload := {
		"accessToken": "access",
		"refreshToken": "refresh",
		"expiresIn": 3600,
		"user": {"userId": "018f9f25-6a5d-7f31-8d5f-b3904c3b6b10", "email": "USER@example.com"},
	}
	var auth_projection: Dictionary = AuthScript.project_auth_payload(auth_payload)
	var auth_ok := bool(auth_projection.get("ok", false)) \
		and str(((auth_projection.get("auth", {}) as Dictionary).get("user", {}) as Dictionary).get("email")) == "user@example.com"
	var auth_strict := not bool(AuthScript.project_auth_payload(auth_payload.merged({"provider": "supabase"}, true)).get("ok", true))

	var device_projection: Dictionary = DeviceScript.project_device_payload({
		"deviceId": "018f9f25-6a5d-7f31-8d5f-b3904c3b6b13",
		"installationId": "018f9f25-6a5d-7f31-8d5f-b3904c3b6b12",
		"platform": "windows",
		"runtimeVersion": "0.1.0",
		"lastSeenAt": "2026-08-26T08:00:00Z",
		"revokedAt": null,
	})
	var device_ok := bool(device_projection.get("ok", false))

	var download_payload := {
		"packageId": "character.meowsom",
		"version": "2.0.0",
		"download": {"url": "https://example.r2.cloudflarestorage.com/package?sig=x", "expiresAt": "2026-08-26T08:02:00Z"},
		"integrity": {"sha256": "a".repeat(64), "signature": "base64:signature", "signatureKeyId": "ed25519:ocp-first-party-1"},
	}
	var download_projection: Dictionary = DownloadScript.project_authorization_payload(download_payload)
	var download_ok := bool(download_projection.get("ok", false))
	# The DTO layer validates signature-key syntax only. Whether a well-formed key
	# is trusted belongs exclusively to the native Rust trust store.
	var unknown_key := download_payload.duplicate(true)
	unknown_key["integrity"] = (download_payload.get("integrity") as Dictionary).duplicate(true)
	(unknown_key["integrity"] as Dictionary)["signatureKeyId"] = "ed25519:demo-1"
	var unknown_key_shape_ok := bool(DownloadScript.project_authorization_payload(unknown_key).get("ok", false))
	var malformed_key := download_payload.duplicate(true)
	malformed_key["integrity"] = (download_payload.get("integrity") as Dictionary).duplicate(true)
	(malformed_key["integrity"] as Dictionary)["signatureKeyId"] = "not-a-signature-key"
	var malformed_key_rejected := not bool(DownloadScript.project_authorization_payload(malformed_key).get("ok", true))
	var path_guard := DownloadScript.is_valid_package_id("character.meowsom") \
		and DownloadScript.is_valid_package_id("effect.creator-acceptance-20260926") \
		and not DownloadScript.is_valid_package_id("../escape") \
		and not DownloadScript.is_valid_package_id("effect.Bad") \
		and not DownloadScript.is_valid_package_id("effect.bad_name") \
		and not DownloadScript.is_valid_package_id("effect..bad") \
		and DownloadScript.is_valid_version("2.0.0") \
		and not DownloadScript.is_valid_version("2.0") \
		and DownloadScript.is_valid_install_grant("A".repeat(43)) \
		and not DownloadScript.is_valid_install_grant("short")

	var ok := auth_ok and auth_strict and device_ok and download_ok and unknown_key_shape_ok \
		and malformed_key_rejected and path_guard
	print("[G17.1] auth=%s strict=%s device=%s download=%s key_shape=%s malformed_key_rejected=%s path=%s" % [
		str(auth_ok).to_lower(), str(auth_strict).to_lower(), str(device_ok).to_lower(),
		str(download_ok).to_lower(), str(unknown_key_shape_ok).to_lower(),
		str(malformed_key_rejected).to_lower(), str(path_guard).to_lower(),
	])
	quit(0 if ok else 1)
