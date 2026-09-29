extends Node

# Explicit preloads keep this runtime independent from Godot's generated
# global_script_class_cache.cfg. This is important after cache cleanup and
# when the project is launched directly from PowerShell.
const InstalledCharacterRepository = preload("res://scripts/runtime/packages/installed_character_repository.gd")
const CharacterPackageInstaller = preload("res://scripts/runtime/packages/character_package_installer.gd")
const OcpPackageReader = preload("res://scripts/runtime/packages/ocp_package_reader.gd")
const OcpPackageValidator = preload("res://scripts/runtime/packages/ocp_package_validator.gd")
## Presentation-only reactions to OcpRuntimeBridge signals (RUNTIME_API เธขเธ2-3,
## เธขเธ8 multi-companion since I6.5 slice 4). No contract/security logic belongs
## here เนโฌโ€ that lives in the GDExtension (apps/desktop-runtime/rust). This
## script only draws things and forwards input back to the bridge.
##
## Multi-companion model (ADR-0013 เธขเธ1): one scene, one node per companion
## (Root เนยโ€ Companion1..N). The static CompanionSprite in Main.tscn doubles as
## the "default" companion so the proven single-companion walking skeleton
## keeps working unchanged; spawned companions get dynamically created
## ColorRect placeholders (real character art is I8 territory).

@onready var bridge: Node = $OcpRuntimeBridge
@onready var bubble_label: Label = $BubbleLabel
@onready var companion_sprite: ColorRect = $CompanionSprite

## companion_id (String) -> ColorRect node
var companions: Dictionary = {}
## companion_id -> AnimatedSprite2D (I8A slice 1b placeholder sprite-sheet).
## Only the default companion gets one for now; spawned companions keep their
## ColorRect until a real character package (.ocp) supplies frames (I8B).
var companion_anims: Dictionary = {}
## companion_id -> Label bubble anchored above that companion's sprite (I8A
## slice 3). Created lazily; a child of the companion's node so it tracks the
## sprite as it moves. Retires the single shared BubbleLabel for เธขเธ2.3 bubbles.
var companion_bubbles: Dictionary = {}
## follower companion_id -> { "leader": String, "distance": float }
var follows: Dictionary = {}
## companion_id -> true while sleeping (placeholder: sleep == hidden + no follow updates)
var sleeping: Dictionary = {}
# Host-owned desktop interaction POC. These controls deliberately live in the
# presentation layer: they never validate packages or make core decisions.
var hover_toolbar: PanelContainer
var quick_panel: PanelContainer
var quick_panel_backdrop: ColorRect
var notification_panel: PanelContainer
var tray_menu_rid := RID()
var animation_menu: PopupMenu
var character_menu: PopupMenu
var character_picker: PanelContainer
var character_picker_list: VBoxContainer
var character_install_dialog: FileDialog
var quick_animation_column: VBoxContainer
var tray_indicator_id := DisplayServer.INVALID_INDICATOR_ID
var hover_visible := false
var hover_hide_deadline_ms := 0
var dragging_companion := false
var hover_suppressed_until_pointer_exit := false
var runtime_hidden_to_tray := false
var companion_drag_mouse_origin := Vector2.ZERO
var companion_drag_position_origin := Vector2.ZERO
var dragging_panel := false
var last_usable_screen_rect := Rect2i()
var last_viewport_size := Vector2.ZERO
# Sprint A.1-A.3: one transparent window spans the same-DPI virtual desktop.
# DisplayServer screen rectangles and window geometry are physical desktop pixels;
# companion nodes use logical canvas units (physical / DESKTOP_CANVAS_SCALE).
var virtual_desktop_rect := Rect2i()
var virtual_desktop_origin := Vector2i.ZERO
var monitor_usable_rects_local: Array[Rect2] = []
# Sprint A.4: mixed-DPI support while retaining the stable single virtual-desktop
# overlay. Screen geometry remains in physical pixels; the companion presentation
# is rescaled when its center enters a monitor with a different Windows scale.
var monitor_scale_factors: Array[float] = []
var monitor_dpi_values: Array[int] = []
var active_monitor_index := -1
var active_monitor_scale := DESKTOP_CANVAS_SCALE
var active_monitor_scale_ratio := 1.0
var saved_companion_desktop_position := Vector2.ZERO
var has_saved_companion_desktop_position := false
const RUNTIME_STATE_FILE := "user://runtime/state.json"
var walk_target := Vector2.ZERO
var walking := false
var shutdown_requested := false
const WALK_PIXELS_PER_SECOND := 180.0
const SPRITE_RENDER_SCALE := 0.60
# Surface Pro / Windows uses a high-DPI physical viewport. Draw the runtime in
# logical desktop units, then scale the entire 2D canvas to physical pixels.
const DESKTOP_CANVAS_SCALE := 2.0
const RENDERED_FRAME_HALF_EXTENT := 154.0
var tray_icon: Texture2D

const TRAY_SHOW := 1
const TRAY_HIDE := 2
const TRAY_DASHBOARD := 3
const TRAY_CHARACTER_STUDIO := 4
const TRAY_MARKETPLACE := 5
const TRAY_PLUGINS := 6
const TRAY_PANEL := 7
const TRAY_BUBBLE := 8
const TRAY_NOTIFICATION := 9
const TRAY_CHECK_UPDATES := 10
const TRAY_ABOUT := 11
const TRAY_EXIT := 12
const TRAY_CHAT := 13
const TRAY_AI_PROVIDER_KEYS := 14
const TRAY_SWITCH_CHARACTER := 15
const CHARACTER_MENU_INSTALL := 1000
const CHARACTER_MENU_UNINSTALL_ACTIVE := 1001

# A package cell is 512px. Keep a host exactly as large as the rendered cell.
const SPRITE_SIZE := Vector2(308, 308)
const HOVER_HIDE_DELAY_MS := 850
var companion_position_initialized := false
var skip_layout_after_geometry_change := false
var show_companion_after_initial_layout := true
var last_mouse_passthrough_polygon := PackedVector2Array()
# Character presentation metadata loaded from character.json. Supported either
# as top-level fields or inside a `runtime` object.
var active_character_runtime: Dictionary = {
    "bubbleAnchor": Vector2(0.0, -176.0),
    "scale": SPRITE_RENDER_SCALE,
    "hitbox": Rect2(Vector2.ZERO, SPRITE_SIZE),
}

## Emotion -> tint mapping. Placeholder only: there is no character package /
## expression art yet (I8). Emotion names are character-defined strings
## (RFC-0001) -- this fixed mapping is just enough to make emotion changes
## visible on the placeholder sprite, not a real expression system.
const EMOTION_TINTS := {
	"happy": Color(1.0, 0.85, 0.2),
	"sad": Color(0.35, 0.5, 0.9),
	"worried": Color(0.9, 0.6, 0.2),
	"excited": Color(1.0, 0.4, 0.7),
	"neutral": Color(1, 1, 1),
}

## emotion -> placeholder mouth shape (Expression module, RFC-0008 เธขเธ4.1). A real
## character package (I8B) ships its own expression set; this is the fallback the
## SDK draws. Keys mirror EMOTION_TINTS.
const EMOTION_MOUTHS := {
	"happy": 1,
	"sad": 2,
	"worried": 4,
	"excited": 3,
	"neutral": 0,
}

## Distinct base colors per spawned companion so multiple companions are
## visually tellable-apart before real character art exists.
const SPAWN_COLORS := [
	Color(0.85, 0.95, 1.0),
	Color(1.0, 0.9, 0.8),
	Color(0.85, 1.0, 0.85),
	Color(1.0, 0.85, 0.95),
]


func _ready() -> void:
	_apply_desktop_canvas_scale()
	bridge.bubble_requested.connect(_on_bubble_requested)
	bridge.speech_requested.connect(_on_speech_requested)
	bridge.emotion_changed.connect(_on_emotion_changed)
	bridge.animation_requested.connect(_on_animation_requested)
	bridge.window_policy_changed.connect(_on_window_policy_changed)
	bridge.state_changed.connect(_on_state_changed)
	bridge.connection_lost.connect(_on_connection_lost)
	bridge.connection_restored.connect(_on_connection_restored)
	bridge.companion_spawn_requested.connect(_on_companion_spawn)
	bridge.companion_despawn_requested.connect(_on_companion_despawn)
	bridge.companion_sleep_requested.connect(_on_companion_sleep)
	bridge.companion_visibility_requested.connect(_on_companion_visibility)
	bridge.companion_focus_requested.connect(_on_companion_focus)
	bridge.companion_follow_requested.connect(_on_companion_follow)
	bridge.look_at_cursor_requested.connect(_on_look_at_cursor)
# Default to Bible when no active-character state exists and Bible is installed.
	var installed_repo := InstalledCharacterRepository.new()
	if installed_repo.get_active().is_empty():
		var bible := installed_repo.find_exact("character.bible", "1.0.0")
		if not bible.is_empty():
			CharacterPackageInstaller.new().set_active("character.bible", "1.0.0")
	# The static sprite is the "default" companion (เธขเธ8.1 single-companion id).
	companions["default"] = companion_sprite
	# I8A slice 1b: give the default companion a real (code-generated) sprite-
	# sheet so เธขเธ7 animations play as frames with real completion timing, not a
	# tween pulse. The ColorRect stays as the invisible hit-target/anchor.
	_attach_placeholder_sprite("default", companion_sprite)
	# BUG FIX (found live, I6.5 slice 4): ColorRect is a Control with
	# mouse_filter = STOP by default เนโฌโ€ it consumes clicks before they reach
	# _unhandled_input, so clicks ON a companion never got hit-tested at all
	# (and clicks beside one fell through as bare "companion"). IGNORE lets
	# every click reach _unhandled_input where our own hit-test runs.
	companion_sprite.size = SPRITE_SIZE
	companion_sprite.z_index = 5
	companion_sprite.clip_contents = false
	companion_sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Avoid showing the boot-position frame before the usable-screen layout is ready.
	companion_sprite.visible = false

	_load_saved_companion_desktop_position()
	_setup_desktop_controls()
	_apply_active_character_runtime()
	_populate_animation_controls()


func _apply_desktop_canvas_scale() -> void:
	var scale_value := DESKTOP_CANVAS_SCALE
	get_viewport().canvas_transform = Transform2D(
		Vector2(scale_value, 0.0),
		Vector2(0.0, scale_value),
		Vector2.ZERO)

func _logical_viewport_size() -> Vector2:
	var physical_size := get_viewport().get_visible_rect().size
	return physical_size / DESKTOP_CANVAS_SCALE

func _logical_mouse_position() -> Vector2:
	var physical_mouse := get_viewport().get_mouse_position()
	return get_viewport().canvas_transform.affine_inverse() * physical_mouse

func _logical_to_window_point(point: Vector2) -> Vector2:
	return get_viewport().canvas_transform * point


# --- Desktop interaction POC (RFC-0006 hover toolbar + host-owned tray) ---

func _setup_desktop_controls() -> void:
	_setup_hover_toolbar()
	_setup_quick_panel()
	_setup_animation_menu()
	_setup_character_menu()
	_setup_notification()
	_apply_ocp_window_icon()
	_setup_system_tray()
	# Initial placement waits for usable desktop bounds in _process().


