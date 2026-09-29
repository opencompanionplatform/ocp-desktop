extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3ThemeService

const DEFAULT_THEME := "solid"
const DEFAULT_FONT_FAMILY := "Noto Sans Thai"
const DEFAULT_LANGUAGE := "en"
const BUNDLED_NOTO_SANS_THAI := preload("res://assets/fonts/NotoSansThai-VF.ttf")
const GLASS_SHADER := preload("res://shaders/glass_panel.gdshader")
const LIQUID_SHADER := preload("res://shaders/liquid_panel.gdshader")

var current_name := DEFAULT_THEME
var current_font_family := DEFAULT_FONT_FAMILY
var current_language := DEFAULT_LANGUAGE
var current_text_scale := 1.15
var active_font: Font
var registered_windows: Array[Window] = []
var presets: Dictionary = {
	"solid": {
		"surface": Color("#111827"),
		"surface_alt": Color("#172033"),
		"surface_strong": Color("#0b1220"),
		"text": Color("#f3f7ff"),
		"muted": Color("#9fb2cc"),
		"accent": Color("#2f7de1"),
		"accent_hover": Color("#4a96f2"),
		"border": Color("#376db2"),
		"hover": Color("#27466d"),
		"alpha": 1.0,
	},
	"glass": {
		"surface": Color(0.08, 0.13, 0.22, 0.82),
		"surface_alt": Color(0.12, 0.20, 0.32, 0.76),
		"surface_strong": Color(0.03, 0.07, 0.14, 0.88),
		"text": Color("#f5f8ff"),
		"muted": Color("#b2c8e5"),
		"accent": Color("#4b9dff"),
		"accent_hover": Color("#78b8ff"),
		"border": Color(0.36, 0.66, 1.0, 0.78),
		"hover": Color(0.20, 0.40, 0.66, 0.78),
		"alpha": 0.82,
	},
	"liquid": {
		"surface": Color(0.04, 0.10, 0.18, 0.84),
		"surface_alt": Color(0.07, 0.19, 0.31, 0.76),
		"surface_strong": Color(0.02, 0.06, 0.12, 0.92),
		"text": Color("#f4fbff"),
		"muted": Color("#a8c9df"),
		"accent": Color("#28b9ee"),
		"accent_hover": Color("#70dcff"),
		"border": Color(0.20, 0.78, 1.0, 0.82),
		"hover": Color(0.08, 0.36, 0.56, 0.82),
		"alpha": 0.86,
	},
}


func start() -> void:
	if is_instance_valid(context) and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)
	_apply_from_settings()


func stop() -> void:
	if is_instance_valid(context) and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)


func _on_context_changed(section: StringName) -> void:
	if section == &"settings":
		_apply_from_settings()


func _apply_from_settings() -> void:
	var previous_font := current_font_family
	var previous_language := current_language
	var previous_scale := current_text_scale
	current_font_family = str(context.settings.get("font_family", DEFAULT_FONT_FAMILY))
	current_language = str(context.settings.get("language", DEFAULT_LANGUAGE)).strip_edges().to_lower()
	if current_language not in ["th", "en"]:
		current_language = DEFAULT_LANGUAGE
	current_text_scale = clampf(float(context.settings.get("text_scale", 1.15)), 1.0, 1.80)
	active_font = _font_resource(current_font_family)
	var requested := str(context.settings.get("theme_preset", DEFAULT_THEME)).to_lower()
	var theme_changed := select_theme(requested, true)
	# Font family, text scale and bubble presentation are part of the same visual
	# contract as the color theme. Re-broadcast even when the theme name itself
	# did not change so every registered window can refresh immediately.
	var presentation_changed := previous_font != current_font_family or previous_language != current_language or not is_equal_approx(previous_scale, current_text_scale)
	if not theme_changed and presentation_changed:
		apply_all_windows()
		event_bus.publish(&"theme.changed", {
			"name": current_name,
			"tokens": presets[current_name].duplicate(true),
			"font_family": current_font_family,
			"language": current_language,
			"text_scale": current_text_scale,
			"bubble_style": str(context.settings.get("bubble_style", "Rounded")),
		})


func select_theme(name: String, publish: bool = true) -> bool:
	var normalized := name.to_lower()
	if not presets.has(normalized):
		normalized = DEFAULT_THEME
	var changed := current_name != normalized
	current_name = normalized
	context.update_runtime_config({
		"theme_preset": current_name,
		"theme_tokens": presets[current_name].duplicate(true),
	})
	apply_all_windows()
	if publish and changed:
		event_bus.publish(&"theme.changed", {
			"name": current_name,
			"tokens": presets[current_name].duplicate(true),
			"font_family": current_font_family,
			"language": current_language,
			"text_scale": current_text_scale,
			"bubble_style": str(context.settings.get("bubble_style", "Rounded")),
		})
	return changed


func preview_text_scale(scale: float) -> void:
	var normalized := clampf(scale, 1.0, 1.80)
	if is_equal_approx(current_text_scale, normalized):
		return
	current_text_scale = normalized
	apply_all_windows()
	if is_instance_valid(event_bus):
		event_bus.publish(&"theme.changed", {
			"name": current_name,
			"tokens": presets[current_name].duplicate(true),
			"font_family": current_font_family,
			"language": current_language,
			"text_scale": current_text_scale,
			"bubble_style": str(context.settings.get("bubble_style", "Rounded")),
		})


