extends RefCounted
class_name RuntimeV3ModeAuthority

const ENV_PRESENTATION_MODE := "OCP_PRESENTATION_MODE"
const ENV_HYBRID_MONITOR_WINDOW_PROBE := "OCP_HYBRID_MONITOR_WINDOW_PROBE"
const ENV_NATIVE_PRODUCTION_ENABLED := "OCP_NATIVE_PRODUCTION_ENABLED"
const MODE_OVERLAY := "overlay"
const MODE_DEBUG := "debug"
const MODE_HYBRID_MONITOR := "hybrid-monitor"
const MODE_NATIVE_COMPANION := "native-companion"


func resolve_start_overlay(settings: Dictionary) -> bool:
	var requested := OS.get_environment(ENV_PRESENTATION_MODE).strip_edges().to_lower()
	if requested in [MODE_OVERLAY, "desktop", "production"]:
		return true
	if requested == MODE_NATIVE_COMPANION:
		return not is_native_companion_enabled()
	if requested in [MODE_DEBUG, "window", "diagnostic"]:
		return false
	return bool(settings.get("startInOverlay", true))


func is_session_forced() -> bool:
	return not OS.get_environment(ENV_PRESENTATION_MODE).strip_edges().is_empty()


func requested_mode() -> String:
	return OS.get_environment(ENV_PRESENTATION_MODE).strip_edges().to_lower()


func resolve_requested_mode(settings: Dictionary) -> StringName:
	var requested := requested_mode()
	if requested == MODE_NATIVE_COMPANION:
		return &"native-companion"
	if requested == MODE_HYBRID_MONITOR:
		return &"hybrid-monitor"
	if requested in [MODE_DEBUG, "window", "diagnostic"]:
		return &"debug"
	if requested in [MODE_OVERLAY, "desktop", "production"]:
		return &"overlay"
	return &"overlay" if bool(settings.get("startInOverlay", true)) else &"debug"


func is_hybrid_monitor_requested() -> bool:
	return requested_mode() == MODE_HYBRID_MONITOR


func is_native_companion_requested() -> bool:
	return requested_mode() == MODE_NATIVE_COMPANION


func is_native_companion_enabled() -> bool:
	if not is_native_companion_requested():
		return false
	return OS.get_environment(ENV_NATIVE_PRODUCTION_ENABLED).strip_edges().to_lower() in [
		"1", "true", "yes", "on"
	]


func is_hybrid_monitor_window_probe_requested() -> bool:
	if not is_hybrid_monitor_requested():
		return false
	return OS.get_environment(
		ENV_HYBRID_MONITOR_WINDOW_PROBE
	).strip_edges().to_lower() in ["1", "true", "yes", "on"]
