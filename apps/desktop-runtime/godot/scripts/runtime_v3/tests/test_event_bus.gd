extends SceneTree

const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")

func _initialize() -> void:
	var bus = BusScript.new()
	var received: Array = []
	var callback := func(payload: Dictionary): received.append(payload.get("value"))
	bus.subscribe(&"test", callback)
	bus.publish(&"test", {"value": 42})
	if received != [42]:
		push_error("Runtime V3 Event Bus test failed")
		quit(1)
		return
	print("[PASS] Runtime V3 Event Bus")
	quit(0)
