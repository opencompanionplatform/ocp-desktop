extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3ResourceMonitorService

const SAMPLE_INTERVAL_SEC := 5.0
const PERFORMANCE_SAMPLE_INTERVAL_SEC := 0.5
const FRAME_SAMPLE_CAPACITY := 600
const PRESENTATION_SAMPLE_CAPACITY := 240
const LONG_FRAME_THRESHOLD_MS := 25.0
const HIGH_THRESHOLD_PERCENT := 80.0
const CLEAR_THRESHOLD_PERCENT := 75.0
const ALERT_DEBOUNCE_SEC := 30.0

var bridge: Node
var sample_elapsed := SAMPLE_INTERVAL_SEC
var alert_elapsed := ALERT_DEBOUNCE_SEC
var pressure_state := "normal"
var performance_elapsed := 0.0
var frame_samples_ms := PackedFloat64Array()
var frame_sample_cursor := 0
var frame_sample_count := 0
var latest_frame_ms := 0.0
var presentation_intervals_ms := PackedFloat64Array()
var presentation_sample_cursor := 0
var presentation_sample_count := 0
var last_presentation_tick_us := 0
var latest_animation_load: Dictionary = {}
var latest_animation_prefetch: Dictionary = {}
var latest_animation_first_frame: Dictionary = {}
var latest_drag_release: Dictionary = {}
var latest_voice_latency: Dictionary = {}
var latest_drag_edge_prediction: Dictionary = {}
var latest_anchor_continuity: Dictionary = {}
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
	frame_samples_ms.resize(FRAME_SAMPLE_CAPACITY)
	presentation_intervals_ms.resize(PRESENTATION_SAMPLE_CAPACITY)
	event_bus.subscribe(&"character.animation_load_measured", Callable(self, "_on_animation_load_measured"))
	event_bus.subscribe(&"character.animation_prefetched", Callable(self, "_on_animation_prefetched"))
	event_bus.subscribe(&"animation.first_frame_measured", Callable(self, "_on_animation_first_frame_measured"))
	event_bus.subscribe(&"character.drag_release_resolved", Callable(self, "_on_drag_release_resolved"))
	event_bus.subscribe(&"tts.latency_measured", Callable(self, "_on_voice_latency_measured"))
	event_bus.subscribe(&"character.drag_edge_predicted", Callable(self, "_on_drag_edge_predicted"))
	event_bus.subscribe(&"character.anchor_continuity_measured", Callable(self, "_on_anchor_continuity_measured"))
	event_bus.subscribe(&"character.presentation_applied", Callable(self, "_on_presentation_applied"))
	set_process(true)
	_publish_snapshot(latest)
	_publish_performance_snapshot()


func stop() -> void:
	event_bus.unsubscribe(&"character.animation_load_measured", Callable(self, "_on_animation_load_measured"))
	event_bus.unsubscribe(&"character.animation_prefetched", Callable(self, "_on_animation_prefetched"))
	event_bus.unsubscribe(&"animation.first_frame_measured", Callable(self, "_on_animation_first_frame_measured"))
	event_bus.unsubscribe(&"character.drag_release_resolved", Callable(self, "_on_drag_release_resolved"))
	event_bus.unsubscribe(&"tts.latency_measured", Callable(self, "_on_voice_latency_measured"))
	event_bus.unsubscribe(&"character.drag_edge_predicted", Callable(self, "_on_drag_edge_predicted"))
	event_bus.unsubscribe(&"character.anchor_continuity_measured", Callable(self, "_on_anchor_continuity_measured"))
	event_bus.unsubscribe(&"character.presentation_applied", Callable(self, "_on_presentation_applied"))
	set_process(false)


func _process(delta: float) -> void:
	_record_frame(delta)
	performance_elapsed += delta
	sample_elapsed += delta
	alert_elapsed += delta
	if performance_elapsed >= PERFORMANCE_SAMPLE_INTERVAL_SEC:
		performance_elapsed = 0.0
		_publish_performance_snapshot()
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


func _record_frame(delta: float) -> void:
	if delta <= 0.0:
		return
	if frame_samples_ms.size() != FRAME_SAMPLE_CAPACITY:
		frame_samples_ms.resize(FRAME_SAMPLE_CAPACITY)
	latest_frame_ms = delta * 1000.0
	frame_samples_ms[frame_sample_cursor] = latest_frame_ms
	frame_sample_cursor = (frame_sample_cursor + 1) % FRAME_SAMPLE_CAPACITY
	frame_sample_count = mini(frame_sample_count + 1, FRAME_SAMPLE_CAPACITY)


