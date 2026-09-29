extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3ProgressionQueueService

## Native SQLite-backed retry queue for hosted C4 progression facts.
## This service never calculates or stores canonical XP/levels.

const DATABASE_PATH := "user://cloud/ocp-local.db"
const MAX_BATCH_SIZE := 100

var bridge: Node


func bind_bridge(target: Node) -> void:
	bridge = target


func enqueue(event: Dictionary) -> Dictionary:
	if not _bridge_has("progression_queue_enqueue"):
		return {"ok": false, "error": "Native progression queue is unavailable"}
	var event_id := str(event.get("id", "")).strip_edges()
	if event_id.is_empty():
		return {"ok": false, "error": "Progression event id is required"}
	var result: Variant = bridge.call(
		"progression_queue_enqueue",
		ProjectSettings.globalize_path(DATABASE_PATH),
		JSON.stringify(event)
	)
	if not (result is Dictionary):
		return {"ok": false, "error": "Native progression queue returned an invalid result"}
	var output := (result as Dictionary).duplicate(true)
	if bool(output.get("ok", false)):
		event_bus.publish(&"progression.queue.changed", {"reason": "enqueue"})
	return output


func pending(limit: int = MAX_BATCH_SIZE) -> Dictionary:
	if not _bridge_has("progression_queue_list"):
		return {"ok": false, "events": [], "error": "Native progression queue is unavailable"}
	var result: Variant = bridge.call(
		"progression_queue_list",
		ProjectSettings.globalize_path(DATABASE_PATH),
		clampi(limit, 1, MAX_BATCH_SIZE)
	)
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		return {"ok": false, "events": [], "error": str((result as Dictionary).get("error", "Queue read failed")) if result is Dictionary else "Queue read failed"}
	var parsed: Variant = JSON.parse_string(str((result as Dictionary).get("events_json", "[]")))
	if not (parsed is Array):
		return {"ok": false, "events": [], "error": "Queue payload is invalid"}
	var events: Array[Dictionary] = []
	for raw_event in parsed:
		if not (raw_event is String):
			return {"ok": false, "events": [], "error": "Queue row is invalid"}
		var event_value: Variant = JSON.parse_string(raw_event)
		if not (event_value is Dictionary):
			return {"ok": false, "events": [], "error": "Queued event is invalid"}
		events.append((event_value as Dictionary).duplicate(true))
	return {"ok": true, "events": events}


func acknowledge(event_ids: Array[String]) -> Dictionary:
	if event_ids.is_empty() or event_ids.size() > MAX_BATCH_SIZE:
		return {"ok": false, "error": "Acknowledgement batch must contain 1 to 100 event ids"}
	if not _bridge_has("progression_queue_ack"):
		return {"ok": false, "error": "Native progression queue is unavailable"}
	var result: Variant = bridge.call(
		"progression_queue_ack",
		ProjectSettings.globalize_path(DATABASE_PATH),
		JSON.stringify(event_ids)
	)
	if not (result is Dictionary):
		return {"ok": false, "error": "Native progression queue returned an invalid result"}
	var output := (result as Dictionary).duplicate(true)
	if bool(output.get("ok", false)):
		event_bus.publish(&"progression.queue.changed", {
			"reason": "ack",
			"removed": int(output.get("removed", 0)),
		})
	return output


func cache_projection(user_id: String, progression: Dictionary) -> Dictionary:
	var clean_user := user_id.strip_edges()
	if clean_user.is_empty():
		return {"ok": false, "error": "Progression cache user id is required"}
	if not _bridge_has("progression_projection_store"):
		return {"ok": false, "error": "Native progression projection cache is unavailable"}
	var projected := progression.duplicate(true)
	if int(projected.get("revision", -1)) < 0 or not (projected.get("companions", null) is Array):
		return {"ok": false, "error": "Progression projection is invalid"}
	var result: Variant = bridge.call(
		"progression_projection_store",
		ProjectSettings.globalize_path(DATABASE_PATH),
		clean_user,
		JSON.stringify(projected)
	)
	if not (result is Dictionary):
		return {"ok": false, "error": "Native progression projection cache returned an invalid result"}
	return (result as Dictionary).duplicate(true)


func cached_projection(user_id: String) -> Dictionary:
	var clean_user := user_id.strip_edges()
	if clean_user.is_empty():
		return {"ok": false, "progression": {}, "error": "Progression cache user id is required"}
	if not _bridge_has("progression_projection_load"):
		return {"ok": false, "progression": {}, "error": "Native progression projection cache is unavailable"}
	var result: Variant = bridge.call(
		"progression_projection_load",
		ProjectSettings.globalize_path(DATABASE_PATH),
		clean_user
	)
	if not (result is Dictionary) or not bool((result as Dictionary).get("ok", false)):
		return {"ok": false, "progression": {}, "error": str((result as Dictionary).get("error", "Projection cache read failed")) if result is Dictionary else "Projection cache read failed"}
	var raw := str((result as Dictionary).get("projection_json", ""))
	if raw.is_empty():
		return {"ok": true, "progression": {}, "cached": false}
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return {"ok": false, "progression": {}, "error": "Cached progression projection is invalid"}
	var progression := (parsed as Dictionary).duplicate(true)
	if int(progression.get("revision", -1)) < 0 or not (progression.get("companions", null) is Array):
		return {"ok": false, "progression": {}, "error": "Cached progression projection shape is invalid"}
	return {"ok": true, "progression": progression, "cached": true}


func _bridge_has(method_name: StringName) -> bool:
	return is_instance_valid(bridge) and bridge.has_method(method_name)
