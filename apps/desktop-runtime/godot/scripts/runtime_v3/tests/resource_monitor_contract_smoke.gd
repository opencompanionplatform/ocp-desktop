extends SceneTree

const ServiceScript = preload(
	"res://scripts/runtime_v3/services/resource_monitor_service.gd"
)


class FakeBridge:
	extends Node

	func resource_usage() -> Dictionary:
		return {
			"available": true,
			"system_cpu_percent": 21.0,
			"system_memory_percent": 44.0,
			"ocp_memory_bytes": 673710080,
			"runtime_memory_bytes": 297795584,
			"desktop_shell_memory_bytes": 341835776,
			"kernel_memory_bytes": 18874368,
			"native_host_memory_bytes": 15204352,
			"ai_memory_bytes": 5054136320,
			"sampled_at_ms": 1234,
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var normal := ServiceScript.classify_pressure(21.0, 44.0)
	var high_cpu := ServiceScript.classify_pressure(81.0, 44.0)
	var high_memory := ServiceScript.classify_pressure(21.0, 82.0)
	var hysteresis := ServiceScript.classify_pressure(77.0, 42.0, "high")
	var cleared := ServiceScript.classify_pressure(74.0, 42.0, "high")

	var service = ServiceScript.new()
	var bridge = FakeBridge.new()
	root.add_child(service)
	service.set_process(false)
	root.add_child(bridge)
	service.bridge = bridge
	var snapshot: Dictionary = service._read_snapshot()
	var breakdown_ok := is_equal_approx(float(snapshot.get("system_memory_percent", 0.0)), 44.0) \
		and is_equal_approx(float(snapshot.get("ocp_memory_mb", 0.0)), 642.5) \
		and is_equal_approx(float(snapshot.get("runtime_memory_mb", 0.0)), 284.0) \
		and is_equal_approx(float(snapshot.get("desktop_shell_memory_mb", 0.0)), 326.0) \
		and is_equal_approx(float(snapshot.get("kernel_memory_mb", 0.0)), 18.0) \
		and is_equal_approx(float(snapshot.get("native_host_memory_mb", 0.0)), 14.5) \
		and is_equal_approx(float(snapshot.get("ai_memory_mb", 0.0)), 4820.0)

	var ok := normal == "normal" \
		and high_cpu == "high" \
		and high_memory == "high" \
		and hysteresis == "high" \
		and cleared == "normal" \
		and breakdown_ok
	print(
		"[P3.1] normal=", normal,
		" high_cpu=", high_cpu,
		" high_memory=", high_memory,
		" hysteresis=", hysteresis,
		" cleared=", cleared,
		" breakdown=", breakdown_ok
	)
	print("[P3.1] resource monitor contract %s" % ("passed" if ok else "failed"))
	quit(0 if ok else 1)
