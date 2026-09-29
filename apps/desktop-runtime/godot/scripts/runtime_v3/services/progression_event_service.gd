extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3ProgressionEventService

## Converts local Runtime facts into retryable progression events. This service
## never calculates XP, level, unlocks, or entitlements; Cloud remains the
## sole progression authority.

const COMPANION_MAP_PATH := "user://cloud/companion-ids.json"
const EVENT_VERSION := "1.0"
const EVENT_SOURCE := "desktop-runtime"

const LOCAL_COOLDOWN_SECONDS := {
	"ocp.chat.completed": 60.0,
	"ocp.companion.interaction": 30.0,
	"ocp.animation.played": 15.0,
}

var _session: Node
var _queue: Node
var _progression: Node
var _bridge: Node
var _companion_ids: Dictionary = {}
var _creation_enqueued: Dictionary = {}
var _daily_attempted: Dictionary = {}
var _last_fact_ms: Dictionary = {}


func bind_session(target: Node) -> void:
	_session = target
	call_deferred("_attempt_daily_active")


func bind_queue(target: Node) -> void:
	_queue = target


func bind_progression(target: Node) -> void:
	_progression = target


func bind_bridge(target: Node) -> void:
	_bridge = target


func start() -> void:
	_load_companion_ids()
	event_bus.subscribe(&"system.ready", Callable(self, "_on_runtime_ready"))
	event_bus.subscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
	event_bus.subscribe(&"cloud.device.updated", Callable(self, "_on_device_updated"))
	event_bus.subscribe(&"character.changed", Callable(self, "_on_character_available"))
	event_bus.subscribe(&"character.loaded", Callable(self, "_on_character_available"))
	event_bus.subscribe(&"chat.assistant_message_received", Callable(self, "_on_chat_completed"))
	event_bus.subscribe(&"character.drag_finished", Callable(self, "_on_companion_interaction"))
	event_bus.subscribe(&"animation.finished", Callable(self, "_on_animation_finished"))


func stop() -> void:
	event_bus.unsubscribe(&"system.ready", Callable(self, "_on_runtime_ready"))
	event_bus.unsubscribe(&"cloud.session.changed", Callable(self, "_on_session_changed"))
	event_bus.unsubscribe(&"cloud.device.updated", Callable(self, "_on_device_updated"))
	event_bus.unsubscribe(&"character.changed", Callable(self, "_on_character_available"))
	event_bus.unsubscribe(&"character.loaded", Callable(self, "_on_character_available"))
	event_bus.unsubscribe(&"chat.assistant_message_received", Callable(self, "_on_chat_completed"))
	event_bus.unsubscribe(&"character.drag_finished", Callable(self, "_on_companion_interaction"))
	event_bus.unsubscribe(&"animation.finished", Callable(self, "_on_animation_finished"))


func _on_runtime_ready(_payload: Dictionary) -> void:
	call_deferred("_attempt_daily_active")


func _on_session_changed(payload: Dictionary) -> void:
	if not bool(payload.get("signed_in", false)):
		_creation_enqueued.clear()
		_daily_attempted.clear()
		_last_fact_ms.clear()
		return
	call_deferred("_attempt_daily_active")


func _on_device_updated(payload: Dictionary) -> void:
	if str(payload.get("status", "")) == "registered":
		call_deferred("_attempt_daily_active")


func _on_character_available(_payload: Dictionary) -> void:
	call_deferred("_attempt_daily_active")


func _on_chat_completed(_payload: Dictionary) -> void:
	_enqueue_reward_fact("ocp.chat.completed", {})


func _on_companion_interaction(_payload: Dictionary) -> void:
	_enqueue_reward_fact("ocp.companion.interaction", {"kind": "drag"})


func _on_animation_finished(payload: Dictionary) -> void:
	var animation_name := str(payload.get("name", "")).strip_edges()
	if animation_name.is_empty() or animation_name in ["idle", "appear", "disappear"]:
		return
	_enqueue_reward_fact("ocp.animation.played", {"animation": animation_name.substr(0, 80)})


func _attempt_daily_active() -> void:
	var identity := _active_identity()
	if identity.is_empty() or not _ready_for_facts():
		return
	var companion_id := _ensure_companion(str(identity.get("characterId", "")))
	if companion_id.is_empty() or _daily_attempted.has(companion_id):
		return
	_daily_attempted[companion_id] = true
	_enqueue_fact(
		"ocp.session.daily-active",
		companion_id,
		str(identity.get("characterId", "")),
		{"runtime": _runtime_version()}
	)


func _enqueue_reward_fact(event_type: String, data: Dictionary) -> void:
	if not _ready_for_facts() or not _cooldown_allows(event_type):
		return
	var identity := _active_identity()
	if identity.is_empty():
		return
	var character_id := str(identity.get("characterId", ""))
	var companion_id := _ensure_companion(character_id)
	if companion_id.is_empty():
		return
	if _enqueue_fact(event_type, companion_id, character_id, data):
		_last_fact_ms[event_type] = Time.get_ticks_msec()


