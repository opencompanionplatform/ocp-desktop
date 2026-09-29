extends RefCounted

const MachineScript = preload("res://scripts/runtime_v3/core/runtime_state_machine.gd")

func run() -> bool:
	var machine = MachineScript.new()
	return machine.transition(&"ready") \
		and machine.transition(&"dragging") \
		and not machine.transition(&"quick_panel") \
		and machine.transition(&"ready")
