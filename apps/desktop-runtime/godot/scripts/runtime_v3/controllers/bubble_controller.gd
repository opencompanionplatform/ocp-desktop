extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3BubbleController

const DEFAULT_FONT_FAMILY := "Noto Sans Thai"
const BUNDLED_NOTO_SANS_THAI := preload("res://assets/fonts/NotoSansThai-VF.ttf")

var host: Control
var bubble: Control
var label: Label
var generation: int = 0


func bind_ui(character_host: Control, target_bubble: Control, target_label: Label) -> void:
	host = character_host
	bubble = target_bubble
	label = target_label
	if is_instance_valid(bubble):
		bubble.visible = false


func start() -> void:
	event_bus.subscribe(&"bubble.requested", Callable(self, "_on_bubble_requested"))
	event_bus.subscribe(&"character.position_changed", Callable(self, "_on_character_position_changed"))
	event_bus.subscribe(&"animation.started", Callable(self, "_on_animation_started"))
	if is_instance_valid(context) and not context.context_changed.is_connected(_on_context_changed):
		context.context_changed.connect(_on_context_changed)
	_apply_bubble_preferences()


func stop() -> void:
	event_bus.unsubscribe(&"bubble.requested", Callable(self, "_on_bubble_requested"))
	event_bus.unsubscribe(&"character.position_changed", Callable(self, "_on_character_position_changed"))
	event_bus.unsubscribe(&"animation.started", Callable(self, "_on_animation_started"))
	if is_instance_valid(context) and context.context_changed.is_connected(_on_context_changed):
		context.context_changed.disconnect(_on_context_changed)


func _on_context_changed(section: StringName) -> void:
	if section == &"settings":
		_apply_bubble_preferences()


func _apply_bubble_preferences() -> void:
	if not is_instance_valid(bubble) or not is_instance_valid(label) or not is_instance_valid(context):
		return
	var style_name := str(context.settings.get("bubble_style", "Rounded"))
	var font_family := str(context.settings.get("font_family", DEFAULT_FONT_FAMILY))
	var style := StyleBoxFlat.new()
	style.border_color = Color("#2d8fff")
	style.set_border_width_all(1)
	match style_name.to_lower():
		"compact":
			style.bg_color = Color(0.035, 0.085, 0.16, 0.98)
			style.set_corner_radius_all(9)
			style.content_margin_left = 11
			style.content_margin_top = 7
			style.content_margin_right = 11
			style.content_margin_bottom = 7
			bubble.custom_minimum_size = Vector2(290, 68)
			bubble.size = Vector2(290, 68)
		"soft":
			style.bg_color = Color(0.075, 0.14, 0.25, 0.94)
			style.border_color = Color(0.38, 0.72, 1.0, 0.72)
			style.set_corner_radius_all(24)
			style.content_margin_left = 18
			style.content_margin_top = 11
			style.content_margin_right = 18
			style.content_margin_bottom = 11
			style.shadow_color = Color(0.0, 0.25, 0.60, 0.25)
			style.shadow_size = 10
			bubble.custom_minimum_size = Vector2(360, 96)
			bubble.size = Vector2(360, 96)
		_:
			style.bg_color = Color(0.045, 0.11, 0.21, 0.97)
			style.set_corner_radius_all(18)
			style.content_margin_left = 16
			style.content_margin_top = 9
			style.content_margin_right = 16
			style.content_margin_bottom = 9
			bubble.custom_minimum_size = Vector2(340, 85)
			bubble.size = Vector2(340, 85)
	if bubble is PanelContainer:
		(bubble as PanelContainer).add_theme_stylebox_override("panel", style)
	var selected_font: Font = BUNDLED_NOTO_SANS_THAI
	if font_family.to_lower() != "noto sans thai":
		var system_font := SystemFont.new()
		match font_family.to_lower():
			"system", "segoe ui": system_font.font_names = PackedStringArray(["Segoe UI Variable", "Segoe UI", "Leelawadee UI", "Tahoma", "Arial"])
			"tahoma": system_font.font_names = PackedStringArray(["Tahoma", "Leelawadee UI", "Segoe UI", "Arial"])
			"leelawadee ui": system_font.font_names = PackedStringArray(["Leelawadee UI", "Tahoma", "Segoe UI", "Arial"])
			"arial": system_font.font_names = PackedStringArray(["Arial", "Tahoma", "Leelawadee UI", "Segoe UI"])
			_: system_font.font_names = PackedStringArray([font_family, "Segoe UI Variable", "Segoe UI", "Leelawadee UI", "Tahoma", "Arial"])
		selected_font = system_font
	label.add_theme_font_override("font", selected_font)
	label.add_theme_font_size_override("font_size", 13 if style_name.to_lower() == "compact" else (17 if style_name.to_lower() == "soft" else 15))


func _on_bubble_requested(payload: Dictionary) -> void:
	if not bool(context.settings.get("show_bubbles", true)):
		if is_instance_valid(bubble):
			bubble.visible = false
		return
	if bool(context.runtime_config.get("native_presentation_enabled", false)):
		# NativeHostLifecycle is the sole bubble owner in native-companion mode.
		# Keeping the Godot panel hidden prevents duplicate bubbles and prevents
		# the full-canvas panel from covering the embedded character.
		if is_instance_valid(bubble):
			bubble.visible = false
		return
	if not is_instance_valid(bubble) or not is_instance_valid(label):
		return

	generation += 1
	var current_generation: int = generation
	label.text = str(payload.get("text", "Hello from Runtime V3"))
	bubble.visible = true
	_layout()
	event_bus.publish(&"bubble.shown", payload)
	event_bus.publish(&"click_through.refresh_requested", {})

	var duration: float = float(payload.get("duration", 4.0))
	if duration > 0.0:
		await get_tree().create_timer(duration).timeout
		if generation == current_generation:
			bubble.visible = false
			event_bus.publish(&"bubble.hidden", {})
			event_bus.publish(&"click_through.refresh_requested", {})


func _on_character_position_changed(_payload: Dictionary) -> void:
	_layout()


func _on_animation_started(payload: Dictionary) -> void:
	if str(payload.get("name", "")) == "speak" and is_instance_valid(bubble) and not bubble.visible:
		_on_bubble_requested({"text": "…", "duration": 2.0})


func _layout() -> void:
	if not is_instance_valid(host) or not is_instance_valid(bubble):
		return

	var anchor: Vector2 = context.character.get("bubble_anchor", Vector2(0, -176))
	var target: Vector2 = host.position + host.size * 0.5 + anchor - Vector2(bubble.size.x * 0.5, bubble.size.y)
	var viewport_size: Vector2 = host.get_viewport_rect().size
	target.x = clampf(target.x, 12.0, maxf(12.0, viewport_size.x - bubble.size.x - 12.0))
	target.y = clampf(target.y, 12.0, maxf(12.0, viewport_size.y - bubble.size.y - 12.0))
	bubble.position = target
