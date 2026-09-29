extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudDownloadService

const CloudHttpTransportScript = preload("res://scripts/runtime_v3/services/cloud_http_transport.gd")

## Hosted-library download/install pipeline.
## Authorization is always server-side; R2 bytes are accepted only after the
## native marketplace trust boundary validates SHA-256 and Ed25519 metadata.

const CloudAuthScript = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const PackageReaderScript = preload("res://scripts/runtime/packages/ocp_package_reader.gd")
const DOWNLOAD_DIR := "user://downloads/cloud"
# Signed character packages can be tens or hundreds of MB. HTTPRequest.timeout
# is a whole-request deadline, so a fixed 3–4 minute limit incorrectly aborts
# slow-but-progressing transfers on corporate networks. Disable the absolute
# HTTPRequest deadline and enforce an inactivity watchdog instead.
const DEFAULT_TIMEOUT_SECONDS := 0.0
const DOWNLOAD_STALL_TIMEOUT_SECONDS := 90.0
const MAX_DOWNLOAD_SECONDS := 1800.0
const DOWNLOAD_WATCHDOG_INTERVAL_SECONDS := 2.0
const DOWNLOAD_PROGRESS_LOG_INTERVAL_SECONDS := 30.0
# Godot defaults HTTPRequest.download_chunk_size to 64 KiB. On high-latency
# corporate paths that turns large signed package downloads into thousands of
# tiny read/write cycles. Use a 1 MiB transfer chunk for package payloads; the
# archive is streamed directly to disk, so this does not retain the full body
# in memory.
const DOWNLOAD_CHUNK_SIZE_BYTES := 1024 * 1024

var _session: Node
var _device_service: Node
var _bridge: Node
var _package_service: Node
var _effect_pack_service: Node
var _authorize_request: HTTPRequest
var _download_request: HTTPRequest
var _download_watchdog: Timer
var _download_started_msec := 0
var _last_progress_msec := 0
var _last_progress_log_msec := 0
var _last_downloaded_bytes := 0
var _state := "idle"
var _pending := {}
var _public_status := {
	"status": "idle",
	"packageId": "",
	"version": "",
	"trust": {"mode": "none", "sequence": 0, "trustedPublishers": 0, "revocationStale": false},
}


func bind_session(target: Node) -> void:
	_session = target


func bind_device_service(target: Node) -> void:
	_device_service = target


func bind_bridge(target: Node) -> void:
	_bridge = target


func bind_package_service(target: Node) -> void:
	_package_service = target


func bind_effect_pack_service(target: Node) -> void:
	_effect_pack_service = target


func start() -> void:
	_authorize_request = HTTPRequest.new()
	CloudHttpTransportScript.configure_https_proxy(_authorize_request)
	_authorize_request.name = "CloudDownloadAuthorizeRequest"
	_authorize_request.timeout = 20.0
	add_child(_authorize_request)
	_authorize_request.request_completed.connect(_on_authorize_completed)
	_download_request = HTTPRequest.new()
	# Large package transfers must not depend on the Runtime main-loop cadence.
	# Threaded HTTPRequest also avoids severe throughput collapse observed on
	# direct signed R2 downloads while preserving the same TLS/proxy policy.
	_download_request.use_threads = true
	_download_request.download_chunk_size = DOWNLOAD_CHUNK_SIZE_BYTES
	CloudHttpTransportScript.configure_https_proxy(_download_request)
	_download_request.name = "CloudPackageDownloadRequest"
	_download_request.timeout = DEFAULT_TIMEOUT_SECONDS
	var proxy_config := CloudHttpTransportScript.environment_https_proxy()
	if not proxy_config.is_empty():
		print("[CloudDownload] corporate-proxy detected; progress watchdog enabled")
	add_child(_download_request)
	_download_request.request_completed.connect(_on_download_completed)
	_download_watchdog = Timer.new()
	_download_watchdog.name = "CloudPackageDownloadWatchdog"
	_download_watchdog.wait_time = DOWNLOAD_WATCHDOG_INTERVAL_SECONDS
	_download_watchdog.one_shot = false
	add_child(_download_watchdog)
	_download_watchdog.timeout.connect(_on_download_watchdog_timeout)
	_download_watchdog.start()
	if is_instance_valid(event_bus):
		event_bus.subscribe(&"cloud.device.updated", Callable(self, "_on_device_updated"))
		event_bus.subscribe(&"cloud.download.desktop_transfer_started", Callable(self, "_on_desktop_transfer_started"))
		event_bus.subscribe(&"cloud.download.desktop_transfer_completed", Callable(self, "_on_desktop_transfer_completed"))


