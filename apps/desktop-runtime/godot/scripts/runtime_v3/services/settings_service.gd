extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3SettingsService

const SETTINGS_FILE := "user://runtime/settings.json"
const STATE_FILE := "user://runtime/state.json"
const BIBLE_CHARACTER_ID := "character.bible"
const BIBLE_DEFAULT_PRESENTATION_SCALE := 0.50
const DEFAULT_PRESENTATION_SCALE := 1.00


func load_settings() -> Dictionary:
	var values: Dictionary = _read_json(SETTINGS_FILE)
	# An empty persisted Cloud URL came from older builds where Cloud was opt-in.
	# Treat it as "unset" so RuntimeContext's public production default survives
	# startup. A non-empty saved value still overrides the product default.
	if values.has("ocp_cloud_api_url") and str(values.get("ocp_cloud_api_url", "")).strip_edges().is_empty():
		values.erase("ocp_cloud_api_url")
	context.update_settings(values)
	return values


func save_settings(values: Dictionary) -> bool:
	var current: Dictionary = context.settings.duplicate(true)
	current.merge(values, true)
	if not _write_json(SETTINGS_FILE, current):
		return false
	context.update_settings(current)
	return true


func load_runtime_state() -> Dictionary:
	return _read_json(STATE_FILE)


func save_runtime_state(values: Dictionary) -> bool:
	var current: Dictionary = _read_json(STATE_FILE)
	current.merge(values, true)
	return _write_json(STATE_FILE, current)


func save_character_desktop_position(position: Vector2, screen_index: int, screen_scale: float) -> bool:
	var state := load_runtime_state()
	var runtime := _runtime_section(state)
	runtime.merge({
		"companionDesktopPosition": [position.x, position.y],
		"screenIndex": screen_index,
		"screenScale": screen_scale,
	}, true)
	state["runtime"] = runtime
	return _write_json(STATE_FILE, state)


func load_character_desktop_position() -> Dictionary:
	var state: Dictionary = load_runtime_state()
	var runtime_value: Variant = state.get("runtime", {})
	var runtime: Dictionary = runtime_value if runtime_value is Dictionary else {}
	var position_value: Variant = runtime.get("companionDesktopPosition", [])
	if not position_value is Array or position_value.size() < 2:
		return {}

	return {
		"position": Vector2(float(position_value[0]), float(position_value[1])),
		"screen_index": int(runtime.get("screenIndex", 0)),
		"screen_scale": float(runtime.get("screenScale", 1.0)),
	}


func save_character_presentation_scale(character_id: String, scale: float) -> bool:
	if character_id.strip_edges().is_empty() or not _is_presentation_scale_allowed(scale):
		return false
	var state := load_runtime_state()
	var runtime := _runtime_section(state)
	var scales_value: Variant = runtime.get("characterPresentationScales", {})
	var scales: Dictionary = scales_value.duplicate(true) if scales_value is Dictionary else {}
	scales[character_id] = scale
	runtime["characterPresentationScales"] = scales
	state["runtime"] = runtime
	return _write_json(STATE_FILE, state)


func load_character_presentation_scale(character_id: String) -> float:
	var clean_character_id := character_id.strip_edges()
	if clean_character_id.is_empty():
		return DEFAULT_PRESENTATION_SCALE
	var default_scale := _default_presentation_scale(clean_character_id)
	var runtime := _runtime_section(load_runtime_state())
	var scales_value: Variant = runtime.get("characterPresentationScales", {})
	if not scales_value is Dictionary:
		return default_scale
	var scale := float((scales_value as Dictionary).get(clean_character_id, default_scale))
	return scale if _is_presentation_scale_allowed(scale) else default_scale


func _default_presentation_scale(character_id: String) -> float:
	return BIBLE_DEFAULT_PRESENTATION_SCALE if character_id == BIBLE_CHARACTER_ID else DEFAULT_PRESENTATION_SCALE


func _runtime_section(state: Dictionary) -> Dictionary:
	var runtime_value: Variant = state.get("runtime", {})
	return runtime_value.duplicate(true) if runtime_value is Dictionary else {}


func _is_presentation_scale_allowed(scale: float) -> bool:
	for preset in [0.25, 0.50, 0.75, 1.00, 1.25]:
		if is_equal_approx(scale, preset):
			return true
	return false


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, values: Dictionary) -> bool:
	# user:// is a Godot virtual path; the non-absolute API is required here.
	# The absolute variant silently fails on a clean headless profile, causing
	# position persistence and Hide-to-Tray restore tests to fail.
	var user_dir := DirAccess.open("user://")
	if user_dir != null:
		user_dir.make_dir_recursive("runtime")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("SettingsService: cannot open " + path)
		return false
	file.store_string(JSON.stringify(values, "\t"))
	file.close()
	return true
