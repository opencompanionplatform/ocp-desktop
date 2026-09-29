extends Node
class_name RuntimeV3Context

signal context_changed(section: StringName)

var character: Dictionary = {
	"id": "",
	"name": "",
	"version": "",
	"position": Vector2.ZERO,
	"desktop_position": Vector2.ZERO,
	"scale": 1.0,
	"visual_profiles": {},
	"presentation": {},
	"voice_profile": {"gender": "neutral", "age": "adult", "thaiSpeechStyle": "neutral"},
	"audio_profile": {"clips": [], "bindings": {}},
	"effects_profile": {"effects": [], "bindings": {}, "teleport": {}},
	"bubble_anchor": Vector2(0.0, -176.0),
	"hitbox": Rect2(44.0, 40.0, 220.0, 248.0),
	"animations": PackedStringArray(),
}

var monitor: Dictionary = {
	"count": 1,
	"active_index": 0,
	"virtual_rect": Rect2i(),
	"rects": [],
	"scales": [],
	"dpis": [],
}

var package: Dictionary = {
	"active_id": "",
	"active_version": "",
	"installed_path": "",
	"manifest": {},
	"entry": {},
}

var window: Dictionary = {
	"overlay_rect": Rect2i(),
	"hidden_to_tray": false,
	"transparent": true,
	"always_on_top": true,
	"canvas_scale": 1.0,
}

# OCP Cloud API is public product configuration, not a credential. Keep a
# production-safe default in Runtime so Store -> ocp://install works even when
# the user has never opened Settings. Persisted settings may still override it.
var settings: Dictionary = {
	"font_family": "Noto Sans Thai",
	"ocp_cloud_api_url": "https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api",
	# First-install presentation is intentionally calm. Aura stays available in
	# Character Effects, but the user must opt in before it renders on desktop.
	"progression_aura_enabled": false,
}
var runtime_config: Dictionary = {
	"debug_enabled": false,
	"performance_overlay_enabled": false,
	"mixed_dpi_mode": "adaptive_single_window",
	"per_monitor_windows_enabled": false,
	"hybrid_monitor_probe_active": false,
	"hybrid_monitor_probe_screen": -1,
	"click_through_enabled": true,
	"native_presentation_enabled": false,
	"native_presentation_state": "overlay",
	"native_presentation_reason": "default-overlay",
	"native_presentation_client_size": Vector2i.ZERO,
	"presentation_owner": "overlay",
	"presentation_requested_mode": "overlay",
	"presentation_fallback_reason": "",
	"resource_monitor": {
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
	},
}


func update_character(values: Dictionary) -> void:
	character.merge(values, true)
	context_changed.emit(&"character")


func update_monitor(values: Dictionary) -> void:
	monitor.merge(values, true)
	context_changed.emit(&"monitor")


func update_package(values: Dictionary) -> void:
	package.merge(values, true)
	context_changed.emit(&"package")


func update_window(values: Dictionary) -> void:
	window.merge(values, true)
	context_changed.emit(&"window")


func update_settings(values: Dictionary) -> void:
	settings.merge(values, true)
	context_changed.emit(&"settings")


func update_runtime_config(values: Dictionary) -> void:
	runtime_config.merge(values, true)
	context_changed.emit(&"runtime_config")


func snapshot() -> Dictionary:
	return {
		"character": character.duplicate(true),
		"monitor": monitor.duplicate(true),
		"package": package.duplicate(true),
		"window": window.duplicate(true),
		"settings": settings.duplicate(true),
		"runtime_config": runtime_config.duplicate(true),
	}
