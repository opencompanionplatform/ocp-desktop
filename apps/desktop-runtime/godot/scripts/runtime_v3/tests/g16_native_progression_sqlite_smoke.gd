extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var bridge := ClassDB.instantiate("OcpRuntimeBridge") as Node
	if not is_instance_valid(bridge):
		push_error("[G16.7] OcpRuntimeBridge unavailable")
		quit(1)
		return
	get_root().add_child(bridge)
	var methods_ok := bridge.has_method("progression_queue_enqueue") \
		and bridge.has_method("progression_queue_list") \
		and bridge.has_method("progression_queue_ack") \
		and bridge.has_method("progression_projection_store") \
		and bridge.has_method("progression_projection_load")
	if not methods_ok:
		push_error("[G16.7] native C4 methods missing")
		quit(1)
		return

	var database := ProjectSettings.globalize_path("user://cloud/c4-native-smoke.db")
	var event_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d41"
	var event := {
		"id": event_id,
		"type": "ocp.companion.created",
		"version": "1.0",
		"source": "runtime",
		"time": "2026-08-26T10:00:00Z",
		"correlationId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d42",
		"contentType": "application/json",
		"data": {
			"companionId": "018f0c64-66d8-7a2a-9f16-5fb5a2db3d43",
			"characterId": "character.sabai",
		},
	}
	var enqueue: Dictionary = bridge.call("progression_queue_enqueue", database, JSON.stringify(event))
	var pending: Dictionary = bridge.call("progression_queue_list", database, 100)
	var pending_raw: Variant = JSON.parse_string(str(pending.get("events_json", "[]")))
	var queue_ok := bool(enqueue.get("ok", false)) and bool(pending.get("ok", false)) \
		and pending_raw is Array and (pending_raw as Array).size() >= 1

	var user_id := "018f0c64-66d8-7a2a-9f16-5fb5a2db3d44"
	var projection := {"revision": 9, "companions": []}
	var store: Dictionary = bridge.call("progression_projection_store", database, user_id, JSON.stringify(projection))
	var load: Dictionary = bridge.call("progression_projection_load", database, user_id)
	var loaded: Variant = JSON.parse_string(str(load.get("projection_json", "")))
	var cache_ok := bool(store.get("ok", false)) and bool(load.get("ok", false)) \
		and loaded is Dictionary and int((loaded as Dictionary).get("revision", -1)) == 9

	var ack: Dictionary = bridge.call("progression_queue_ack", database, JSON.stringify([event_id]))
	var ack_ok := bool(ack.get("ok", false)) and int(ack.get("removed", 0)) >= 1
	var ok := methods_ok and queue_ok and cache_ok and ack_ok
	print("[G16.7] methods=%s queue=%s cache=%s ack=%s" % [
		str(methods_ok).to_lower(), str(queue_ok).to_lower(), str(cache_ok).to_lower(), str(ack_ok).to_lower(),
	])
	bridge.queue_free()
	await process_frame
	quit(0 if ok else 1)