func stop() -> void:
	if is_instance_valid(event_bus):
		event_bus.unsubscribe(&"cloud.device.updated", Callable(self, "_on_device_updated"))
		event_bus.unsubscribe(&"cloud.download.desktop_transfer_started", Callable(self, "_on_desktop_transfer_started"))
		event_bus.unsubscribe(&"cloud.download.desktop_transfer_completed", Callable(self, "_on_desktop_transfer_completed"))
	if is_instance_valid(_authorize_request) and _authorize_request.request_completed.is_connected(_on_authorize_completed):
		_authorize_request.request_completed.disconnect(_on_authorize_completed)
	if is_instance_valid(_download_request) and _download_request.request_completed.is_connected(_on_download_completed):
		_download_request.request_completed.disconnect(_on_download_completed)
	if is_instance_valid(_download_watchdog):
		_download_watchdog.stop()
		if _download_watchdog.timeout.is_connected(_on_download_watchdog_timeout):
			_download_watchdog.timeout.disconnect(_on_download_watchdog_timeout)
	_reset_download_watchdog()
	_state = "idle"
	_pending.clear()
	_public_status = {
		"status": "idle",
		"packageId": "",
		"version": "",
		"trust": {"mode": "none", "sequence": 0, "trustedPublishers": 0, "revocationStale": false},
	}


func public_snapshot() -> Dictionary:
	return _public_status.duplicate(true)


func download_and_install(package_id: String, version: String) -> Dictionary:
	if _state != "idle":
		return {"ok": false, "status": "busy"}
	var clean_id := package_id.strip_edges()
	var clean_version := version.strip_edges()
	if not is_valid_package_id(clean_id) or not is_valid_version(clean_version):
		return {"ok": false, "status": "invalid-package"}
	if not is_instance_valid(_session) or not _session.has_method("is_signed_in") or not bool(_session.call("is_signed_in")):
		return {"ok": false, "status": "sign-in-required"}
	var device_id := str(_session.call("device_id")) if _session.has_method("device_id") else ""
	if device_id.is_empty():
		if not is_instance_valid(_device_service) or not _device_service.has_method("ensure_registered"):
			return {"ok": false, "status": "device-registration-required"}
		var registration: Variant = _device_service.call("ensure_registered")
		var registration_status := str((registration as Dictionary).get("status", "device-registration-required")) if registration is Dictionary else "device-registration-required"
		if registration_status == "registered":
			device_id = str(_session.call("device_id")) if _session.has_method("device_id") else ""
		elif registration_status in ["loading", "busy"]:
			_state = "waiting-device"
			_pending = {"packageId": clean_id, "version": clean_version, "mode": "session"}
			_publish("device-registering", {"packageId": clean_id, "version": clean_version})
			return {"ok": true, "status": "device-registering"}
		else:
			return {"ok": false, "status": registration_status}
		if device_id.is_empty():
			return {"ok": false, "status": "device-registration-required"}
	var base_url := _cloud_api_base_url()
	if not CloudAuthScript.is_valid_cloud_api_url(base_url):
		return {"ok": false, "status": "not-configured"}
	if not is_instance_valid(_authorize_request):
		return {"ok": false, "status": "unavailable"}
	_state = "authorizing"
	_pending = {"packageId": clean_id, "version": clean_version, "mode": "session"}
	_publish("authorizing")
	var error := _authorize_request.request(
		base_url.rstrip("/") + "/v1/downloads/authorize",
		PackedStringArray([
			"Accept: application/json",
			"Content-Type: application/json",
			"Authorization: Bearer %s" % str(_session.call("access_token")),
		]),
		HTTPClient.METHOD_POST,
		JSON.stringify({
			"packageId": clean_id,
			"version": clean_version,
			"deviceId": device_id,
		})
	)
	if error != OK:
		_fail("authorization-request-failed")
		return {"ok": false, "status": "request-failed"}
	return {"ok": true, "status": "authorizing"}


