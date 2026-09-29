extends Node

const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const TracerScript = preload("res://scripts/runtime_v3/core/runtime_event_tracer.gd")

func run() -> bool:
	var bus = BusScript.new()
	var tracer = TracerScript.new()
	add_child(bus)
	add_child(tracer)
	tracer.configure(bus)
	tracer.set_enabled(true)
	bus.publish(&"trace.test", {"ok": true})
	return tracer.snapshot().size() == 1