func _panel_style(background: Color, border: Color, radius := 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func _make_button(caption: String, hint: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.tooltip_text = hint
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_color_override("font_color", Color("e8efff"))
	button.add_theme_stylebox_override("normal", _panel_style(Color("18243b"), Color("2d4268"), 7))
	button.add_theme_stylebox_override("hover", _panel_style(Color("263b63"), Color("6fa7ff"), 7))
	button.add_theme_stylebox_override("pressed", _panel_style(Color("34548a"), Color("9bc2ff"), 7))
	button.pressed.connect(action)
	return button


func _make_hover_menu_item(label: String, hint: String, action: int, color: Color) -> Button:
	var button := _make_button(label, hint, _on_tray_menu_selected.bind(action))
	button.icon = _make_menu_icon(color)
	button.expand_icon = true
	button.custom_minimum_size = Vector2(224, 26)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	return button


func _setup_hover_toolbar() -> void:
	hover_toolbar = PanelContainer.new()
	hover_toolbar.name = "HoverToolbar"
	hover_toolbar.z_index = 3
	hover_toolbar.mouse_filter = Control.MOUSE_FILTER_STOP
	hover_toolbar.custom_minimum_size = Vector2(244, 330)
	hover_toolbar.visible = false
	hover_toolbar.clip_contents = true
	hover_toolbar.add_theme_stylebox_override("panel", _panel_style(Color("0f1729ef"), Color("466da9"), 10))
	var scroll := ScrollContainer.new()
	scroll.name = "HoverScroll"
	scroll.custom_minimum_size = Vector2(244, 330)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.clip_contents = true
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(224, 0)
	var heading := Label.new()
	heading.text = "OCP Companion Menu"
	heading.add_theme_color_override("font_color", Color("dceaff"))
	column.add_child(heading)
	column.add_child(_make_hover_menu_item("Show companion", "Show overlay", TRAY_SHOW, Color("56a8ff")))
	column.add_child(_make_hover_menu_item("Hide to tray", "Hide overlay and keep tray icon", TRAY_HIDE, Color("7b8ba9")))
	column.add_child(_make_hover_menu_item("Dashboard", "Open dashboard", TRAY_DASHBOARD, Color("5eead4")))
	column.add_child(_make_hover_menu_item("OCP Quick Panel", "Open Quick Panel", TRAY_PANEL, Color("60a5fa")))
	column.add_child(_make_hover_menu_item("Chat / AI Command", "Open AI Chat", TRAY_CHAT, Color("38bdf8")))
	column.add_child(_make_hover_menu_item("AI Provider Keys", "How to configure AI provider credentials", TRAY_AI_PROVIDER_KEYS, Color("22c55e")))
	column.add_child(_make_hover_menu_item("Change Character", "Choose an installed .ocp character", TRAY_SWITCH_CHARACTER, Color("c084fc")))
	column.add_child(_make_hover_menu_item("Character Studio", "Open Character Studio", TRAY_CHARACTER_STUDIO, Color("a78bfa")))
	column.add_child(_make_hover_menu_item("Marketplace", "Open Marketplace", TRAY_MARKETPLACE, Color("fbbf24")))
	column.add_child(_make_hover_menu_item("Plugins", "Manage plugins", TRAY_PLUGINS, Color("f472b6")))
	column.add_child(_make_hover_menu_item("Check for updates", "Check OCP updates", TRAY_CHECK_UPDATES, Color("f59e0b")))
	column.add_child(_make_hover_menu_item("About OCP", "About this Runtime", TRAY_ABOUT, Color("94a3b8")))
	column.add_child(_make_hover_menu_item("Exit OCP Runtime", "Exit Runtime", TRAY_EXIT, Color("fb7185")))
	scroll.add_child(column)
	hover_toolbar.add_child(scroll)
	add_child(hover_toolbar)

func _setup_quick_panel() -> void:
	quick_panel_backdrop = ColorRect.new()
	quick_panel_backdrop.name = "QuickPanelBackdrop"
	quick_panel_backdrop.z_index = 1
	quick_panel_backdrop.color = Color(0.02, 0.04, 0.08, 0.56)
	quick_panel_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	quick_panel_backdrop.visible = false
	add_child(quick_panel_backdrop)

	quick_panel = PanelContainer.new()
	quick_panel.name = "OcpQuickPanel"
	quick_panel.position = Vector2(28, 72)
	quick_panel.size = Vector2(360, minf(620.0, maxf(280.0, _logical_viewport_size().y - 32.0)))
	quick_panel.z_index = 2
	quick_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	quick_panel.visible = false
	quick_panel.add_theme_stylebox_override("panel", _panel_style(Color("101a2eef"), Color("4577c4"), 14))
	var panel_scroll := ScrollContainer.new()
	panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	var column := VBoxContainer.new()
	var title := Label.new()
	title.text = "OCP Quick Panel เธขเธ— drag here to move"
	title.mouse_filter = Control.MOUSE_FILTER_STOP
	title.gui_input.connect(_on_panel_title_input)
	title.add_theme_color_override("font_color", Color("e8efff"))
	column.add_child(title)
	var status := Label.new()
	status.text = "Runtime active เธขเธ— Character package loaded"
	status.add_theme_color_override("font_color", Color("87e6b1"))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)
	var character_row := HBoxContainer.new()
	character_row.add_child(_make_button("Change Character", "Choose an installed signed .ocp package", _open_character_menu))
	column.add_child(character_row)
	var walk_row := HBoxContainer.new()
	walk_row.add_child(_make_button("Walk ←", "Walk to the left safe edge", _walk_to_left))
	walk_row.add_child(_make_button("Center", "Walk to the screen center", _walk_to_center))
	walk_row.add_child(_make_button("Walk →", "Walk to the right safe edge", _walk_to_right))
	column.add_child(walk_row)
	var animation_title := Label.new()
	animation_title.text = "Animations"
	animation_title.add_theme_color_override("font_color", Color("a8c7ff"))
	column.add_child(animation_title)
	var animation_scroll := ScrollContainer.new()
	animation_scroll.custom_minimum_size = Vector2(332, 150)
	animation_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	quick_animation_column = VBoxContainer.new()
	animation_scroll.add_child(quick_animation_column)
	_populate_animation_controls()
	column.add_child(animation_scroll)
	var emotion_row := HBoxContainer.new()
	for emotion: String in ["happy", "sad", "angry", "surprised"]:
		emotion_row.add_child(_make_button(emotion, "Preview " + emotion + " expression", _preview_emotion.bind(emotion)))
	column.add_child(emotion_row)
	var action_row := HBoxContainer.new()
	action_row.add_child(_make_button("Bubble", "Show a companion bubble", func() -> void: _show_local_bubble("Hello from OCP Companion!")))
	action_row.add_child(_make_button("Notify", "Show an in-app notification", func() -> void: _show_notification("OCP notification preview")))
	action_row.add_child(_make_button("Chat", "AI Chat placeholder", _open_chat_placeholder))
	action_row.add_child(_make_button("Close", "Close Quick Panel", _toggle_quick_panel))
	column.add_child(action_row)
	var note := Label.new()
	note.text = "Missing animation assets stay on idle and show an availability bubble."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	panel_scroll.add_child(column)
	quick_panel.add_child(panel_scroll)
	add_child(quick_panel)


func _setup_animation_menu() -> void:
	animation_menu = PopupMenu.new()
	animation_menu.name = "AnimationMenu"
	animation_menu.id_pressed.connect(_on_animation_menu_selected)
	add_child(animation_menu)
	_populate_animation_controls()


func _available_animation_names() -> PackedStringArray:
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim == null or anim.sprite_frames == null:
		return PackedStringArray()
	var names: PackedStringArray = anim.sprite_frames.get_animation_names()
	names.sort()
	return names


func _populate_animation_controls() -> void:
	var names: PackedStringArray = _available_animation_names()
	if animation_menu != null:
		animation_menu.clear()
		for index in names.size():
			animation_menu.add_item(names[index], index)
	if quick_animation_column != null:
		for child in quick_animation_column.get_children():
			child.queue_free()
		for animation_id: String in names:
			var action: Callable = _preview_animation.bind(animation_id)
			if animation_id == "walk_left":
				action = _walk_to_left
			elif animation_id == "walk_right":
				action = _walk_to_right
			var animation_button := _make_button("▶  " + animation_id, "Preview " + animation_id, action)
			animation_button.icon = _make_menu_icon(Color("6fa7ff"))
			animation_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			quick_animation_column.add_child(animation_button)


func _on_animation_menu_selected(item_id: int) -> void:
	var names: PackedStringArray = _available_animation_names()
	if item_id >= 0 and item_id < names.size():
		_preview_animation(names[item_id])


func _setup_character_menu() -> void:
	# Sprint A: use an in-window picker instead of PopupMenu. PopupMenu is a
	# separate native window and proved unreliable with a scaled transparent
	# overlay and mouse-passthrough polygons.
	character_menu = PopupMenu.new() # kept for compatibility; no longer shown
	character_menu.name = "CharacterMenuLegacy"
	add_child(character_menu)

	character_picker = PanelContainer.new()
	character_picker.name = "CharacterPicker"
	character_picker.z_index = 20
	character_picker.size = Vector2(430.0, 520.0)
	character_picker.visible = false
	character_picker.mouse_filter = Control.MOUSE_FILTER_STOP
	character_picker.add_theme_stylebox_override("panel", _panel_style(Color("101a2ef5"), Color("6fa7ff"), 14))
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "Change Character"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)
	header.add_child(_make_button("Close", "Close character picker", _close_character_picker))
	root.add_child(header)
	root.add_child(_make_button("Install .ocp", "Validate, install, activate and reload a character package", _open_character_install_dialog))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	character_picker_list = VBoxContainer.new()
	character_picker_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	character_picker_list.add_theme_constant_override("separation", 8)
	scroll.add_child(character_picker_list)
	root.add_child(scroll)
	character_picker.add_child(root)
	add_child(character_picker)

	character_install_dialog = FileDialog.new()
	character_install_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	character_install_dialog.access = FileDialog.ACCESS_FILESYSTEM
	character_install_dialog.filters = PackedStringArray(["*.ocp ; OCP character package"])
	character_install_dialog.file_selected.connect(_on_character_package_selected)
	add_child(character_install_dialog)


func _open_character_install_dialog() -> void:
	character_install_dialog.popup_centered_ratio(0.7)


func _clear_character_picker_list() -> void:
	for child in character_picker_list.get_children():
		character_picker_list.remove_child(child)
		child.free()


func _refresh_character_picker() -> void:
	_clear_character_picker_list()
	var repo := InstalledCharacterRepository.new()
	var installed: Array = repo.list_installed()
	var active: Dictionary = repo.get_active()
	if installed.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No installed character packages."
		character_picker_list.add_child(empty_label)
		return
	for raw in installed:
		if not raw is Dictionary:
			continue
		var item: Dictionary = raw
		var package_id := str(item.get("packageId", ""))
		var version := str(item.get("version", ""))
		var manifest: Dictionary = item.get("manifest", {})
		var display_name := str(manifest.get("name", package_id))
		var is_active := package_id == str(active.get("packageId", "")) and version == str(active.get("version", ""))
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 4)
		var label := Label.new()
		label.text = ("ACTIVE — " if is_active else "") + "%s  (%s @ %s)" % [display_name, package_id, version]
		card.add_child(label)
		var actions := HBoxContainer.new()
		var activate_button := _make_button("Active" if is_active else "Activate", "Use this character immediately", _activate_installed_character.bind(package_id, version))
		activate_button.disabled = is_active
		actions.add_child(activate_button)
		var uninstall_button := _make_button("Uninstall", "Remove this installed version", _uninstall_installed_character.bind(package_id, version))
		actions.add_child(uninstall_button)
		card.add_child(actions)
		character_picker_list.add_child(card)
		character_picker_list.add_child(HSeparator.new())


func _open_character_menu() -> void:
	_refresh_character_picker()
	character_picker.visible = true
	var viewport_size := _logical_viewport_size()
	character_picker.position = Vector2(
		clampf(companion_sprite.position.x - character_picker.size.x - 20.0, 12.0, maxf(12.0, viewport_size.x - character_picker.size.x - 12.0)),
		clampf(companion_sprite.position.y - 80.0, 12.0, maxf(12.0, viewport_size.y - character_picker.size.y - 12.0)))
	hover_toolbar.visible = false
	hover_visible = false
	_update_click_through()


