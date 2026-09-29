extends SceneTree

const ServiceScript = preload("res://scripts/runtime_v3/services/progression_queue_service.gd")

class FakeBridge:
	extends Node
	var enqueued_json := ""
	var ack_json := ""
	var stored_user := ""
	var stored_projection := ""
	var cached_projection := {"revision": 4, "companions": []}
	var sample_event := {
		"id": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d18",
		"type": "ocp.companion.created",
		"version": "1.0",
		"source": "runtime",
		"time": "2026-08-26T10:00:00Z",
		"correlationId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d19",
		"contentType": "application/json",
		"data": {"companionId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d20", "characterId": "character.sabai"},
	}

	func progression_queue_enqueue(_path: String, event_json: String) -> Dictionary:
		enqueued_json = event_json
		return {"ok": true, "inserted": true}

	func progression_queue_list(_path: String, _limit: int) -> Dictionary:
		return {"ok": true, "events_json": JSON.stringify([JSON.stringify(sample_event)])}

	func progression_queue_ack(_path: String, event_ids_json: String) -> Dictionary:
		ack_json = event_ids_json
		return {"ok": true, "removed": 1}

	func progression_projection_store(_path: String, user_id: String, projection_json: String) -> Dictionary:
		stored_user = user_id
		stored_projection = projection_json
		return {"ok": true}

	func progression_projection_load(_path: String, _user_id: String) -> Dictionary:
		return {"ok": true, "projection_json": JSON.stringify(cached_projection)}


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
	var bridge := FakeBridge.new()
	var bus := FakeBus.new()
	var context := Node.new()
	for node in [service, bridge, bus, context]:
		holder.add_child(node)
	service.configure(context, bus)
	service.bind_bridge(bridge)
	var enqueue_result: Dictionary = service.enqueue(bridge.sample_event)
	var pending_result: Dictionary = service.pending(10)
	var pending_events: Array = pending_result.get("events", [])
	var ids: Array[String] = [str(bridge.sample_event.get("id"))]
	var ack_result: Dictionary = service.acknowledge(ids)
	var user_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d21"
	var projection := {"revision": 5, "companions": []}
	var cache_result: Dictionary = service.cache_projection(user_id, projection)
	var load_result: Dictionary = service.cached_projection(user_id)

	var enqueue_ok: bool = bool(enqueue_result.get("ok", false)) and bridge.enqueued_json.contains("ocp.companion.created")
	var pending_ok: bool = bool(pending_result.get("ok", false)) and pending_events.size() == 1 \
		and str((pending_events[0] as Dictionary).get("id")) == ids[0]
	var ack_ok: bool = bool(ack_result.get("ok", false)) and bridge.ack_json.contains(ids[0])
	var authority_ok: bool = not bridge.enqueued_json.contains("\"xp\"") and not bridge.enqueued_json.contains("\"level\"")
	var cache_ok: bool = bool(cache_result.get("ok", false)) \
		and bridge.stored_user == user_id \
		and bridge.stored_projection.contains("\"revision\":5")
	var loaded_projection: Dictionary = load_result.get("progression", {})
	var load_ok: bool = bool(load_result.get("ok", false)) \
		and int(loaded_projection.get("revision", -1)) == 4
	var ok: bool = enqueue_ok and pending_ok and ack_ok and authority_ok and cache_ok and load_ok
	print("[G16.3] enqueue=%s pending=%s ack=%s authority=%s cache=%s load=%s" % [
		str(enqueue_ok).to_lower(), str(pending_ok).to_lower(), str(ack_ok).to_lower(), str(authority_ok).to_lower(),
		str(cache_ok).to_lower(), str(load_ok).to_lower(),
	])
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
