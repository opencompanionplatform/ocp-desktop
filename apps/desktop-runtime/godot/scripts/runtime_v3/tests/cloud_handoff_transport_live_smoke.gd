extends SceneTree

const DownloadService = preload("res://scripts/runtime_v3/services/cloud_download_service.gd")

class FakeContext:
	extends Node
	var settings := {"ocp_cloud_api_url": "https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api"}

class FakeBus:
	extends Node
	var events: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": String(topic), "payload": payload.duplicate(true)})
	func subscribe(_topic: StringName, _callable: Callable) -> void:
		pass
	func unsubscribe(_topic: StringName, _callable: Callable) -> void:
		pass

class FakeDevice:
	extends Node
	func ensure_installation_id() -> String:
		return "018f9f25-6a5d-7f31-8d5f-b3904c3b6b12"
	func runtime_version() -> String:
		return "0.1.0"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var context := FakeContext.new()
	var bus := FakeBus.new()
	var device := FakeDevice.new()
	var service := DownloadService.new()
	get_root().add_child(context)
	get_root().add_child(bus)
	get_root().add_child(device)
	get_root().add_child(service)
	service.configure(context, bus)
	service.bind_device_service(device)
	service.start()
	var started: Dictionary = service.redeem_install_handoff(
		"character.sabai-sompoo",
		"1.0.0",
		"A".repeat(43)
	)
	for _step in range(120):
		var finished := false
		for event in bus.events:
			var payload := event.get("payload", {}) as Dictionary
			if str(payload.get("status", "")) == "handoff-redemption-failed":
				finished = true
				break
		if finished:
			break
		await create_timer(0.1).timeout
	var final_payload := {}
	for event in bus.events:
		var payload := event.get("payload", {}) as Dictionary
		if str(payload.get("status", "")) == "handoff-redemption-failed":
			final_payload = payload
	var response := int(final_payload.get("responseCode", 0))
	var ok := bool(started.get("ok", false)) and response == 403
	print("[CLOUD-HANDOFF-TRANSPORT-LIVE] started=", started, " final=", final_payload, " ok=", ok)
	service.stop()
	quit(0 if ok else 1)