func _close_character_picker() -> void:
	character_picker.visible = false
	_update_click_through()


func _activate_installed_character(package_id: String, version: String) -> void:
	var repo := InstalledCharacterRepository.new()
	if repo.find_exact(package_id, version).is_empty():
		_show_notification("Character is no longer installed: %s @ %s" % [package_id, version])
		_refresh_character_picker()
		return
	CharacterPackageInstaller.new().set_active(package_id, version)
	_reload_active_character()
	_refresh_character_picker()
	_show_notification("Active character: %s @ %s" % [package_id, version])


func _uninstall_installed_character(package_id: String, version: String) -> void:
	var repo := InstalledCharacterRepository.new()
	var active := repo.get_active()
	var was_active := package_id == str(active.get("packageId", "")) and version == str(active.get("version", ""))
	var removed: bool = repo.uninstall(package_id, version)
	if not removed:
		_show_notification("Uninstall failed: %s @ %s" % [package_id, version])
		return
	if was_active:
		var remaining: Array = repo.list_installed()
		if not remaining.is_empty() and remaining[0] is Dictionary:
			var fallback: Dictionary = remaining[0]
			CharacterPackageInstaller.new().set_active(str(fallback.get("packageId", "")), str(fallback.get("version", "")))
	_reload_active_character()
	_refresh_character_picker()
	_show_notification("Character uninstalled: %s @ %s" % [package_id, version])


func _on_character_menu_selected(_index: int) -> void:
	# Legacy callback retained for scene compatibility. The Sprint A picker uses
	# explicit buttons and no longer relies on PopupMenu item metadata.
	pass

func _open_animation_menu() -> void:
	animation_menu.position = get_viewport().get_mouse_position()
	animation_menu.popup()


func _preview_idle() -> void:
	_preview_animation("idle")
func _setup_notification() -> void:
	notification_panel = PanelContainer.new()
	notification_panel.name = "OcpNotification"
	notification_panel.position = Vector2(28, 386)
	notification_panel.size = Vector2(360, 58)
	notification_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	notification_panel.visible = false
	notification_panel.add_theme_stylebox_override("panel", _panel_style(Color("15233aef"), Color("4679c5"), 10))
	var label := Label.new()
	label.name = "Text"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notification_panel.add_child(label)
	add_child(notification_panel)


func _make_ocp_icon_image(size: int) -> Image:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var u := maxi(1, size / 32)
	var blue := Color("2877df")
	var light := Color("eff7ff")
	var dark := Color("19335e")
	_fill_rect(image, 2 * u, 2 * u, 28 * u, 28 * u, blue)
	_fill_rect(image, 7 * u, 8 * u, 18 * u, 16 * u, light)
	_fill_rect(image, 10 * u, 13 * u, 3 * u, 3 * u, dark)
	_fill_rect(image, 19 * u, 13 * u, 3 * u, 3 * u, dark)
	_fill_rect(image, 13 * u, 19 * u, 6 * u, 2 * u, dark)
	_fill_rect(image, 15 * u, 4 * u, 2 * u, 4 * u, light)
	return image


func _apply_ocp_window_icon() -> void:
	# `-Action Run` hosts the project in Godot.exe. Override its window icon at
	# runtime; an exported OCP executable is still needed to change its process
	# identity in the Windows taskbar group permanently.
	DisplayServer.set_icon(_make_ocp_icon_image(256))


func _make_tray_icon() -> Texture2D:
	if tray_icon == null:
		tray_icon = ImageTexture.create_from_image(_make_ocp_icon_image(32))
	return tray_icon

func _make_menu_icon(color: Color) -> Texture2D:
	var image := Image.create(20, 20, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	_fill_rect(image, 3, 3, 14, 14, color)
	_fill_rect(image, 7, 7, 6, 6, Color(0.95, 0.98, 1.0, 1.0))
	return ImageTexture.create_from_image(image)

func _add_tray_item(label: String, action: int, color: Color) -> void:
	NativeMenu.add_icon_item(tray_menu_rid, _make_menu_icon(color), label, _on_native_tray_action, Callable(), action)


func _setup_system_tray() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR):
		push_warning("System tray is unavailable on this display server")
		return
	if not NativeMenu.has_feature(NativeMenu.FEATURE_POPUP_MENU):
		push_warning("Native tray menu is unavailable on this display server")
		return
	tray_menu_rid = NativeMenu.create_menu()
	_add_tray_item("Show companion", TRAY_SHOW, Color("56a8ff"))
	_add_tray_item("Hide to tray", TRAY_HIDE, Color("7b8ba9"))
	NativeMenu.add_separator(tray_menu_rid)
	_add_tray_item("Dashboard", TRAY_DASHBOARD, Color("5eead4"))
	_add_tray_item("OCP Quick Panel", TRAY_PANEL, Color("60a5fa"))
	_add_tray_item("Chat / AI Command", TRAY_CHAT, Color("38bdf8"))
	_add_tray_item("AI Provider Keys", TRAY_AI_PROVIDER_KEYS, Color("22c55e"))
	_add_tray_item("Change Character", TRAY_SWITCH_CHARACTER, Color("c084fc"))
	_add_tray_item("Character Studio", TRAY_CHARACTER_STUDIO, Color("a78bfa"))
	_add_tray_item("Marketplace", TRAY_MARKETPLACE, Color("fbbf24"))
	_add_tray_item("Plugins", TRAY_PLUGINS, Color("f472b6"))
	NativeMenu.add_separator(tray_menu_rid)
	_add_tray_item("Show bubble", TRAY_BUBBLE, Color("38bdf8"))
	_add_tray_item("Show notification", TRAY_NOTIFICATION, Color("34d399"))
	_add_tray_item("Check for updates", TRAY_CHECK_UPDATES, Color("f59e0b"))
	_add_tray_item("About OCP", TRAY_ABOUT, Color("94a3b8"))
	NativeMenu.add_separator(tray_menu_rid)
	_add_tray_item("Exit OCP Runtime", TRAY_EXIT, Color("fb7185"))
	tray_indicator_id = DisplayServer.create_status_indicator(_make_tray_icon(), "OCP Desktop Runtime", _on_tray_activated)
	if tray_indicator_id != DisplayServer.INVALID_INDICATOR_ID:
		DisplayServer.status_indicator_set_menu(tray_indicator_id, tray_menu_rid)

func _on_native_tray_action(action: Variant) -> void:
	_on_tray_menu_selected(int(action))


func _dispose_runtime_ui() -> void:
	for node in [hover_toolbar, quick_panel, quick_panel_backdrop, character_picker, notification_panel, animation_menu, character_menu, character_install_dialog]:
		if is_instance_valid(node):
			node.queue_free()
	for anim in companion_anims.values():
		if is_instance_valid(anim):
			anim.stop()
			anim.sprite_frames = null
			anim.queue_free()
	companion_anims.clear()
	companion_bubbles.clear()
	tray_icon = null

func _shutdown_runtime() -> void:
	if shutdown_requested:
		return
	shutdown_requested = true
	_save_companion_desktop_position()
	_dispose_runtime_ui()
	# queue_free() is processed on the next frame, before the scene tree shuts down.
	await get_tree().process_frame
	get_tree().quit()

func _exit_tree() -> void:
	if tray_indicator_id != DisplayServer.INVALID_INDICATOR_ID:
		DisplayServer.delete_status_indicator(tray_indicator_id)
		tray_indicator_id = DisplayServer.INVALID_INDICATOR_ID
	if tray_menu_rid.is_valid():
		NativeMenu.free_menu(tray_menu_rid)
		tray_menu_rid = RID()

func _on_tray_activated(button: int, _screen_position: Vector2i) -> void:
	if button == MOUSE_BUTTON_LEFT:
		_restore_from_tray()


func _on_tray_menu_selected(id: int) -> void:
	match id:
		TRAY_SHOW:
			_restore_from_tray()
		TRAY_HIDE:
			_hide_companion()
		TRAY_DASHBOARD:
			_show_companion()
			_show_notification("Dashboard is available in the OCP Quick Panel")
		TRAY_PANEL:
			_show_companion()
			if not quick_panel.visible:
				_toggle_quick_panel()
		TRAY_CHAT:
			_show_companion()
			_open_chat_placeholder()
		TRAY_AI_PROVIDER_KEYS:
			_show_companion()
			_show_notification("AI keys: use Settings guide; keys remain in Windows Credential Manager")
		TRAY_SWITCH_CHARACTER:
			_show_companion()
			_open_character_menu()
		TRAY_CHARACTER_STUDIO:
			_show_companion()
			_show_notification("Character Studio is planned for the full OCP release")
		TRAY_MARKETPLACE:
			_show_companion()
			_show_notification("Marketplace is not connected in this Runtime POC")
		TRAY_PLUGINS:
			_show_companion()
			_show_notification("Plugin management is not connected in this Runtime POC")
		TRAY_BUBBLE:
			_show_companion()
			_show_local_bubble("Hello from the OCP tray!")
		TRAY_NOTIFICATION:
			_show_companion()
			_show_notification("OCP Runtime is active")
		TRAY_CHECK_UPDATES:
			_show_companion()
			_show_notification("Update check is not connected in this Runtime POC")
		TRAY_ABOUT:
			_show_companion()
			_show_notification("OCP Desktop Runtime - Package Contract v0.1")
		TRAY_EXIT:
			_shutdown_runtime()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown_runtime()

func _toggle_quick_panel() -> void:
	quick_panel.visible = not quick_panel.visible
	quick_panel_backdrop.visible = quick_panel.visible
	if quick_panel.visible and character_picker != null:
		character_picker.visible = false
	if quick_panel.visible:
		# Open at the same anchor as the hover menu; do not relocate the companion.
		_layout_hover_toolbar()
		quick_panel.position = hover_toolbar.position
		_show_companion()
		_show_notification("Quick Panel opened")


func _show_companion() -> void:
	runtime_hidden_to_tray = false
	companion_sprite.visible = true
	_sync_companion_anim_position()
	_update_click_through()


func _restore_from_tray() -> void:
	# Restore only the companion. Transient UI must never auto-open after tray
	# restore; Quick Panel and character picker require an explicit command.
	runtime_hidden_to_tray = false
	quick_panel.visible = false
	quick_panel_backdrop.visible = false
	if character_picker != null:
		character_picker.visible = false
	hover_toolbar.visible = false
	hover_visible = false
	hover_hide_deadline_ms = 0
	companion_sprite.visible = true
	_sync_companion_anim_position()
	_update_click_through()


func _hide_companion() -> void:
	_save_companion_desktop_position()
	runtime_hidden_to_tray = true
	quick_panel.visible = false
	quick_panel_backdrop.visible = false
	if character_picker != null:
		character_picker.visible = false
	hover_toolbar.visible = false
	hover_visible = false
	hover_hide_deadline_ms = 0
	companion_sprite.visible = false
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim != null:
		anim.visible = false
	_update_click_through()

func _show_local_bubble(text: String, duration_seconds := 4.0) -> void:
	var bubble := _bubble_for("default")
	var label: Label = bubble["label"]
	var panel: PanelContainer = bubble["panel"]
	label.text = text.left(240)
	panel.visible = true
	await get_tree().create_timer(duration_seconds).timeout
	if label.text == text.left(240):
		label.text = ""
		panel.visible = false


func _show_notification(text: String, duration_seconds := 4.0) -> void:
	var label := notification_panel.get_node("Text") as Label
	label.text = text.left(180)
	_show_local_bubble(text.left(80), minf(duration_seconds, 2.0))
	notification_panel.visible = true
	await get_tree().create_timer(duration_seconds).timeout
	if label.text == text.left(180):
		notification_panel.visible = false
	notification_panel.add_theme_stylebox_override("panel", _panel_style(Color("15233aef"), Color("4679c5"), 10))

