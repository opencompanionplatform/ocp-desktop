extends RefCounted

const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")

func run() -> bool:
	var bus = BusScript.new()
	var received: Array = []
	var callback := func(payload: Dictionary): received.append(payload.get("value"))
	bus.subscribe(&"test", callback)
	bus.publish(&"test", {"value": 42})
	return received == [42]