func _on_device_updated(payload: Dictionary) -> void:
	if _state != "waiting-device":
		return
	var status := str(payload.get("status", ""))
	if status == "registered":
		var package_id := str(_pending.get("packageId", ""))
		var version := str(_pending.get("version", ""))
		_state = "idle"
		_pending.clear()
		var retry: Dictionary = download_and_install(package_id, version)
		if not bool(retry.get("ok", false)):
			_pending = {"packageId": package_id, "version": version, "mode": "session"}
			_fail(str(retry.get("status", "device-registration-failed")))
	elif status == "error":
		_fail("device-registration-failed")


func redeem_install_handoff(package_id: String, version: String, grant: String) -> Dictionary:
	if _state != "idle":
		return {"ok": false, "status": "busy"}
	var clean_id := package_id.strip_edges()
	var clean_version := version.strip_edges()
	var clean_grant := grant.strip_edges()
	if not is_valid_package_id(clean_id) or not is_valid_version(clean_version) or not is_valid_install_grant(clean_grant):
		return {"ok": false, "status": "invalid-handoff"}
	# Store deep links are intentionally idempotent. A browser can lose access to
	# the localhost Runtime-state endpoint after navigation/reload (for example
	# Chromium Local Network Access permission), so the same owned package may be
	# opened again even though this Desktop already has the exact version. Never
	# redeem another grant or reinstall in that case; just activate an installed
	# character and let the Character Manager open normally.
	if is_instance_valid(_package_service) \
	and _package_service.has_method("is_installed_exact") \
	and bool(_package_service.call("is_installed_exact", clean_id, clean_version)):
		if _package_service.has_method("activate") and bool(_package_service.call("activate", clean_id, clean_version)):
			return {"ok": true, "status": "already-installed"}
	if is_instance_valid(_effect_pack_service) \
	and _effect_pack_service.has_method("is_installed_exact") \
	and bool(_effect_pack_service.call("is_installed_exact", clean_id, clean_version)):
		return {"ok": true, "status": "already-installed"}
	if not is_instance_valid(_device_service) or not _device_service.has_method("ensure_installation_id"):
		return {"ok": false, "status": "device-identity-unavailable"}
	var installation_id := str(_device_service.call("ensure_installation_id")).strip_edges().to_lower()
	if installation_id.is_empty():
		return {"ok": false, "status": "device-identity-unavailable"}
	var runtime_version := str(_device_service.call("runtime_version")) if _device_service.has_method("runtime_version") else "0.1.0"
	var base_url := _cloud_api_base_url()
	if not CloudAuthScript.is_valid_cloud_api_url(base_url):
		return {"ok": false, "status": "not-configured"}
	if not is_instance_valid(_authorize_request):
		return {"ok": false, "status": "unavailable"}
	_state = "authorizing"
	_pending = {"packageId": clean_id, "version": clean_version, "mode": "handoff"}
	_publish("handoff-redeeming", {"packageId": clean_id, "version": clean_version})
	var error := _authorize_request.request(
		base_url.rstrip("/") + "/v1/downloads/redeem",
		PackedStringArray(["Accept: application/json", "Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		JSON.stringify({
			"grant": clean_grant,
			"packageId": clean_id,
			"version": clean_version,
			"installationId": installation_id,
			"platform": "windows",
			"runtimeVersion": runtime_version,
		})
	)
	if error != OK:
		_fail("handoff-request-failed")
		return {"ok": false, "status": "request-failed"}
	return {"ok": true, "status": "handoff-redeeming"}