func _open_chat_placeholder() -> void:
	_show_local_bubble("AI Chat is not connected in this Runtime POC.")
	bridge.capture_input("click", "open-chat", "companion:default")


func _preview_animation(animation_id: String) -> void:
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim == null or not anim.sprite_frames.has_animation(animation_id):
		_show_local_bubble("Animation unavailable in this package: " + animation_id)
		return
	anim.play(animation_id)
	_show_notification("Previewing animation: " + animation_id)
	if not anim.sprite_frames.get_animation_loop(animation_id):
		anim.animation_finished.connect(func() -> void: anim.play(anim.get_meta("expression", "idle_neutral")), CONNECT_ONE_SHOT)


func _preview_emotion(emotion: String) -> void:
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim == null:
		return
	var expression := "idle_" + emotion
	if anim.sprite_frames.has_animation(expression):
		anim.set_meta("expression", expression)
		anim.play(expression)
		_show_notification("Previewing expression: " + emotion)
		return
	# Bible character/1 uses one-shot emotion clip names directly.
	if anim.sprite_frames.has_animation(emotion):
		_preview_animation(emotion)
		_show_local_bubble(emotion.capitalize() + "!", 1.5)
		return
	_show_local_bubble("Expression unavailable in this package: " + emotion)


# --- I8A slice 1b: code-generated placeholder sprite-sheet ---
# Proves the AnimatedSprite2D pipeline + real `animation_finished` completion
# before any real character-package art exists. A real `.ocp` sprite/rig (I8B)
# replaces `_build_placeholder_frames()`; every other line here is unchanged เนโฌโ€
# the animation-request เนยโ€ play เนยโ€ report-completion wiring is the real pipeline.
# SKELETON: `Image.create` / `ImageTexture.create_from_image` verified on the
# first live build (Godot 4.7); if `Image.create` warns as deprecated, swap to
# `Image.create_empty` with the same args.

const SPRITE_PX := 96

func _fill_rect(img: Image, x: int, y: int, w: int, h: int, col: Color) -> void:
	for iy in range(maxi(y, 0), mini(y + h, img.get_height())):
		for ix in range(maxi(x, 0), mini(x + w, img.get_width())):
			img.set_pixel(ix, iy, col)

# `mouth`: the expression the Expression module renders for an emotion เนโฌโ€
# 0 neutral, 1 smile (happy), 2 frown (sad), 3 open (excited), 4 small (worried).
func _make_frame(base: Color, arm_up: bool, eyes_open: bool, mouth: int) -> ImageTexture:
	var img := Image.create(SPRITE_PX, SPRITE_PX, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0)) # transparent background
	_fill_rect(img, 24, 30, 48, 54, base)                        # body
	_fill_rect(img, 28, 12, 40, 26, base.lightened(0.15))        # head
	var eye_h: int = 6 if eyes_open else 2
	var eye_col: Color = Color(0.1, 0.1, 0.12) if eyes_open else base.darkened(0.25)
	_fill_rect(img, 36, 20, 6, eye_h, eye_col)                   # left eye
	_fill_rect(img, 54, 20, 6, eye_h, eye_col)                   # right eye
	var m := Color(0.15, 0.08, 0.1)                              # mouth
	match mouth:
		1: # smile: line + up-turned corners
			_fill_rect(img, 43, 32, 12, 2, m); _fill_rect(img, 41, 30, 2, 2, m); _fill_rect(img, 55, 30, 2, 2, m)
		2: # frown: line + down-turned corners
			_fill_rect(img, 43, 32, 12, 2, m); _fill_rect(img, 41, 34, 2, 2, m); _fill_rect(img, 55, 34, 2, 2, m)
		3: # open (excited)
			_fill_rect(img, 44, 30, 10, 6, m)
		4: # small (worried)
			_fill_rect(img, 46, 32, 6, 2, m)
		_: # neutral line
			_fill_rect(img, 44, 32, 10, 2, m)
	var arm_y: int = 18 if arm_up else 52
	_fill_rect(img, 70, arm_y, 12, 26, base.darkened(0.1))       # waving arm
	return ImageTexture.create_from_image(img)

func _build_placeholder_frames() -> SpriteFrames:
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	var body := Color(0.55, 0.75, 1.0)
	# One idle expression per emotion (blink loop) เนโฌโ€ the Expression module plays
	# the one matching `emotion-changed` (เธขเธ4.1); unknown emotions fall back to
	# neutral. Plus a plain "idle" alias (= neutral) so a เธขเธ7 `idle` request resolves.
	for emotion: String in EMOTION_MOUTHS:
		var mouth: int = EMOTION_MOUTHS[emotion]
		var ename := "idle_" + emotion
		sf.add_animation(ename)
		sf.set_animation_loop(ename, true)
		sf.set_animation_speed(ename, 2.0)
		sf.add_frame(ename, _make_frame(body, false, true, mouth))
		sf.add_frame(ename, _make_frame(body, false, false, mouth))
	sf.add_animation("idle")
	sf.set_animation_loop("idle", true)
	sf.set_animation_speed("idle", 2.0)
	sf.add_frame("idle", _make_frame(body, false, true, 0))
	sf.add_frame("idle", _make_frame(body, false, false, 0))
	# wave: one-shot arm up/down (เธขเธ7 reactive verb the demo rule fires)
	sf.add_animation("wave")
	sf.set_animation_loop("wave", false)
	sf.set_animation_speed("wave", 6.0)
	for up: bool in [true, false, true, false]:
		sf.add_frame("wave", _make_frame(body, up, true, 0))
	return sf

func _default_character_runtime() -> Dictionary:
	return {
		"bubbleAnchor": Vector2(0.0, -176.0),
		"scale": SPRITE_RENDER_SCALE,
		"hitbox": Rect2(Vector2.ZERO, SPRITE_SIZE),
	}


func _vector2_from_json(value, fallback: Vector2) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


func _rect2_from_json(value, fallback: Rect2) -> Rect2:
	if value is Array and value.size() >= 4:
		return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	if value is Dictionary:
		var pos := _vector2_from_json(value.get("position", []), fallback.position)
		var size := _vector2_from_json(value.get("size", []), fallback.size)
		return Rect2(pos, size)
	return fallback


func _active_character_entry_path() -> String:
	var active: Dictionary = InstalledCharacterRepository.new().get_active()
	if active.is_empty():
		return ""
	var root := str(active.get("path", ""))
	var manifest: Dictionary = active.get("manifest", {})
	var entry_rel := str(manifest.get("entry", "character.json"))
	var candidate := root.path_join(entry_rel)
	if FileAccess.file_exists(candidate):
		return candidate
	var legacy := root.path_join("character.json")
	return legacy if FileAccess.file_exists(legacy) else ""


func _load_active_character_runtime() -> Dictionary:
	var config := _default_character_runtime()
	var entry_path := _active_character_entry_path()
	if entry_path.is_empty():
		return config
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not parsed is Dictionary:
		return config
	var entry: Dictionary = parsed
	var runtime_raw = entry.get("runtime", {})
	var runtime: Dictionary = runtime_raw if runtime_raw is Dictionary else {}
	var bubble_value = runtime.get("bubbleAnchor", entry.get("bubbleAnchor", []))
	var scale_value = runtime.get("scale", entry.get("scale", SPRITE_RENDER_SCALE))
	var hitbox_value = runtime.get("hitbox", entry.get("hitbox", []))
	config["bubbleAnchor"] = _vector2_from_json(bubble_value, config["bubbleAnchor"])
	config["scale"] = clampf(float(scale_value), 0.05, 4.0)
	config["hitbox"] = _rect2_from_json(hitbox_value, config["hitbox"])
	return config


func _apply_active_character_runtime() -> void:
	active_character_runtime = _load_active_character_runtime()
	_apply_active_monitor_dpi_scale(true)
	_layout_bubbles()
	_update_click_through()

func _companion_host_size() -> Vector2:
	return SPRITE_SIZE * active_monitor_scale_ratio

func _rendered_frame_half_extent() -> float:
	return RENDERED_FRAME_HALF_EXTENT * active_monitor_scale_ratio

func _monitor_scale_for_screen(screen_index: int) -> float:
	var scale_value := DisplayServer.screen_get_scale(screen_index)
	if scale_value <= 0.0:
		var dpi := DisplayServer.screen_get_dpi(screen_index)
		scale_value = float(dpi) / 96.0 if dpi > 0 else 1.0
	return clampf(scale_value, 0.75, 4.0)

func _monitor_index_for_local_point(point: Vector2) -> int:
	for index in monitor_usable_rects_local.size():
		if monitor_usable_rects_local[index].has_point(point):
			return index
	var best_index := 0
	var best_distance := INF
	for index in monitor_usable_rects_local.size():
		var rect := monitor_usable_rects_local[index]
		var closest := Vector2(clampf(point.x, rect.position.x, rect.end.x), clampf(point.y, rect.position.y, rect.end.y))
		var distance := point.distance_squared_to(closest)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	return best_index

func _apply_active_monitor_dpi_scale(force: bool = false) -> void:
	if monitor_usable_rects_local.is_empty():
		return
	var old_size := _companion_host_size()
	var center := companion_sprite.position + old_size / 2.0
	var next_index := _monitor_index_for_local_point(center)
	if not force and next_index == active_monitor_index:
		return
	active_monitor_index = next_index
	active_monitor_scale = monitor_scale_factors[next_index] if next_index < monitor_scale_factors.size() else DESKTOP_CANVAS_SCALE
	active_monitor_scale_ratio = active_monitor_scale / DESKTOP_CANVAS_SCALE
	var new_size := _companion_host_size()
	companion_sprite.size = new_size
	companion_sprite.position = center - new_size / 2.0
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim != null:
		var character_scale := float(active_character_runtime.get("scale", SPRITE_RENDER_SCALE)) * active_monitor_scale_ratio
		anim.scale = Vector2(character_scale, character_scale)
	_sync_companion_anim_position()
	_layout_hover_toolbar()
	_layout_bubbles()
	_update_click_through()
	print("OCP: active monitor DPI -> index=", active_monitor_index, " dpi=", monitor_dpi_values[active_monitor_index] if active_monitor_index < monitor_dpi_values.size() else 0, " scale=", active_monitor_scale, " ratio=", active_monitor_scale_ratio)


func _reload_active_character() -> void:
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim == null:
		return
	var frames: SpriteFrames = _character_frames()
	if frames == null:
		frames = _build_placeholder_frames()
	anim.stop()
	anim.sprite_frames = frames
	_apply_active_character_runtime()
	var resting := "idle_neutral" if frames.has_animation("idle_neutral") else ("idle" if frames.has_animation("idle") else "")
	if resting != "":
		anim.set_meta("expression", resting)
		anim.play(resting)
	_populate_animation_controls()
	_sync_companion_anim_position()
	_layout_hover_toolbar()
	_layout_bubbles()
	_update_click_through()
	print("OCP: active character reloaded; animations=", frames.get_animation_names())


func _companion_hit_rect() -> Rect2:
	var configured_value = active_character_runtime.get("hitbox", Rect2(Vector2.ZERO, SPRITE_SIZE))
	var configured: Rect2 = configured_value if configured_value is Rect2 else Rect2(Vector2.ZERO, SPRITE_SIZE)
	return Rect2(companion_sprite.global_position + configured.position * active_monitor_scale_ratio, configured.size * active_monitor_scale_ratio)