func _ensure_companion(character_id: String) -> String:
	var cloud_id := _canonical_companion_id(character_id)
	if not cloud_id.is_empty():
		_remember_companion(character_id, cloud_id)
		return cloud_id

	var user_id := _user_id()
	if user_id.is_empty():
		return ""
	var user_map: Dictionary = _companion_ids.get(user_id, {})
	var companion_id := str(user_map.get(character_id, "")).strip_edges().to_lower()
	if companion_id.is_empty():
		companion_id = _new_uuid()
		if companion_id.is_empty():
			return ""
		_remember_companion(character_id, companion_id)

	if not _creation_enqueued.has(companion_id):
		var queued := _enqueue_fact(
			"ocp.companion.created",
			companion_id,
			character_id,
			{"name": _active_character_name()}
		)
		if queued:
			_creation_enqueued[companion_id] = true
	return companion_id


func _enqueue_fact(event_type: String, companion_id: String, character_id: String, extra_data: Dictionary) -> bool:
	if not is_instance_valid(_queue) or not _queue.has_method("enqueue"):
		return false
	var event_id := _new_uuid()
	var correlation_id := _new_uuid()
	if event_id.is_empty() or correlation_id.is_empty():
		return false

	var data := {
		"companionId": companion_id,
		"characterId": character_id,
	}
	for key in extra_data.keys():
		data[key] = extra_data[key]

	var event := {
		"id": event_id,
		"type": event_type,
		"version": EVENT_VERSION,
		"source": EVENT_SOURCE,
		"time": _utc_now(),
		"correlationId": correlation_id,
		"contentType": "application/json",
		"data": data,
	}
	var result: Variant = _queue.call("enqueue", event)
	var ok := result is Dictionary and bool((result as Dictionary).get("ok", false))
	if ok:
		event_bus.publish(&"progression.fact_queued", {
			"type": event_type,
			"companionId": companion_id,
			"characterId": character_id,
		})
	return ok


func _ready_for_facts() -> bool:
	if not is_instance_valid(_session) or not _session.has_method("is_signed_in") or not bool(_session.call("is_signed_in")):
		return false
	if not _session.has_method("device_id") or str(_session.call("device_id")).strip_edges().is_empty():
		return false
	return is_instance_valid(_queue) and is_instance_valid(_bridge) and _bridge.has_method("new_uuid_v7")


func _cooldown_allows(event_type: String) -> bool:
	var cooldown := float(LOCAL_COOLDOWN_SECONDS.get(event_type, 0.0))
	if cooldown <= 0.0 or not _last_fact_ms.has(event_type):
		return true
	var elapsed_ms := Time.get_ticks_msec() - int(_last_fact_ms[event_type])
	return elapsed_ms >= int(cooldown * 1000.0)


func _active_identity() -> Dictionary:
	if not is_instance_valid(context):
		return {}
	var character_id := str(context.package.get("active_id", "")).strip_edges()
	var version := str(context.package.get("active_version", "")).strip_edges()
	if character_id.is_empty() or not character_id.contains("."):
		return {}
	return {"characterId": character_id, "version": version}


func _active_character_name() -> String:
	if not is_instance_valid(context):
		return "Companion"
	var value := str(context.character.get("name", "")).strip_edges()
	return value.substr(0, 160) if not value.is_empty() else "Companion"


func _canonical_companion_id(character_id: String) -> String:
	if not is_instance_valid(_progression) or not _progression.has_method("canonical_projection"):
		return ""
	var raw: Variant = _progression.call("canonical_projection")
	if not (raw is Dictionary):
		return ""
	var companions: Variant = (raw as Dictionary).get("companions", [])
	if not (companions is Array):
		return ""
	for raw_companion in companions:
		if not (raw_companion is Dictionary):
			continue
		var companion := raw_companion as Dictionary
		if str(companion.get("characterId", "")) == character_id:
			return str(companion.get("companionId", "")).strip_edges().to_lower()
	return ""


func _user_id() -> String:
	if not is_instance_valid(_session) or not _session.has_method("snapshot"):
		return ""
	var snapshot: Variant = _session.call("snapshot")
	if not (snapshot is Dictionary):
		return ""
	return str((snapshot as Dictionary).get("user_id", "")).strip_edges().to_lower()


func _runtime_version() -> String:
	var value := OS.get_environment("OCP_RUNTIME_VERSION").strip_edges()
	if not value.is_empty():
		return value.substr(0, 96)
	return str(ProjectSettings.get_setting("application/config/version", "0.1.0")).substr(0, 96)


func _new_uuid() -> String:
	if not is_instance_valid(_bridge) or not _bridge.has_method("new_uuid_v7"):
		return ""
	return str(_bridge.call("new_uuid_v7")).strip_edges().to_lower()


func _utc_now() -> String:
	return Time.get_datetime_string_from_system(true, true)


func _remember_companion(character_id: String, companion_id: String) -> void:
	var user_id := _user_id()
	if user_id.is_empty():
		return
	var user_map: Dictionary = _companion_ids.get(user_id, {})
	if str(user_map.get(character_id, "")) == companion_id:
		return
	user_map[character_id] = companion_id
	_companion_ids[user_id] = user_map
	_save_companion_ids()


func _load_companion_ids() -> void:
	if not FileAccess.file_exists(COMPANION_MAP_PATH):
		return
	var file := FileAccess.open(COMPANION_MAP_PATH, FileAccess.READ)
	if not is_instance_valid(file):
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_companion_ids = (parsed as Dictionary).duplicate(true)


func _save_companion_ids() -> void:
	var absolute := ProjectSettings.globalize_path(COMPANION_MAP_PATH)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var temporary := absolute + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if not is_instance_valid(file):
		return
	file.store_string(JSON.stringify(_companion_ids))
	file.close()
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)
	DirAccess.rename_absolute(temporary, absolute)
