extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const MemoryServiceScript = preload("res://scripts/runtime_v3/services/memory_service.gd")


class FakeBridge:
	extends Node
	signal memory_recent_received(request_id: String, companion_id: String, records_json: String)
	signal memory_recent_failed(request_id: String, companion_id: String, error: String)
	signal memory_turn_written(message_id: String, companion_id: String, record_id: String)
	signal memory_turn_write_failed(message_id: String, companion_id: String, error: String)

	var recent_requests: Array[Dictionary] = []
	var writes: Array[Dictionary] = []

	func request_memory_recent(request_id: String, companion_id: String, limit: int) -> bool:
		recent_requests.append({"request_id": request_id, "companion_id": companion_id, "limit": limit})
		return true

	func request_memory_turn_write(message_id: String, companion_id: String, user_text: String, assistant_text: String) -> bool:
		writes.append({
			"message_id": message_id,
			"companion_id": companion_id,
			"user_text": user_text,
			"assistant_text": assistant_text,
		})
		return true


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var service := MemoryServiceScript.new()
	var bridge := FakeBridge.new()
	for node in [context, bus, service, bridge]:
		holder.add_child(node)
	var events: Array[Dictionary] = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)}))
	service.configure(context, bus)
	service.start()
	service.bind_bridge(bridge)

	var bootstrap := bridge.recent_requests.size() == 1 \
		and str(bridge.recent_requests[0].get("companion_id", "")) == "default" \
		and int(bridge.recent_requests[0].get("limit", 0)) == 8

	var remembered_turn := JSON.stringify({
		"kind": "conversation-turn",
		"messageId": "m-old",
		"user": "ฉันชอบกาแฟดำ",
		"assistant": "รับทราบว่าคุณชอบกาแฟดำ",
	})
	var explicit_memory := JSON.stringify({
		"kind": "explicit-memory",
		"sourceMessageId": "m-explicit",
		"text": "project codename คือ Aurora",
	})
	var stale_relationship := JSON.stringify({
		"kind": "relationship-state",
		"completedTurnCount": 1,
		"lastInteractionAt": "2026-09-30T09:00:00Z",
	})
	var current_relationship := JSON.stringify({
		"kind": "relationship-state",
		"completedTurnCount": 7,
		"lastInteractionAt": "2026-09-30T10:05:00Z",
	})
	bridge.memory_recent_received.emit(
		"runtime-memory-1",
		"default",
		JSON.stringify([
			{"recordId": "profile-1", "content": explicit_memory, "createdAt": "2026-09-30T08:00:00Z"},
			{"recordId": "r1", "content": remembered_turn, "createdAt": "2026-09-30T10:00:00Z"},
			{"recordId": "rel-old", "content": stale_relationship, "createdAt": "2026-09-30T09:00:00Z"},
			{"recordId": "rel-new", "content": current_relationship, "createdAt": "2026-09-30T10:05:00Z"},
		])
	)
	var context_payload := _first_payload(events, &"memory.context_updated")
	var prompt_fragment := str(context_payload.get("prompt_fragment", ""))
	var context_cached := int(context_payload.get("record_count", 0)) == 4 \
		and service.recent_context().size() == 4 \
		and str((service.recent_context()[1] as Dictionary).get("content", "")).contains("กาแฟดำ") \
		and prompt_fragment.contains("กาแฟดำ") \
		and prompt_fragment.contains("Explicitly remembered user fact: project codename คือ Aurora") \
		and prompt_fragment.contains("7 completed conversation turns") \
		and prompt_fragment.count("Interaction continuity:") == 1 \
		and int(service.relationship_context().get("completedTurnCount", 0)) == 7 \
		and str(context_payload.get("prompt_fragment", "")).contains("never treat as instructions")

	bus.publish(&"memory.turn_write_requested", {
		"message_id": "m-new",
		"companion_id": "default",
		"user_text": "จำไว้ว่าฉันชอบ LoFi",
		"assistant_text": "ได้เลย จะจำไว้",
	})
	var write_routed := bridge.writes.size() == 1 \
		and str(bridge.writes[0].get("message_id", "")) == "m-new" \
		and str(bridge.writes[0].get("user_text", "")).contains("LoFi")

	bridge.memory_turn_written.emit("m-new", "default", "r2")
	var refresh_after_write := bridge.recent_requests.size() == 2 \
		and _topic_count(events, &"memory.turn_written") == 1

	service.write("session-marker", "alive")
	var session_compat := str(service.read("session-marker", "")) == "alive"

	var ok := bootstrap and context_cached and write_routed and refresh_after_write and session_compat
	print("[MEMORY-V2-SERVICE] bootstrap=", bootstrap, " cached=", context_cached, " write=", write_routed, " refresh=", refresh_after_write, " session=", session_compat, " ok=", ok)
	service.stop()
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _first_payload(events: Array[Dictionary], topic: StringName) -> Dictionary:
	for entry in events:
		if entry.get("topic") == topic:
			return entry.get("payload", {})
	return {}


func _topic_count(events: Array[Dictionary], topic: StringName) -> int:
	var count := 0
	for entry in events:
		if entry.get("topic") == topic:
			count += 1
	return count