# I8B-2 + Step 4 manifest-aware loader:
# Priority order:
#   1. Active installed character from user://runtime/state.json
#   2. OCP_CHARACTER_DIR env var (legacy / dev override)
#   3. Code-generated placeholder
func _character_frames() -> SpriteFrames:
	# เนโ€โฌเนโ€โฌ 1. Active installed package เนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌ
	var state_file := "user://runtime/state.json"
	if FileAccess.file_exists(state_file):
		var state_text := FileAccess.get_file_as_string(state_file)
		var state = JSON.parse_string(state_text)
		if state is Dictionary:
			var active = state.get("activeCharacter", null)
			if active is Dictionary:
				var pkg_id  := str(active.get("packageId", ""))
				var version := str(active.get("version",   ""))
				if not pkg_id.is_empty() and not version.is_empty():
					var pkg_root := "user://packages/characters/%s/%s" % [pkg_id, version]
					var frames := _load_frames_from_manifest(pkg_root)
					if frames != null:
						print("companion: loaded installed character '%s@%s'" % [pkg_id, version])
						return frames

	# เนโ€โฌเนโ€โฌ 2. Dev env-var override (legacy) เนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌ
	var dir := OS.get_environment("OCP_CHARACTER_DIR")
	if dir != "":
		if not FileAccess.file_exists(dir.path_join("character.json")):
			_bake_sample_package(dir)
		# Try manifest-first, fall back to bare character.json for legacy dirs
		var frames := _load_frames_from_manifest(dir)
		if frames == null:
			frames = _load_frames_from_package(dir)
		if frames != null:
			return frames

	# เนโ€โฌเนโ€โฌ 3. Placeholder เนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌ
	return _build_placeholder_frames()

# Author a minimal REAL character package on disk (a sprite-sheet PNG + a
# character/1 `character.json`) from procedural frames เนโฌโ€ a stand-in until a
# creator ships a signed `.ocp`. The runtime then LOADS it like any package,
# proving the loadเนยโ€render path end to end.
# SKELETON (verify on first live run): Image.blit_rect / save_png /
# load_from_file + AtlasTexture regions are the risky Godot 4.7 surfaces.
func _bake_sample_package(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var body := Color(0.55, 0.75, 1.0)
	var frames := [
		_make_frame(body, false, true, 1), _make_frame(body, false, false, 1), # idle 0,1 (smile)
		_make_frame(body, true, true, 1), _make_frame(body, false, true, 1),    # wave 2,3
		_make_frame(body, true, true, 1), _make_frame(body, false, true, 1),    # wave 4,5
	]
	var sheet := Image.create(SPRITE_PX * frames.size(), SPRITE_PX, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0, 0, 0, 0))
	for i in frames.size():
		sheet.blit_rect(frames[i].get_image(), Rect2i(0, 0, SPRITE_PX, SPRITE_PX), Vector2i(i * SPRITE_PX, 0))
	sheet.save_png(dir.path_join("sprite.png"))
	var entry := {
		"schema": "character/1", "name": "Aiko (baked)", "renderer": "sprite-sheet-2d",
		"sprites": [{"id": "body", "path": "sprite.png", "frameSize": [SPRITE_PX, SPRITE_PX]}],
		"animations": {
			"idle": {"frames": [0, 1], "fps": 2, "loop": true},
			"wave": {"frames": [2, 3, 4, 5], "fps": 6, "loop": false},
		},
	}
	var f := FileAccess.open(dir.path_join("character.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(entry))
	f.close()

# Build SpriteFrames by reading manifest.json first เนยโ€ resolving entry path เนยโ€
# loading character/1 JSON เนยโ€ building frames. This is the production flow
# matching the installed directory layout (Step 4 manifest-aware loader).
func _load_frames_from_manifest(package_root: String) -> SpriteFrames:
	var manifest_path := package_root.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return null  # no manifest เนโฌโ€ caller may try legacy path
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary:
		return null
	var entry_rel := str((manifest as Dictionary).get("entry", ""))
	if entry_rel.is_empty():
		return null
	var entry_path := package_root.path_join(entry_rel)
	if not FileAccess.file_exists(entry_path):
		return null
	return _load_frames_from_package_at(package_root, entry_path)

# Load SpriteFrames from a character/1 JSON at `entry_path`, with assets
# resolved relative to `package_root`.
# Tolerant of real-world packages: frameSize may equal full image size (1 frame),
# animations dict may be absent, extra JSON fields (expressions, authorship) are ignored.
func _normalized_sprite_cell(sheet_image: Image, cell_rect: Rect2i, frame_size: Vector2i) -> Texture2D:
	var cell := sheet_image.get_region(cell_rect)
	var used := cell.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return ImageTexture.create_from_image(cell)
	var normalized := Image.create(frame_size.x, frame_size.y, false, Image.FORMAT_RGBA8)
	normalized.fill(Color(0, 0, 0, 0))
	# Keep every frame centered horizontally and aligned to the same baseline.
	var destination := Vector2i(maxi(0, (frame_size.x - used.size.x) / 2), maxi(0, frame_size.y - used.size.y - 8))
	normalized.blit_rect(cell, used, destination)
	return ImageTexture.create_from_image(normalized)

func _load_frames_from_package_at(package_root: String, entry_path: String) -> SpriteFrames:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not parsed is Dictionary:
		push_warning("_load_frames_from_package_at: entry is not a JSON object: " + entry_path)
		return null
	var entry: Dictionary = parsed
	var sprite_list: Array = entry.get("sprites", [])
	if sprite_list.is_empty():
		push_warning("_load_frames_from_package_at: no sprites in entry")
		return null

	# เนโ€โฌเนโ€โฌ Load every declared sprite sheet เนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌ
	var sheets: Dictionary = {}   # id -> {tex, fw, fh, cols, rows}
	var default_id := ""
	for sprite_raw in sprite_list:
		if not sprite_raw is Dictionary:
			continue
		var sprite: Dictionary = sprite_raw
		var sid := str(sprite.get("id", ""))
		if sid.is_empty():
			continue

		var img_path := package_root.path_join(str(sprite.get("path", "")))
		var img := Image.load_from_file(img_path)
		if img == null:
			push_warning("_load_frames_from_package_at: cannot load image: " + img_path)
			continue

		# frameSize from JSON; clamp to actual image if larger.
		var fs = sprite.get("frameSize", [])
		var fw: int = int(fs[0]) if (fs is Array and fs.size() >= 2) else img.get_width()
		var fh: int = int(fs[1]) if (fs is Array and fs.size() >= 2) else img.get_height()
		fw = clampi(fw, 1, img.get_width())   # never larger than image
		fh = clampi(fh, 1, img.get_height())

		# cols/rows: use integer division; a single full-image frame gives cols=1.
		var cols: int = maxi(1, img.get_width()  / fw)
		var rows: int = maxi(1, img.get_height() / fh)

		var normalized_frames: Array = []
		for frame_idx in range(cols * rows):
			var cell_rect := Rect2i((frame_idx % cols) * fw, (frame_idx / cols) * fh, fw, fh)
			normalized_frames.append(_normalized_sprite_cell(img, cell_rect, Vector2i(fw, fh)))

		sheets[sid] = {
			"frames": normalized_frames,
			"fw": fw,
			"fh": fh,
			"cols": cols,
			"rows": rows,
		}
		if default_id == "":
			default_id = sid

	if sheets.is_empty():
		push_warning("_load_frames_from_package_at: no sheets loaded from: " + entry_path)
		return null

	# เนโ€โฌเนโ€โฌ Build SpriteFrames เนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌเนโ€โฌ
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")

	var animations_raw = entry.get("animations", {})
	var animations: Dictionary = animations_raw if animations_raw is Dictionary else {}

	for anim_name: String in animations:
		var clip_raw = animations[anim_name]
		if not clip_raw is Dictionary:
			continue
		var clip: Dictionary = clip_raw

		# Resolve sprite sheet: clip.sprite > default
		# Note: PackageBuilder may write sprite:null when no sheet selected
		var sid_raw = clip.get("sprite", null)
		var sid: String = str(sid_raw) if (sid_raw != null and str(sid_raw) != "null") else ""
		if sid.is_empty() or not sheets.has(sid):
			sid = default_id
		var sheet: Dictionary = sheets[sid]

		sf.add_animation(anim_name)
		sf.set_animation_loop(anim_name, bool(clip.get("loop", false)))
		# Character/2 authoring owns playback timing. Do not silently cap package
		# FPS (the old 2.5/6 FPS cap stretched 4-second Studio animations to 8+
		# seconds). Keep only a defensive bound against malformed package data.
		var requested_fps := float(clip.get("fps", 8.0))
		sf.set_animation_speed(anim_name, clampf(requested_fps, 0.1, 60.0))

		var frames_raw = clip.get("frames", [])
		var frames_arr: Array = frames_raw if frames_raw is Array else []
		if frames_arr.is_empty():
			# No frame list เนโฌโ€ use frame 0 (full image or first cell)
			frames_arr = [0]


		var max_frame: int = int(sheet["cols"]) * int(sheet["rows"])
		for idx_raw in frames_arr:
			var idx: int = clampi(int(idx_raw), 0, maxi(0, max_frame - 1))
			var normalized_frames: Array = sheet["frames"]
			sf.add_frame(anim_name, normalized_frames[idx])

	# If no animations were declared, create a static idle from first sheet
	if sf.get_animation_names().size() == 0:
		var sheet: Dictionary = sheets[default_id]
		sf.add_animation("idle")
		sf.set_animation_loop("idle", true)
		sf.set_animation_speed("idle", 2.0)
		var normalized_frames: Array = sheet["frames"]
		sf.add_frame("idle", normalized_frames[0])

	# Always alias idle_neutral เนยโ€ idle for the expression system
	if not sf.has_animation("idle_neutral") and sf.has_animation("idle"):
		sf.add_animation("idle_neutral")
		sf.set_animation_loop("idle_neutral", true)
		sf.set_animation_speed("idle_neutral", 2.0)
		for i in sf.get_frame_count("idle"):
			sf.add_frame("idle_neutral", sf.get_frame_texture("idle", i))
	return sf

# Legacy bare-directory loader (no manifest.json) เนโฌโ€ kept for OCP_CHARACTER_DIR
# compat and _bake_sample_package output.
func _load_frames_from_package(dir: String) -> SpriteFrames:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("character.json")))
	if not parsed is Dictionary:
		return null
	var entry: Dictionary = parsed
	var sprite_list: Array = entry.get("sprites", [])
	if sprite_list.is_empty():
		return null
	# I8C-2 multi-sheet: load EVERY declared sprite sheet เนโฌโ€ id -> {tex, fw, fh, cols}.
	# Each animation picks its source sheet via `clip.sprite` (default = first).
	var sheets: Dictionary = {}
	var default_id := ""
	for sprite: Dictionary in sprite_list:
		var sid := str(sprite["id"])
		var fw: int = int(sprite["frameSize"][0])
		var fh: int = int(sprite["frameSize"][1])
		var img := Image.load_from_file(dir.path_join(str(sprite["path"])))
		if img == null or fw <= 0 or fh <= 0 or img.get_width() % fw != 0 or img.get_height() % fh != 0:
			continue
		var cols: int = img.get_width() / fw
		if cols <= 0:
			continue
		sheets[sid] = {"tex": ImageTexture.create_from_image(img), "fw": fw, "fh": fh, "cols": cols}
		if default_id == "":
			default_id = sid
	if sheets.is_empty():
		return null
	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")
	for name: String in entry["animations"]:
		var clip: Dictionary = entry["animations"][name]
		var sid: String = str(clip.get("sprite", default_id))
		if not sheets.has(sid):
			sid = default_id
		var sheet: Dictionary = sheets[sid]
		sf.add_animation(name)
		sf.set_animation_loop(name, bool(clip.get("loop", false)))
		sf.set_animation_speed(name, float(clip.get("fps", 4.0)))
		for idx in clip["frames"]:
			var at := AtlasTexture.new()
			at.atlas = sheet["tex"]
			at.region = Rect2((int(idx) % int(sheet["cols"])) * int(sheet["fw"]), (int(idx) / int(sheet["cols"])) * int(sheet["fh"]), int(sheet["fw"]), int(sheet["fh"]))
			sf.add_frame(name, at)
	# The Expression module falls back to `idle_neutral`; alias it to `idle` so a
	# package without per-emotion expression frames still has a resting animation.
	if not sf.has_animation("idle_neutral") and sf.has_animation("idle"):
		sf.add_animation("idle_neutral")
		sf.set_animation_loop("idle_neutral", true)
		sf.set_animation_speed("idle_neutral", 2.0)
		for i in sf.get_frame_count("idle"):
			sf.add_frame("idle_neutral", sf.get_frame_texture("idle", i))
	return sf

