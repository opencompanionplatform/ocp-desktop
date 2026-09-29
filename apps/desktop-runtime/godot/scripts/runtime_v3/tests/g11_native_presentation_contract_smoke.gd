extends Node

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const CoordinatorScript = preload("res://scripts/runtime_v3/services/native_presentation_coordinator.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[G11] native presentation contract smoke begin")
	var context = ContextScript.new()
	var bus = BusScript.new()
	var coordinator = CoordinatorScript.new()
	add_child(context)
	add_child(bus)
	add_child(coordinator)
	coordinator.configure(context, bus)
	coordinator.start()

	var disabled_rejected: bool = not coordinator.request("default", "g11-host-token")
	var overlay_default: bool = coordinator.state_name() == "fallback" \
		and context.runtime_config.get("presentation_owner", "") == "overlay"

	context.update_runtime_config({"native_presentation_enabled": true})
	var requested: bool = coordinator.request("default", "g11-host-token")
	var ready: bool = coordinator.accept_ready("default", "g11-host-token")
	var resized: bool = coordinator.accept_resized(256, 256) \
		and context.runtime_config.get("native_presentation_client_size", Vector2i.ZERO) == Vector2i(256, 256)
	var attached: bool = coordinator.accept_attached("default")
	var detached: bool = coordinator.accept_detached("default")
	var invalid_rejected: bool = not coordinator.accept_attached("wrong-companion") \
		and coordinator.state_name() == "fallback" \
		and context.runtime_config.get("presentation_owner", "") == "overlay"

	var passed: bool = disabled_rejected and overlay_default and requested and ready and resized \
		and attached and detached and invalid_rejected
	if passed:
		print("[G11] native presentation contract smoke passed")
	else:
		push_error("[G11] native presentation contract smoke failed")
	coordinator.stop()
	get_tree().quit(0 if passed else 1)
