extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ProgressionCelebrationController

## Dedicated relationship-level presentation. Speech Bubble remains reserved for
## dialogue/personality; progression uses its own non-interactive overlay and
## falls back to the normal notification channel when motion/resources say so.

const DISPLAY_SECONDS := 3.2
const PANEL_WIDTH := 390.0
const PANEL_HEIGHT := 118.0

var _layer: CanvasLayer
var _root: Control
var _panel: PanelContainer
var _title: Label
var _subtitle: Label
var _progress: ProgressBar
var _generation := 0
var _resource_pressure := "normal"
var _character_host: Control
var _character_sprite: AnimatedSprite2D
var _floating_panel: PanelContainer
var _floating_label: Label


func bind_character(character_host: Control, character_sprite: AnimatedSprite2D) -> void:
	_character_host = character_host
	_character_sprite = character_sprite
	if is_instance_valid(_character_host):
		_character_host.clip_contents = false
	_build_character_badge()


func start() -> void:
	_build_ui()
	_build_character_badge()
	event_bus.subscribe(&"progression.level_up", Callable(self, "_on_level_up"))
	event_bus.subscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor_updated"))


func stop() -> void:
	event_bus.unsubscribe(&"progression.level_up", Callable(self, "_on_level_up"))
	event_bus.unsubscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor_updated"))
	if is_instance_valid(_layer):
		_layer.queue_free()
	if is_instance_valid(_floating_panel):
		_floating_panel.queue_free()
	_floating_panel = null
	_floating_label = null


func _build_ui() -> void:
	if is_instance_valid(_layer):
		return

	_layer = CanvasLayer.new()
	_layer.name = "ProgressionCelebrationLayer"
	_layer.layer = 1750
	add_child(_layer)

	_root = Control.new()
	_root.name = "ProgressionCelebrationRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_root)

	_panel = PanelContainer.new()
	_panel.name = "ProgressionToast"
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.offset_left = -PANEL_WIDTH / 2.0
	_panel.offset_right = PANEL_WIDTH / 2.0
	_panel.offset_top = 34.0
	_panel.offset_bottom = 34.0 + PANEL_HEIGHT
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.075, 0.13, 0.96)
	style.border_color = Color(0.30, 0.80, 1.0, 0.78)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.shadow_color = Color(0.05, 0.55, 1.0, 0.24)
	style.shadow_size = 14
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 16
	style.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var stack := VBoxContainer.new()
	stack.name = "LevelUpStack"
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", 5)
	_panel.add_child(stack)

	_title = Label.new()
	_title.name = "LevelUpTitle"
	_title.text = "LEVEL UP"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	_title.add_theme_color_override("font_color", Color(0.58, 0.91, 1.0))
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_title)

	_subtitle = Label.new()
	_subtitle.name = "LevelUpSubtitle"
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 14)
	_subtitle.add_theme_color_override("font_color", Color(0.87, 0.92, 1.0))
	_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_subtitle)

	_progress = ProgressBar.new()
	_progress.name = "LevelProgress"
	_progress.min_value = 0
	_progress.max_value = 1000
	_progress.value = 1000
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 8)
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(_progress)


func _on_resource_monitor_updated(payload: Dictionary) -> void:
	var pressure := str(payload.get("pressure", "normal"))
	_resource_pressure = pressure if pressure in ["normal", "high"] else "normal"