func _attach_placeholder_sprite(companion_id: String, host: ColorRect) -> void:
	var anim := AnimatedSprite2D.new()
	anim.sprite_frames = _character_frames()
	anim.centered = true
	anim.scale = Vector2(SPRITE_RENDER_SCALE, SPRITE_RENDER_SCALE)
	anim.visible = true
	anim.z_index = host.z_index + 1
	add_child(anim)
	host.color = Color(0.05, 0.15, 0.3, 0.20)
	companion_anims[companion_id] = anim
	# `expression` meta = the resting idle to return to after a one-shot (wave).
	anim.set_meta("expression", "idle_neutral")
	anim.play("idle_neutral")
	_sync_companion_anim_position()
	print("OCP: attached companion anim", companion_id, "visible=", anim.visible, "pos=", anim.position, "frames=", anim.sprite_frames, "animation_names=", anim.sprite_frames.get_animation_names())
	if not anim.is_playing():
		print("OCP: companion anim is not playing, current_animation=", anim.animation)


func _companion_safe_position(position: Vector2) -> Vector2:
	# During drag, permit movement throughout the bounding rectangle of the
	# virtual desktop. A drop in a monitor gap is corrected on release.
	var viewport_size := _logical_viewport_size()
	var host_size := _companion_host_size()
	var extent := _rendered_frame_half_extent()
	var min_position := Vector2(extent - host_size.x / 2.0, extent - host_size.y / 2.0)
	var max_position := Vector2(viewport_size.x - extent - host_size.x / 2.0, viewport_size.y - extent - host_size.y / 2.0)
	return Vector2(
		clampf(position.x, min_position.x, maxf(min_position.x, max_position.x)),
		clampf(position.y, min_position.y, maxf(min_position.y, max_position.y)))

func _companion_position_clamped_to_monitor(position: Vector2, monitor_rect: Rect2) -> Vector2:
	var host_size := _companion_host_size()
	var extent := _rendered_frame_half_extent()
	var min_offset := Vector2(extent - host_size.x / 2.0, extent - host_size.y / 2.0)
	var max_offset := Vector2(extent + host_size.x / 2.0, extent + host_size.y / 2.0)
	var minimum := monitor_rect.position + min_offset
	var maximum := monitor_rect.end - max_offset
	return Vector2(
		clampf(position.x, minimum.x, maxf(minimum.x, maximum.x)),
		clampf(position.y, minimum.y, maxf(minimum.y, maximum.y)))

func _snap_companion_to_nearest_monitor() -> void:
	if monitor_usable_rects_local.is_empty():
		companion_sprite.position = _companion_safe_position(companion_sprite.position)
		return
	var center := companion_sprite.position + _companion_host_size() / 2.0
	var best_position := companion_sprite.position
	var best_distance := INF
	for monitor_rect: Rect2 in monitor_usable_rects_local:
		var candidate := _companion_position_clamped_to_monitor(companion_sprite.position, monitor_rect)
		# The nearest monitor is the one requiring the smallest correction to
		# place the complete rendered character inside its usable rectangle.
		var distance := candidate.distance_squared_to(companion_sprite.position)
		if monitor_rect.has_point(center):
			distance *= 0.25
		if distance < best_distance:
			best_distance = distance
			best_position = candidate
	companion_sprite.position = best_position
	_sync_companion_anim_position()

func _virtual_desktop_rect() -> Rect2i:
	var count := DisplayServer.get_screen_count()
	if count <= 0:
		return DisplayServer.screen_get_usable_rect()
	var merged := DisplayServer.screen_get_usable_rect(0)
	for screen_index in range(1, count):
		merged = merged.merge(DisplayServer.screen_get_usable_rect(screen_index))
	return merged

func _refresh_monitor_usable_rects() -> void:
	monitor_usable_rects_local.clear()
	monitor_scale_factors.clear()
	monitor_dpi_values.clear()
	var count := DisplayServer.get_screen_count()
	for screen_index in range(count):
		var rect_i := DisplayServer.screen_get_usable_rect(screen_index)
		var local_position := (Vector2(rect_i.position) - Vector2(virtual_desktop_origin)) / DESKTOP_CANVAS_SCALE
		var local_size := Vector2(rect_i.size) / DESKTOP_CANVAS_SCALE
		monitor_usable_rects_local.append(Rect2(local_position, local_size))
		monitor_scale_factors.append(_monitor_scale_for_screen(screen_index))
		monitor_dpi_values.append(DisplayServer.screen_get_dpi(screen_index))

func _overlay_to_desktop_position(local_position: Vector2) -> Vector2:
	return Vector2(virtual_desktop_origin) + local_position * DESKTOP_CANVAS_SCALE

func _desktop_to_overlay_position(desktop_position: Vector2) -> Vector2:
	return (desktop_position - Vector2(virtual_desktop_origin)) / DESKTOP_CANVAS_SCALE

func _load_saved_companion_desktop_position() -> void:
	if not FileAccess.file_exists(RUNTIME_STATE_FILE):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(RUNTIME_STATE_FILE))
	if not (parsed is Dictionary):
		return
	var runtime = parsed.get("runtime", {})
	if not (runtime is Dictionary):
		return
	var value = runtime.get("companionDesktopPosition", [])
	if value is Array and value.size() >= 2:
		saved_companion_desktop_position = Vector2(float(value[0]), float(value[1]))
		has_saved_companion_desktop_position = true

func _save_companion_desktop_position() -> void:
	if not companion_position_initialized or virtual_desktop_rect.size == Vector2i.ZERO:
		return
	var state: Dictionary = {}
	if FileAccess.file_exists(RUNTIME_STATE_FILE):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(RUNTIME_STATE_FILE))
		if parsed is Dictionary:
			state = parsed
	var runtime = state.get("runtime", {})
	if not (runtime is Dictionary):
		runtime = {}
	var desktop_position := _overlay_to_desktop_position(companion_sprite.position)
	runtime["companionDesktopPosition"] = [desktop_position.x, desktop_position.y]
	runtime["virtualDesktopOrigin"] = [virtual_desktop_origin.x, virtual_desktop_origin.y]
	runtime["screenIndex"] = active_monitor_index
	runtime["screenScale"] = active_monitor_scale
	state["runtime"] = runtime
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://runtime"))
	var file := FileAccess.open(RUNTIME_STATE_FILE, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(state, "  "))

func _begin_walk(target: Vector2) -> void:
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim == null:
		return
	walk_target = _companion_safe_position(target)
	var animation_id := "walk_right" if walk_target.x >= companion_sprite.position.x else "walk_left"
	if not anim.sprite_frames.has_animation(animation_id):
		_show_local_bubble("Walk animation unavailable")
		return
	walking = true
	anim.play(animation_id)

func _walk_to_left() -> void:
	_begin_walk(Vector2(-99999.0, companion_sprite.position.y))

func _walk_to_right() -> void:
	_begin_walk(Vector2(99999.0, companion_sprite.position.y))

func _walk_to_center() -> void:
	var viewport_size := _logical_viewport_size()
	_begin_walk(Vector2(viewport_size.x / 2.0 - SPRITE_SIZE.x / 2.0, viewport_size.y / 2.0 - SPRITE_SIZE.y / 2.0))

func _update_walk(delta: float) -> void:
	if not walking:
		return
	companion_sprite.position = companion_sprite.position.move_toward(walk_target, WALK_PIXELS_PER_SECOND * delta)
	_sync_companion_anim_position()
	if companion_sprite.position.is_equal_approx(walk_target):
		walking = false
		_snap_companion_to_nearest_monitor()
		_save_companion_desktop_position()
		var anim: AnimatedSprite2D = companion_anims.get("default")
		if anim != null:
			anim.play(anim.get_meta("expression", "idle_neutral"))

func _sync_overlay_to_usable_screen() -> void:
	var desktop_rect := _virtual_desktop_rect()
	var window := get_window()
	var geometry_changed := desktop_rect != virtual_desktop_rect
	var position_mismatch := window.position != desktop_rect.position
	var size_mismatch := (
		absi(window.size.x - desktop_rect.size.x) > 1
		or absi(window.size.y - desktop_rect.size.y) > 1)
	if not geometry_changed and not position_mismatch and not size_mismatch:
		return

	# Preserve the companion's physical desktop position while Windows changes
	# monitor layout, including unplug/replug and negative monitor coordinates.
	var previous_desktop_position := Vector2.ZERO
	var had_previous_geometry := virtual_desktop_rect.size != Vector2i.ZERO and companion_position_initialized
	if had_previous_geometry:
		previous_desktop_position = _overlay_to_desktop_position(companion_sprite.position)

	virtual_desktop_rect = desktop_rect
	virtual_desktop_origin = desktop_rect.position
	last_usable_screen_rect = desktop_rect
	window.position = desktop_rect.position
	window.size = desktop_rect.size
	_refresh_monitor_usable_rects()
	active_monitor_index = -1

	if had_previous_geometry:
		companion_sprite.position = _desktop_to_overlay_position(previous_desktop_position)
		_snap_companion_to_nearest_monitor()
		_save_companion_desktop_position()

	# The native resize settles at frame end. Delay layout until the viewport
	# reports the new full virtual-desktop size.
	skip_layout_after_geometry_change = true
	print("OCP: virtual desktop ->", virtual_desktop_rect, " monitors=", monitor_usable_rects_local.size())

func _sync_companion_anim_position() -> void:
	var anim: AnimatedSprite2D = companion_anims.get("default")
	if anim == null:
		return
	anim.position = companion_sprite.position + _companion_host_size() / 2.0
	anim.visible = companion_sprite.visible
	anim.z_index = companion_sprite.z_index + 1