func _record_presentation_tick(now_us: int) -> void:
	if now_us <= 0:
		return
	if last_presentation_tick_us <= 0:
		last_presentation_tick_us = now_us
		return
	var interval_ms := float(now_us - last_presentation_tick_us) / 1000.0
	last_presentation_tick_us = now_us
	if interval_ms <= 0.0:
		return
	if presentation_intervals_ms.size() != PRESENTATION_SAMPLE_CAPACITY:
		presentation_intervals_ms.resize(PRESENTATION_SAMPLE_CAPACITY)
	presentation_intervals_ms[presentation_sample_cursor] = interval_ms
	presentation_sample_cursor = (presentation_sample_cursor + 1) % PRESENTATION_SAMPLE_CAPACITY
	presentation_sample_count = mini(presentation_sample_count + 1, PRESENTATION_SAMPLE_CAPACITY)


func _presentation_cadence_snapshot() -> Dictionary:
	var values := PackedFloat64Array()
	values.resize(presentation_sample_count)
	var total := 0.0
	for index in range(presentation_sample_count):
		var value := float(presentation_intervals_ms[index])
		values[index] = value
		total += value
	values.sort()
	var average := total / float(presentation_sample_count) if presentation_sample_count > 0 else 0.0
	return {
		"presentation_interval_avg_ms": average,
		"presentation_interval_p95_ms": _percentile_sorted(values, 0.95),
		"presentation_interval_max_ms": float(values[values.size() - 1]) if not values.is_empty() else 0.0,
		"presentation_hz": 1000.0 / average if average > 0.0 else 0.0,
		"presentation_sample_count": presentation_sample_count,
	}


