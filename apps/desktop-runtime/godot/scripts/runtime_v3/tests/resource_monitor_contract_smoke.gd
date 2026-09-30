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

	service._record_frame(0.010)
	service._record_frame(0.020)
	service._record_frame(0.030)
	service._record_presentation_tick(1_000_000)
	service._record_presentation_tick(1_008_333)
	service._record_presentation_tick(1_016_666)
	service._on_animation_load_measured({
		"name": "fall",
		"loadMs": 17.5,
		"cacheHit": false,
		"ok": true,
		"cacheEntries": 2,
		"loadedAnimations": 3,
	})
	service._on_animation_prefetched({
		"name": "fall",
		"reason": "drag-release:airborne-falling",
		"elapsedMs": 18.0,
		"ok": true,
		"alreadyResident": false,
	})
	service._on_animation_first_frame_measured({"name": "fall", "firstFrameMs": 24.0})
	service._on_drag_release_resolved({
		"latencyMs": 11.5,
		"snapDistancePx": 52.0,
		"movementState": "climb-ready",
		"attachmentState": "attached",
		"surfaceKind": "monitor-edge",
	})
	service._on_voice_latency_measured({
		"deliveryMode": "streaming",
		"milestone": "audio-start",
		"requestToStreamStartMs": 82.0,
		"requestToSynthesisReadyMs": 0.0,
		"requestToFirstPcmMs": 104.0,
		"requestToAudioStartMs": 218.0,
		"totalMs": 0.0,
	})
	service._on_drag_edge_predicted({
		"animation": "climb_ready_right",
		"edge": "left",
		"facing": "right",
		"distancePx": 104.0,
	})
	service._on_anchor_continuity_measured({
		"reason": "drag-release",
		"preventedDeltaPx": 18.0,
	})
	var performance: Dictionary = service._performance_snapshot()
	var performance_ok := is_equal_approx(float(performance.get("frame_ms_avg", 0.0)), 20.0) \
		and is_equal_approx(float(performance.get("frame_ms_p95", 0.0)), 30.0) \
		and is_equal_approx(float(performance.get("frame_ms_p99", 0.0)), 30.0) \
		and is_equal_approx(float(performance.get("frame_ms_max", 0.0)), 30.0) \
		and int(performance.get("long_frame_count", 0)) == 1 \
		and float(performance.get("presentation_hz", 0.0)) > 119.0 \
		and float(performance.get("presentation_hz", 0.0)) < 121.0 \
		and is_equal_approx(float(performance.get("presentation_interval_avg_ms", 0.0)), 8.333) \
		and is_equal_approx(float(performance.get("presentation_interval_p95_ms", 0.0)), 8.333) \
		and str(performance.get("animation_load_name", "")) == "fall" \
		and is_equal_approx(float(performance.get("animation_load_ms", 0.0)), 17.5) \
		and int(performance.get("animation_cache_entries", 0)) == 2 \
		and int(performance.get("loaded_animation_count", 0)) == 3 \
		and str(performance.get("animation_prefetch_name", "")) == "fall" \
		and str(performance.get("animation_prefetch_reason", "")) == "drag-release:airborne-falling" \
		and is_equal_approx(float(performance.get("animation_prefetch_ms", 0.0)), 18.0) \
		and bool(performance.get("animation_prefetch_ok", false)) \
		and not bool(performance.get("animation_prefetch_resident", true)) \
		and is_equal_approx(float(performance.get("animation_first_frame_ms", 0.0)), 24.0) \
		and str(performance.get("voice_delivery_mode", "")) == "streaming" \
		and str(performance.get("voice_latency_milestone", "")) == "audio-start" \
		and is_equal_approx(float(performance.get("voice_stream_start_ms", 0.0)), 82.0) \
		and is_equal_approx(float(performance.get("voice_first_pcm_ms", 0.0)), 104.0) \
		and is_equal_approx(float(performance.get("voice_audio_start_ms", 0.0)), 218.0) \
		and is_equal_approx(float(performance.get("drag_release_latency_ms", 0.0)), 11.5) \
		and is_equal_approx(float(performance.get("drag_release_snap_distance_px", 0.0)), 52.0) \
		and str(performance.get("drag_release_movement_state", "")) == "climb-ready" \
		and str(performance.get("drag_release_attachment_state", "")) == "attached" \
		and str(performance.get("drag_release_surface_kind", "")) == "monitor-edge" \
		and str(performance.get("drag_edge_prediction_animation", "")) == "climb_ready_right" \
		and str(performance.get("drag_edge_prediction_edge", "")) == "left" \
		and str(performance.get("drag_edge_prediction_facing", "")) == "right" \
		and is_equal_approx(float(performance.get("drag_edge_prediction_distance_px", 0.0)), 104.0) \
		and str(performance.get("anchor_lock_reason", "")) == "drag-release" \
		and is_equal_approx(float(performance.get("anchor_prevented_delta_px", 0.0)), 18.0)

	var ok := normal == "normal" \
		and high_cpu == "high" \
		and high_memory == "high" \
		and hysteresis == "high" \
		and cleared == "normal" \
		and breakdown_ok \
		and performance_ok
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
