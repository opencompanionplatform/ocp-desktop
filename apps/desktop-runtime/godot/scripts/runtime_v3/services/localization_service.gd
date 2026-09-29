extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3LocalizationService

## Runtime-localized copy authority.
##
## The service intentionally keeps locale persistence in SettingsService and
## presentation in each Window.  This mirrors ThemeService: one saved setting
## fans out to every registered window without coupling controllers to a
## specific UI tree.  Catalogs are plain JSON so creators can add languages
## without recompiling the runtime.

const DEFAULT_LOCALE := "en"
const SUPPORTED_LOCALES := ["en", "th"]
const CATALOG_PATHS := {
	"en": "res://assets/i18n/en.json",
	"th": "res://assets/i18n/th.json",
}

var current_locale := DEFAULT_LOCALE
var catalogs: Dictionary = {}
var registered_windows: Array[Window] = []


func start() -> void:
	_load_catalogs()
	if is_instance_valid(context) and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)
	_apply_from_settings(false)


func stop() -> void:
	if is_instance_valid(context) and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)


func supported_locales() -> PackedStringArray:
	return PackedStringArray(SUPPORTED_LOCALES)


func normalize_locale(locale: String) -> String:
	var normalized := locale.strip_edges().to_lower().replace("_", "-")
	if normalized.begins_with("th"):
		return "th"
	if normalized.begins_with("en"):
		return "en"
	return DEFAULT_LOCALE


func select_locale(locale: String, publish: bool = true) -> bool:
	var normalized := normalize_locale(locale)
	var changed := current_locale != normalized
	current_locale = normalized
	TranslationServer.set_locale(current_locale)
	if is_instance_valid(context):
		context.update_runtime_config({"language": current_locale})
	apply_all_windows()
	if publish and changed and is_instance_valid(event_bus):
		event_bus.publish(&"language.changed", {
			"locale": current_locale,
			"catalog": catalog(),
		})
	return changed


func text(key: String, fallback: String = "") -> String:
	var active: Dictionary = catalogs.get(current_locale, {})
	if active.has(key):
		return str(active[key])
	var english: Dictionary = catalogs.get(DEFAULT_LOCALE, {})
	if english.has(key):
		return str(english[key])
	return fallback if not fallback.is_empty() else key


func textf(key: String, values: Dictionary, fallback: String = "") -> String:
	var rendered := text(key, fallback)
	for token in values.keys():
		rendered = rendered.replace("{%s}" % str(token), str(values[token]))
	return rendered


func catalog() -> Dictionary:
	return Dictionary(catalogs.get(current_locale, {})).duplicate(true)


func register_window(window: Window) -> void:
	if not is_instance_valid(window):
		return
	for registered in registered_windows:
		if registered == window:
			apply_to_window(window)
			return
	registered_windows.append(window)
	apply_to_window(window)


func unregister_window(window: Window) -> void:
	for index in range(registered_windows.size() - 1, -1, -1):
		if not is_instance_valid(registered_windows[index]) or registered_windows[index] == window:
			registered_windows.remove_at(index)


func apply_all_windows() -> void:
	for index in range(registered_windows.size() - 1, -1, -1):
		var window := registered_windows[index]
		if not is_instance_valid(window):
			registered_windows.remove_at(index)
			continue
		apply_to_window(window)


func apply_to_window(window: Window) -> void:
	if not is_instance_valid(window):
		return
	if window.has_method("apply_ocp_language"):
		window.call("apply_ocp_language", current_locale, catalog())


func _on_context_changed(section: StringName) -> void:
	if section == &"settings":
		_apply_from_settings(true)


func _apply_from_settings(publish: bool) -> void:
	if not is_instance_valid(context):
		return
	var requested := str(context.settings.get("language", DEFAULT_LOCALE))
	select_locale(requested, publish)


func _load_catalogs() -> void:
	catalogs.clear()
	for locale in CATALOG_PATHS.keys():
		var loaded := _read_catalog(str(CATALOG_PATHS[locale]))
		if loaded.is_empty():
			push_warning("LocalizationService: empty catalog for %s" % locale)
		catalogs[locale] = loaded


func _read_catalog(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("LocalizationService: cannot open %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return Dictionary(parsed)
	push_error("LocalizationService: invalid JSON catalog %s" % path)
	return {}