func _performance_snapshot() -> Dictionary:
	var values := PackedFloat64Array()
	values.resize(frame_sample_count)
	var total := 0.0
	var long_frames := 0
	for index in range(frame_sample_count):
		var value := float(frame_samples_ms[index])
		values[index] = value
		total += value
		if value > LONG_FRAME_THRESHOLD_MS:
			long_frames += 1
	values.sort()
	var average := total / float(frame_sample_count) if frame_sample_count > 0 else 0.0
	var maximum := float(values[values.size() - 1]) if not values.is_empty() else 0.0
	var cadence := _presentation_cadence_snapshot()
	return {
		"fps": Engine.get_frames_per_second(),
		"frame_ms_latest": latest_frame_ms,
		"frame_ms_avg": average,
		"frame_ms_p95": _percentile_sorted(values, 0.95),
		"frame_ms_p99": _percentile_sorted(values, 0.99),
		"frame_ms_max": maximum,
		"frame_sample_count": frame_sample_count,
		"long_frame_threshold_ms": LONG_FRAME_THRESHOLD_MS,
		"long_frame_count": long_frames,
		"presentation_hz": float(cadence.get("presentation_hz", 0.0)),
		"presentation_interval_avg_ms": float(cadence.get("presentation_interval_avg_ms", 0.0)),
		"presentation_interval_p95_ms": float(cadence.get("presentation_interval_p95_ms", 0.0)),
		"presentation_interval_max_ms": float(cadence.get("presentation_interval_max_ms", 0.0)),
		"presentation_sample_count": int(cadence.get("presentation_sample_count", 0)),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"godot_static_memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"resource_available": bool(latest.get("available", false)),
		"system_cpu_percent": float(latest.get("system_cpu_percent", 0.0)),
		"system_memory_percent": float(latest.get("system_memory_percent", 0.0)),
		"ocp_memory_mb": float(latest.get("ocp_memory_mb", 0.0)),
		"runtime_memory_mb": float(latest.get("runtime_memory_mb", 0.0)),
		"desktop_shell_memory_mb": float(latest.get("desktop_shell_memory_mb", 0.0)),
		"kernel_memory_mb": float(latest.get("kernel_memory_mb", 0.0)),
		"native_host_memory_mb": float(latest.get("native_host_memory_mb", 0.0)),
		"ai_memory_mb": float(latest.get("ai_memory_mb", 0.0)),
		"animation_load_name": str(latest_animation_load.get("name", "")),
		"animation_load_ms": float(latest_animation_load.get("loadMs", 0.0)),
		"animation_load_cache_hit": bool(latest_animation_load.get("cacheHit", false)),
		"animation_load_ok": bool(latest_animation_load.get("ok", false)),
		"animation_cache_entries": int(latest_animation_load.get("cacheEntries", 0)),
		"loaded_animation_count": int(latest_animation_load.get("loadedAnimations", 0)),
		"animation_prefetch_name": str(latest_animation_prefetch.get("name", "")),
		"animation_prefetch_reason": str(latest_animation_prefetch.get("reason", "")),
		"animation_prefetch_ms": float(latest_animation_prefetch.get("elapsedMs", 0.0)),
		"animation_prefetch_ok": bool(latest_animation_prefetch.get("ok", false)),
		"animation_prefetch_resident": bool(latest_animation_prefetch.get("alreadyResident", false)),
		"animation_first_frame_name": str(latest_animation_first_frame.get("name", "")),
		"animation_first_frame_ms": float(latest_animation_first_frame.get("firstFrameMs", 0.0)),
		"voice_delivery_mode": str(latest_voice_latency.get("deliveryMode", "")),
		"voice_latency_milestone": str(latest_voice_latency.get("milestone", "")),
		"voice_stream_start_ms": float(latest_voice_latency.get("requestToStreamStartMs", 0.0)),
		"voice_synthesis_ready_ms": float(latest_voice_latency.get("requestToSynthesisReadyMs", 0.0)),
		"voice_first_pcm_ms": float(latest_voice_latency.get("requestToFirstPcmMs", 0.0)),
		"voice_audio_start_ms": float(latest_voice_latency.get("requestToAudioStartMs", 0.0)),
		"voice_total_ms": float(latest_voice_latency.get("totalMs", 0.0)),
		"drag_release_latency_ms": float(latest_drag_release.get("latencyMs", 0.0)),
		"drag_release_snap_distance_px": float(latest_drag_release.get("snapDistancePx", 0.0)),
		"drag_release_movement_state": str(latest_drag_release.get("movementState", "")),
		"drag_release_attachment_state": str(latest_drag_release.get("attachmentState", "")),
		"drag_release_surface_kind": str(latest_drag_release.get("surfaceKind", "")),
		"drag_edge_prediction_animation": str(latest_drag_edge_prediction.get("animation", "")),
		"drag_edge_prediction_edge": str(latest_drag_edge_prediction.get("edge", "")),
		"drag_edge_prediction_facing": str(latest_drag_edge_prediction.get("facing", "")),
		"drag_edge_prediction_distance_px": float(latest_drag_edge_prediction.get("distancePx", 0.0)),
		"anchor_lock_reason": str(latest_anchor_continuity.get("reason", "")),
		"anchor_prevented_delta_px": float(latest_anchor_continuity.get("preventedDeltaPx", 0.0)),
	}


static func _percentile_sorted(values: PackedFloat64Array, percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var bounded := clampf(percentile, 0.0, 1.0)
	var index := clampi(int(ceil(float(values.size() - 1) * bounded)), 0, values.size() - 1)
	return float(values[index])


func _publish_performance_snapshot() -> void:
	var snapshot := _performance_snapshot()
	if context != null:
		context.update_runtime_config({"performance_baseline": snapshot.duplicate(true)})
	if event_bus != null:
		event_bus.publish(&"performance_baseline.updated", snapshot.duplicate(true))


func _on_animation_load_measured(payload: Dictionary) -> void:
	latest_animation_load = payload.duplicate(true)


func _on_animation_prefetched(payload: Dictionary) -> void:
	latest_animation_prefetch = payload.duplicate(true)


func _on_animation_first_frame_measured(payload: Dictionary) -> void:
	latest_animation_first_frame = payload.duplicate(true)


func _on_drag_release_resolved(payload: Dictionary) -> void:
	latest_drag_release = payload.duplicate(true)


func _on_voice_latency_measured(payload: Dictionary) -> void:
	latest_voice_latency = payload.duplicate(true)


func _on_drag_edge_predicted(payload: Dictionary) -> void:
	latest_drag_edge_prediction = payload.duplicate(true)


func _on_anchor_continuity_measured(payload: Dictionary) -> void:
	latest_anchor_continuity = payload.duplicate(true)


func _on_presentation_applied(_payload: Dictionary) -> void:
	_record_presentation_tick(Time.get_ticks_usec())


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
