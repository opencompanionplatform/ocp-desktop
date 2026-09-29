extends SceneTree

const DeepLinkScript = preload("res://scripts/runtime_v3/services/cloud_deep_link_service.gd")

class FakeBus:
	extends Node
	var events: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := DeepLinkScript.parse_uri("ocp://store/character.sabai?version=1.2.0")
	var request := valid.get("request", {}) as Dictionary
	var parse_ok: bool = bool(valid.get("ok", false)) \
		and request.get("packageId") == "character.sabai" \
		and request.get("version") == "1.2.0"
	var rejects := not bool(DeepLinkScript.parse_uri("https://store.example/character.sabai?version=1.2.0").get("ok", true)) \
		and not bool(DeepLinkScript.parse_uri("ocp://store/../sabai?version=1.2.0").get("ok", true)) \
		and not bool(DeepLinkScript.parse_uri("ocp://store/character.sabai?version=1.2.0&admin=true").get("ok", true)) \
		and not bool(DeepLinkScript.parse_uri("ocp://store/character.sabai?version=1.2").get("ok", true)) \
		and not bool(DeepLinkScript.parse_uri("ocp://store/character.sabai?version=1.2.0#fragment").get("ok", true))
	var arg_ok := DeepLinkScript.first_uri_argument(PackedStringArray(["--flag", "ocp://store/character.sabai?version=1.2.0"])) \
		== "ocp://store/character.sabai?version=1.2.0"

	var holder := Node.new()
	get_root().add_child(holder)
	var service := DeepLinkScript.new()
	var context := Node.new()
	var bus := FakeBus.new()
	for node in [service, context, bus]:
		holder.add_child(node)
	service.configure(context, bus)
	var dispatched := service.handle_uri("ocp://store/character.sabai?version=1.2.0")
	var dispatch_ok: bool = bool(dispatched.get("ok", false)) \
		and bus.events.size() == 2 \
		and bus.events[0].get("topic") == &"character_picker.open_requested" \
		and bus.events[1].get("topic") == &"cloud.store.character_requested"
	var ok: bool = parse_ok and rejects and arg_ok and dispatch_ok
	print("[G16.9] parse=%s rejects=%s args=%s dispatch=%s" % [
		str(parse_ok).to_lower(), str(rejects).to_lower(), str(arg_ok).to_lower(), str(dispatch_ok).to_lower(),
	])
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
