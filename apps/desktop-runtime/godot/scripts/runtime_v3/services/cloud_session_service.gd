extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CloudSessionService

## In-memory authenticated Cloud session boundary.
## Access tokens are never persisted in RuntimeContext/settings or emitted in events.

var _access_token := ""
var _user_id := ""
var _device_id := ""
var _email := ""


func establish(access_token: String, user_id: String, device_id: String = "", email: String = "") -> Dictionary:
	var token := access_token.strip_edges()
	var canonical_user_id := user_id.strip_edges()
	var canonical_device_id := device_id.strip_edges()
	var canonical_email := email.strip_edges().to_lower()
	if token.is_empty() or canonical_user_id.is_empty():
		return {"ok": false, "error": "Access token and user id are required"}
	_access_token = token
	_user_id = canonical_user_id
	_device_id = canonical_device_id
	_email = canonical_email
	_publish_state()
	return {"ok": true, "session": snapshot()}


func set_device_id(device_id: String) -> bool:
	if not is_signed_in():
		return false
	var canonical := device_id.strip_edges()
	if canonical.is_empty():
		return false
	_device_id = canonical
	_publish_state()
	return true


func clear() -> void:
	_access_token = ""
	_user_id = ""
	_device_id = ""
	_email = ""
	_publish_state()


func is_signed_in() -> bool:
	return not _access_token.is_empty() and not _user_id.is_empty()


func access_token() -> String:
	return _access_token


func device_id() -> String:
	return _device_id


func snapshot() -> Dictionary:
	return {
		"signed_in": is_signed_in(),
		"user_id": _user_id,
		"device_id": _device_id,
		"email": _email,
	}


func _publish_state() -> void:
	if not is_instance_valid(event_bus):
		return
	# Deliberately excludes the bearer token.
	event_bus.publish(&"cloud.session.changed", snapshot())