func theme_names() -> PackedStringArray:
	return PackedStringArray(["solid", "glass", "liquid"])


func tokens() -> Dictionary:
	return presets.get(current_name, presets[DEFAULT_THEME]).duplicate(true)


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
		var registered := registered_windows[index]
		if not is_instance_valid(registered) or registered == window:
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
	var palette := tokens()
	var controls: Array[Node] = window.find_children("*", "Control", true, false)
	for node in controls:
		var control := node as Control
		if _is_mock_theme_locked(control):
			continue
		_apply_surface_material(control, palette)
		if control is Label or control is Button or control is CheckButton or control is OptionButton or control is TextEdit:
			control.add_theme_color_override("font_color", palette["text"])
			control.add_theme_color_override("font_hover_color", palette["text"])
		if control is PanelContainer or control is Panel:
			control.add_theme_stylebox_override("panel", _panel_style(palette["surface"], palette["border"], 12))
		if control is Button or control is CheckButton or control is OptionButton:
			control.add_theme_stylebox_override("normal", _panel_style(palette["surface_alt"], palette["border"], 10))
			control.add_theme_stylebox_override("hover", _panel_style(palette["hover"], palette["accent"], 10))
			control.add_theme_stylebox_override("pressed", _panel_style(palette["hover"], palette["accent_hover"], 10))
		if control is TextEdit:
			control.add_theme_color_override("caret_color", palette["accent_hover"])
			control.add_theme_color_override("font_placeholder_color", palette["muted"])
	if window.has_method("apply_ocp_theme"):
		window.call("apply_ocp_theme", palette, current_name)
	# Apply font family and text scale last so window-specific visual polish does
	# not overwrite the user's readability preference.
	_apply_font_to_window(window)


func _is_mock_theme_locked(control: Control) -> bool:
	var node: Node = control
	while is_instance_valid(node) and node != null:
		if bool(node.get_meta("ocp_mock_theme_locked", false)):
			return true
		if node == control.get_window():
			break
		node = node.get_parent()
	return false


func _apply_surface_material(control: Control, palette: Dictionary) -> void:
	if not (control is PanelContainer or control is Panel):
		return
	if current_name == DEFAULT_THEME:
		if bool(control.get_meta("ocp_theme_material_owned", false)):
			control.material = null
			control.remove_meta("ocp_theme_material_owned")
		return
	var material := ShaderMaterial.new()
	material.shader = GLASS_SHADER if current_name == "glass" else LIQUID_SHADER
	material.set_shader_parameter("tint_color", palette["surface_alt"])
	material.set_shader_parameter("border_color", palette["border"])
	if current_name == "glass":
		material.set_shader_parameter("blur_amount", 2.5)
		material.set_shader_parameter("corner_radius", 0.08)
	else:
		material.set_shader_parameter("blur_amount", 2.0)
		material.set_shader_parameter("warp_intensity", 0.08)
		material.set_shader_parameter("corner_radius", 0.10)
	control.material = material
	control.set_meta("ocp_theme_material_owned", true)


func _font_resource(family: String) -> Font:
	if family.strip_edges().to_lower() == "noto sans thai":
		return BUNDLED_NOTO_SANS_THAI
	var system_font := SystemFont.new()
	match family.to_lower():
		"system", "segoe ui":
			system_font.font_names = PackedStringArray(["Segoe UI Variable", "Segoe UI", "Leelawadee UI", "Tahoma", "Arial"])
		"tahoma":
			system_font.font_names = PackedStringArray(["Tahoma", "Leelawadee UI", "Segoe UI", "Arial"])
		"leelawadee ui":
			system_font.font_names = PackedStringArray(["Leelawadee UI", "Tahoma", "Segoe UI", "Arial"])
		"arial":
			system_font.font_names = PackedStringArray(["Arial", "Tahoma", "Leelawadee UI", "Segoe UI"])
		_:
			# Future Store font packs can flow through by family name while keeping
			# Thai-capable Windows fallbacks if the custom family is unavailable.
			system_font.font_names = PackedStringArray([family, "Segoe UI Variable", "Segoe UI", "Leelawadee UI", "Tahoma", "Arial"])
	return system_font


func _apply_font_to_window(window: Window) -> void:
	if not is_instance_valid(window):
		return
	if not is_instance_valid(active_font):
		active_font = _font_resource(current_font_family)
	var controls: Array[Node] = window.find_children("*", "Control", true, false)
	for node in controls:
		var control := node as Control
		control.add_theme_font_override("font", active_font)
		if control is Label or control is Button or control is CheckButton or control is OptionButton or control is TextEdit or control is LineEdit or control is RichTextLabel:
			var base_size := int(control.get_meta("ocp_base_font_size", 0))
			if base_size <= 0:
				base_size = maxi(control.get_theme_font_size("font_size"), 12)
				control.set_meta("ocp_base_font_size", base_size)
			control.add_theme_font_size_override("font_size", maxi(10, int(round(float(base_size) * current_text_scale))))
		if control is OptionButton:
			var popup := (control as OptionButton).get_popup()
			if is_instance_valid(popup):
				popup.add_theme_font_override("font", active_font)
				popup.add_theme_font_size_override("font_size", maxi(11, int(round(15.0 * current_text_scale))))
	if window.has_method("apply_ocp_font"):
		window.call("apply_ocp_font", active_font, current_font_family)


func _panel_style(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12
	style.content_margin_top = 10
	style.content_margin_right = 12
	style.content_margin_bottom = 10
	return style