func _on_authorize_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if _state != "authorizing":
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300:
		var mode := str(_pending.get("mode", "session"))
		if mode == "session" and response_code in [401, 403] and is_instance_valid(_session) and _session.has_method("clear"):
			_session.call("clear")
		_fail("handoff-redemption-failed" if mode == "handoff" else "authorization-failed", {"responseCode": response_code, "requestResult": result})
		return
	var projected := project_authorization_payload(JSON.parse_string(body.get_string_from_utf8()))
	if not bool(projected.get("ok", false)):
		_fail("invalid-authorization-response")
		return
	var authorization := projected.get("authorization", {}) as Dictionary
	if str(authorization.get("packageId", "")) != str(_pending.get("packageId", "")) \
	or str(authorization.get("version", "")) != str(_pending.get("version", "")):
		_fail("authorization-mismatch")
		return
	_pending.merge(authorization, true)
	# Store handoff redemption can create/update the server-side device by
	# installationId. If this desktop session is authenticated but still lacks
	# its canonical deviceId, reconcile it immediately so later Library installs
	# do not fail with device-registration-required.
	if str(_pending.get("mode", "session")) == "handoff" \
	and is_instance_valid(_session) and _session.has_method("is_signed_in") and bool(_session.call("is_signed_in")) \
	and (not _session.has_method("device_id") or str(_session.call("device_id")).strip_edges().is_empty()) \
	and is_instance_valid(_device_service) and _device_service.has_method("ensure_registered"):
		_device_service.call_deferred("ensure_registered")
	var target := _download_path(str(_pending.get("packageId")), str(_pending.get("version")))
	if target.is_empty():
		_fail("download-path-invalid")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DOWNLOAD_DIR))
	var integrity := _pending.get("integrity", {}) as Dictionary
	var expected_sha := str(integrity.get("sha256", "")).to_lower()
	if FileAccess.file_exists(target):
		var cached_sha := FileAccess.get_sha256(target).to_lower()
		if not expected_sha.is_empty() and cached_sha == expected_sha:
			print("[CloudDownload] cache-hit package=%s version=%s sha256=matched" % [
				str(_pending.get("packageId", "-")),
				str(_pending.get("version", "-")),
			])
			_state = "downloading"
			_publish("downloading", {"packageId": _pending.get("packageId"), "version": _pending.get("version")})
			_install_downloaded_package(target)
			return
		print("[CloudDownload] cache-discard package=%s version=%s reason=sha256-mismatch" % [
			str(_pending.get("packageId", "-")),
			str(_pending.get("version", "-")),
		])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
	var download_url := str((_pending.get("download", {}) as Dictionary).get("url", ""))
	if _try_start_desktop_transfer(download_url, target):
		return
	_start_godot_download(download_url, target)


func _try_start_desktop_transfer(download_url: String, target: String) -> bool:
	if not is_instance_valid(event_bus) or download_url.is_empty() or target.is_empty():
		return false
	var random_bytes := Crypto.new().generate_random_bytes(16)
	if random_bytes.size() != 16:
		return false
	var request_id := random_bytes.hex_encode()
	_pending["desktopTransferRequestId"] = request_id
	_pending["desktopTransferUrl"] = download_url
	_pending["desktopTransferFallbackTarget"] = target
	_state = "desktop-requesting"
	event_bus.publish(&"cloud.download.desktop_transfer_requested", {
		"requestId": request_id,
		"url": download_url,
	})
	# EventBus dispatch is synchronous. If Desktop Shell accepted the request its
	# adapter publishes desktop_transfer_started before publish() returns.
	if _state == "desktop-downloading":
		return true
	_pending.erase("desktopTransferRequestId")
	_pending.erase("desktopTransferUrl")
	_pending.erase("desktopTransferFallbackTarget")
	_state = "authorizing"
	return false


