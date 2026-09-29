extends SceneTree

const SessionService = preload("res://scripts/runtime_v3/services/cloud_session_service.gd")
const AuthService = preload("res://scripts/runtime_v3/services/cloud_auth_service.gd")
const DeviceService = preload("res://scripts/runtime_v3/services/cloud_device_service.gd")
const PackageService = preload("res://scripts/runtime_v3/services/package_service.gd")
const OperationsService = preload("res://scripts/runtime_v3/services/cloud_operations_service.gd")

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

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var context := LiveContext.new()
	var bus := LiveBus.new()
	var bridge := OcpRuntimeBridge.new()
	var session := SessionService.new()
	var auth := AuthService.new()
	var device := DeviceService.new()
	var package_service := PackageService.new()
	var operations := OperationsService.new()
	for node in [context, bus, bridge, session, auth, device, package_service, operations]:
		root.add_child(node)

	session.configure(context, bus)
	auth.configure(context, bus)
	device.configure(context, bus)
	package_service.configure(context, bus)
	operations.configure(context, bus)

	auth.bind_session(session)
	auth.bind_bridge(bridge)
	device.bind_session(session)
	device.bind_bridge(bridge)
	operations.bind_session(session)
	operations.bind_device_service(device)
	operations.bind_package_service(package_service)
	operations.bind_bridge(bridge)

	device.start()
	operations.start()
	auth.start()

	var session_ready := false
	for _step in range(500):
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
		print("[S8-LIVE] session=false device=false auth=%s deviceEvents=%s result=SESSION_NOT_READY" % [str(auth_statuses), str(device_statuses)])
		auth.stop(); device.stop(); operations.stop()
		quit(2)
		return

	var active: Dictionary = package_service.get_active_candidate()
	var active_id := str(active.get("packageId", active.get("package_id", "")))
	var active_version := str(active.get("version", ""))
	var send_result: Dictionary = operations.send_heartbeat()
	if not bool(send_result.get("ok", false)):
		print("[S8-LIVE] session=true device=true send=%s result=START_FAILED" % str(send_result.get("status", "failed")))
		auth.stop(); device.stop(); operations.stop()
		quit(3)
		return

	var final_status := ""
	for _step in range(400):
		final_status = str(operations.snapshot().get("status", ""))
		if final_status in ["accepted", "error", "invalid-response"]:
			break
		await create_timer(0.05).timeout

	var snapshot := operations.snapshot()
	var ok := final_status == "accepted"
	print("[S8-LIVE] session=true device=true heartbeat=%s runtime=%s active=%s@%s interval=%s ok=%s" % [
		final_status,
		device.runtime_version(),
		active_id if not active_id.is_empty() else "none",
		active_version if not active_version.is_empty() else "none",
		str(snapshot.get("intervalSeconds", 0)),
		str(ok).to_lower(),
	])

	auth.stop(); device.stop(); operations.stop()
	quit(0 if ok else 4)
