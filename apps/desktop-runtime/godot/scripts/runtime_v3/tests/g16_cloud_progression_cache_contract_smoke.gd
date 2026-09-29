extends SceneTree

const ServiceScript = preload("res://scripts/runtime_v3/services/cloud_progression_service.gd")


class FakeSession:
	extends Node
	var signed_in := true
	var user := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d31"
	func is_signed_in() -> bool:
		return signed_in
	func snapshot() -> Dictionary:
		return {"signed_in": signed_in, "user_id": user, "device_id": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d32"}


class FakeContext:
	extends Node
	var settings: Dictionary = {"ocp_cloud_api_url": ""}


class FakeQueue:
	extends Node
	var stored_user := ""
	var stored_projection: Dictionary = {}
	func cached_projection(_user_id: String) -> Dictionary:
		return {
			"ok": true,
			"cached": true,
			"progression": {
				"revision": 7,
				"companions": [{
					"companionId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d33",
					"characterId": "character.sabai",
					"relationship": {"level": 2, "xp": 125},
					"skills": [],
				}],
			},
		}
	func cache_projection(user_id: String, progression: Dictionary) -> Dictionary:
		stored_user = user_id
		stored_projection = progression.duplicate(true)
		return {"ok": true}


class FakeBus:
	extends Node
	var published: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary = {}) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var service := ServiceScript.new()
	var session := FakeSession.new()
	var queue := FakeQueue.new()
	var bus := FakeBus.new()
	var context := FakeContext.new()
	for node in [service, session, queue, bus, context]:
		holder.add_child(node)
	service.configure(context, bus)
	service.bind_session(session)
	var before_queue_ok: bool = int(service.canonical_projection().get("revision", -1)) == 0
	service.bind_queue(queue)

	# Production wiring binds the restored session before the queue. bind_queue()
	# must retry the cache bootstrap so EXP/Level is immediately available.
	var load_ok: bool = before_queue_ok and int(service.canonical_projection().get("revision", -1)) == 7
	service._canonical_projection = {"revision": 8, "companions": []}
	service._cache_canonical_projection()
	var store_ok: bool = queue.stored_user == session.user and int(queue.stored_projection.get("revision", -1)) == 8
	service._on_session_changed({"signed_in": false})
	var signout_ok: bool = int(service.canonical_projection().get("revision", -1)) == 0
	var ok: bool = load_ok and store_ok and signout_ok
	print("[G16.6] cache_load=%s cache_store=%s signout_reset=%s" % [
		str(load_ok).to_lower(), str(store_ok).to_lower(), str(signout_ok).to_lower(),
	])
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