func _passthrough_polygon_equal(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		if not a[index].is_equal_approx(b[index]):
			return false
	return true


func _set_mouse_passthrough_polygon(points: PackedVector2Array) -> void:
	# Windows recalculates native mouse ownership whenever this property is set.
	# Writing the same polygon every frame can make a transparent overlay flicker.
	if _passthrough_polygon_equal(points, last_mouse_passthrough_polygon):
		return
	last_mouse_passthrough_polygon = points.duplicate()
	get_window().mouse_passthrough_polygon = points


func _update_click_through() -> void:
	var modal_ui_visible: bool = (
		quick_panel.visible
		or (character_install_dialog != null and character_install_dialog.visible)
		or (character_picker != null and character_picker.visible)
		or (character_menu != null and character_menu.visible)
		or (animation_menu != null and animation_menu.visible)
	)
	if modal_ui_visible:
		# Empty polygon means the complete window accepts mouse input.
		_set_mouse_passthrough_polygon(PackedVector2Array())
		return

	# Keep one stable native input island that includes BOTH the companion and
	# the toolbar's future position, even while the toolbar is hidden. If the
	# polygon grows only after the toolbar becomes visible, Windows stops sending
	# mouse input as the pointer crosses the gap and the menu repeatedly toggles.
	var hit_rect: Rect2 = _companion_hit_rect().grow(36.0)
	if hover_toolbar != null:
		var toolbar_rect: Rect2 = hover_toolbar.get_global_rect().grow(28.0)
		hit_rect = hit_rect.merge(toolbar_rect)

	var points := PackedVector2Array([
		_logical_to_window_point(hit_rect.position),
		_logical_to_window_point(Vector2(hit_rect.end.x, hit_rect.position.y)),
		_logical_to_window_point(hit_rect.end),
		_logical_to_window_point(Vector2(hit_rect.position.x, hit_rect.end.y))])
	_set_mouse_passthrough_polygon(points)

func _layout_bubbles() -> void:
	var viewport_size := _logical_viewport_size()
	for companion_id: String in companion_bubbles.keys():
		var bubble: Dictionary = companion_bubbles[companion_id]
		var panel: PanelContainer = bubble["panel"]
		var host: ColorRect = bubble["host"]
		var host_rect: Rect2 = host.get_global_rect()
		var anchor_value = active_character_runtime.get("bubbleAnchor", Vector2(0.0, -176.0))
		var anchor_offset: Vector2 = anchor_value if (companion_id == "default" and anchor_value is Vector2) else Vector2(0.0, -176.0)
		var anchor: Vector2 = host_rect.get_center() + anchor_offset * active_monitor_scale_ratio
		var desired := Vector2(anchor.x - panel.size.x / 2.0, anchor.y - panel.size.y)
		panel.position = Vector2(
			clampf(desired.x, 8.0, maxf(8.0, viewport_size.x - panel.size.x - 8.0)),
			maxf(8.0, desired.y))

func _layout_hover_toolbar() -> void:
	if hover_toolbar == null:
		return
	var viewport_size := _logical_viewport_size()
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	hover_toolbar.size = Vector2(244.0, 330.0) * active_monitor_scale_ratio
	var desired := companion_sprite.position + Vector2(-hover_toolbar.size.x - 12.0 * active_monitor_scale_ratio, -112.0 * active_monitor_scale_ratio)
	hover_toolbar.position = Vector2(
		clampf(desired.x, 8.0, maxf(8.0, viewport_size.x - hover_toolbar.size.x - 8.0)),
		clampf(desired.y, 8.0, maxf(8.0, viewport_size.y - hover_toolbar.size.y - 8.0)))


func _fit_runtime_layout() -> void:
	var viewport_size := _logical_viewport_size()
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	# Keep the panel entirely inside the actual overlay viewport, including when
	# the window is resized after `_ready()`.
	var panel_size := Vector2(360.0, minf(420.0, maxf(300.0, viewport_size.y - 180.0)))
	quick_panel_backdrop.position = Vector2.ZERO
	quick_panel_backdrop.size = viewport_size
	quick_panel.size = panel_size
	if not dragging_panel:
		quick_panel.position = Vector2(
			clampf(quick_panel.position.x, 8.0, maxf(8.0, viewport_size.x - panel_size.x - 8.0)),
			clampf(quick_panel.position.y, 8.0, maxf(8.0, viewport_size.y - panel_size.y - 8.0)))
	if not companion_position_initialized:
		# Restore a physical desktop-global position so monitor origin changes do
		# not move the companion. If no saved state exists, use the primary monitor.
		if has_saved_companion_desktop_position:
			companion_sprite.position = _desktop_to_overlay_position(saved_companion_desktop_position)
		elif not monitor_usable_rects_local.is_empty():
			var primary_rect: Rect2 = monitor_usable_rects_local[0]
			companion_sprite.position = primary_rect.end - _companion_host_size() - Vector2(72.0, 48.0)
		else:
			companion_sprite.position = Vector2(viewport_size.x - _companion_host_size().x - 72.0, viewport_size.y - _companion_host_size().y - 48.0)
		companion_position_initialized = true
		_snap_companion_to_nearest_monitor()
		_save_companion_desktop_position()
		if show_companion_after_initial_layout:
			companion_sprite.visible = true
			print("OCP: companion visible flag set during initial layout ->", companion_sprite.visible)
		# If the sprite somehow failed to render, force visible as a defensive
		# fallback so users in debug mode can confirm placement; this helps when
		# platform DPI or scaling hides controls unexpectedly.
		if not companion_sprite.visible:
			companion_sprite.visible = true
			print("OCP: forced companion.visible = true for debug")
		var anim: AnimatedSprite2D = companion_anims.get("default")
		if anim != null:
			anim.visible = true
			if anim.get_parent() != companion_sprite:
				anim.position = companion_sprite.position + _companion_host_size() / 2.0
			else:
				anim.position = SPRITE_SIZE / 2.0
			anim.z_index = companion_sprite.z_index + 1
			print("OCP: forced companion anim.visible = true for debug")
		# Defensive log to help debug 'not visible' at startup in debug builds.
		if Engine.is_editor_hint() == false:
			print("OCP: initial companion placed at", companion_sprite.position)
	# Keep the whole rendered cell in the usable area so no frame edge is cut.
	companion_sprite.position = _companion_safe_position(companion_sprite.position)
	_sync_companion_anim_position()

func _process(delta: float) -> void:
	# _shutdown_runtime() queues dynamic UI for deletion and yields one frame.
	# Do not touch those controls during that final frame.
	if shutdown_requested:
		return
	_sync_overlay_to_usable_screen()
	if skip_layout_after_geometry_change:
		skip_layout_after_geometry_change = false
		return
	var viewport_size := _logical_viewport_size()
	var viewport_changed_significantly := last_viewport_size == Vector2.ZERO
	if not viewport_changed_significantly:
		var viewport_delta_x := absf(viewport_size.x - last_viewport_size.x)
		var viewport_delta_y := absf(viewport_size.y - last_viewport_size.y)
		# Windows ARM/DPI may alternate between 480 and 481 physical pixels.
		# Ignore only that one-pixel jitter; process genuine geometry changes.
		viewport_changed_significantly = viewport_delta_x > 1.0 or viewport_delta_y > 1.0

	if viewport_changed_significantly:
		last_viewport_size = viewport_size
		print("OCP: logical viewport_size ->", viewport_size, " physical:", get_viewport().get_visible_rect().size, " usable_rect:", last_usable_screen_rect)
		_fit_runtime_layout()
		_layout_bubbles()
	_apply_active_monitor_dpi_scale()
	_update_walk(delta)
	# RFC-0006 hover toolbar. Use one expanded, stable hover zone covering the
	# companion, toolbar, and the gap between them. Update visibility before the
	# click-through polygon so Windows never alternates input ownership per frame.
	if hover_toolbar != null:
		_layout_hover_toolbar()
		var mouse: Vector2 = _logical_mouse_position()
		var companion_zone: Rect2 = _companion_hit_rect().grow(36.0)
		var toolbar_zone: Rect2 = hover_toolbar.get_global_rect().grow(28.0)
		var combined_hover_zone: Rect2 = companion_zone.merge(toolbar_zone)
		var pointer_in_companion_zone: bool = companion_sprite.visible and companion_zone.has_point(mouse)
		var pointer_in_hover_zone: bool = companion_sprite.visible and combined_hover_zone.has_point(mouse)
		var now_ms: int = Time.get_ticks_msec()
		# Dragging always hides the hover menu. After release, require the pointer
		# to leave the companion once before hover can open again; otherwise the
		# menu reappears immediately under the released pointer.
		if hover_suppressed_until_pointer_exit and not pointer_in_companion_zone:
			hover_suppressed_until_pointer_exit = false
		if dragging_companion or hover_suppressed_until_pointer_exit:
			hover_visible = false
			hover_hide_deadline_ms = 0
		else:
			if pointer_in_hover_zone:
				hover_hide_deadline_ms = now_ms + HOVER_HIDE_DELAY_MS
			hover_visible = pointer_in_hover_zone or now_ms < hover_hide_deadline_ms
		var desired_toolbar_visible: bool = hover_visible and not quick_panel.visible and not character_picker.visible
		if hover_toolbar.visible != desired_toolbar_visible:
			hover_toolbar.visible = desired_toolbar_visible
	_update_click_through()
	# Follow behavior (เธขเธ8.2 companion-follow เนโฌโ€ a companion follows another
	# companion, never the cursor; that's the separate เธขเธ2.4 family).
	for follower_id: String in follows.keys():
		if sleeping.get(follower_id, false):
			continue
		var info: Dictionary = follows[follower_id]
		var follower: ColorRect = companions.get(follower_id)
		var leader: ColorRect = companions.get(info["leader"])
		if follower == null or leader == null:
			continue
		var target: Vector2 = leader.position + Vector2(info["distance"], 0.0)
		follower.position = follower.position.lerp(target, 0.08)


func _sprite(companion_id: String) -> ColorRect:
	return companions.get(companion_id, companion_sprite)


# I8A slice 3: the bubble anchored above a companion's sprite. Created lazily as
# a child of the companion's host so it tracks the sprite as it walks. A real
# styled bubble (Panel + theme) is presentation polish; a plain floating Label
# matches the existing shared label and proves the per-companion anchoring.
func _bubble_for(companion_id: String) -> Dictionary:
	if companion_bubbles.has(companion_id):
		return companion_bubbles[companion_id]
	var host: ColorRect = companions.get(companion_id, companion_sprite)
	var panel := PanelContainer.new()
	panel.size = Vector2(240, 72)
	panel.z_index = 10
	panel.clip_contents = false
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.visible = false
	panel.add_theme_stylebox_override("panel", _panel_style(Color("ffffffff"), Color("d8e2f0"), 14))
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color("172033"))
	label.add_theme_font_size_override("font_size", 15)
	label.custom_minimum_size = Vector2(216, 56)
	panel.add_child(label)
	var arrow := Polygon2D.new()
	arrow.position = Vector2(110, 68)
	arrow.polygon = PackedVector2Array([Vector2(0, 0), Vector2(20, 0), Vector2(10, 12)])
	arrow.color = Color("ffffffff")
	panel.add_child(arrow)
	add_child(panel)
	companion_bubbles[companion_id] = {"panel": panel, "label": label, "arrow": arrow, "host": host}
	return companion_bubbles[companion_id]


# --- เธขเธ2 presentation verbs, now companion-addressed (เธขเธ8.1) ---

func _on_bubble_requested(companion_id: String, _bubble_id: String, text: String, _tone: String, duration_ms: int, _truncated: bool) -> void:
	# 	ext` arrives already sanitized (เธขเธ5) by the GDExtension เนโฌโ€ safe to assign
	# directly to a plain Label (never a RichTextLabel with bbcode on this value;
	# RUNTIME_API เธขเธ5 / THREAT_MODEL X4-I). I8A slice 3: show it in THIS companion's
	# own bubble, anchored above its sprite, not the single shared label.
	var bubble := _bubble_for(companion_id)
	var lbl: Label = bubble["label"]
	var panel: PanelContainer = bubble["panel"]
	lbl.text = text
	panel.visible = true
	if duration_ms > 0:
		await get_tree().create_timer(duration_ms / 1000.0).timeout
		if lbl.text == text:
			lbl.text = ""
			panel.visible = false


func _on_speech_requested(companion_id: String, speech_id: String, text: String, subtitle: bool, audio_path: String) -> void:
	if subtitle:
		bubble_label.text = text
	# I7 V1 slice 4b: play the synthesized clip, then report REAL completion so
	# the kernel's speech FSM advances on actual playback, not a fake immediate
	# outcome. No clip (tts-unavailable) -> the subtitle above is the output and
	# we complete right away.
	if audio_path == "":
		bridge.report_speech_finished(speech_id, companion_id, "tts-unavailable")
		return
	# SKELETON (verify on first live run): AudioStreamWAV.load_from_file is
	# Godot 4.4+. On an older editor, load bytes instead:
	#   var wav := AudioStreamWAV.load_from_buffer(FileAccess.get_file_as_bytes(audio_path))
	# or wire the WAV through the resource importer.
	var stream := AudioStreamWAV.load_from_file(audio_path)
	if stream == null:
		push_warning("speech clip failed to load: " + audio_path)
		bridge.report_speech_finished(speech_id, companion_id, "tts-unavailable")
		return
	var player := AudioStreamPlayer.new()
	add_child(player)
	player.stream = stream
	# `finished` fires when playback actually ends -> real speech-completed.
	player.finished.connect(func() -> void:
		bridge.report_speech_finished(speech_id, companion_id, "finished")
		player.queue_free())
	player.play()