func _on_level_up(payload: Dictionary) -> void:
	if is_instance_valid(context) and not bool(context.settings.get("progression_level_up_enabled", true)):
		event_bus.publish(&"progression.celebration_skipped", {"reason": "disabled"})
		return
	var from_level := maxi(1, int(payload.get("fromLevel", 1)))
	var to_level := maxi(from_level + 1, int(payload.get("toLevel", from_level + 1)))
	var bond_rank := str(payload.get("bondRank", "stranger"))
	var text := "Level %d → %d · %s" % [from_level, to_level, _rank_label(bond_rank)]

	if _should_use_fallback():
		event_bus.publish(&"notification.requested", {
			"text": "LEVEL UP! " + text,
			"duration": 4.0,
			"source": "progression-fallback",
		})
		return

	_generation += 1
	var current_generation := _generation
	_title.text = "LEVEL UP  ·  Lv.%d" % to_level
	_subtitle.text = "%s  ·  %s" % [
		str(payload.get("characterId", "Companion")),
		_rank_label(bond_rank),
	]
	_progress.value = 1000
	_panel.modulate = Color(1, 1, 1, 0)
	_panel.scale = Vector2(0.94, 0.94)
	_panel.pivot_offset = Vector2(PANEL_WIDTH / 2.0, PANEL_HEIGHT / 2.0)
	_panel.visible = true
	_show_character_badge(to_level, bond_rank)
	event_bus.publish(&"progression.celebration_shown", payload.duplicate(true))
	event_bus.publish(&"click_through.refresh_requested", {})

	var intro := create_tween()
	intro.set_parallel(true)
	intro.tween_property(_panel, "modulate:a", 1.0, 0.18)
	intro.tween_property(_panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	await get_tree().create_timer(DISPLAY_SECONDS).timeout
	if current_generation != _generation or not is_instance_valid(_panel):
		return

	var outro := create_tween()
	outro.tween_property(_panel, "modulate:a", 0.0, 0.22)
	await outro.finished
	if current_generation == _generation and is_instance_valid(_panel):
		_panel.visible = false
		event_bus.publish(&"click_through.refresh_requested", {})


func _build_character_badge() -> void:
	if is_instance_valid(_floating_panel) or not is_instance_valid(_character_host):
		return
	_floating_panel = PanelContainer.new()
	_floating_panel.name = "FloatingLevelUpBadge"
	_floating_panel.custom_minimum_size = Vector2(132, 62)
	_floating_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floating_panel.z_index = 120
	_floating_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.08, 0.15, 0.94)
	style.border_color = Color(0.28, 0.86, 1.0, 0.92)
	style.set_border_width_all(2)
	style.set_corner_radius_all(18)
	style.shadow_color = Color(0.12, 0.72, 1.0, 0.38)
	style.shadow_size = 18
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_floating_panel.add_theme_stylebox_override("panel", style)
	_character_host.add_child(_floating_panel)

	_floating_label = Label.new()
	_floating_label.name = "FloatingLevelUpLabel"
	_floating_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_floating_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_floating_label.add_theme_font_size_override("font_size", 18)
	_floating_label.add_theme_color_override("font_color", Color(0.68, 0.95, 1.0))
	_floating_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floating_panel.add_child(_floating_label)


func _show_character_badge(level: int, bond_rank: String) -> void:
	_build_character_badge()
	if not is_instance_valid(_floating_panel) or not is_instance_valid(_floating_label):
		return
	var center := _character_sprite.position if is_instance_valid(_character_sprite) else _character_host.size * 0.5
	var start_position := center + Vector2(-66.0, -138.0)
	_floating_panel.position = start_position
	_floating_panel.scale = Vector2(0.78, 0.78)
	_floating_panel.pivot_offset = Vector2(66.0, 31.0)
	_floating_panel.modulate = Color(1, 1, 1, 0)
	_floating_panel.visible = true
	_floating_label.text = "LEVEL UP\nLv.%d · %s" % [level, _rank_label(bond_rank)]

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_floating_panel, "position:y", start_position.y - 42.0, 1.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_floating_panel, "scale", Vector2.ONE, 0.24).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_floating_panel, "modulate:a", 1.0, 0.18)
	tween.chain().tween_interval(0.78)
	tween.chain().tween_property(_floating_panel, "modulate:a", 0.0, 0.28)
	tween.chain().tween_callback(func() -> void:
		if is_instance_valid(_floating_panel):
			_floating_panel.visible = false
	)


func _should_use_fallback() -> bool:
	if _resource_pressure == "high":
		return true
	if not is_instance_valid(context):
		return false
	return bool(context.settings.get("reduce_motion", false))


static func _rank_label(value: String) -> String:
	match value:
		"best-companion":
			return "Best Companion"
		"partner":
			return "Partner"
		"close-friend":
			return "Close Friend"
		"friend":
			return "Friend"
		_:
			return "Stranger"
