extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const CredentialServiceScript = preload("res://scripts/runtime_v3/services/credential_service.gd")


class FakeBridge:
	extends Node
	var values: Dictionary = {}

	func store_provider_credential(provider_id: String, credential: String) -> Dictionary:
		values[provider_id] = credential
		return {"ok": true, "provider_id": provider_id, "present": true}

	func provider_credential_present(provider_id: String) -> bool:
		return values.has(provider_id)

	func delete_provider_credential(provider_id: String) -> Dictionary:
		values.erase(provider_id)
		return {"ok": true, "provider_id": provider_id, "present": false}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var bridge := FakeBridge.new()
	var service := CredentialServiceScript.new()
	for node in [context, bus, bridge, service]:
		holder.add_child(node)
	service.configure(context, bus)
	service.bind_bridge(bridge)

	var secret := "test-secret-never-persist"
	var saved := service.store("openrouter", secret)
	var present_after_save := service.present("openrouter")
	var context_is_clean := not JSON.stringify(context.snapshot()).contains(secret)
	var removed := service.remove("openrouter")
	var absent_after_remove := not service.present("openrouter")
	var invalid_rejected := not bool(service.store("", secret).get("ok", true))
	var ok := bool(saved.get("ok", false)) \
		and present_after_save \
		and context_is_clean \
		and bool(removed.get("ok", false)) \
		and absent_after_remove \
		and invalid_rejected
	print("[AI-CREDENTIALS] save=", saved.get("ok", false), " present=", present_after_save, " context_clean=", context_is_clean, " removed=", absent_after_remove)
	holder.free()
	quit(0 if ok else 1)