func _on_emotion_changed(companion_id: String, emotion: String, emotion_instance: String) -> void:
	print("emotion[", companion_id, "] -> ", emotion)
	var tint: Color = EMOTION_TINTS.get(emotion, Color(1, 1, 1))
	# I8A slice 2 เนโฌโ€ Expression module (RFC-0008 เธขเธ4.1): render emotion-changed as a
	# facial expression + a tint; hold no emotion state (Behavior owns it). Resolve
	# the target: a sprite-backed companion switches its idle_<emotion> expression;
	# a spawned ColorRect just tints; an unknown id (the standing behavior-engine
	# stray-uuid quirk) applies to the default so the demo still emotes.
	var anim: AnimatedSprite2D = companion_anims.get(companion_id)
	if anim == null and not companions.has(companion_id):
		anim = companion_anims.get("default")
	if anim != null:
		var ename := "idle_" + emotion
		if not anim.sprite_frames.has_animation(ename):
			ename = "idle_neutral" # package has no mapping for this emotion (fallback)
		anim.set_meta("expression", ename)
		# switch the resting expression now unless mid one-shot; the wave handler
		# returns to this expression when it finishes.
		if not anim.is_playing() or String(anim.animation).begins_with("idle"):
			anim.play(ename)
		anim.modulate = tint
	else:
		_sprite(companion_id).modulate = tint
	# I8A slice 2b: report the REAL presentation (เธขเธ2.5) so emotion-presented is
	# honest เนโฌโ€ retiring the bridge's old hardcoded expressionSet/fallback (the
	# last fake runtime outcome). Placeholder set id = "placeholder:<emotion>";
	# fallback=true when this (placeholder) package has no mapping and rendered
	# neutral instead.
	var mapped: bool = EMOTION_MOUTHS.has(emotion)
	var expr_set: String = "placeholder:" + (emotion if mapped else "neutral")
	# `call_deferred`, not a direct call: this handler runs synchronously inside
	# the bridge's `emit_signal`, so a direct report would re-enter the bridge
	# (`&mut self`) mid-dispatch AND run before the bridge finishes registering
	# the token. Deferring runs it after dispatch returns เนโฌโ€ token present, no
	# re-entrancy. (speech/animation don't need this: they report later, on
	# playback/tween end.)
	bridge.call_deferred("report_emotion_presented", emotion_instance, companion_id, emotion, expr_set, not mapped)


func _on_animation_requested(companion_id: String, animation_id: String, _looped: bool, priority: String, blend_ms: int, animation_instance: String) -> void:
	print("animation[", companion_id, "] -> ", animation_id, " (", priority, ")")
	# I8A slice 1b: play the real frame animation when the companion's sprite-
	# sheet has it, reporting REAL completion on `animation_finished` (เธขเธ7 timing,
	# retiring I2's fake-immediate outcome as I7 did for speech). A looping state
	# (idle) is "satisfied" as soon as it starts; a one-shot reports when its
	# frames end, then returns to idle. Companions with no sprite-sheet (spawned
	# ColorRects) or unknown animation names fall back to the placeholder pulse,
	# which still reports real completion.
	var anim: AnimatedSprite2D = companion_anims.get(companion_id)
	if anim != null:
		# `call_deferred` for the SYNCHRONOUS reports below (missing-asset + a
		# looping animation that has no end): this handler runs inside the bridge's
		# emit_signal, so a direct report fires before the bridge registers the
		# token (same fix as emotion). The one-shot path already defers via
		# `animation_finished`, which fires in a later frame.
		if not anim.sprite_frames.has_animation(animation_id):
			# เธขเธ2.2 missing-asset: the character package has no such animation เนโฌโ€ a
			# fact, not an error. Keep the idle set playing and report it so the
			# kernel's behavior can fall back, instead of a fake "finished".
			anim.play(anim.get_meta("expression", "idle_neutral"))
			bridge.call_deferred("report_animation_finished", animation_instance, companion_id, animation_id, "missing-asset")
			return
		anim.play(animation_id)
		if anim.sprite_frames.get_animation_loop(animation_id):
			bridge.call_deferred("report_animation_finished", animation_instance, companion_id, animation_id, "finished")
		else:
			anim.animation_finished.connect(func() -> void:
				bridge.report_animation_finished(animation_instance, companion_id, animation_id, "finished")
				anim.play(anim.get_meta("expression", "idle_neutral")), CONNECT_ONE_SHOT)
		return
	var sprite := _sprite(companion_id)
	var tween := create_tween()
	var blend_floor: int = maxi(blend_ms, 80)
	var duration: float = blend_floor / 1000.0
	tween.tween_property(sprite, "scale", Vector2(1.15, 1.15), duration * 0.5)
	tween.tween_property(sprite, "scale", Vector2.ONE, duration * 0.5)
	tween.finished.connect(func() -> void:
		bridge.report_animation_finished(animation_instance, companion_id, animation_id, "finished"))


# --- เธขเธ8.2 companion lifecycle ---

func _on_companion_spawn(companion_id: String, character_package_id: String, x: int, y: int) -> void:
	if companions.has(companion_id):
		return  # already present; the bridge/kernel own duplicate policy
	print("spawn[", companion_id, "] package=", character_package_id)
	var sprite := ColorRect.new()
	sprite.size = SPRITE_SIZE
	sprite.position = Vector2(x, y)
	sprite.color = SPAWN_COLORS[companions.size() % SPAWN_COLORS.size()]
	sprite.name = "Companion_" + companion_id
	sprite.mouse_filter = Control.MOUSE_FILTER_IGNORE  # same fix as _ready
	add_child(sprite)
	companions[companion_id] = sprite
	# I8A: give the spawned companion the character package's sprite too (not a
	# bare ColorRect) เนโฌโ€ a real multi-companion character. Tint via modulate to
	# tell copies of the same character apart until packages vary per spawn.
	var spawn_tint: Color = sprite.color
	_attach_placeholder_sprite(companion_id, sprite)
	if companion_anims.has(companion_id):
		companion_anims[companion_id].modulate = spawn_tint


func _on_companion_despawn(companion_id: String) -> void:
	if companion_id == "default":
		companion_sprite.visible = false  # the static node is never freed
		return
	var sprite: ColorRect = companions.get(companion_id)
	if sprite != null:
		sprite.queue_free()
	companions.erase(companion_id)
	follows.erase(companion_id)
	sleeping.erase(companion_id)


func _on_companion_sleep(companion_id: String, active: bool) -> void:
	# Placeholder: sleeping presents as hidden + paused follow updates. Real
	# resource unloading (ADR-0013 เธขเธ8 lazy loading) belongs to the
	# character-package/asset pipeline, which doesn't exist yet (I8).
	sleeping[companion_id] = active
	_sprite(companion_id).visible = not active


func _on_companion_visibility(companion_id: String, visible_now: bool) -> void:
	# Hide เนยย  sleep (เธขเธ8.2): a hidden companion still updates state; we only
	# stop drawing it.
	_sprite(companion_id).visible = visible_now


func _on_companion_focus(companion_id: String) -> void:
	# Bring to the front render layer (ADR-0013 เธขเธ9 z-order priority).
	var sprite := _sprite(companion_id)
	move_child(sprite, get_child_count() - 1)


func _on_companion_follow(companion_id: String, leader_companion_id: String, active: bool, distance_px: int) -> void:
	if active:
		follows[companion_id] = { "leader": leader_companion_id, "distance": float(distance_px) }
	else:
		follows.erase(companion_id)


func _on_look_at_cursor(companion_id: String, duration_ms: int) -> void:
	# Placeholder "glance": nudge toward the cursor and back เนโฌโ€ enough to make
	# the one-shot เธขเธ8.2 verb visibly distinct from continuous cursor-follow.
	var sprite := _sprite(companion_id)
	var toward := (_logical_mouse_position() - sprite.position).normalized() * 8.0
	var half: float = maxi(duration_ms, 200) / 2000.0
	var origin := sprite.position
	var tween := create_tween()
	tween.tween_property(sprite, "position", origin + toward, half)
	tween.tween_property(sprite, "position", origin, half)


# --- window / connection / input ---

func _on_window_policy_changed(_transparent: bool, _always_on_top: bool, _click_through: String) -> void:
	# The bridge (rust/src/lib.rs::apply_window_policy) already applied this
	# via DisplayServer and reported real degradation over IPC before this
	# signal fired เนโฌโ€ window mutation is contract-relevant (truthful เธขเธ3.1
	# degradation reporting), so it does not belong in presentation-only
	# GDScript. This handler exists only for future cosmetic reactions.
	pass


func _on_state_changed(from_state: String, to_state: String) -> void:
	print("companion state: ", from_state, " -> ", to_state)


func _on_connection_lost() -> void:
	bubble_label.text = "(disconnected)"


func _on_connection_restored() -> void:
	bubble_label.text = ""


func _on_panel_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging_panel = event.pressed
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and dragging_panel:
		quick_panel.position += event.relative
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var pos := _logical_mouse_position()
		if event.pressed and companion_sprite.visible and _companion_hit_rect().has_point(pos):
			dragging_companion = true
			hover_suppressed_until_pointer_exit = true
			hover_visible = false
			hover_hide_deadline_ms = 0
			if hover_toolbar != null:
				hover_toolbar.visible = false
			walking = false
			companion_drag_mouse_origin = pos
			companion_drag_position_origin = companion_sprite.position
			bridge.capture_input("drag", "", "companion:default")
			get_viewport().set_input_as_handled()
			return
		if not event.pressed and dragging_companion:
			dragging_companion = false
			hover_visible = false
			hover_hide_deadline_ms = 0
			_snap_companion_to_nearest_monitor()
			_save_companion_desktop_position()
			_layout_hover_toolbar()
			_layout_bubbles()
			bridge.capture_input("drag", "", "companion:default")
			_update_click_through()
			return
		if event.pressed:
			bridge.capture_input("click", "", "companion")
	elif event is InputEventMouseMotion and dragging_companion:
		var delta: Vector2 = _logical_mouse_position() - companion_drag_mouse_origin
		companion_sprite.position = _companion_safe_position(companion_drag_position_origin + delta)
		_sync_companion_anim_position()
		_layout_hover_toolbar()
		_layout_bubbles()
		_update_click_through()
		get_viewport().set_input_as_handled()
func _on_character_package_selected(path: String) -> void:
	var normalized_path := path.replace("\\", "/")
	var reader := OcpPackageReader.new()
	var read_result = reader.read(normalized_path)
	if not read_result.ok:
		_show_notification("Character read failed: " + read_result.error_message)
		return

	var validator := OcpPackageValidator.new()
	var validation = validator.validate(read_result)
	if not validation.ok:
		if read_result.zip != null:
			read_result.zip.close()
		_show_notification("Character validation failed: " + validation.error_message)
		return

	var installer := CharacterPackageInstaller.new()
	var install_result = installer.install(read_result)
	if read_result.zip != null:
		read_result.zip.close()
	if not install_result.ok:
		_show_notification("Character install failed: " + install_result.error_message)
		return

	_reload_active_character()
	if character_picker != null:
		character_picker.visible = true
		_refresh_character_picker()
	_show_notification("Installed and active: %s @ %s" % [install_result.package_id, install_result.version])
	_update_click_through()
