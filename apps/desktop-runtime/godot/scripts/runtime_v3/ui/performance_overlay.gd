extends CanvasLayer
class_name RuntimeV3PerformanceOverlay

var label: Label
var elapsed: float = 0.0
var latest_snapshot: Dictionary = {}


func _ready() -> void:
	label = Label.new()
	label.position = Vector2(16, 120)
	add_child(label)
	visible = false


func apply_snapshot(snapshot: Dictionary) -> void:
	latest_snapshot = snapshot.duplicate(true)
	if visible:
		_render_snapshot()


func _process(delta: float) -> void:
	if not visible:
		return

	elapsed += delta
	if elapsed < 0.25:
		return
	elapsed = 0.0
	_render_snapshot()


func _render_snapshot() -> void:
	if not is_instance_valid(label):
		return

	var fps := float(latest_snapshot.get("fps", Engine.get_frames_per_second()))
	var frame_latest := float(latest_snapshot.get("frame_ms_latest", 0.0))
	var frame_avg := float(latest_snapshot.get("frame_ms_avg", frame_latest))
	var frame_p95 := float(latest_snapshot.get("frame_ms_p95", frame_latest))
	var frame_p99 := float(latest_snapshot.get("frame_ms_p99", frame_latest))
	var frame_max := float(latest_snapshot.get("frame_ms_max", frame_latest))
	var long_threshold := float(latest_snapshot.get("long_frame_threshold_ms", 25.0))
	var long_count := int(latest_snapshot.get("long_frame_count", 0))
	var node_count := int(latest_snapshot.get(
		"node_count",
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	))
	var static_memory_mb := float(latest_snapshot.get(
		"godot_static_memory_mb",
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	))

	var lines := PackedStringArray()
	lines.append("OCP PERFORMANCE BASELINE")
	lines.append("FPS: %.0f  Frame: %.2f ms  Avg: %.2f ms" % [fps, frame_latest, frame_avg])
	lines.append("P95: %.2f ms  P99: %.2f ms  Max: %.2f ms" % [frame_p95, frame_p99, frame_max])
	lines.append("Long > %.0f ms: %d  Samples: %d" % [
		long_threshold,
		long_count,
		int(latest_snapshot.get("frame_sample_count", 0)),
	])
	lines.append("Presentation: %.1f Hz  Avg: %.2f ms  P95: %.2f ms  Max: %.2f ms" % [
		float(latest_snapshot.get("presentation_hz", 0.0)),
		float(latest_snapshot.get("presentation_interval_avg_ms", 0.0)),
		float(latest_snapshot.get("presentation_interval_p95_ms", 0.0)),
		float(latest_snapshot.get("presentation_interval_max_ms", 0.0)),
	])
	lines.append("Nodes: %d  Godot static: %.1f MB" % [node_count, static_memory_mb])

	if bool(latest_snapshot.get("resource_available", false)):
		lines.append("System CPU: %.1f%%  Memory: %.1f%%" % [
			float(latest_snapshot.get("system_cpu_percent", 0.0)),
			float(latest_snapshot.get("system_memory_percent", 0.0)),
		])
		lines.append("OCP: %.1f MB  Runtime: %.1f MB  Electron: %.1f MB" % [
			float(latest_snapshot.get("ocp_memory_mb", 0.0)),
			float(latest_snapshot.get("runtime_memory_mb", 0.0)),
			float(latest_snapshot.get("desktop_shell_memory_mb", 0.0)),
		])
		lines.append("Kernel: %.1f MB  Native: %.1f MB  AI: %.1f MB" % [
			float(latest_snapshot.get("kernel_memory_mb", 0.0)),
			float(latest_snapshot.get("native_host_memory_mb", 0.0)),
			float(latest_snapshot.get("ai_memory_mb", 0.0)),
		])

	var animation_name := str(latest_snapshot.get("animation_load_name", ""))
	if not animation_name.is_empty():
		var cache_label := "hit" if bool(latest_snapshot.get("animation_load_cache_hit", false)) else "load"
		var ok_label := "ok" if bool(latest_snapshot.get("animation_load_ok", false)) else "failed"
		lines.append("Animation: %s  %.2f ms  %s/%s  cache=%d loaded=%d" % [
			animation_name,
			float(latest_snapshot.get("animation_load_ms", 0.0)),
			cache_label,
			ok_label,
			int(latest_snapshot.get("animation_cache_entries", 0)),
			int(latest_snapshot.get("loaded_animation_count", 0)),
		])

	var prefetch_name := str(latest_snapshot.get("animation_prefetch_name", ""))
	if not prefetch_name.is_empty():
		var prefetch_state := "resident" if bool(latest_snapshot.get("animation_prefetch_resident", false)) else "warmed"
		if not bool(latest_snapshot.get("animation_prefetch_ok", false)):
			prefetch_state = "failed"
		lines.append("Prefetch: %s  %.2f ms  %s  reason=%s" % [
			prefetch_name,
			float(latest_snapshot.get("animation_prefetch_ms", 0.0)),
			prefetch_state,
			str(latest_snapshot.get("animation_prefetch_reason", "")),
		])

	var first_frame_name := str(latest_snapshot.get("animation_first_frame_name", ""))
	if not first_frame_name.is_empty():
		lines.append("First frame: %s  %.2f ms" % [
			first_frame_name,
			float(latest_snapshot.get("animation_first_frame_ms", 0.0)),
		])

	var voice_mode := str(latest_snapshot.get("voice_delivery_mode", ""))
	if not voice_mode.is_empty():
		if voice_mode == "streaming":
			lines.append("Voice: streaming  start=%.0f ms  pcm=%.0f ms  audible=%.0f ms  total=%.0f ms  [%s]" % [
				float(latest_snapshot.get("voice_stream_start_ms", 0.0)),
				float(latest_snapshot.get("voice_first_pcm_ms", 0.0)),
				float(latest_snapshot.get("voice_audio_start_ms", 0.0)),
				float(latest_snapshot.get("voice_total_ms", 0.0)),
				str(latest_snapshot.get("voice_latency_milestone", "")),
			])
		else:
			lines.append("Voice: quality  ready=%.0f ms  audible=%.0f ms  total=%.0f ms  [%s]" % [
				float(latest_snapshot.get("voice_synthesis_ready_ms", 0.0)),
				float(latest_snapshot.get("voice_audio_start_ms", 0.0)),
				float(latest_snapshot.get("voice_total_ms", 0.0)),
				str(latest_snapshot.get("voice_latency_milestone", "")),
			])

	var edge_prediction := str(latest_snapshot.get("drag_edge_prediction_animation", ""))
	if not edge_prediction.is_empty():
		lines.append("Edge prefetch: %s  %.1f px  facing=%s  animation=%s" % [
			str(latest_snapshot.get("drag_edge_prediction_edge", "")),
			float(latest_snapshot.get("drag_edge_prediction_distance_px", 0.0)),
			str(latest_snapshot.get("drag_edge_prediction_facing", "")),
			edge_prediction,
		])

	var release_state := str(latest_snapshot.get("drag_release_movement_state", ""))
	if not release_state.is_empty():
		lines.append("Release: %.2f ms  snap=%.1f px  %s/%s  surface=%s" % [
			float(latest_snapshot.get("drag_release_latency_ms", 0.0)),
			float(latest_snapshot.get("drag_release_snap_distance_px", 0.0)),
			release_state,
			str(latest_snapshot.get("drag_release_attachment_state", "")),
			str(latest_snapshot.get("drag_release_surface_kind", "")),
		])

	var anchor_reason := str(latest_snapshot.get("anchor_lock_reason", ""))
	if not anchor_reason.is_empty():
		lines.append("Anchor continuity: %s  prevented=%.1f px" % [
			anchor_reason,
			float(latest_snapshot.get("anchor_prevented_delta_px", 0.0)),
		])

	label.text = "\n".join(lines)
