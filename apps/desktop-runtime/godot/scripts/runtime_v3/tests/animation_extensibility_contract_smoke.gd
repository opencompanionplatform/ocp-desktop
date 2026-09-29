extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const SdkScript = preload("res://scripts/runtime_v3/sdk/runtime_sdk.gd")
const LocalBehaviorCatalogScript = preload("res://scripts/runtime_v3/core/local_behavior_catalog.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var sdk := SdkScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(sdk)

	context.update_package({
		"entry": {
			"animationRoles": {
				"hang.left": "sword_fly_left",
				"hang.right": "sword_fly_right",
				"drag.hold": "drag_hold",
			},
			"actions": {
				"charge_power": {
					"animation": "charge_power",
					"priority": "presentation",
					"interruptible": false,
					"cooldownMs": 2500,
				},
			},
		},
	})
	sdk.configure(context, bus, null)

	var received: Array[Dictionary] = []
	bus.subscribe(&"animation.requested", func(payload: Dictionary) -> void:
		received.append(payload.duplicate(true))
	)

	var action_ok := sdk.play_action(&"charge_power")
	var cooldown_rejected := not sdk.play_action(&"charge_power")
	var missing_rejected := not sdk.play_action(&"missing_action")
	var payload_ok := received.size() == 1 \
		and str(received[0].get("name", "")) == "charge_power" \
		and str(received[0].get("source", "")) == "character-action" \
		and str(received[0].get("action", "")) == "charge_power" \
		and str(received[0].get("priority", "")) == "presentation" \
		and not bool(received[0].get("interruptible", true))

	var character_controller_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/character_controller.gd"
	)
	var animation_controller_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/animation_controller.gd"
	)
	var role_resolver_ok := character_controller_source.contains("animationRoles") \
		and character_controller_source.contains("hang.left") \
		and character_controller_source.contains("hang.right") \
		and character_controller_source.contains("drag.hold") \
		and character_controller_source.contains("drag.release")
	var action_arbitration_ok := animation_controller_source.contains("presentation_interruptible") \
		and animation_controller_source.contains("presentation_priority") \
		and animation_controller_source.contains("canonical Physics always remains authoritative")
	var optional_catalog_ok := LocalBehaviorCatalogScript.owner_for("hang_left") == "physics-directional-optional" \
		and LocalBehaviorCatalogScript.owner_for("drag_hold") == "interaction-optional" \
		and LocalBehaviorCatalogScript.owner_for("idle") == "ambient"

	var ok := action_ok and cooldown_rejected and missing_rejected and payload_ok and role_resolver_ok and action_arbitration_ok and optional_catalog_ok
	print("[AnimationExtensibility] action=", action_ok,
		" cooldown_rejected=", cooldown_rejected,
		" missing_rejected=", missing_rejected,
		" payload=", payload_ok,
		" roles=", role_resolver_ok,
		" arbitration=", action_arbitration_ok,
		" optional_catalog=", optional_catalog_ok,
		" result=", ok)

	holder.free()
	await process_frame
	quit(0 if ok else 1)
