extends SceneTree

const SessionService = preload("res://scripts/runtime_v3/services/cloud_session_service.gd")
const AuthService = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const DeviceService = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const DownloadService = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")

class LiveContext:
	extends Node
	var settings := {"ocp_cloud_api_url": "https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api"}

class LiveBus:
	extends Node
	var events: Array[Dictionary] = []
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
		events.append({"topic": key, "payload": payload.duplicate(true)})
		if subscribers.has(key):
			for callback in (subscribers[key] as Array).duplicate():
				if callback is Callable and (callback as Callable).is_valid():
					(callback as Callable).call(payload.duplicate(true))

class FakePackageService:
	extends Node
	var activated := ""
	func activate(package_id: String, version: String) -> bool:
		activated = "%s@%s" % [package_id, version]
		return true

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var context := LiveContext.new()
	var bus := LiveBus.new()
	var bridge := OcpRuntimeBridge.new()
	var session := SessionService.new()
	var auth := AuthService.new()
	var device := DeviceService.new()
	var download := DownloadService.new()
	var package_service := FakePackageService.new()
	for node in [context, bus, bridge, session, auth, device, download, package_service]:
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
		var auth_statuses: Array[String] = []
		var device_statuses: Array[String] = []
		for event in bus.events:
			var topic := str(event.get("topic", ""))
			var payload := event.get("payload", {}) as Dictionary
			if topic == "cloud.auth.updated": auth_statuses.append(str(payload.get("status", "")))
			if topic == "cloud.device.updated": device_statuses.append(str(payload.get("status", "")))
		print("[S7-LIVE] session=false device=false auth=%s deviceEvents=%s result=SESSION_NOT_READY" % [str(auth_statuses), str(device_statuses)])
		auth.stop(); device.stop(); download.stop()
		quit(2)
		return

	var started: Dictionary = download.download_and_install("character.sabai-sompoo", "1.0.1")
	if not bool(started.get("ok", false)):
		print("[S7-LIVE] session=true device=true start=", str(started.get("status", "failed")), " result=START_FAILED")
		auth.stop(); device.stop(); download.stop()
		quit(3)
		return

	var final_status := ""
	# Corporate networks can legitimately take several minutes to transfer a
	# signed character archive. Keep the live acceptance window aligned with the
	# downloader's progress watchdog/absolute ceiling instead of the old 120 s
	# fixed deadline that masked slow-but-progressing downloads as test failures.
	var live_wait_seconds := DownloadService.MAX_DOWNLOAD_SECONDS + 60.0
	var deadline_msec := Time.get_ticks_msec() + int(live_wait_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline_msec:
		var snapshot := download.public_snapshot()
		var status := str(snapshot.get("status", ""))
		if status in ["installed", "error"]:
			final_status = status
			break
		await create_timer(0.25).timeout

	var final_snapshot := download.public_snapshot()
	var trust := final_snapshot.get("trust", {}) as Dictionary
	var mode := str(trust.get("mode", "none"))
	var sequence := int(trust.get("sequence", 0))
	var publishers := int(trust.get("trustedPublishers", 0))
	var stale := bool(trust.get("revocationStale", true))
	var activated_ok := package_service.activated == "character.sabai-sompoo@1.0.1"
	var ok := final_status == "installed" and mode == "marketplace-release" and sequence >= 1 and publishers >= 1 and not stale and activated_ok
	print("[S7-LIVE] session=true device=true status=%s trust=%s seq=%d publishers=%d stale=%s activated=%s ok=%s" % [
		final_status, mode, sequence, publishers, str(stale).to_lower(), str(activated_ok).to_lower(), str(ok).to_lower()
	])
	auth.stop(); device.stop(); download.stop()
	quit(0 if ok else 4)
