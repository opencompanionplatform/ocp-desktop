extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3ResourceMonitorService

const SAMPLE_INTERVAL_SEC := 5.0
const HIGH_THRESHOLD_PERCENT := 80.0
const CLEAR_THRESHOLD_PERCENT := 75.0
const ALERT_DEBOUNCE_SEC := 30.0

var bridge: Node
var sample_elapsed := SAMPLE_INTERVAL_SEC
var alert_elapsed := ALERT_DEBOUNCE_SEC
var pressure_state := "normal"
var latest: Dictionary = {
	"available": false,
	"cpu_percent": 0.0,
	"memory_percent": 0.0,
	"system_cpu_percent": 0.0,
	"system_memory_percent": 0.0,
	"ocp_memory_mb": 0.0,
	"runtime_memory_mb": 0.0,
	"desktop_shell_memory_mb": 0.0,
	"kernel_memory_mb": 0.0,
	"native_host_memory_mb": 0.0,
	"ai_memory_mb": 0.0,
	"pressure": "unavailable",
	"message": "Resource telemetry unavailable",
}


func bind_bridge(target: Node) -> void:
	bridge = target


func start() -> void:
	set_process(true)
	_publish_snapshot(latest)


func stop() -> void:
	set_process(false)


func _process(delta: float) -> void:
	sample_elapsed += delta
	alert_elapsed += delta
	if sample_elapsed < SAMPLE_INTERVAL_SEC:
		return
	sample_elapsed = 0.0
	sample_now()


func sample_now() -> Dictionary:
	var snapshot := _read_snapshot()
	latest = snapshot
	_publish_snapshot(snapshot)
	_update_pressure_policy(snapshot)
	return snapshot.duplicate(true)


func _read_snapshot() -> Dictionary:
	if not is_instance_valid(bridge) or not bridge.has_method("resource_usage"):
		return _unavailable_snapshot("Resource telemetry unavailable in this runtime")
	var raw: Variant = bridge.call("resource_usage")
	if not raw is Dictionary or not bool(raw.get("available", false)):
		return _unavailable_snapshot("Resource telemetry unavailable in this runtime")
	var cpu := clampf(float(raw.get("system_cpu_percent", raw.get("cpu_percent", 0.0))), 0.0, 100.0)
	var memory := clampf(float(raw.get("system_memory_percent", raw.get("memory_percent", 0.0))), 0.0, 100.0)
	var pressure := classify_pressure(cpu, memory, pressure_state)
	const BYTES_PER_MIB := 1048576.0
	return {
		"available": true,
		# Legacy aliases remain whole-machine values for older in-Runtime widgets.
		"cpu_percent": cpu,
		"memory_percent": memory,
		"system_cpu_percent": cpu,
		"system_memory_percent": memory,
		"ocp_memory_mb": maxf(0.0, float(raw.get("ocp_memory_bytes", 0)) / BYTES_PER_MIB),
		"runtime_memory_mb": maxf(0.0, float(raw.get("runtime_memory_bytes", 0)) / BYTES_PER_MIB),
		"desktop_shell_memory_mb": maxf(0.0, float(raw.get("desktop_shell_memory_bytes", 0)) / BYTES_PER_MIB),
		"kernel_memory_mb": maxf(0.0, float(raw.get("kernel_memory_bytes", 0)) / BYTES_PER_MIB),
		"native_host_memory_mb": maxf(0.0, float(raw.get("native_host_memory_bytes", 0)) / BYTES_PER_MIB),
		"ai_memory_mb": maxf(0.0, float(raw.get("ai_memory_bytes", 0)) / BYTES_PER_MIB),
		"pressure": pressure,
		"message": "Normal resource usage" if pressure == "normal" else "High system resource usage",
		"sampled_at_ms": int(raw.get("sampled_at_ms", 0)),
	}


func _unavailable_snapshot(message: String) -> Dictionary:
	return {
		"available": false,
		"cpu_percent": 0.0,
		"memory_percent": 0.0,
		"system_cpu_percent": 0.0,
		"system_memory_percent": 0.0,
		"ocp_memory_mb": 0.0,
		"runtime_memory_mb": 0.0,
		"desktop_shell_memory_mb": 0.0,
		"kernel_memory_mb": 0.0,
		"native_host_memory_mb": 0.0,
		"ai_memory_mb": 0.0,
		"pressure": "unavailable",
		"message": message,
	}


static func classify_pressure(cpu: float, memory: float, previous: String = "normal") -> String:
	var peak := maxf(cpu, memory)
	if peak >= HIGH_THRESHOLD_PERCENT:
		return "high"
	if previous == "high" and peak > CLEAR_THRESHOLD_PERCENT:
		return "high"
	return "normal"


func _publish_snapshot(snapshot: Dictionary) -> void:
	context.update_runtime_config({"resource_monitor": snapshot.duplicate(true)})
	event_bus.publish(&"resource_monitor.updated", snapshot.duplicate(true))


func _update_pressure_policy(snapshot: Dictionary) -> void:
	var next_state := str(snapshot.get("pressure", "unavailable"))
	if next_state == "unavailable":
		pressure_state = "normal"
		alert_elapsed = ALERT_DEBOUNCE_SEC
		return
	if next_state == "high" and pressure_state != "high":
		pressure_state = "high"
		alert_elapsed = 0.0
		return
	if next_state == "high" and alert_elapsed >= ALERT_DEBOUNCE_SEC:
		event_bus.publish(&"resource_monitor.alert", snapshot.duplicate(true))
		alert_elapsed = 0.0
	elif next_state == "normal":
		pressure_state = "normal"