func _on_desktop_transfer_started(payload: Dictionary) -> void:
	if _state != "desktop-requesting":
		return
	var request_id := str(payload.get("requestId", ""))
	if request_id != str(_pending.get("desktopTransferRequestId", "")):
		return
	_state = "desktop-downloading"
	_publish("downloading", {
		"packageId": _pending.get("packageId"),
		"version": _pending.get("version"),
		"transport": "desktop-chromium",
	})
	print("[CloudDownload] transport=desktop-chromium package=%s version=%s" % [
		str(_pending.get("packageId", "-")), str(_pending.get("version", "-")),
	])


func _on_desktop_transfer_completed(payload: Dictionary) -> void:
	if _state != "desktop-downloading":
		return
	var request_id := str(payload.get("requestId", ""))
	if request_id != str(_pending.get("desktopTransferRequestId", "")):
		return
	var status := str(payload.get("status", ""))
	var downloaded_path := str(payload.get("path", ""))
	if status == "succeeded" and not downloaded_path.is_empty() and FileAccess.file_exists(downloaded_path):
		print("[CloudDownload] desktop-transfer-completed package=%s version=%s bytes=%d" % [
			str(_pending.get("packageId", "-")),
			str(_pending.get("version", "-")),
			maxi(0, int(payload.get("bytes", 0))),
		])
		_install_downloaded_package(downloaded_path)
		return
	var fallback_url := str(_pending.get("desktopTransferUrl", ""))
	var fallback_target := str(_pending.get("desktopTransferFallbackTarget", ""))
	print("[CloudDownload] desktop-transfer-failed; falling back to Godot HTTP")
	_pending.erase("desktopTransferRequestId")
	_pending.erase("desktopTransferUrl")
	_pending.erase("desktopTransferFallbackTarget")
	_start_godot_download(fallback_url, fallback_target)


func _start_godot_download(download_url: String, target: String) -> void:
	if not is_instance_valid(_download_request) or download_url.is_empty() or target.is_empty():
		_fail("download-request-failed")
		return
	_download_request.download_file = target
	_begin_download_watchdog()
	_state = "downloading"
	_publish("downloading", {
		"packageId": _pending.get("packageId"),
		"version": _pending.get("version"),
		"transport": "godot-http",
	})
	var error := _download_request.request(download_url, PackedStringArray(["Accept: application/octet-stream"]), HTTPClient.METHOD_GET)
	if error != OK:
		_download_request.download_file = ""
		_fail("download-request-failed")


func _begin_download_watchdog() -> void:
	var now := Time.get_ticks_msec()
	_download_started_msec = now
	_last_progress_msec = now
	_last_progress_log_msec = now
	_last_downloaded_bytes = 0


func _reset_download_watchdog() -> void:
	_download_started_msec = 0
	_last_progress_msec = 0
	_last_progress_log_msec = 0
	_last_downloaded_bytes = 0


func _on_download_watchdog_timeout() -> void:
	if _state != "downloading" or not is_instance_valid(_download_request):
		return
	var now := Time.get_ticks_msec()
	var downloaded_bytes := maxi(0, int(_download_request.get_downloaded_bytes()))
	var progressed := downloaded_bytes > _last_downloaded_bytes
	if progressed:
		_last_downloaded_bytes = downloaded_bytes
		_last_progress_msec = now
	var stalled_seconds := float(now - _last_progress_msec) / 1000.0 if _last_progress_msec > 0 else 0.0
	var total_seconds := float(now - _download_started_msec) / 1000.0 if _download_started_msec > 0 else 0.0
	if _last_progress_log_msec <= 0 or float(now - _last_progress_log_msec) / 1000.0 >= DOWNLOAD_PROGRESS_LOG_INTERVAL_SECONDS:
		_last_progress_log_msec = now
		print("[CloudDownloadProgress] package=%s version=%s bytes=%d stalled_s=%d elapsed_s=%d" % [
			str(_pending.get("packageId", "-")),
			str(_pending.get("version", "-")),
			downloaded_bytes,
			int(stalled_seconds),
			int(total_seconds),
		])
	if progressed:
		return
	if stalled_seconds < DOWNLOAD_STALL_TIMEOUT_SECONDS and total_seconds < MAX_DOWNLOAD_SECONDS:
		return
	var downloaded_path := _download_request.download_file
	_download_request.cancel_request()
	_download_request.download_file = ""
	if not downloaded_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(downloaded_path))
	var status := "download-stalled" if stalled_seconds >= DOWNLOAD_STALL_TIMEOUT_SECONDS else "download-timeout"
	_fail(status, {
		"downloadedBytes": downloaded_bytes,
		"stalledSeconds": int(stalled_seconds),
		"elapsedSeconds": int(total_seconds),
	})


