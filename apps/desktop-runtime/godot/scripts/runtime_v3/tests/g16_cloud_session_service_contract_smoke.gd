extends SceneTree

const ServiceScript = preload("res://scripts/runtime_v3/services/cloud_session_service.gd")

class FakeBus:
	extends Node
	var published: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var service := ServiceScript.new()
	var context := Node.new()
	var bus := FakeBus.new()
	for node in [service, context, bus]:
		holder.add_child(node)
	service.configure(context, bus)
	var result: Dictionary = service.establish("secret-access-token", "user-1", "", "User@Example.com")
	var snapshot: Dictionary = service.snapshot()
	var no_token_leak: bool = not snapshot.has("access_token") and not JSON.stringify(bus.published).contains("secret-access-token")
	var session_ok: bool = bool(result.get("ok", false)) and bool(snapshot.get("signed_in", false)) \
		and snapshot.get("user_id") == "user-1" and snapshot.get("email") == "user@example.com"
	var device_ok: bool = service.set_device_id("device-1") and service.snapshot().get("device_id") == "device-1"
	service.clear()
	var cleared_ok: bool = not service.is_signed_in() and service.access_token().is_empty()
	var ok: bool = no_token_leak and session_ok and device_ok and cleared_ok
	print("[G16.4] session=%s device=%s no_token_leak=%s cleared=%s" % [
		str(session_ok).to_lower(), str(device_ok).to_lower(), str(no_token_leak).to_lower(), str(cleared_ok).to_lower(),
	])
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
