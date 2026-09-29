extends SceneTree

const AuthScript = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const DeviceScript = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const DownloadScript = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var auth_projection := AuthScript.project_auth_payload({
		"accessToken": "access-secret",
		"refreshToken": "refresh-secret",
		"expiresIn": 3600,
		"user": {
			"userId": "018f9f25-6a5d-7f31-8d5f-b3904c3b6b10",
			"email": "USER@example.com",
		},
	})
	var auth_ok: bool = bool(auth_projection.get("ok", false)) \
		and str((auth_projection.get("auth", {}) as Dictionary).get("user", {}).get("email", "")) == "user@example.com" \
		and not bool(AuthScript.project_auth_payload({"accessToken": "x"}).get("ok", true)) \
		and AuthScript.is_valid_cloud_api_url("https://api.ocp.example") \
		and not AuthScript.is_valid_cloud_api_url("http://api.ocp.example")

	var device_projection := DeviceScript.project_device_payload({
		"deviceId": "018f9f25-6a5d-7f31-8d5f-b3904c3b6b12",
		"installationId": "018f9f25-6a5d-7f31-8d5f-b3904c3b6b13",
		"platform": "windows",
		"runtimeVersion": "0.1.0",
		"lastSeenAt": "2026-08-26T08:00:00Z",
		"revokedAt": null,
	})
	var device_ok: bool = bool(device_projection.get("ok", false)) \
		and not bool(DeviceScript.project_device_payload({
			"deviceId": "device",
			"installationId": "installation",
			"platform": "linux",
			"runtimeVersion": "0.1.0",
			"lastSeenAt": "2026-08-26T08:00:00Z",
			"revokedAt": null,
		}).get("ok", true))

	var authorization := DownloadScript.project_authorization_payload({
		"packageId": "character.sabai",
		"version": "1.2.0",
		"download": {
			"url": "https://bucket.example/character.ocp?token=short-lived",
			"expiresAt": "2026-08-26T08:02:00Z",
		},
		"integrity": {
			"sha256": "a".repeat(64),
			"signature": "base64:signature",
			"signatureKeyId": "ed25519:ocp-first-party-1",
		},
		"trust": {"domain": "marketplace-release", "bundle": "{}"},
	})
	var malformed_trust := DownloadScript.project_authorization_payload({
		"packageId": "character.sabai",
		"version": "1.2.0",
		"download": {"url": "https://bucket.example/character.ocp", "expiresAt": "2026-08-26T08:02:00Z"},
		"integrity": {"sha256": "a".repeat(64), "signature": "sig", "signatureKeyId": "ed25519:ocp-first-party-1"},
		"trust": {"domain": "local-beta", "bundle": "{}"},
	})
	var download_ok: bool = bool(authorization.get("ok", false)) \
		and DownloadScript.DEFAULT_TIMEOUT_SECONDS == 0.0 \
		and DownloadScript.DOWNLOAD_STALL_TIMEOUT_SECONDS >= 60.0 \
		and DownloadScript.MAX_DOWNLOAD_SECONDS >= 900.0 \
		and DownloadScript.DOWNLOAD_CHUNK_SIZE_BYTES >= 512 * 1024 \
		and not bool(malformed_trust.get("ok", true)) \
		and DownloadScript.is_valid_package_id("character.sabai") \
		and not DownloadScript.is_valid_package_id("../sabai") \
		and DownloadScript.is_valid_version("1.2.0") \
		and not DownloadScript.is_valid_version("1.2") \
		and not bool(DownloadScript.project_authorization_payload({
			"packageId": "character.sabai",
			"version": "1.2.0",
			"download": {"url": "http://unsafe.example/file", "expiresAt": "x"},
			"integrity": {"sha256": "a".repeat(64), "signature": "sig", "signatureKeyId": "ed25519:ocp-first-party-1"},
		}).get("ok", true))

	var ok := auth_ok and device_ok and download_ok
	print("[G16.8] auth=%s device=%s download=%s" % [
		str(auth_ok).to_lower(), str(device_ok).to_lower(), str(download_ok).to_lower(),
	])
	quit(0 if ok else 1)