func _on_download_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	_body: PackedByteArray
) -> void:
	if _state != "downloading":
		return
	var downloaded_path := _download_request.download_file
	_download_request.download_file = ""
	_reset_download_watchdog()
	if result != HTTPRequest.RESULT_SUCCESS or response_code < 200 or response_code >= 300 \
	or downloaded_path.is_empty() or not FileAccess.file_exists(downloaded_path):
		var failure_status := "download-timeout" if result == HTTPRequest.RESULT_TIMEOUT else "download-failed"
		_fail(failure_status, {"responseCode": response_code, "requestResult": result})
		return
	_install_downloaded_package(downloaded_path)


func _install_downloaded_package(downloaded_path: String) -> void:
	if downloaded_path.is_empty() or not FileAccess.file_exists(downloaded_path):
		_fail("download-file-missing")
		return
	if not is_instance_valid(_bridge) or not _bridge.has_method("install_cloud_package"):
		_fail("native-trust-unavailable")
		return

	# Read only the manifest type to choose the fixed local repository. This
	# projection is not trusted for authorization; native install_cloud_package
	# re-verifies the signed archive, detached metadata and Marketplace trust.
	var package_type := "character"
	var untrusted_reader = PackageReaderScript.new()
	var untrusted_read = untrusted_reader.read(downloaded_path)
	if untrusted_read != null and bool(untrusted_read.get("ok")):
		package_type = str(untrusted_read.manifest.get("type", "character"))
		untrusted_read.close()
	if package_type not in ["character", "effect-pack"]:
		_fail("unsupported-package-type")
		return
	var repository_root := "user://packages/effects" if package_type == "effect-pack" else "user://packages/characters"

	var integrity := _pending.get("integrity", {}) as Dictionary
	var trust_bundle := ""
	if _pending.get("trust") is Dictionary:
		trust_bundle = str((_pending.get("trust") as Dictionary).get("bundle", ""))
	var install_result: Variant = _bridge.call(
		"install_cloud_package",
		ProjectSettings.globalize_path(downloaded_path),
		ProjectSettings.globalize_path(repository_root),
		str(integrity.get("sha256", "")),
		str(integrity.get("signatureKeyId", "")),
		str(integrity.get("signature", "")),
		trust_bundle
	)
	if not (install_result is Dictionary) or not bool((install_result as Dictionary).get("ok", false)):
		_fail("package-verification-failed", {
			"error": str((install_result as Dictionary).get("error", "Package verification failed")) if install_result is Dictionary else "Package verification failed",
		})
		return
	var package_id := str((install_result as Dictionary).get("package_id", ""))
	var version := str((install_result as Dictionary).get("version", ""))
	var trusted_type := str((install_result as Dictionary).get("package_type", ""))
	if package_id != str(_pending.get("packageId", "")) or version != str(_pending.get("version", "")) or trusted_type != package_type:
		_fail("installed-package-mismatch")
		return

	if trusted_type == "character":
		if not is_instance_valid(_package_service) or not _package_service.has_method("activate") \
		or not bool(_package_service.call("activate", package_id, version)):
			_fail("installed-activation-failed")
			return
	elif trusted_type == "effect-pack":
		if not is_instance_valid(_effect_pack_service):
			_fail("effect-pack-service-unavailable")
			return
		# Effect packs install into the available list but do not silently replace
		# a user's current three-slot loadout. The Character UI owns equip choice.
		if is_instance_valid(event_bus):
			event_bus.publish(&"effect_pack.installed", {
				"ok": true,
				"packageId": package_id,
				"version": version,
				"source": "cloud-library",
			})

	if is_instance_valid(event_bus):
		event_bus.publish(&"package.installed", {
			"ok": true,
			"packageId": package_id,
			"version": version,
			"packageType": trusted_type,
			"path": ProjectSettings.globalize_path(downloaded_path),
			"source": "cloud-library",
		})
	_publish("installed", {
		"packageId": package_id,
		"version": version,
		"packageType": trusted_type,
		"alreadyInstalled": bool(install_result.get("already_installed", false)),
		"revocationStale": bool(install_result.get("revocation_stale", false)),
		"trustMode": str(install_result.get("trust_mode", "")),
		"trustSequence": maxi(0, int(install_result.get("trust_sequence", 0))),
		"trustedPublishers": maxi(0, int(install_result.get("trusted_publishers", 0))),
	})
	if bool(install_result.get("revocation_stale", false)) and is_instance_valid(event_bus):
		event_bus.publish(&"notification.requested", {"text": "Package verified; the signed revocation list is stale. Refresh the Local Beta trust bundle."})
	_state = "idle"
	_pending.clear()


