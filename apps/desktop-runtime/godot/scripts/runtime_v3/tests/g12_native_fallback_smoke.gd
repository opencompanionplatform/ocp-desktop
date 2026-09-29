extends Node

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const CoordinatorScript = preload("res://scripts/runtime_v3/services/native_presentation_coordinator.gd")
const ModeAuthorityScript = preload("res://scripts/runtime_v3/services/runtime_mode_authority.gd")


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[G12.2] native companion fallback smoke begin")
	var authority = ModeAuthorityScript.new()
	var context = ContextScript.new()
	var bus = BusScript.new()
	var coordinator = CoordinatorScript.new()
	add_child(context)
	add_child(bus)
	add_child(coordinator)
	coordinator.configure(context, bus)
	coordinator.start()

	var requested_mode: bool = authority.resolve_requested_mode({"startInOverlay": true}) == &"native-companion"
	var overlay_required: bool = authority.resolve_start_overlay({"startInOverlay": true})
	var safe_default: bool = context.runtime_config.get("presentation_owner", "") == "overlay"
	var rejected_without_host: bool = not coordinator.request("default", "g12-host-token") \
		and coordinator.state_name() == "fallback" \
		and context.runtime_config.get("presentation_owner", "") == "overlay"

	var passed: bool = requested_mode and overlay_required and safe_default and rejected_without_host
	if passed:
		print("[G12.2] native companion fallback smoke passed")
	else:
		push_error("[G12.2] native companion fallback smoke failed")
	coordinator.stop()
	get_tree().quit(0 if passed else 1)
