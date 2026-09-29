extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CredentialService

## Presentation-safe credential facade. Secrets cross GDScript memory only long
## enough to call the native bridge; they are never persisted in context,
## settings.json, events, logs, or .ocp packages.

var bridge: Node


func bind_bridge(target: Node) -> void:
	bridge = target


func store(provider_id: String, credential: String) -> Dictionary:
	var clean_id := provider_id.strip_edges().to_lower()
	if clean_id.is_empty() or credential.strip_edges().is_empty():
		return {"ok": false, "error": "Provider id and credential are required"}
	if not is_instance_valid(bridge) or not bridge.has_method("store_provider_credential"):
		return {"ok": false, "error": "Secure credential bridge unavailable"}
	var result: Variant = bridge.call("store_provider_credential", clean_id, credential)
	if result is Dictionary:
		return (result as Dictionary).duplicate(true)
	return {"ok": false, "error": "Secure credential bridge returned an invalid result"}


func present(provider_id: String) -> bool:
	var clean_id := provider_id.strip_edges().to_lower()
	if clean_id.is_empty() or not is_instance_valid(bridge):
		return false
	if not bridge.has_method("provider_credential_present"):
		return false
	return bool(bridge.call("provider_credential_present", clean_id))


func remove(provider_id: String) -> Dictionary:
	var clean_id := provider_id.strip_edges().to_lower()
	if clean_id.is_empty():
		return {"ok": false, "error": "Provider id is required"}
	if not is_instance_valid(bridge) or not bridge.has_method("delete_provider_credential"):
		return {"ok": false, "error": "Secure credential bridge unavailable"}
	var result: Variant = bridge.call("delete_provider_credential", clean_id)
	if result is Dictionary:
		return (result as Dictionary).duplicate(true)
	return {"ok": false, "error": "Secure credential bridge returned an invalid result"}