func _fail(status: String, extra: Dictionary = {}) -> void:
	var failure := extra.duplicate(true)
	var detail := str(failure.get("error", "")).strip_edges()
	if not detail.is_empty():
		print("[CloudDownloadError] status=%s detail=%s" % [status, detail])
	if not failure.has("packageId") and _pending.has("packageId"):
		failure["packageId"] = _pending.get("packageId")
	if not failure.has("version") and _pending.has("version"):
		failure["version"] = _pending.get("version")
	_reset_download_watchdog()
	_state = "idle"
	_pending.clear()
	_publish(status, failure)


func _publish(status: String, extra: Dictionary = {}) -> void:
	var payload := {"status": status}
	payload.merge(extra, true)
	var projected_status := "error"
	if status in ["authorizing", "handoff-redeeming", "device-registering"]:
		projected_status = "authorizing"
	elif status == "downloading":
		projected_status = "downloading"
	elif status == "installed":
		projected_status = "installed"
	elif status == "idle":
		projected_status = "idle"
	var trust := {"mode": "none", "sequence": 0, "trustedPublishers": 0, "revocationStale": false}
	if status == "installed":
		var trust_mode := str(payload.get("trustMode", ""))
		if trust_mode in ["local-beta", "marketplace-release", "marketplace-staging"]:
			trust = {
				"mode": trust_mode,
				"sequence": maxi(0, int(payload.get("trustSequence", 0))),
				"trustedPublishers": maxi(0, int(payload.get("trustedPublishers", 0))),
				"revocationStale": bool(payload.get("revocationStale", false)),
			}
	_public_status = {
		"status": projected_status,
		"packageId": str(payload.get("packageId", "")),
		"version": str(payload.get("version", "")),
		"trust": trust,
	}
	# Keep the Store -> Desktop handoff observable without ever logging the
	# one-time grant, bearer tokens, signatures, or signed R2 URLs.
	print("[CloudDownload] status=%s package=%s version=%s response=%s result=%s" % [
		status,
		str(payload.get("packageId", "-")),
		str(payload.get("version", "-")),
		str(payload.get("responseCode", "-")),
		str(payload.get("requestResult", "-")),
	])
	if not is_instance_valid(event_bus):
		return
	event_bus.publish(&"cloud.download.updated", payload)


func _cloud_api_base_url() -> String:
	if not is_instance_valid(context):
		return ""
	return str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()


func _download_path(package_id: String, version: String) -> String:
	if not is_valid_package_id(package_id) or not is_valid_version(version):
		return ""
	return "%s/%s-%s.ocp" % [DOWNLOAD_DIR, package_id.replace(".", "_"), version]


static func is_valid_package_id(value: String) -> bool:
	# Match the Marketplace package-id contract: lowercase ASCII alphanumeric
	# segments separated by '.' or '-'. A single digit is not a valid GDScript
	# identifier, so String.is_valid_identifier() must not be used here.
	if value.length() < 3 or value.length() > 128:
		return false
	var has_separator := false
	var previous_separator := false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var alphanumeric := (code >= 48 and code <= 57) or (code >= 97 and code <= 122)
		var separator := code in [45, 46]
		if not alphanumeric and not separator:
			return false
		if separator:
			if index == 0 or index == value.length() - 1 or previous_separator:
				return false
			has_separator = true
		previous_separator = separator
	return has_separator


static func is_valid_version(value: String) -> bool:
	var parts := value.split(".")
	if parts.size() != 3:
		return false
	for part in parts:
		if part.is_empty() or not part.is_valid_int() or int(part) < 0:
			return false
	return true


static func is_valid_install_grant(value: String) -> bool:
	var grant := value.strip_edges()
	if grant.length() < 43 or grant.length() > 128:
		return false
	for index in range(grant.length()):
		var code := grant.unicode_at(index)
		var valid := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 95]
		if not valid:
			return false
	return true


static func project_authorization_payload(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return {"ok": false}
	var row := payload as Dictionary
	if row.size() not in [4, 5] or not row.has("packageId") or not row.has("version") \
	or not row.has("download") or not row.has("integrity"):
		return {"ok": false}
	if row.size() == 5 and not row.has("trust"):
		return {"ok": false}
	if not is_valid_package_id(str(row.get("packageId", ""))) or not is_valid_version(str(row.get("version", ""))):
		return {"ok": false}
	if not (row.get("download") is Dictionary) or not (row.get("integrity") is Dictionary):
		return {"ok": false}
	var download := row.get("download") as Dictionary
	var integrity := row.get("integrity") as Dictionary
	if download.size() != 2 or not download.has("url") or not download.has("expiresAt") \
	or integrity.size() != 3 or not integrity.has("sha256") or not integrity.has("signature") or not integrity.has("signatureKeyId"):
		return {"ok": false}
	var url := str(download.get("url", ""))
	var sha := str(integrity.get("sha256", "")).to_lower()
	var key_id := str(integrity.get("signatureKeyId", ""))
	var signature := str(integrity.get("signature", ""))
	if not url.begins_with("https://") or sha.length() != 64 or not sha.is_valid_hex_number(false) \
	or not is_valid_signature_key_id(key_id) or signature.is_empty():
		return {"ok": false}
	if row.has("trust"):
		if not (row.get("trust") is Dictionary):
			return {"ok": false}
		var trust := row.get("trust") as Dictionary
		var trust_domain := str(trust.get("domain", ""))
		if trust.size() != 2 or trust_domain not in ["marketplace-release", "marketplace-staging"]:
			return {"ok": false}
		var bundle := str(trust.get("bundle", "")).strip_edges()
		if bundle.length() < 2 or bundle.length() > 524288 or not bundle.begins_with("{") or not bundle.ends_with("}"):
			return {"ok": false}
	return {"ok": true, "authorization": row.duplicate(true)}


static func is_valid_signature_key_id(value: String) -> bool:
	var key_id := value.strip_edges()
	if not key_id.begins_with("ed25519:"):
		return false
	var suffix := key_id.trim_prefix("ed25519:")
	if suffix.is_empty() or suffix.length() > 240:
		return false
	for index in range(suffix.length()):
		var code := suffix.unicode_at(index)
		var valid := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) or code in [45, 46, 95]
		if not valid:
			return false
	return true
