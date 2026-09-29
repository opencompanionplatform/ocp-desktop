extends Window

## OCP Control Center shell.
## Chat is detached into its own native Window at runtime; this window keeps
## only Settings + Updates. The legacy scene nodes remain as compatibility
## anchors for controllers/smoke tests, while the visible Settings surface is
## rebuilt as a mock-aligned component tree.

signal theme_preview_requested(theme_name: String)
signal language_preview_requested(locale: String)
signal text_scale_preview_requested(scale: float)
signal offline_presence_changed(enabled: bool)
signal ai_settings_save_requested(values: Dictionary)
signal ai_connection_test_requested(values: Dictionary)
signal provider_credential_save_requested(provider_id: String, credential: String)
signal tts_test_requested(text: String)

const GAUGE_SCRIPT := preload("res://scripts/runtime_v3/ui/resource_gauge.gd")
const TITLE_BAR_SCRIPT := preload("res://scripts/runtime_v3/ui/ocp_title_bar.gd")
const AMBIENT_WAVE_SCRIPT := preload("res://scripts/runtime_v3/ui/ambient_wave.gd")
const TITLE_BAR_HEIGHT := 46.0
const RAIL_WIDTH := 260.0
const INFO_RAIL_WIDTH := 232.0
const TEXT := Color("#f2f7ff")
const MUTED := Color("#8ea7c9")
const CYAN := Color("#23b7ff")

# Baseline typography tokens. Individual controls use these semantic sizes,
# while ThemeService applies the user's accessibility text-scale multiplier.
# This keeps the visual hierarchy predictable across English and Thai instead
# of accumulating one-off sizes per widget.
const TYPE_CAPTION := 12
const TYPE_BODY := 14
const TYPE_CONTROL := 16
const TYPE_SECTION := 20
const TYPE_VALUE := 24
const TYPE_PAGE := 32

var root_control: PanelContainer
var tabs: TabContainer
var rail: PanelContainer
var info_rail: PanelContainer
var title_bar: PanelContainer
var chat_title_bar: PanelContainer
var nav_buttons: Dictionary = {}
var page_tween: Tween

var chat_window: Window
var chat_root: PanelContainer
var chat_page: Control
var chat_window_has_opened := false

var settings_scroll: ScrollContainer
var settings_body: VBoxContainer
var appearance_card: PanelContainer
var behavior_card: PanelContainer
var resource_card: PanelContainer
var resource_inner_panel: PanelContainer
var font_option: OptionButton
var bubble_option: OptionButton
var language_option: OptionButton
var text_scale_option: OptionButton
var ai_voice_page: MarginContainer
var ai_provider_option: OptionButton
var ai_base_url_input: LineEdit
var ai_model_input: LineEdit
var ai_timeout_option: OptionButton
var ai_connection_status: Label
var ai_test_button: Button
var ai_save_button: Button
var tts_enabled_toggle: CheckButton
var tts_provider_option: OptionButton
var tts_voice_option: OptionButton
var tts_test_button: Button
var gemini_key_input: LineEdit
var gemini_key_status: Label
var gemini_key_save_button: Button
var cloud_credential_row: HBoxContainer
var cloud_key_input: LineEdit
var cloud_key_status: Label
var cloud_key_save_button: Button
var update_status_card: PanelContainer
var update_security_card: PanelContainer
var update_actions_card: PanelContainer
var click_through_toggle: CheckButton
var start_with_windows_toggle: CheckButton
var offline_presence_toggle: CheckButton
var offline_presence_status: Label
var save_button: Button
var cpu_gauge: Control
var memory_gauge: Control
var theme_buttons: Dictionary = {}
var ambient_waves: Array[Control] = []
var selected_theme := "solid"
var current_palette: Dictionary = {}
var current_language := "en"
var current_catalog: Dictionary = {}
var current_companion_name := "Lumi"


func _ready() -> void:
	title = "Open OCP"
	borderless = true
	unresizable = false
	min_size = Vector2i(900, 620)
	if size.x < 980 or size.y < 680:
		size = Vector2i(1050, 720)
	_build_shell()
	if not size_changed.is_connected(_layout_shell):
		size_changed.connect(_layout_shell)


func _build_shell() -> void:
	if is_instance_valid(rail):
		return
	root_control = get_node_or_null("ApplicationRoot") as PanelContainer
	if not is_instance_valid(root_control):
		return
	tabs = root_control.get_node_or_null("ApplicationLayout/ApplicationTabs") as TabContainer
	if not is_instance_valid(tabs):
		return
	root_control.set_meta("ocp_mock_theme_locked", true)
	tabs.tabs_visible = false
	var legacy_title := root_control.get_node_or_null("ApplicationLayout/ApplicationTitle") as Label
	if is_instance_valid(legacy_title):
		legacy_title.visible = false

	var shell_wave := AMBIENT_WAVE_SCRIPT.new()
	shell_wave.name = "ShellAmbientWave"
	shell_wave.configure("shell")
	# First child at z=0: above the root panel fill, below the existing layout.
	shell_wave.z_index = 0
	root_control.add_child(shell_wave)
	root_control.move_child(shell_wave, 0)
	ambient_waves.append(shell_wave)

	_build_window_title_bar()
	_build_chat_window()
	_build_control_rail()
	_build_info_rail()
	_rebuild_settings_page()
	_build_ai_voice_page()
	_style_updates_page()
	_layout_shell()
	_select_control_page("settings", false)
	apply_ocp_theme(_fallback_palette(), "solid")


func _build_window_title_bar() -> void:
	if is_instance_valid(title_bar):
		return
	title_bar = TITLE_BAR_SCRIPT.new()
	title_bar.configure(self, "")
	title_bar.close_requested.connect(hide)
	title_bar.z_index = 100
	add_child(title_bar)


func _build_chat_window() -> void:
	if is_instance_valid(chat_window):
		return
	chat_window = get_parent().get_node_or_null("ChatWindow") as Window
	if not is_instance_valid(chat_window):
		return
	chat_window.borderless = true
	chat_window.unresizable = false
	chat_root = chat_window.get_node_or_null("ChatRoot") as PanelContainer
	chat_page = chat_root.get_node_or_null("Chat") as Control if is_instance_valid(chat_root) else null
	if not is_instance_valid(chat_root) or not is_instance_valid(chat_page):
		return
	chat_root.set_meta("ocp_mock_theme_locked", true)
	var chat_ambient := AMBIENT_WAVE_SCRIPT.new()
	chat_ambient.name = "ChatAmbientVisual"
	chat_ambient.configure("shell")
	# Chat should keep ambience behind the conversation, not compete with it.
	# Settings can carry the stronger material preview; Chat stays ~1/3 quieter.
	chat_ambient.modulate = Color(1.0, 1.0, 1.0, 0.64)
	chat_ambient.z_index = 0
	chat_root.add_child(chat_ambient)
	chat_root.move_child(chat_ambient, 0)
	ambient_waves.append(chat_ambient)
	if not chat_window.close_requested.is_connected(hide_chat_window):
		chat_window.close_requested.connect(hide_chat_window)
	chat_title_bar = TITLE_BAR_SCRIPT.new()
	chat_title_bar.configure(chat_window, "Chat")
	chat_title_bar.close_requested.connect(hide_chat_window)
	chat_title_bar.z_index = 100
	chat_window.add_child(chat_title_bar)
	if not chat_window.size_changed.is_connected(_layout_chat_window):
		chat_window.size_changed.connect(_layout_chat_window)
	_style_chat_page()
	_layout_chat_window()


func get_chat_window() -> Window:
	return chat_window


func set_chat_companion_identity(display_name: String) -> void:
	var normalized := display_name.strip_edges()
	current_companion_name = normalized if not normalized.is_empty() else "Companion"
	if not is_instance_valid(chat_root):
		return
	var name_label := chat_root.find_child("CompanionName", true, false) as Label
	if is_instance_valid(name_label):
		name_label.text = current_companion_name
	var assistant := chat_root.get_node_or_null("Chat/ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow/AssistantCard/AssistantMargins/AssistantText") as Label
	if is_instance_valid(assistant):
		assistant.text = _chat_greeting_text()
	_sync_chat_companion_portrait()


func show_chat_window() -> void:
	if not is_instance_valid(chat_window):
		return
	_sync_chat_companion_portrait()
	var is_first_open := not chat_window_has_opened
	if is_first_open:
		# Chat is a separate OCP native window. Reference the Control Center's
		# geometry for first placement, never the companion MAIN_WINDOW_ID.
		_center_native_window(chat_window, self)
	# A hidden child Window does not have a registered native HWND yet on Windows.
	# Show it before overlap avoidance so any display-server queries are safe.
	chat_window.show()
	if is_first_open:
		_avoid_companion_overlap_for_window(chat_window)
		chat_window_has_opened = true
	chat_window.grab_focus()


func hide_chat_window() -> void:
	if is_instance_valid(chat_window):
		chat_window.hide()


func _build_control_rail() -> void:
	rail = PanelContainer.new()
	rail.name = "ProductionNavigationRail"
	rail.set_meta("ocp_mock_theme_locked", true)
	rail.mouse_filter = Control.MOUSE_FILTER_STOP
	rail.z_index = 20
	add_child(rail)
	var rail_wave := AMBIENT_WAVE_SCRIPT.new()
	rail_wave.name = "RailAmbientWave"
	rail_wave.configure("bottom_left")
	rail.add_child(rail_wave)
	ambient_waves.append(rail_wave)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 20)
	rail.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var logo_center := CenterContainer.new()
	logo_center.custom_minimum_size = Vector2(0, 86)
	column.add_child(logo_center)
	var logo := TextureRect.new()
	logo.custom_minimum_size = Vector2(78, 78)
	logo.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.texture = load("res://assets/icons/ocp.svg") as Texture2D
	logo_center.add_child(logo)
	var wordmark := Label.new()
	wordmark.text = "OCP"
	wordmark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wordmark.add_theme_font_size_override("font_size", 34)
	column.add_child(wordmark)
	var subtitle := Label.new()
	subtitle.name = "RailSubtitle"
	subtitle.text = "Open Companion Platform"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 12)
	column.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 34)
	column.add_child(gap)
	_add_control_nav(column, "Settings", "settings")
	_add_control_nav(column, "AI & Voice", "ai_voice")
	_add_control_nav(column, "Updates", "updates")
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)


func _add_control_nav(column: VBoxContainer, label: String, page_name: String) -> void:
	var button := Button.new()
	button.text = label
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.custom_minimum_size = Vector2(0, 58)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_constant_override("icon_max_width", 22)
	button.add_theme_constant_override("h_separation", 12)
	var icon_path := "res://assets/ui/icons/settings.svg"
	match page_name:
		"ai_voice": icon_path = "res://assets/ui/icons/ai_voice.svg"
		"updates": icon_path = "res://assets/ui/icons/updates.svg"
	button.icon = load(icon_path) as Texture2D
	button.pressed.connect(func(): _select_control_page(page_name, true))
	column.add_child(button)
	nav_buttons[page_name] = button


func _build_info_rail() -> void:
	# Compatibility node retained for the existing shell contract; intentionally hidden.
	info_rail = PanelContainer.new()
	info_rail.name = "ProductionInfoRail"
	info_rail.visible = false
	add_child(info_rail)


func select_control_page(page_name: String, animate: bool = true) -> void:
	_select_control_page(page_name, animate)


func _select_control_page(page_name: String, animate: bool) -> void:
	if not is_instance_valid(tabs):
		return
	var requested := page_name.to_lower()
	var tab_name := "ai & voice" if requested in ["ai_voice", "ai & voice", "ai", "voice"] else requested
	var nav_key := "ai_voice" if tab_name == "ai & voice" else requested
	for index in range(tabs.get_tab_count()):
		if tabs.get_tab_title(index).to_lower() == tab_name:
			tabs.current_tab = index
			for key in nav_buttons.keys():
				(nav_buttons[key] as Button).button_pressed = str(key) == nav_key
			_refresh_nav_styles()
			if animate:
				_animate_page(tabs.get_child(index) as Control)
			return


func _refresh_nav_styles() -> void:
	var palette := current_palette if not current_palette.is_empty() else _fallback_palette()
	var surface: Color = palette.get("surface", Color("#08152b"))
	var border: Color = palette.get("border", Color("#236fb8"))
	var text: Color = palette.get("text", TEXT)
	var accent: Color = palette.get("accent", CYAN)
	for button_key in nav_buttons.keys():
		var nav := nav_buttons[button_key] as Button
		if not is_instance_valid(nav):
			continue
		var active := nav.button_pressed
		nav.add_theme_color_override("font_color", text)
		nav.add_theme_color_override("font_hover_color", text)
		nav.add_theme_color_override("font_pressed_color", text)
		var normal_style := _panel_style(Color(surface, 0.08), Color.TRANSPARENT, 12, 0)
		if active:
			normal_style = _panel_style(Color(accent, 0.18), Color(accent, 0.92), 12, 10)
		nav.add_theme_stylebox_override("normal", normal_style)
		nav.add_theme_stylebox_override("hover", _panel_style(Color(accent, 0.12), Color(border, 0.64), 12, 6))
		nav.add_theme_stylebox_override("pressed", _panel_style(Color(accent, 0.24), Color(accent, 0.96), 12, 11))


func _animate_page(page: Control) -> void:
	if not is_instance_valid(page):
		return
	if is_instance_valid(page_tween):
		page_tween.kill()
	page.modulate = Color(1, 1, 1, 0.0)
	page.position.x = 12.0
	page_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	page_tween.tween_property(page, "modulate", Color.WHITE, 0.20)
	page_tween.tween_property(page, "position:x", 0.0, 0.20)


func _rebuild_settings_page() -> void:
	var page := tabs.get_node_or_null("Settings") as MarginContainer
	if not is_instance_valid(page):
		return
	page.add_theme_constant_override("margin_left", 40)
	page.add_theme_constant_override("margin_top", 24)
	page.add_theme_constant_override("margin_right", 34)
	page.add_theme_constant_override("margin_bottom", 22)
	var layout := page.get_node_or_null("SettingsLayout") as VBoxContainer
	if not is_instance_valid(layout):
		return
	layout.set_meta("ocp_mock_theme_locked", true)
	layout.add_theme_constant_override("separation", 10)

	var heading := layout.get_node_or_null("SettingsHeading") as Label
	var intro := layout.get_node_or_null("SettingsIntro") as Label
	var save := layout.get_node_or_null("SaveSettingsButton") as Button
	save_button = save
	var status := layout.get_node_or_null("SettingsStatusLabel") as Label
	for child in layout.get_children():
		(child as CanvasItem).visible = false
	if is_instance_valid(heading):
		heading.visible = true
		heading.text = "Settings"
		heading.add_theme_font_size_override("font_size", TYPE_PAGE)
	if is_instance_valid(intro):
		intro.visible = true
		intro.text = "Customize OCP to your liking"
		intro.add_theme_font_size_override("font_size", TYPE_BODY)
	if is_instance_valid(save):
		save.visible = true
		save.text = "Save changes"
		save.custom_minimum_size = Vector2(230, 54)
		save.size_flags_horizontal = Control.SIZE_SHRINK_END
	if is_instance_valid(status):
		status.visible = true
		status.add_theme_font_size_override("font_size", 12)

	settings_scroll = ScrollContainer.new()
	settings_scroll.name = "SettingsScroll"
	settings_scroll.set_meta("ocp_mock_theme_locked", true)
	settings_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	settings_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	layout.add_child(settings_scroll)
	layout.move_child(settings_scroll, 2)

	settings_body = VBoxContainer.new()
	settings_body.name = "MockSettingsBody"
	settings_body.set_meta("ocp_mock_theme_locked", true)
	settings_body.add_theme_constant_override("separation", 12)
	settings_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_scroll.add_child(settings_body)
	var v_scroll := settings_scroll.get_v_scroll_bar()
	if is_instance_valid(v_scroll):
		v_scroll.custom_minimum_size.x = 8

	appearance_card = _new_card("Appearance")
	appearance_card.custom_minimum_size = Vector2(0, 250)
	settings_body.add_child(appearance_card)
	_build_appearance_card(appearance_card)
	behavior_card = _new_card("Companion Behavior")
	behavior_card.custom_minimum_size = Vector2(0, 205)
	settings_body.add_child(behavior_card)
	_build_behavior_card(behavior_card)
	resource_card = _new_card("Resource Monitor")
	resource_card.custom_minimum_size = Vector2(0, 205)
	settings_body.add_child(resource_card)
	_build_resource_card(resource_card)


func _build_ai_voice_page() -> void:
	if not is_instance_valid(tabs):
		return
	var existing := tabs.get_node_or_null("AI & Voice") as MarginContainer
	if is_instance_valid(existing):
		ai_voice_page = existing
		return

	ai_voice_page = MarginContainer.new()
	ai_voice_page.name = "AI & Voice"
	ai_voice_page.set_meta("ocp_mock_theme_locked", true)
	ai_voice_page.add_theme_constant_override("margin_left", 40)
	ai_voice_page.add_theme_constant_override("margin_top", 24)
	ai_voice_page.add_theme_constant_override("margin_right", 34)
	ai_voice_page.add_theme_constant_override("margin_bottom", 22)
	tabs.add_child(ai_voice_page)
	tabs.move_child(ai_voice_page, mini(1, tabs.get_child_count() - 1))

	var layout := VBoxContainer.new()
	layout.name = "AIVoiceLayout"
	layout.add_theme_constant_override("separation", 10)
	ai_voice_page.add_child(layout)

	var heading := Label.new()
	heading.name = "AIVoiceHeading"
	heading.text = "AI & Voice"
	heading.add_theme_font_size_override("font_size", TYPE_PAGE)
	layout.add_child(heading)
	var intro := Label.new()
	intro.name = "AIVoiceIntro"
	intro.text = "Connect your AI provider and control spoken replies."
	intro.add_theme_font_size_override("font_size", TYPE_BODY)
	intro.add_theme_color_override("font_color", MUTED)
	layout.add_child(intro)

	var scroll := ScrollContainer.new()
	scroll.name = "AIVoiceScroll"
	scroll.set_meta("ocp_mock_theme_locked", true)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	layout.add_child(scroll)
	var body := VBoxContainer.new()
	body.name = "AIVoiceBody"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	var provider_card := _new_card("AI Provider")
	provider_card.name = "AIProviderCard"
	provider_card.custom_minimum_size = Vector2(0, 430)
	body.add_child(provider_card)
	var provider_stack := _card_stack(provider_card)
	var provider_help := Label.new()
	provider_help.name = "AIProviderHelp"
	provider_help.text = "Start offline, connect local Ollama, or use an OpenAI-compatible cloud endpoint with a secure OS-stored key."
	provider_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	provider_help.add_theme_font_size_override("font_size", TYPE_BODY)
	provider_help.add_theme_color_override("font_color", MUTED)
	provider_stack.add_child(provider_help)

	var fields := GridContainer.new()
	fields.name = "AIProviderFields"
	fields.columns = 2
	fields.add_theme_constant_override("h_separation", 18)
	fields.add_theme_constant_override("v_separation", 12)
	provider_stack.add_child(fields)

	var provider_column := VBoxContainer.new()
	provider_column.add_theme_constant_override("separation", 6)
	fields.add_child(provider_column)
	var provider_label := Label.new()
	provider_label.name = "AIProviderLabel"
	provider_label.text = "Provider"
	provider_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	provider_column.add_child(provider_label)
	ai_provider_option = OptionButton.new()
	ai_provider_option.name = "AIProviderOption"
	ai_provider_option.custom_minimum_size = Vector2(280, 44)
	ai_provider_option.add_item("Offline")
	ai_provider_option.set_item_metadata(0, "offline")
	ai_provider_option.add_item("Ollama · Local")
	ai_provider_option.set_item_metadata(1, "ollama")
	ai_provider_option.add_item("OpenAI-compatible · Cloud")
	ai_provider_option.set_item_metadata(2, "openai-compatible")
	ai_provider_option.item_selected.connect(_on_ai_provider_option_selected)
	provider_column.add_child(ai_provider_option)
	_style_option_popup(ai_provider_option)

	var model_column := VBoxContainer.new()
	model_column.add_theme_constant_override("separation", 6)
	fields.add_child(model_column)
	var model_label := Label.new()
	model_label.name = "AIModelLabel"
	model_label.text = "Model"
	model_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	model_column.add_child(model_label)
	ai_model_input = LineEdit.new()
	ai_model_input.name = "AIModelInput"
	ai_model_input.placeholder_text = "e.g. qwen3.5:latest"
	ai_model_input.custom_minimum_size = Vector2(280, 44)
	model_column.add_child(ai_model_input)

	var base_column := VBoxContainer.new()
	base_column.add_theme_constant_override("separation", 6)
	fields.add_child(base_column)
	var base_label := Label.new()
	base_label.name = "AIBaseUrlLabel"
	base_label.text = "Base URL"
	base_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	base_column.add_child(base_label)
	ai_base_url_input = LineEdit.new()
	ai_base_url_input.name = "AIBaseUrlInput"
	ai_base_url_input.placeholder_text = "http://127.0.0.1:11434"
	ai_base_url_input.custom_minimum_size = Vector2(280, 44)
	base_column.add_child(ai_base_url_input)

	var timeout_column := VBoxContainer.new()
	timeout_column.add_theme_constant_override("separation", 6)
	fields.add_child(timeout_column)
	var timeout_label := Label.new()
	timeout_label.name = "AITimeoutLabel"
	timeout_label.text = "Timeout"
	timeout_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	timeout_column.add_child(timeout_label)
	ai_timeout_option = OptionButton.new()
	ai_timeout_option.name = "AITimeoutOption"
	ai_timeout_option.custom_minimum_size = Vector2(280, 44)
	for seconds in [15, 30, 45, 60, 120]:
		ai_timeout_option.add_item("%d s" % seconds)
		ai_timeout_option.set_item_metadata(ai_timeout_option.item_count - 1, seconds)
	ai_timeout_option.select(2)
	timeout_column.add_child(ai_timeout_option)
	_style_option_popup(ai_timeout_option)

	cloud_credential_row = HBoxContainer.new()
	cloud_credential_row.name = "CloudCredentialRow"
	cloud_credential_row.add_theme_constant_override("separation", 14)
	cloud_credential_row.visible = false
	provider_stack.add_child(cloud_credential_row)
	var cloud_credential_column := VBoxContainer.new()
	cloud_credential_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cloud_credential_column.add_theme_constant_override("separation", 6)
	cloud_credential_row.add_child(cloud_credential_column)
	var cloud_credential_label := Label.new()
	cloud_credential_label.name = "CloudCredentialLabel"
	cloud_credential_label.text = "Cloud API key"
	cloud_credential_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	cloud_credential_column.add_child(cloud_credential_label)
	cloud_key_input = LineEdit.new()
	cloud_key_input.name = "CloudCredentialInput"
	cloud_key_input.secret = true
	cloud_key_input.placeholder_text = "Paste API key"
	cloud_key_input.custom_minimum_size = Vector2(360, 44)
	cloud_credential_column.add_child(cloud_key_input)
	cloud_key_status = Label.new()
	cloud_key_status.name = "CloudCredentialStatus"
	cloud_key_status.text = "No cloud API key stored."
	cloud_key_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cloud_key_status.add_theme_font_size_override("font_size", TYPE_CAPTION)
	cloud_key_status.add_theme_color_override("font_color", MUTED)
	cloud_credential_column.add_child(cloud_key_status)
	cloud_key_save_button = Button.new()
	cloud_key_save_button.name = "CloudCredentialSaveButton"
	cloud_key_save_button.text = "Save key securely"
	cloud_key_save_button.custom_minimum_size = Vector2(185, 44)
	cloud_key_save_button.pressed.connect(_on_cloud_key_save_pressed)
	cloud_credential_row.add_child(cloud_key_save_button)

	var status_row := HBoxContainer.new()
	status_row.name = "AIStatusRow"
	status_row.add_theme_constant_override("separation", 12)
	provider_stack.add_child(status_row)
	ai_connection_status = Label.new()
	ai_connection_status.name = "AIConnectionStatus"
	ai_connection_status.text = "Offline mode — no network provider selected."
	ai_connection_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ai_connection_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ai_connection_status.add_theme_font_size_override("font_size", TYPE_BODY)
	ai_connection_status.add_theme_color_override("font_color", MUTED)
	status_row.add_child(ai_connection_status)
	ai_test_button = Button.new()
	ai_test_button.name = "AITestButton"
	ai_test_button.text = "Test connection"
	ai_test_button.custom_minimum_size = Vector2(170, 46)
	ai_test_button.pressed.connect(_on_ai_test_pressed)
	status_row.add_child(ai_test_button)
	ai_save_button = Button.new()
	ai_save_button.name = "AISaveButton"
	ai_save_button.text = "Save AI settings"
	ai_save_button.custom_minimum_size = Vector2(180, 46)
	ai_save_button.pressed.connect(_on_ai_save_pressed)
	status_row.add_child(ai_save_button)

	var voice_card := _new_card("Voice (TTS)")
	voice_card.name = "VoiceCard"
	voice_card.custom_minimum_size = Vector2(0, 310)
	body.add_child(voice_card)
	var voice_stack := _card_stack(voice_card)
	var voice_help := Label.new()
	voice_help.name = "VoiceHelp"
	voice_help.text = "Spoken replies use the current kernel voice chain: Gemini when available, then the Windows system voice fallback."
	voice_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	voice_help.add_theme_font_size_override("font_size", TYPE_BODY)
	voice_help.add_theme_color_override("font_color", MUTED)
	voice_stack.add_child(voice_help)
	var voice_row := HBoxContainer.new()
	voice_row.add_theme_constant_override("separation", 18)
	voice_stack.add_child(voice_row)
	var enable_column := VBoxContainer.new()
	enable_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	voice_row.add_child(enable_column)
	var enable_label := Label.new()
	enable_label.name = "TTSEnableLabel"
	enable_label.text = "Spoken replies"
	enable_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	enable_column.add_child(enable_label)
	tts_enabled_toggle = CheckButton.new()
	tts_enabled_toggle.name = "TTSEnabledToggle"
	tts_enabled_toggle.text = "Enable TTS"
	tts_enabled_toggle.custom_minimum_size = Vector2(220, 44)
	enable_column.add_child(tts_enabled_toggle)

	var tts_provider_column := VBoxContainer.new()
	tts_provider_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	voice_row.add_child(tts_provider_column)
	var tts_provider_label := Label.new()
	tts_provider_label.name = "TTSProviderLabel"
	tts_provider_label.text = "Voice provider"
	tts_provider_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	tts_provider_column.add_child(tts_provider_label)
	tts_provider_option = OptionButton.new()
	tts_provider_option.name = "TTSProviderOption"
	tts_provider_option.add_item("Automatic · Gemini → System")
	tts_provider_option.set_item_metadata(0, "auto")
	tts_provider_option.add_item("Windows system voice")
	tts_provider_option.set_item_metadata(1, "system")
	tts_provider_option.custom_minimum_size = Vector2(260, 44)
	tts_provider_column.add_child(tts_provider_option)
	_style_option_popup(tts_provider_option)

	var voice_column := VBoxContainer.new()
	voice_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	voice_row.add_child(voice_column)
	var voice_label := Label.new()
	voice_label.name = "TTSVoiceLabel"
	voice_label.text = "Voice"
	voice_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	voice_column.add_child(voice_label)
	tts_voice_option = OptionButton.new()
	tts_voice_option.name = "TTSVoiceOption"
	var gemini_voice_catalog := [
		["Automatic", "auto"],
		["Zephyr · Bright", "Zephyr"], ["Puck · Upbeat", "Puck"], ["Charon · Informative", "Charon"],
		["Kore · Firm", "Kore"], ["Fenrir · Excitable", "Fenrir"], ["Leda · Youthful", "Leda"],
		["Orus · Firm", "Orus"], ["Aoede · Breezy", "Aoede"], ["Callirrhoe · Easy-going", "Callirrhoe"],
		["Autonoe · Bright", "Autonoe"], ["Enceladus · Breathy", "Enceladus"], ["Iapetus · Clear", "Iapetus"],
		["Umbriel · Easy-going", "Umbriel"], ["Algieba · Smooth", "Algieba"], ["Despina · Smooth", "Despina"],
		["Erinome · Clear", "Erinome"], ["Algenib · Gravelly", "Algenib"], ["Rasalgethi · Informative", "Rasalgethi"],
		["Laomedeia · Upbeat", "Laomedeia"], ["Achernar · Soft", "Achernar"], ["Alnilam · Firm", "Alnilam"],
		["Schedar · Even", "Schedar"], ["Gacrux · Mature", "Gacrux"], ["Pulcherrima · Forward", "Pulcherrima"],
		["Achird · Friendly", "Achird"], ["Zubenelgenubi · Casual", "Zubenelgenubi"], ["Vindemiatrix · Gentle", "Vindemiatrix"],
		["Sadachbia · Lively", "Sadachbia"], ["Sadaltager · Knowledgeable", "Sadaltager"], ["Sulafat · Warm", "Sulafat"],
	]
	for entry in gemini_voice_catalog:
		tts_voice_option.add_item(str(entry[0]))
		tts_voice_option.set_item_metadata(tts_voice_option.item_count - 1, str(entry[1]))
	tts_voice_option.custom_minimum_size = Vector2(220, 44)
	voice_column.add_child(tts_voice_option)
	_style_option_popup(tts_voice_option)

	var test_voice_column := VBoxContainer.new()
	test_voice_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	voice_row.add_child(test_voice_column)
	var test_voice_label := Label.new()
	test_voice_label.name = "TTSTestLabel"
	test_voice_label.text = "Preview"
	test_voice_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	test_voice_column.add_child(test_voice_label)
	tts_test_button = Button.new()
	tts_test_button.name = "TTSTestButton"
	tts_test_button.text = "Test voice"
	tts_test_button.custom_minimum_size = Vector2(170, 44)
	tts_test_button.pressed.connect(_on_tts_test_pressed)
	test_voice_column.add_child(tts_test_button)

	var credential_row := HBoxContainer.new()
	credential_row.name = "GeminiCredentialRow"
	credential_row.add_theme_constant_override("separation", 14)
	voice_stack.add_child(credential_row)
	var credential_column := VBoxContainer.new()
	credential_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	credential_column.add_theme_constant_override("separation", 6)
	credential_row.add_child(credential_column)
	var credential_label := Label.new()
	credential_label.name = "GeminiCredentialLabel"
	credential_label.text = "Gemini API key"
	credential_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	credential_column.add_child(credential_label)
	gemini_key_input = LineEdit.new()
	gemini_key_input.name = "GeminiCredentialInput"
	gemini_key_input.secret = true
	gemini_key_input.placeholder_text = "Paste a new key to save or replace"
	gemini_key_input.custom_minimum_size = Vector2(360, 44)
	credential_column.add_child(gemini_key_input)
	gemini_key_status = Label.new()
	gemini_key_status.name = "GeminiCredentialStatus"
	gemini_key_status.text = "No Gemini API key stored. Automatic voice will use the Windows fallback."
	gemini_key_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	gemini_key_status.add_theme_font_size_override("font_size", TYPE_CAPTION)
	gemini_key_status.add_theme_color_override("font_color", MUTED)
	credential_column.add_child(gemini_key_status)
	gemini_key_save_button = Button.new()
	gemini_key_save_button.name = "GeminiCredentialSaveButton"
	gemini_key_save_button.text = "Save key securely"
	gemini_key_save_button.custom_minimum_size = Vector2(185, 44)
	gemini_key_save_button.pressed.connect(_on_gemini_key_save_pressed)
	credential_row.add_child(gemini_key_save_button)

	_on_ai_provider_selected(ai_provider_option.selected)


func get_ai_settings_snapshot() -> Dictionary:
	var provider_id := "offline"
	if is_instance_valid(ai_provider_option) and ai_provider_option.selected >= 0:
		provider_id = str(ai_provider_option.get_item_metadata(ai_provider_option.selected))
	var timeout_seconds := 45
	if is_instance_valid(ai_timeout_option) and ai_timeout_option.selected >= 0:
		timeout_seconds = int(ai_timeout_option.get_item_metadata(ai_timeout_option.selected))
	var tts_provider := "auto"
	if is_instance_valid(tts_provider_option) and tts_provider_option.selected >= 0:
		tts_provider = str(tts_provider_option.get_item_metadata(tts_provider_option.selected))
	var voice := "auto"
	if is_instance_valid(tts_voice_option) and tts_voice_option.selected >= 0:
		voice = str(tts_voice_option.get_item_metadata(tts_voice_option.selected))
	return {
		"ai_provider_id": provider_id,
		"ai_base_url": ai_base_url_input.text.strip_edges() if is_instance_valid(ai_base_url_input) else "",
		"ai_model": ai_model_input.text.strip_edges() if is_instance_valid(ai_model_input) else "",
		"ai_timeout_seconds": timeout_seconds,
		"tts_enabled": tts_enabled_toggle.button_pressed if is_instance_valid(tts_enabled_toggle) else false,
		"tts_provider_id": tts_provider,
		"tts_voice": voice,
	}


func sync_ai_settings(settings: Dictionary, status: Dictionary = {}) -> void:
	var provider_id := str(settings.get("ai_provider_id", "offline")).to_lower()
	if is_instance_valid(ai_provider_option):
		for index in range(ai_provider_option.item_count):
			if str(ai_provider_option.get_item_metadata(index)).to_lower() == provider_id:
				ai_provider_option.select(index)
				break
	if is_instance_valid(ai_base_url_input):
		ai_base_url_input.text = str(settings.get("ai_base_url", "http://127.0.0.1:11434"))
	if is_instance_valid(ai_model_input):
		ai_model_input.text = str(settings.get("ai_model", ""))
	if is_instance_valid(ai_timeout_option):
		var desired_timeout := int(settings.get("ai_timeout_seconds", 45))
		for index in range(ai_timeout_option.item_count):
			if int(ai_timeout_option.get_item_metadata(index)) == desired_timeout:
				ai_timeout_option.select(index)
				break
	if is_instance_valid(tts_enabled_toggle):
		tts_enabled_toggle.button_pressed = bool(settings.get("tts_enabled", false))
	if is_instance_valid(tts_provider_option):
		var desired_tts_provider := str(settings.get("tts_provider_id", "auto"))
		for index in range(tts_provider_option.item_count):
			if str(tts_provider_option.get_item_metadata(index)) == desired_tts_provider:
				tts_provider_option.select(index)
				break
	if is_instance_valid(tts_voice_option):
		var desired_voice := str(settings.get("tts_voice", "auto"))
		for index in range(tts_voice_option.item_count):
			if str(tts_voice_option.get_item_metadata(index)) == desired_voice:
				tts_voice_option.select(index)
				break
	_on_ai_provider_selected(ai_provider_option.selected if is_instance_valid(ai_provider_option) else 0)
	if not status.is_empty():
		set_ai_connection_status(status)


func set_ai_connection_status(payload: Dictionary) -> void:
	if not is_instance_valid(ai_connection_status):
		return
	var ok := bool(payload.get("ok", payload.get("reachable", false)))
	var provider_id := str(payload.get("provider_id", "offline"))
	var models_value: Variant = payload.get("models", [])
	if provider_id == "ollama" and models_value is Array and not (models_value as Array).is_empty() and is_instance_valid(ai_model_input):
		var models: Array = models_value
		var current_model := ai_model_input.text.strip_edges()
		if current_model.is_empty() or not models.has(current_model):
			# Do not guess that the newest/largest tag will fit this device. Ollama's
			# own list order is a safer default; the user can still type any model.
			ai_model_input.text = str(models[0])
	var message := str(payload.get("message", payload.get("status_message", ""))).strip_edges()
	if message.is_empty():
		message = "Connected" if ok else ("Offline mode" if provider_id == "offline" else "Not connected")
	ai_connection_status.text = message
	var palette := current_palette if not current_palette.is_empty() else _fallback_palette()
	ai_connection_status.add_theme_color_override(
		"font_color",
		palette.get("success", Color("#62e6b5")) if ok else palette.get("muted", MUTED)
	)


func _on_ai_provider_selected(index: int) -> void:
	var provider_id := "offline"
	if is_instance_valid(ai_provider_option) and index >= 0 and index < ai_provider_option.item_count:
		provider_id = str(ai_provider_option.get_item_metadata(index))
	var ollama_selected := provider_id == "ollama"
	var cloud_selected := provider_id == "openai-compatible"
	var configurable := ollama_selected or cloud_selected
	if is_instance_valid(ai_base_url_input):
		ai_base_url_input.editable = configurable
		ai_base_url_input.placeholder_text = (
			"https://api.openai.com/v1"
			if cloud_selected
			else "http://127.0.0.1:11434"
		)
	if is_instance_valid(ai_model_input):
		ai_model_input.editable = configurable
		ai_model_input.placeholder_text = (
			_localized("ai.model_cloud_placeholder", "Enter the model id exposed by your endpoint")
			if cloud_selected
			else "e.g. qwen3.5:latest"
		)
	if is_instance_valid(ai_timeout_option):
		ai_timeout_option.disabled = not configurable
	if is_instance_valid(ai_test_button):
		ai_test_button.disabled = provider_id == "offline"
	if is_instance_valid(cloud_credential_row):
		cloud_credential_row.visible = cloud_selected


	if is_instance_valid(ai_connection_status):
		if ollama_selected:
			ai_connection_status.text = _localized("ai.status.ready_to_test", "Ready to test the local Ollama connection.")
		elif cloud_selected:
			ai_connection_status.text = _localized("ai.status.cloud_ready", "Configure Base URL, model and secure API key, then save settings.")
		else:
			ai_connection_status.text = _localized("ai.status.offline", "Offline mode — no network provider selected.")


func _on_ai_provider_option_selected(index: int) -> void:
	# Keep the shell UI responsible for presentation only. Runtime activation is
	# routed through the existing save signal so the controller remains the
	# single owner of SettingsService + AIService lifecycle.
	_on_ai_provider_selected(index)
	if not is_instance_valid(ai_provider_option) or index < 0 or index >= ai_provider_option.item_count:
		return
	var provider_id := str(ai_provider_option.get_item_metadata(index)).strip_edges().to_lower()
	if provider_id != "ollama":
		return
	var selected_base_url := ai_base_url_input.text.strip_edges() if is_instance_valid(ai_base_url_input) else ""
	var selected_model := ai_model_input.text.strip_edges() if is_instance_valid(ai_model_input) else ""
	if selected_base_url.is_empty() or selected_model.is_empty():
		return
	# This is a real user selection, not sync_ai_settings() selecting a value
	# programmatically. The controller will persist the choice and reload the
	# active provider, preventing Chat from remaining on Offline.
	ai_settings_save_requested.emit(get_ai_settings_snapshot())


func _on_ai_test_pressed() -> void:
	if is_instance_valid(ai_connection_status):
		ai_connection_status.text = _localized("ai.status.testing", "Testing connection…")
	ai_connection_test_requested.emit(get_ai_settings_snapshot())


func _on_ai_save_pressed() -> void:
	ai_settings_save_requested.emit(get_ai_settings_snapshot())


func _on_tts_test_pressed() -> void:
	var provider_id := "auto"
	if is_instance_valid(tts_provider_option) and tts_provider_option.selected >= 0:
		provider_id = str(tts_provider_option.get_item_metadata(tts_provider_option.selected))
	# The Windows fallback on this machine currently has English SAPI voices
	# only. Keep its diagnostic sample ASCII so Test voice can prove the real
	# playback path independently from Gemini/network availability.
	if provider_id == "system":
		tts_test_requested.emit(_localized("voice.test_sample_system", "Hello! This is your OCP companion voice."))
		return
	tts_test_requested.emit(_localized("voice.test_sample", "Hello! This is your OCP companion voice."))


func _on_gemini_key_save_pressed() -> void:
	_emit_credential_save(
		"gemini-cloud",
		gemini_key_input,
		gemini_key_status,
		_localized("voice.credential.required", "Enter a Gemini API key first.")
	)


func _on_cloud_key_save_pressed() -> void:
	_emit_credential_save(
		"openai-compatible",
		cloud_key_input,
		cloud_key_status,
		_localized("ai.credential.required", "Enter a cloud API key first.")
	)


func _emit_credential_save(provider_id: String, input: LineEdit, status: Label, required_message: String) -> void:
	if not is_instance_valid(input):
		return
	var credential := input.text.strip_edges()
	if credential.is_empty():
		if is_instance_valid(status):
			status.text = required_message
		return
	# The credential exists in GDScript only for this synchronous signal hop.
	# CredentialService immediately sends it to the native OS-keystore bridge;
	# it is never included in settings snapshots, events or package data.
	provider_credential_save_requested.emit(provider_id, credential)
	input.clear()


func sync_provider_credential_status(provider_id: String, present: bool, message: String = "") -> void:
	var clean_id := provider_id.strip_edges().to_lower()
	if is_instance_valid(ai_voice_page):
		ai_voice_page.set_meta("%s_credential_present" % clean_id.replace("-", "_"), present)
	match clean_id:
		"gemini-cloud":
			if is_instance_valid(gemini_key_input):
				gemini_key_input.clear()
				gemini_key_input.placeholder_text = _localized(
					"voice.credential.replace_placeholder" if present else "voice.credential.placeholder",
					"Paste a new key to replace the stored key" if present else "Paste Gemini API key"
				)
			if is_instance_valid(gemini_key_status):
				gemini_key_status.text = message if not message.strip_edges().is_empty() else (
					_localized("voice.credential.stored", "A Gemini API key is stored securely. Validity is checked when Gemini is used.")
					if present
					else _localized("voice.credential.missing", "No Gemini API key stored. Automatic voice will use the Windows fallback.")
				)
			if is_instance_valid(gemini_key_save_button):
				gemini_key_save_button.text = _localized(
					"voice.credential.replace" if present else "voice.credential.save",
					"Replace key" if present else "Save key securely"
				)
		"openai-compatible":
			if is_instance_valid(cloud_key_input):
				cloud_key_input.clear()
				cloud_key_input.placeholder_text = _localized(
					"ai.credential.replace_placeholder" if present else "ai.credential.placeholder",
					"Paste a new key to replace the stored key" if present else "Paste cloud API key"
				)
			if is_instance_valid(cloud_key_status):
				cloud_key_status.text = message if not message.strip_edges().is_empty() else (
					_localized("ai.credential.stored", "A cloud API key is stored securely. It is never exposed to Godot settings or chat events.")
					if present
					else _localized("ai.credential.missing", "No cloud API key stored.")
				)
			if is_instance_valid(cloud_key_save_button):
				cloud_key_save_button.text = _localized(
					"ai.credential.replace" if present else "ai.credential.save",
					"Replace key" if present else "Save key securely"
				)


func _new_card(title_text: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.set_meta("ocp_mock_theme_locked", true)
	card.clip_contents = true
	if title_text in ["Appearance", "Resource Monitor"]:
		var wave := AMBIENT_WAVE_SCRIPT.new()
		wave.name = "%sAmbientWave" % title_text.replace(" ", "")
		wave.configure("top_right")
		card.add_child(wave)
		ambient_waves.append(wave)
	var margin := MarginContainer.new()
	margin.name = "CardMargin"
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_bottom", 18)
	card.add_child(margin)
	var stack := VBoxContainer.new()
	stack.name = "CardStack"
	stack.add_theme_constant_override("separation", 10)
	margin.add_child(stack)
	var title_label := Label.new()
	title_label.name = "CardTitle"
	title_label.text = title_text
	title_label.add_theme_font_size_override("font_size", TYPE_SECTION)
	stack.add_child(title_label)
	return card


func _card_stack(card: PanelContainer) -> VBoxContainer:
	return card.get_node("CardMargin/CardStack") as VBoxContainer


func _build_appearance_card(card: PanelContainer) -> void:
	var stack := _card_stack(card)
	var content := HFlowContainer.new()
	content.add_theme_constant_override("h_separation", 28)
	content.add_theme_constant_override("v_separation", 14)
	stack.add_child(content)

	var themes_column := VBoxContainer.new()
	themes_column.custom_minimum_size = Vector2(430, 0)
	themes_column.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	themes_column.add_theme_constant_override("separation", 7)
	content.add_child(themes_column)
	var theme_label := Label.new()
	theme_label.name = "ThemeLabel"
	theme_label.text = "Theme"
	theme_label.add_theme_font_size_override("font_size", TYPE_BODY)
	themes_column.add_child(theme_label)
	var theme_row := HBoxContainer.new()
	theme_row.add_theme_constant_override("separation", 10)
	themes_column.add_child(theme_row)
	for theme_name in ["solid", "glass", "liquid"]:
		var preview_column := VBoxContainer.new()
		preview_column.custom_minimum_size = Vector2(116, 0)
		preview_column.add_theme_constant_override("separation", 5)
		theme_row.add_child(preview_column)
		var button := Button.new()
		button.text = ""
		button.tooltip_text = "Use %s theme" % theme_name.capitalize()
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(132, 88)
		button.icon = _theme_preview_texture(theme_name)
		button.expand_icon = true
		button.add_theme_constant_override("icon_max_width", 108)
		button.pressed.connect(func(): _on_theme_card_pressed(theme_name))
		preview_column.add_child(button)
		var caption := Label.new()
		caption.text = theme_name.capitalize()
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.add_theme_font_size_override("font_size", TYPE_CAPTION)
		preview_column.add_child(caption)
		theme_buttons[theme_name] = button

	var preferences := HBoxContainer.new()
	preferences.custom_minimum_size = Vector2(600, 0)
	preferences.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preferences.add_theme_constant_override("separation", 16)
	content.add_child(preferences)
	var font_column := VBoxContainer.new()
	font_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	font_column.add_theme_constant_override("separation", 7)
	preferences.add_child(font_column)
	var font_label := Label.new()
	font_label.name = "FontLabel"
	font_label.text = "Font"
	font_label.add_theme_font_size_override("font_size", TYPE_BODY)
	font_column.add_child(font_label)
	font_option = OptionButton.new()
	font_option.custom_minimum_size = Vector2(0, 44)
	font_option.add_item("Noto Sans Thai")
	font_option.add_item("Segoe UI")
	font_option.add_item("Leelawadee UI")
	font_option.add_item("Tahoma")
	font_option.add_item("Arial")
	font_column.add_child(font_option)
	_style_option_popup(font_option)
	var text_scale_label := Label.new()
	text_scale_label.name = "TextScaleLabel"
	text_scale_label.text = "Text size"
	text_scale_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	font_column.add_child(text_scale_label)
	text_scale_option = OptionButton.new()
	text_scale_option.name = "TextScaleOption"
	text_scale_option.custom_minimum_size = Vector2(0, 40)
	for item in [["text_scale.normal", "Normal", 1.0], ["text_scale.standard", "Standard", 1.15], ["text_scale.comfortable", "Comfortable", 1.30], ["text_scale.large", "Large", 1.50], ["text_scale.extra", "Extra", 1.80]]:
		text_scale_option.add_item(_localized(str(item[0]), str(item[1])))
		text_scale_option.set_item_metadata(text_scale_option.item_count - 1, float(item[2]))
	text_scale_option.item_selected.connect(_on_text_scale_option_selected)
	font_column.add_child(text_scale_option)
	_style_option_popup(text_scale_option)
	var bubble_column := VBoxContainer.new()
	bubble_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bubble_column.add_theme_constant_override("separation", 7)
	preferences.add_child(bubble_column)
	var bubble_label := Label.new()
	bubble_label.name = "BubbleStyleLabel"
	bubble_label.text = "Bubble style"
	bubble_label.add_theme_font_size_override("font_size", 14)
	bubble_column.add_child(bubble_label)
	bubble_option = OptionButton.new()
	bubble_option.custom_minimum_size = Vector2(0, 44)
	for item in ["Rounded", "Compact", "Soft"]:
		bubble_option.add_item(item)
	bubble_column.add_child(bubble_option)
	_style_option_popup(bubble_option)

	var language_column := VBoxContainer.new()
	language_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	language_column.add_theme_constant_override("separation", 7)
	preferences.add_child(language_column)
	var language_label := Label.new()
	language_label.name = "LanguageLabel"
	language_label.text = "Language"
	language_label.add_theme_font_size_override("font_size", 14)
	language_column.add_child(language_label)
	language_option = OptionButton.new()
	language_option.custom_minimum_size = Vector2(0, 44)
	language_option.add_item("English")
	language_option.set_item_metadata(0, "en")
	language_option.add_item("ไทย")
	language_option.set_item_metadata(1, "th")
	language_option.item_selected.connect(_on_language_option_selected)
	language_column.add_child(language_option)
	_style_option_popup(language_option)


func _style_option_popup(option: OptionButton) -> void:
	if not is_instance_valid(option):
		return
	var palette := current_palette if not current_palette.is_empty() else _fallback_palette()
	var strong: Color = palette.get("surface_strong", Color("#07152a"))
	var surface: Color = palette.get("surface", Color("#0b1d36"))
	var border: Color = palette.get("border", Color(0.18, 0.55, 0.92, 0.74))
	var accent: Color = palette.get("accent", CYAN)
	var text: Color = palette.get("text", TEXT)
	var muted: Color = palette.get("muted", MUTED)
	var theme_key := selected_theme.to_lower()
	var popup_alpha := 1.0 if theme_key == "solid" else 0.97
	var option_alpha := 0.90 if theme_key == "solid" else (0.70 if theme_key == "glass" else 0.74)

	option.add_theme_font_size_override("font_size", TYPE_CONTROL)
	option.add_theme_color_override("font_color", text)
	option.add_theme_color_override("font_hover_color", text)
	option.add_theme_stylebox_override("normal", _panel_style(Color(surface, option_alpha), Color(border, 0.54), 11, 0))
	option.add_theme_stylebox_override("hover", _panel_style(Color(surface.lightened(0.04), minf(option_alpha + 0.10, 1.0)), Color(accent, 0.86), 11, 5))
	option.add_theme_stylebox_override("pressed", _panel_style(Color(accent, 0.16), Color(accent, 0.96), 11, 7))
	option.add_theme_stylebox_override("focus", _panel_style(Color(surface, option_alpha), Color(accent, 0.92), 11, 6))
	option.add_theme_icon_override("arrow", _dropdown_arrow_texture(accent.lightened(0.25)))

	var popup := option.get_popup()
	if not is_instance_valid(popup):
		return
	popup.borderless = true
	popup.transparent = false
	popup.transparent_bg = false
	popup.add_theme_font_size_override("font_size", 14)
	popup.add_theme_color_override("font_color", text)
	popup.add_theme_color_override("font_hover_color", Color.WHITE)
	popup.add_theme_color_override("font_disabled_color", Color(muted, 0.48))
	popup.add_theme_color_override("font_separator_color", muted)
	popup.add_theme_stylebox_override("panel", _panel_style(Color(strong, popup_alpha), Color(border, 0.76), 11, 0))
	popup.add_theme_constant_override("shadow_size", 0)
	popup.add_theme_constant_override("shadow_outline_size", 0)
	popup.add_theme_stylebox_override("hover", _panel_style(Color(accent, 0.16), Color(accent, 0.82), 8, 0))
	popup.add_theme_stylebox_override("separator", _panel_style(Color(border, 0.16), Color.TRANSPARENT, 0, 0))
	popup.add_theme_constant_override("item_start_padding", 15)
	popup.add_theme_constant_override("item_end_padding", 15)
	popup.add_theme_constant_override("v_separation", 8)
	if not popup.about_to_popup.is_connected(_prepare_option_popup.bind(option)):
		popup.about_to_popup.connect(_prepare_option_popup.bind(option))


func _prepare_option_popup(option: OptionButton) -> void:
	if not is_instance_valid(option):
		return
	var popup := option.get_popup()
	if not is_instance_valid(popup):
		return
	# PopupMenu sometimes inherits a very short cached height and displays an
	# unnecessary scrollbar. Give the small OCP menus enough native space.
	for index in range(popup.item_count):
		popup.set_item_as_radio_checkable(index, false)
		popup.set_item_as_checkable(index, false)
	var item_height := 46
	var desired_height := maxi(64, option.item_count * item_height + 20)
	var desired_width := maxi(int(option.size.x), 190)
	popup.min_size = Vector2i(desired_width, desired_height)
	popup.size = Vector2i(desired_width, desired_height)


func _dropdown_arrow_texture(color: Color = Color("#a9bdd8")) -> Texture2D:
	var stroke := color.to_html(false)
	var svg := """
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18" fill="none">
  <path d="M5 7l4 4 4-4" stroke="#%s" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
""" % stroke
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _build_behavior_card(card: PanelContainer) -> void:
	var stack := _card_stack(card)
	click_through_toggle = _add_toggle_row(stack, "Click-through", "Allow clicks to pass through the desktop character", "ClickThroughRow")
	_add_behavior_separator(stack)
	start_with_windows_toggle = _add_toggle_row(stack, "Start with Windows", "Launch OCP when you sign in", "StartWithWindowsRow")
	_add_behavior_separator(stack)
	offline_presence_toggle = _add_toggle_row(stack, "Enable Offline companion activity", "Run local-only animations and floor walks while AI services are offline", "OfflineActivityRow")
	offline_presence_toggle.toggled.connect(func(enabled: bool):
		_update_offline_presence_status(enabled)
		offline_presence_changed.emit(enabled)
	)
	offline_presence_status = Label.new()
	offline_presence_status.add_theme_font_size_override("font_size", TYPE_CAPTION)
	offline_presence_status.add_theme_color_override("font_color", MUTED)
	stack.add_child(offline_presence_status)
	_update_offline_presence_status(offline_presence_toggle.button_pressed)


func _update_offline_presence_status(enabled: bool) -> void:
	if not is_instance_valid(offline_presence_status):
		return
	offline_presence_status.text = _localized(
		"behavior.offline.running" if enabled else "behavior.offline.stopped",
		"Offline Bot: Running — local-only animations and floor walks" if enabled else "Offline Bot: Stopped — no scheduled actions"
	)
	offline_presence_status.add_theme_color_override(
		"font_color",
		Color("#9fc4f3") if enabled else MUTED
	)


func _add_behavior_separator(parent: VBoxContainer) -> void:
	var separator := HSeparator.new()
	separator.modulate = Color(0.18, 0.50, 0.78, 0.24)
	parent.add_child(separator)


func _add_toggle_row(parent: VBoxContainer, title_text: String, detail: String, row_name: String = "") -> CheckButton:
	var row := HBoxContainer.new()
	if not row_name.is_empty():
		row.name = row_name
	row.custom_minimum_size = Vector2(0, 50)
	parent.add_child(row)
	var copy := VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_constant_override("separation", 1)
	row.add_child(copy)
	var title_label := Label.new()
	title_label.name = "Title"
	title_label.text = title_text
	title_label.add_theme_font_size_override("font_size", TYPE_BODY)
	copy.add_child(title_label)
	var detail_label := Label.new()
	detail_label.name = "Detail"
	detail_label.text = detail
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
	copy.add_child(detail_label)
	var toggle := CheckButton.new()
	toggle.text = ""
	toggle.custom_minimum_size = Vector2(58, 0)
	_apply_toggle_icons(toggle)
	row.add_child(toggle)
	return toggle


func _build_resource_card(card: PanelContainer) -> void:
	var stack := _card_stack(card)
	resource_inner_panel = PanelContainer.new()
	resource_inner_panel.name = "ResourceInnerPanel"
	resource_inner_panel.set_meta("ocp_mock_theme_locked", true)
	resource_inner_panel.custom_minimum_size = Vector2(0, 126)
	stack.add_child(resource_inner_panel)
	var inner_margin := MarginContainer.new()
	inner_margin.add_theme_constant_override("margin_left", 20)
	inner_margin.add_theme_constant_override("margin_top", 8)
	inner_margin.add_theme_constant_override("margin_right", 20)
	inner_margin.add_theme_constant_override("margin_bottom", 8)
	resource_inner_panel.add_child(inner_margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 28)
	inner_margin.add_child(row)
	cpu_gauge = GAUGE_SCRIPT.new()
	cpu_gauge.configure("CPU", Color("#23a8ff"))
	cpu_gauge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(cpu_gauge)
	var divider := VSeparator.new()
	divider.custom_minimum_size = Vector2(1, 96)
	divider.modulate = Color(0.32, 0.54, 0.82, 0.48)
	row.add_child(divider)
	memory_gauge = GAUGE_SCRIPT.new()
	memory_gauge.configure("System RAM", Color("#8b4dff"))
	memory_gauge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(memory_gauge)


func _style_chat_page() -> void:
	if not is_instance_valid(chat_page):
		return
	chat_window.min_size = Vector2i(820, 600)
	if chat_window.size.x < 980 or chat_window.size.y < 700:
		chat_window.size = Vector2i(1040, 740)
	chat_page.add_theme_constant_override("margin_left", 22)
	chat_page.add_theme_constant_override("margin_top", 12)
	chat_page.add_theme_constant_override("margin_right", 22)
	chat_page.add_theme_constant_override("margin_bottom", 12)
	var layout := chat_page.get_node_or_null("ChatLayout") as VBoxContainer
	if not is_instance_valid(layout):
		return
	layout.set_meta("ocp_mock_theme_locked", true)
	layout.add_theme_constant_override("separation", 10)

	# The custom native title bar already owns the page title. Keeping another
	# large "Chat" heading inside the surface wastes vertical space and differs
	# from the floating-window mock, so the companion identity strip becomes the
	# visual header instead.
	var header := chat_page.get_node_or_null("ChatLayout/ChatHeader") as Label
	if is_instance_valid(header):
		header.visible = false

	var identity := layout.get_node_or_null("ChatIdentityCard") as PanelContainer
	if not is_instance_valid(identity):
		identity = PanelContainer.new()
		identity.name = "ChatIdentityCard"
		identity.custom_minimum_size = Vector2(0, 66)
		identity.set_meta("ocp_mock_theme_locked", true)
		layout.add_child(identity)
		layout.move_child(identity, 0)
		var identity_margin := MarginContainer.new()
		identity_margin.add_theme_constant_override("margin_left", 12)
		identity_margin.add_theme_constant_override("margin_top", 7)
		identity_margin.add_theme_constant_override("margin_right", 12)
		identity_margin.add_theme_constant_override("margin_bottom", 7)
		identity.add_child(identity_margin)
		var identity_row := HBoxContainer.new()
		identity_row.name = "IdentityRow"
		identity_row.add_theme_constant_override("separation", 10)
		identity_margin.add_child(identity_row)
		var avatar_shell := PanelContainer.new()
		avatar_shell.name = "ChatIdentityAvatar"
		avatar_shell.custom_minimum_size = Vector2(48, 48)
		avatar_shell.set_meta("ocp_mock_theme_locked", true)
		identity_row.add_child(avatar_shell)
		var avatar_center := CenterContainer.new()
		avatar_shell.add_child(avatar_center)
		var avatar := TextureRect.new()
		avatar.name = "ChatIdentityAvatarTexture"
		avatar.custom_minimum_size = Vector2(38, 38)
		avatar.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		avatar.texture = load("res://assets/icons/ocp.svg") as Texture2D
		avatar_center.add_child(avatar)
		var identity_copy := VBoxContainer.new()
		identity_copy.name = "IdentityCopy"
		identity_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		identity_copy.alignment = BoxContainer.ALIGNMENT_CENTER
		identity_copy.add_theme_constant_override("separation", 2)
		identity_row.add_child(identity_copy)
		var name_label := Label.new()
		name_label.name = "CompanionName"
		name_label.text = current_companion_name
		name_label.add_theme_font_size_override("font_size", 18)
		identity_copy.add_child(name_label)
		var description := Label.new()
		description.name = "CompanionSubtitle"
		description.text = "Your friendly AI companion"
		description.add_theme_font_size_override("font_size", TYPE_BODY)
		description.add_theme_color_override("font_color", MUTED)
		identity_copy.add_child(description)
		var badge := PanelContainer.new()
		badge.name = "ChatConnectionBadge"
		badge.custom_minimum_size = Vector2(104, 30)
		badge.set_meta("ocp_mock_theme_locked", true)
		identity_row.add_child(badge)
		var badge_center := CenterContainer.new()
		badge.add_child(badge_center)
		var badge_label := Label.new()
		badge_label.name = "ChatConnectionBadgeLabel"
		badge_label.text = "Offline mode"
		badge_label.add_theme_font_size_override("font_size", TYPE_CAPTION)
		badge_center.add_child(badge_label)

	# Re-apply compact identity metrics on every style pass because the node may
	# already exist when theme/language changes are previewed.
	identity.custom_minimum_size = Vector2(0, 60)
	var identity_avatar_shell := identity.find_child("ChatIdentityAvatar", true, false) as PanelContainer
	if is_instance_valid(identity_avatar_shell):
		identity_avatar_shell.custom_minimum_size = Vector2(44, 44)
	var identity_avatar_texture := identity.find_child("ChatIdentityAvatarTexture", true, false) as TextureRect
	if is_instance_valid(identity_avatar_texture):
		identity_avatar_texture.custom_minimum_size = Vector2(36, 36)
	var connection_badge := identity.find_child("ChatConnectionBadge", true, false) as PanelContainer
	if is_instance_valid(connection_badge):
		connection_badge.custom_minimum_size = Vector2(100, 28)

	var status := chat_page.get_node_or_null("ChatLayout/ChatStatus") as Label
	if is_instance_valid(status):
		# Provider diagnostics belong in AI & Voice, not in the conversation
		# surface. The compact status badge communicates the useful state.
		status.visible = false

	var transcript_frame := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame") as PanelContainer
	if is_instance_valid(transcript_frame):
		# The conversation canvas should feel open like the mock, not like a
		# large empty bordered form field. Messages own the visual hierarchy.
		transcript_frame.custom_minimum_size = Vector2(0, 390)
		transcript_frame.add_theme_stylebox_override("panel", _panel_style(Color(0.02, 0.07, 0.15, 0.10), Color(0.20, 0.54, 0.86, 0.10), 16, 0))
	var transcript_margins := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins") as MarginContainer
	if is_instance_valid(transcript_margins):
		transcript_margins.add_theme_constant_override("margin_left", 18)
		transcript_margins.add_theme_constant_override("margin_top", 14)
		transcript_margins.add_theme_constant_override("margin_right", 22)
		transcript_margins.add_theme_constant_override("margin_bottom", 14)
	var transcript := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript") as ScrollContainer
	if is_instance_valid(transcript):
		transcript.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		transcript.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_style_chat_scroll_bar(transcript.get_v_scroll_bar(), CYAN)
	var messages := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages") as VBoxContainer
	if is_instance_valid(messages):
		messages.add_theme_constant_override("separation", 14)

	var assistant_row := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow") as HBoxContainer
	if is_instance_valid(assistant_row):
		assistant_row.add_theme_constant_override("separation", 10)
		if not is_instance_valid(assistant_row.get_node_or_null("AssistantAvatar")):
			var assistant_avatar := PanelContainer.new()
			assistant_avatar.name = "AssistantAvatar"
			assistant_avatar.custom_minimum_size = Vector2(38, 38)
			assistant_avatar.set_meta("ocp_mock_theme_locked", true)
			assistant_row.add_child(assistant_avatar)
			assistant_row.move_child(assistant_avatar, 0)
			var assistant_avatar_center := CenterContainer.new()
			assistant_avatar.add_child(assistant_avatar_center)
			var assistant_avatar_icon := TextureRect.new()
			assistant_avatar_icon.name = "AssistantAvatarTexture"
			assistant_avatar_icon.custom_minimum_size = Vector2(30, 30)
			assistant_avatar_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
			assistant_avatar_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			assistant_avatar_icon.texture = load("res://assets/icons/ocp.svg") as Texture2D
			assistant_avatar_center.add_child(assistant_avatar_icon)

	var assistant_card := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow/AssistantCard") as PanelContainer
	if is_instance_valid(assistant_card):
		assistant_card.custom_minimum_size = Vector2(400, 0)
		assistant_card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		assistant_card.add_theme_stylebox_override("panel", _panel_style(Color(0.08, 0.15, 0.27, 0.86), Color(0.34, 0.62, 0.90, 0.40), 16, 3))
	var assistant_margins := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow/AssistantCard/AssistantMargins") as MarginContainer
	if is_instance_valid(assistant_margins):
		assistant_margins.add_theme_constant_override("margin_left", 16)
		assistant_margins.add_theme_constant_override("margin_top", 12)
		assistant_margins.add_theme_constant_override("margin_right", 16)
		assistant_margins.add_theme_constant_override("margin_bottom", 12)
	var assistant := chat_page.get_node_or_null("ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow/AssistantCard/AssistantMargins/AssistantText") as Label
	if is_instance_valid(assistant):
		assistant.text = _chat_greeting_text()
		assistant.add_theme_font_size_override("font_size", TYPE_CONTROL)

	var input_row := chat_page.get_node_or_null("ChatLayout/ChatInputRow") as HBoxContainer
	if is_instance_valid(input_row):
		# ChatGPT-like usability: the composer reads as one surface instead of
		# four adjacent cards. ChatInputRow now only carries the outer Composer.
		input_row.add_theme_constant_override("separation", 0)
		input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var composer := chat_page.get_node_or_null("ChatLayout/ChatInputRow/Composer") as PanelContainer
	if is_instance_valid(composer):
		composer.custom_minimum_size = Vector2(0, 86)
		composer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		composer.add_theme_stylebox_override("panel", _panel_style(Color(0.035, 0.10, 0.22, 0.90), Color(0.25, 0.60, 0.98, 0.46), 18, 4))
	var composer_margins := chat_page.get_node_or_null("ChatLayout/ChatInputRow/Composer/ComposerMargins") as MarginContainer
	if is_instance_valid(composer_margins):
		composer_margins.add_theme_constant_override("margin_left", 12)
		composer_margins.add_theme_constant_override("margin_top", 8)
		composer_margins.add_theme_constant_override("margin_right", 10)
		composer_margins.add_theme_constant_override("margin_bottom", 8)

	# Build a unified composer stack lazily so existing controller object
	# references stay valid while the visual hierarchy becomes input + actions.
	var composer_stack := composer_margins.get_node_or_null("ComposerStack") as VBoxContainer if is_instance_valid(composer_margins) else null
	if is_instance_valid(composer_margins) and not is_instance_valid(composer_stack):
		composer_stack = VBoxContainer.new()
		composer_stack.name = "ComposerStack"
		composer_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		composer_stack.add_theme_constant_override("separation", 4)
		composer_margins.add_child(composer_stack)

	var input := chat_root.find_child("ChatInput", true, false) as TextEdit if is_instance_valid(chat_root) else null
	if is_instance_valid(input) and is_instance_valid(composer_stack):
		if input.get_parent() != composer_stack:
			var input_owner := input.owner
			input.owner = null
			input.reparent(composer_stack)
			if is_instance_valid(input_owner):
				input.owner = input_owner
		input.placeholder_text = _localized("chat.placeholder", "Type your message...")
		input.custom_minimum_size = Vector2(0, 38)
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		input.add_theme_font_size_override("font_size", TYPE_CONTROL)
		var input_empty := StyleBoxEmpty.new()
		input.add_theme_stylebox_override("normal", input_empty)
		input.add_theme_stylebox_override("focus", input_empty)
		input.add_theme_stylebox_override("read_only", input_empty)
		_style_chat_scroll_bar(input.get_v_scroll_bar(), CYAN)
		if not input.text_changed.is_connected(_refresh_chat_composer_height):
			input.text_changed.connect(_refresh_chat_composer_height)

	var actions := composer_stack.get_node_or_null("ComposerActions") as HBoxContainer if is_instance_valid(composer_stack) else null
	if is_instance_valid(composer_stack) and not is_instance_valid(actions):
		actions = HBoxContainer.new()
		actions.name = "ComposerActions"
		actions.custom_minimum_size = Vector2(0, 34)
		actions.add_theme_constant_override("separation", 6)
		composer_stack.add_child(actions)

	var model_option := chat_root.find_child("ChatModelOption", true, false) as OptionButton if is_instance_valid(chat_root) else null
	if is_instance_valid(actions) and not is_instance_valid(model_option):
		model_option = OptionButton.new()
		model_option.name = "ChatModelOption"
		model_option.add_item(_localized("chat.profile_local", "Local"))
		model_option.select(0)
		model_option.focus_mode = Control.FOCUS_NONE
		actions.add_child(model_option)
	if is_instance_valid(model_option) and is_instance_valid(actions):
		if model_option.get_parent() != actions:
			model_option.reparent(actions)
		model_option.tooltip_text = _localized("chat.profile_tooltip", "AI profile")
		model_option.custom_minimum_size = Vector2(118, 34)

	var action_spacer := actions.get_node_or_null("ComposerActionSpacer") as Control if is_instance_valid(actions) else null
	if is_instance_valid(actions) and not is_instance_valid(action_spacer):
		action_spacer = Control.new()
		action_spacer.name = "ComposerActionSpacer"
		action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(action_spacer)

	var voice := chat_root.find_child("VoiceChatButton", true, false) as Button if is_instance_valid(chat_root) else null
	var send := chat_root.find_child("SendChatButton", true, false) as Button if is_instance_valid(chat_root) else null
	if is_instance_valid(voice) and is_instance_valid(actions):
		if voice.get_parent() != actions:
			var voice_owner := voice.owner
			voice.owner = null
			voice.reparent(actions)
			if is_instance_valid(voice_owner):
				voice.owner = voice_owner
		voice.text = ""
		voice.icon = _chat_action_icon("mic", CYAN)
		voice.expand_icon = true
		voice.tooltip_text = _localized("chat.voice", "Voice chat")
		voice.custom_minimum_size = Vector2(36, 34)
		voice.add_theme_constant_override("icon_max_width", 19)
	if is_instance_valid(send) and is_instance_valid(actions):
		if send.get_parent() != actions:
			var send_owner := send.owner
			send.owner = null
			send.reparent(actions)
			if is_instance_valid(send_owner):
				send.owner = send_owner
		send.text = ""
		send.icon = _chat_action_icon("send", Color.WHITE)
		send.expand_icon = true
		send.tooltip_text = _localized("chat.send", "Send message")
		send.custom_minimum_size = Vector2(42, 34)
		send.add_theme_constant_override("icon_max_width", 20)

	# Normalize action order after reparenting from older layouts.
	if is_instance_valid(actions):
		if is_instance_valid(model_option):
			actions.move_child(model_option, 0)
		if is_instance_valid(action_spacer):
			actions.move_child(action_spacer, mini(1, actions.get_child_count() - 1))
		if is_instance_valid(voice):
			actions.move_child(voice, mini(2, actions.get_child_count() - 1))
		if is_instance_valid(send):
			actions.move_child(send, actions.get_child_count() - 1)
	_refresh_chat_composer_height()
	_ensure_chat_typing_indicator()

	var footnote := chat_page.get_node_or_null("ChatLayout/ChatFootnote") as Label
	if is_instance_valid(footnote):
		# Shortcut help is available via tooltips; keeping it permanently visible
		# makes the composer feel diagnostic rather than conversational.
		footnote.visible = false
	_sync_chat_companion_portrait()


func _sync_chat_companion_portrait() -> void:
	if not is_instance_valid(chat_root):
		return
	var portrait := _active_chat_portrait_texture()
	if portrait == null:
		return
	for node_name in ["ChatIdentityAvatarTexture", "AssistantAvatarTexture"]:
		var target := chat_root.find_child(node_name, true, false) as TextureRect
		if is_instance_valid(target):
			target.texture = portrait
			target.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED


func _active_chat_portrait_texture() -> Texture2D:
	var runtime_root := get_parent()
	if not is_instance_valid(runtime_root):
		return null
	var sprite := runtime_root.get_node_or_null("RuntimeUI/CompanionLayer/CompanionHost/CompanionSprite") as AnimatedSprite2D
	if not is_instance_valid(sprite) or sprite.sprite_frames == null:
		return null
	var frames := sprite.sprite_frames
	var animation := sprite.animation
	if not frames.has_animation(animation) or frames.get_frame_count(animation) <= 0:
		var names := frames.get_animation_names()
		if names.is_empty():
			return null
		animation = names[0]
	var frame_count := frames.get_frame_count(animation)
	if frame_count <= 0:
		return null
	var frame_index := clampi(sprite.frame, 0, frame_count - 1)
	var frame_texture := frames.get_frame_texture(animation, frame_index)
	if frame_texture == null:
		return null

	# SpriteFrames commonly use AtlasTexture regions. Reading the atlas directly
	# without extracting the region makes the portrait detector see the complete
	# sprite sheet and produces a tiny full-body thumbnail. Extract the actual
	# frame first, then crop the alpha bounds to a head/shoulders portrait.
	var image: Image = null
	var atlas_texture := frame_texture as AtlasTexture
	if is_instance_valid(atlas_texture) and atlas_texture.atlas != null:
		var atlas_image := atlas_texture.atlas.get_image()
		if atlas_image != null and not atlas_image.is_empty():
			var region := Rect2i(atlas_texture.region)
			if region.size.x > 0 and region.size.y > 0:
				image = atlas_image.get_region(region)
	if image == null:
		image = frame_texture.get_image()
	if image == null or image.is_empty():
		return frame_texture

	var used := _alpha_used_rect(image, 0.04)
	if used.size.x <= 0 or used.size.y <= 0:
		return frame_texture
	# Chibi companions have proportionally large heads. A tighter crop based on
	# roughly the top quarter of character height keeps the face readable in a
	# 32-48 px avatar while retaining enough shoulder context for identity.
	var portrait_side := int(round(maxf(float(used.size.x) * 0.78, float(used.size.y) * 0.27)))
	portrait_side = clampi(portrait_side, 1, mini(image.get_width(), image.get_height()))
	var center_x := used.position.x + used.size.x / 2
	var crop_x := clampi(center_x - portrait_side / 2, 0, maxi(0, image.get_width() - portrait_side))
	var top_bias := int(round(float(used.size.y) * 0.015))
	var crop_y := clampi(used.position.y + top_bias, 0, maxi(0, image.get_height() - portrait_side))
	var crop := Rect2i(crop_x, crop_y, portrait_side, portrait_side)
	var portrait_image := image.get_region(crop)
	if portrait_image == null or portrait_image.is_empty():
		return frame_texture
	return ImageTexture.create_from_image(portrait_image)


func _alpha_used_rect(image: Image, threshold: float) -> Rect2i:
	if image == null or image.is_empty():
		return Rect2i()
	var min_x := image.get_width()
	var min_y := image.get_height()
	var max_x := -1
	var max_y := -1
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			if image.get_pixel(x, y).a <= threshold:
				continue
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)
	if max_x < min_x or max_y < min_y:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _style_chat_scroll_bar(bar: VScrollBar, accent_color: Color) -> void:
	if not is_instance_valid(bar):
		return
	bar.custom_minimum_size.x = 5.0
	bar.add_theme_stylebox_override("scroll", StyleBoxEmpty.new())
	bar.add_theme_stylebox_override("grabber", _panel_style(Color(accent_color, 0.22), Color.TRANSPARENT, 3, 0))
	bar.add_theme_stylebox_override("grabber_highlight", _panel_style(Color(accent_color, 0.38), Color.TRANSPARENT, 3, 0))
	bar.add_theme_stylebox_override("grabber_pressed", _panel_style(Color(accent_color, 0.52), Color.TRANSPARENT, 3, 0))


func _refresh_chat_composer_height() -> void:
	if not is_instance_valid(chat_root):
		return
	var input := chat_root.find_child("ChatInput", true, false) as TextEdit
	var composer := chat_root.find_child("Composer", true, false) as PanelContainer
	if not is_instance_valid(input) or not is_instance_valid(composer):
		return
	var actual_lines := maxi(1, input.get_line_count())
	var visible_lines := clampi(actual_lines, 1, 4)
	var line_height := maxi(21, int(round(float(TYPE_CONTROL) * 1.35)))
	var input_height := clampi(38 + (visible_lines - 1) * line_height, 38, 102)
	input.custom_minimum_size.y = input_height
	input.scroll_fit_content_height = actual_lines <= 4
	# Outer surface includes the compact action row beneath the editor.
	composer.custom_minimum_size.y = input_height + 54


func _ensure_chat_typing_indicator() -> void:
	if not is_instance_valid(chat_root):
		return
	var messages := chat_root.get_node_or_null("Chat/ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages") as VBoxContainer
	if not is_instance_valid(messages) or is_instance_valid(messages.get_node_or_null("TypingIndicator")):
		return
	var typing := Label.new()
	typing.name = "TypingIndicator"
	typing.text = _localized("chat.typing", "Thinking") + "  ···"
	typing.visible = false
	typing.custom_minimum_size = Vector2(220, 42)
	typing.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	typing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	typing.add_theme_font_size_override("font_size", TYPE_BODY)
	typing.add_theme_color_override("font_color", Color("#9ecbff"))
	messages.add_child(typing)


func _avoid_companion_overlap_for_window(target: Window) -> void:
	if not is_instance_valid(target):
		return

	# Do not resolve the screen from the child Window's native id here. A child
	# Window can exist as a Godot object before Windows has registered its HWND,
	# which returns INVALID_SCREEN and logs an error on first Chat open.
	# Resolve the screen from geometry instead; this is also stable across DPI and
	# multi-monitor transitions.
	var target_rect := Rect2i(target.position, target.size)
	var target_center := target_rect.position + target_rect.size / 2
	var screen := -1
	for screen_index in range(DisplayServer.get_screen_count()):
		if DisplayServer.screen_get_usable_rect(screen_index).has_point(target_center):
			screen = screen_index
			break
	if screen < 0:
		var main_screen := DisplayServer.window_get_current_screen(DisplayServer.MAIN_WINDOW_ID)
		screen = main_screen if main_screen >= 0 else DisplayServer.get_primary_screen()

	var usable := DisplayServer.screen_get_usable_rect(screen)
	var companion_position := DisplayServer.window_get_position(DisplayServer.MAIN_WINDOW_ID)
	var companion_size := DisplayServer.window_get_size(DisplayServer.MAIN_WINDOW_ID)
	var companion_rect := Rect2i(companion_position, companion_size)
	if not target_rect.intersects(companion_rect):
		return
	var gap := 24
	var candidates: Array[Vector2i] = [
		Vector2i(companion_rect.end.x + gap, target.position.y),
		Vector2i(companion_rect.position.x - target.size.x - gap, target.position.y),
		Vector2i(target.position.x, companion_rect.end.y + gap),
		Vector2i(target.position.x, companion_rect.position.y - target.size.y - gap),
	]
	var best_position := target.position
	var best_distance := INF
	for candidate in candidates:
		candidate.x = clampi(candidate.x, usable.position.x, usable.end.x - target.size.x)
		candidate.y = clampi(candidate.y, usable.position.y, usable.end.y - target.size.y)
		var candidate_rect := Rect2i(candidate, target.size)
		if candidate_rect.intersects(companion_rect):
			continue
		var distance := Vector2(candidate - target.position).length_squared()
		if distance < best_distance:
			best_distance = distance
			best_position = candidate
	if best_distance < INF:
		target.position = best_position


func _chat_action_icon(kind: String, color: Color) -> Texture2D:
	var stroke := "#" + color.to_html(false)
	var body := ""
	match kind:
		"mic":
			body = "<rect x='9' y='3' width='6' height='11' rx='3' fill='none' stroke='%s' stroke-width='2'/><path d='M6 11a6 6 0 0 0 12 0M12 17v4M9 21h6' fill='none' stroke='%s' stroke-width='2' stroke-linecap='round'/>" % [stroke, stroke]
		"send":
			body = "<path d='M3 4.5 21 12 3 19.5l3.4-6.2L14 12l-7.6-1.3L3 4.5Z' fill='%s'/><path d='M6.4 10.7 14 12l-7.6 1.3' fill='none' stroke='#ffffff' stroke-opacity='.45' stroke-width='1'/>" % stroke
		_:
			body = "<circle cx='12' cy='12' r='4' fill='%s'/>" % stroke
	var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'>%s</svg>" % body
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _style_updates_page() -> void:
	var page := tabs.get_node_or_null("Updates") as MarginContainer
	if not is_instance_valid(page):
		return
	page.set_meta("ocp_mock_theme_locked", true)
	page.add_theme_constant_override("margin_left", 40)
	page.add_theme_constant_override("margin_top", 28)
	page.add_theme_constant_override("margin_right", 40)
	page.add_theme_constant_override("margin_bottom", 28)
	var update_scroll := page.find_child("UpdatesScroll", true, false) as ScrollContainer
	if is_instance_valid(update_scroll):
		update_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		update_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var layout := page.find_child("UpdatesLayout", true, false) as VBoxContainer
	if is_instance_valid(layout):
		layout.add_theme_constant_override("separation", 18)
	var heading := page.find_child("UpdatesHeading", true, false) as Label
	if is_instance_valid(heading):
		heading.text = "Update Center"
		heading.add_theme_font_size_override("font_size", 34)
	var subtitle := page.find_child("UpdatesSubtitle", true, false) as Label
	if is_instance_valid(subtitle):
		subtitle.add_theme_font_size_override("font_size", 15)
		subtitle.add_theme_color_override("font_color", MUTED)
	update_status_card = page.find_child("UpdateStatusCard", true, false) as PanelContainer
	update_security_card = page.find_child("UpdateSecurityCard", true, false) as PanelContainer
	update_actions_card = page.find_child("UpdateActionsCard", true, false) as PanelContainer
	var current := page.find_child("CurrentVersionLabel", true, false) as Label
	if is_instance_valid(current):
		current.add_theme_font_size_override("font_size", 22)
	var channel := page.find_child("UpdateChannelLabel", true, false) as Label
	if is_instance_valid(channel):
		channel.add_theme_font_size_override("font_size", 14)
	var readiness := page.find_child("UpdateReadinessLabel", true, false) as Label
	if is_instance_valid(readiness):
		readiness.add_theme_font_size_override("font_size", 15)
	var safety := page.find_child("UpdateSafetyLabel", true, false) as Label
	if is_instance_valid(safety):
		safety.add_theme_font_size_override("font_size", 14)
	var check := page.find_child("CheckUpdatesButton", true, false) as Button
	if is_instance_valid(check):
		check.text = "↻  Check for updates"
		check.custom_minimum_size = Vector2(250, 50)
		check.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var install := page.find_child("InstallUpdateButton", true, false) as Button
	if is_instance_valid(install):
		install.custom_minimum_size = Vector2(330, 50)
		install.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_refresh_update_card_styles()


func _refresh_update_card_styles() -> void:
	var palette := current_palette if not current_palette.is_empty() else _fallback_palette()
	var surface: Color = palette.get("surface", Color("#0b1d36"))
	var strong: Color = palette.get("surface_strong", Color("#061126"))
	var border: Color = palette.get("border", Color("#286fb4"))
	var accent: Color = palette.get("accent", CYAN)
	var muted: Color = palette.get("muted", MUTED)
	var text: Color = palette.get("text", TEXT)
	var theme_key := selected_theme.to_lower()
	var card_alpha := 0.92 if theme_key == "solid" else (0.72 if theme_key == "glass" else 0.76)
	for card in [update_status_card, update_security_card, update_actions_card]:
		if is_instance_valid(card):
			card.add_theme_stylebox_override("panel", _panel_style(Color(surface, card_alpha), Color(border, 0.54), 18, 8))
	var pill := tabs.find_child("UpdateChannelPill", true, false) as PanelContainer if is_instance_valid(tabs) else null
	if is_instance_valid(pill):
		pill.add_theme_stylebox_override("panel", _panel_style(Color(accent, 0.13), Color(accent, 0.66), 12, 3))
	var divider := tabs.find_child("StatusDivider", true, false) as HSeparator if is_instance_valid(tabs) else null
	if is_instance_valid(divider):
		divider.modulate = Color(border, 0.28)
	for badge_name in ["PinnedKeyBadge", "HttpsBadge", "RustUpdaterBadge"]:
		var badge := tabs.find_child(badge_name, true, false) as Label if is_instance_valid(tabs) else null
		if is_instance_valid(badge):
			badge.add_theme_color_override("font_color", Color(muted, 0.92))
	var check := tabs.find_child("CheckUpdatesButton", true, false) as Button if is_instance_valid(tabs) else null
	if is_instance_valid(check):
		check.add_theme_color_override("font_color", text)
		check.add_theme_color_override("font_hover_color", Color.WHITE)
		check.add_theme_stylebox_override("normal", _panel_style(Color(accent, 0.18), Color(accent, 0.82), 11, 6))
		check.add_theme_stylebox_override("hover", _panel_style(Color(accent, 0.30), Color(accent.lightened(0.20), 1.0), 11, 10))
		check.add_theme_stylebox_override("pressed", _panel_style(Color(accent.darkened(0.10), 0.34), Color(accent, 1.0), 11, 4))
	var install := tabs.find_child("InstallUpdateButton", true, false) as Button if is_instance_valid(tabs) else null
	if is_instance_valid(install):
		install.add_theme_color_override("font_color", text)
		install.add_theme_color_override("font_disabled_color", Color(muted, 0.58))
		install.add_theme_stylebox_override("normal", _panel_style(Color(strong, 0.64), Color(border, 0.40), 11, 2))
		install.add_theme_stylebox_override("hover", _panel_style(Color(surface.lightened(0.04), 0.84), Color(accent, 0.70), 11, 6))
		install.add_theme_stylebox_override("disabled", _panel_style(Color(strong, 0.36), Color(border, 0.18), 11, 0))


func _on_theme_card_pressed(theme_name: String) -> void:
	selected_theme = theme_name.to_lower()
	set_theme_selection(selected_theme)
	theme_preview_requested.emit(selected_theme)


func get_settings_snapshot() -> Dictionary:
	return {
		"theme_preset": selected_theme,
		"font_family": font_option.get_item_text(font_option.selected) if is_instance_valid(font_option) else "Noto Sans Thai",
		"text_scale": float(text_scale_option.get_item_metadata(text_scale_option.selected)) if is_instance_valid(text_scale_option) and text_scale_option.selected >= 0 else 1.15,
		"bubble_style": bubble_option.get_item_text(bubble_option.selected) if is_instance_valid(bubble_option) else "Rounded",
		"language": str(language_option.get_item_metadata(language_option.selected)) if is_instance_valid(language_option) and language_option.selected >= 0 else "en",
		"click_through_enabled": click_through_toggle.button_pressed if is_instance_valid(click_through_toggle) else true,
		"start_with_windows": start_with_windows_toggle.button_pressed if is_instance_valid(start_with_windows_toggle) else false,
		"offline_presence_enabled": offline_presence_toggle.button_pressed if is_instance_valid(offline_presence_toggle) else true,
	}


func sync_settings(settings: Dictionary, runtime_config: Dictionary) -> void:
	set_theme_selection(str(settings.get("theme_preset", runtime_config.get("theme_preset", "solid"))))
	_select_option_text(font_option, str(settings.get("font_family", "Noto Sans Thai")))
	_select_text_scale_option(float(settings.get("text_scale", 1.15)))
	_select_option_text(bubble_option, str(settings.get("bubble_style", "Rounded")))
	_select_language_option(str(settings.get("language", runtime_config.get("language", "en"))))
	if is_instance_valid(click_through_toggle):
		click_through_toggle.button_pressed = bool(settings.get("click_through_enabled", runtime_config.get("click_through_enabled", true)))
	if is_instance_valid(start_with_windows_toggle):
		start_with_windows_toggle.button_pressed = bool(settings.get("start_with_windows", false))
	if is_instance_valid(offline_presence_toggle):
		offline_presence_toggle.button_pressed = bool(settings.get("offline_presence_enabled", true))
		_update_offline_presence_status(offline_presence_toggle.button_pressed)


func _select_option_text(option: OptionButton, value: String) -> void:
	if not is_instance_valid(option):
		return
	for index in range(option.item_count):
		if option.get_item_text(index).to_lower() == value.to_lower():
			option.select(index)
			return


func _select_text_scale_option(scale: float) -> void:
	if not is_instance_valid(text_scale_option):
		return
	var best_index := 0
	var best_distance := INF
	for index in range(text_scale_option.item_count):
		var candidate := float(text_scale_option.get_item_metadata(index))
		var distance := absf(candidate - scale)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	text_scale_option.select(best_index)


func _refresh_text_scale_labels() -> void:
	if not is_instance_valid(text_scale_option) or text_scale_option.item_count < 5:
		return
	var labels := [
		["text_scale.normal", "Normal"],
		["text_scale.standard", "Standard"],
		["text_scale.comfortable", "Comfortable"],
		["text_scale.large", "Large"],
		["text_scale.extra", "Extra"],
	]
	for index in range(labels.size()):
		text_scale_option.set_item_text(index, _localized(str(labels[index][0]), str(labels[index][1])))


func _on_text_scale_option_selected(index: int) -> void:
	if not is_instance_valid(text_scale_option) or index < 0 or index >= text_scale_option.item_count:
		return
	text_scale_preview_requested.emit(float(text_scale_option.get_item_metadata(index)))


func _select_language_option(locale: String) -> void:
	if not is_instance_valid(language_option):
		return
	var normalized := locale.to_lower()
	if normalized.begins_with("th"):
		normalized = "th"
	else:
		normalized = "en"
	for index in range(language_option.item_count):
		if str(language_option.get_item_metadata(index)) == normalized:
			language_option.select(index)
			return


func _on_language_option_selected(index: int) -> void:
	if not is_instance_valid(language_option) or index < 0 or index >= language_option.item_count:
		return
	language_preview_requested.emit(str(language_option.get_item_metadata(index)))


func set_theme_selection(theme_name: String) -> void:
	selected_theme = theme_name.to_lower()
	for key in theme_buttons.keys():
		var button := theme_buttons[key] as Button
		button.button_pressed = str(key) == selected_theme
		_style_theme_preview_button(button, str(key), str(key) == selected_theme)


func set_resource_monitor(payload: Dictionary) -> void:
	var available := bool(payload.get("available", false))
	var cpu := float(payload.get("cpu_percent", 0.0)) if available else 0.0
	var memory := float(payload.get("memory_percent", 0.0)) if available else 0.0
	if is_instance_valid(cpu_gauge):
		cpu_gauge.set_value(cpu)
	if is_instance_valid(memory_gauge):
		memory_gauge.set_value(memory)


func apply_ocp_language(locale: String, catalog: Dictionary) -> void:
	current_language = "th" if locale.to_lower().begins_with("th") else "en"
	current_catalog = catalog.duplicate(true)
	_select_language_option(current_language)
	_refresh_text_scale_labels()

	if nav_buttons.has("settings"):
		(nav_buttons["settings"] as Button).text = _localized("nav.settings", "Settings")
	if nav_buttons.has("ai_voice"):
		(nav_buttons["ai_voice"] as Button).text = _localized("nav.ai_voice", "AI & Voice")
	if nav_buttons.has("updates"):
		(nav_buttons["updates"] as Button).text = _localized("nav.updates", "Updates")
	_apply_ai_voice_language()

	if is_instance_valid(tabs):
		var settings_heading := tabs.get_node_or_null("Settings/SettingsLayout/SettingsHeading") as Label
		if is_instance_valid(settings_heading):
			settings_heading.text = _localized("settings.title", "Settings")
		var settings_intro := tabs.get_node_or_null("Settings/SettingsLayout/SettingsIntro") as Label
		if is_instance_valid(settings_intro):
			settings_intro.text = _localized("settings.subtitle", "Customize OCP to your liking")
		var settings_status := tabs.find_child("SettingsStatusLabel", true, false) as Label
		if is_instance_valid(settings_status):
			settings_status.text = _localized("settings.saved_local", "Settings are stored locally.")
		var update_heading := tabs.find_child("UpdatesHeading", true, false) as Label
		if is_instance_valid(update_heading):
			update_heading.text = _localized("update.title", "Update Center")
		var update_subtitle := tabs.find_child("UpdatesSubtitle", true, false) as Label
		if is_instance_valid(update_subtitle):
			update_subtitle.text = _localized("update.subtitle", "Keep OCP secure, current and ready.")
		var status_eyebrow := tabs.find_child("UpdateStatusEyebrow", true, false) as Label
		if is_instance_valid(status_eyebrow):
			status_eyebrow.text = _localized("update.runtime", "OCP Runtime")
		var security_title := tabs.find_child("UpdateSecurityTitle", true, false) as Label
		if is_instance_valid(security_title):
			security_title.text = _localized("update.security_title", "Signed update protection")
		var update_safety := tabs.find_child("UpdateSafetyLabel", true, false) as Label
		if is_instance_valid(update_safety):
			update_safety.text = _localized("update.read_only", "The check is read-only until the pinned key, HTTPS manifest and packaged Rust updater are present.")
		var pinned_badge := tabs.find_child("PinnedKeyBadge", true, false) as Label
		if is_instance_valid(pinned_badge):
			pinned_badge.text = "○  " + _localized("update.pinned_key", "Pinned key")
		var https_badge := tabs.find_child("HttpsBadge", true, false) as Label
		if is_instance_valid(https_badge):
			https_badge.text = "○  " + _localized("update.https_manifest", "HTTPS manifest")
		var rust_badge := tabs.find_child("RustUpdaterBadge", true, false) as Label
		if is_instance_valid(rust_badge):
			rust_badge.text = "○  " + _localized("update.rust_updater", "Rust updater")
		var actions_title := tabs.find_child("UpdateActionsTitle", true, false) as Label
		if is_instance_valid(actions_title):
			actions_title.text = _localized("update.actions_title", "Update actions")
		var actions_subtitle := tabs.find_child("UpdateActionsSubtitle", true, false) as Label
		if is_instance_valid(actions_subtitle):
			actions_subtitle.text = _localized("update.actions_subtitle", "Check readiness first. Installation becomes available when a trusted staged update is ready.")
		var check_button := tabs.find_child("CheckUpdatesButton", true, false) as Button
		if is_instance_valid(check_button):
			check_button.text = "↻  " + _localized("update.check", "Check for updates")
		var install_button := tabs.find_child("InstallUpdateButton", true, false) as Button
		if is_instance_valid(install_button):
			install_button.text = _localized("update.install", "Install staged update (check first)")

	if is_instance_valid(appearance_card):
		var appearance_title := appearance_card.find_child("CardTitle", true, false) as Label
		if is_instance_valid(appearance_title):
			appearance_title.text = _localized("appearance.title", "Appearance")
		var theme_label := appearance_card.find_child("ThemeLabel", true, false) as Label
		if is_instance_valid(theme_label):
			theme_label.text = _localized("appearance.theme", "Theme")
		var font_label := appearance_card.find_child("FontLabel", true, false) as Label
		if is_instance_valid(font_label):
			font_label.text = _localized("common.font", "Font")
		var text_scale_label := appearance_card.find_child("TextScaleLabel", true, false) as Label
		if is_instance_valid(text_scale_label):
			text_scale_label.text = _localized("common.text_size", "Text size")
		var bubble_label := appearance_card.find_child("BubbleStyleLabel", true, false) as Label
		if is_instance_valid(bubble_label):
			bubble_label.text = _localized("common.bubble_style", "Bubble style")
		var language_label := appearance_card.find_child("LanguageLabel", true, false) as Label
		if is_instance_valid(language_label):
			language_label.text = _localized("common.language", "Language")
		for theme_key in theme_buttons.keys():
			var theme_button := theme_buttons[theme_key] as Button
			if not is_instance_valid(theme_button):
				continue
			var preview_column := theme_button.get_parent()
			if is_instance_valid(preview_column) and preview_column.get_child_count() > 1:
				var caption := preview_column.get_child(1) as Label
				if is_instance_valid(caption):
					caption.text = _localized("theme.%s" % str(theme_key), str(theme_key).capitalize())

	if is_instance_valid(behavior_card):
		var behavior_title := behavior_card.find_child("CardTitle", true, false) as Label
		if is_instance_valid(behavior_title):
			behavior_title.text = _localized("behavior.title", "Companion Behavior")
		_apply_behavior_row_language(
			"ClickThroughRow",
			"behavior.click_through",
			"Click-through",
			"behavior.click_through.detail",
			"Allow clicks to pass through the desktop character"
		)
		_apply_behavior_row_language(
			"StartWithWindowsRow",
			"behavior.start_windows",
			"Start with Windows",
			"behavior.start_windows.detail",
			"Launch OCP when you sign in"
		)
		_apply_behavior_row_language(
			"OfflineActivityRow",
			"behavior.offline",
			"Enable Offline companion activity",
			"behavior.offline.detail",
			"Run local-only animations and floor walks while AI services are offline"
		)
		if is_instance_valid(offline_presence_toggle):
			_update_offline_presence_status(offline_presence_toggle.button_pressed)

	if is_instance_valid(resource_card):
		var resource_title := resource_card.find_child("CardTitle", true, false) as Label
		if is_instance_valid(resource_title):
			resource_title.text = _localized("resource.title", "Resource Monitor")
	if is_instance_valid(save_button):
		save_button.text = _localized("common.save_changes", "Save changes")

	if is_instance_valid(chat_root):
		if is_instance_valid(chat_title_bar) and chat_title_bar.has_method("set_title"):
			chat_title_bar.call("set_title", _localized("chat.title", "Chat"))
		var chat_header := chat_root.get_node_or_null("Chat/ChatLayout/ChatHeader") as Label
		if is_instance_valid(chat_header):
			chat_header.text = _localized("chat.title", "Chat")
		var connection_badge := chat_root.find_child("ChatConnectionBadgeLabel", true, false) as Label
		if is_instance_valid(connection_badge):
			connection_badge.text = _localized("chat.connection_offline", "Offline mode")
		var companion_subtitle := chat_root.find_child("CompanionSubtitle", true, false) as Label
		if is_instance_valid(companion_subtitle):
			companion_subtitle.text = _localized("chat.companion_subtitle", "Your friendly AI companion")
		var chat_status := chat_root.get_node_or_null("Chat/ChatLayout/ChatStatus") as Label
		if is_instance_valid(chat_status):
			chat_status.text = _localized("chat.session_status", "Local session · provider transport can be connected later")
		var name_label := chat_root.find_child("CompanionName", true, false) as Label
		if is_instance_valid(name_label):
			name_label.text = current_companion_name
		var assistant := chat_root.get_node_or_null("Chat/ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow/AssistantCard/AssistantMargins/AssistantText") as Label
		if is_instance_valid(assistant):
			assistant.text = _chat_greeting_text()
		var model_option := chat_root.find_child("ChatModelOption", true, false) as OptionButton
		if is_instance_valid(model_option) and model_option.item_count > 0:
			model_option.set_item_text(0, _localized("chat.profile_local", "Local"))
			model_option.tooltip_text = _localized("chat.profile_tooltip", "AI profile")
		var input := chat_root.find_child("ChatInput", true, false) as TextEdit
		if is_instance_valid(input):
			input.placeholder_text = _localized("chat.placeholder", "Type your message...")
		var voice := chat_root.find_child("VoiceChatButton", true, false) as Button
		if is_instance_valid(voice):
			voice.tooltip_text = _localized("chat.voice", "Voice chat")
		var send := chat_root.find_child("SendChatButton", true, false) as Button
		if is_instance_valid(send):
			send.tooltip_text = _localized("chat.send", "Send message")
		var footnote := chat_root.get_node_or_null("Chat/ChatLayout/ChatFootnote") as Label
		if is_instance_valid(footnote):
			footnote.text = _localized("chat.footnote", "✦  Lumi 3.0   ·   Enter to send   ·   Ctrl+Enter for a new line")


func _apply_ai_voice_language() -> void:
	if not is_instance_valid(ai_voice_page):
		return
	var labels := {
		"AIVoiceHeading": ["ai.title", "AI & Voice"],
		"AIVoiceIntro": ["ai.subtitle", "Connect your AI provider and control spoken replies."],
		"AIProviderHelp": ["ai.provider_help", "Start offline, connect local Ollama, or use an OpenAI-compatible cloud endpoint with a secure OS-stored key."],
		"AIProviderLabel": ["ai.provider", "Provider"],
		"AIModelLabel": ["ai.model", "Model"],
		"AIBaseUrlLabel": ["ai.base_url", "Base URL"],
		"AITimeoutLabel": ["ai.timeout", "Timeout"],
		"VoiceHelp": ["voice.help", "Spoken replies use the current kernel voice chain: Gemini when available, then the Windows system voice fallback."],
		"TTSEnableLabel": ["voice.spoken_replies", "Spoken replies"],
		"TTSProviderLabel": ["voice.provider", "Voice provider"],
		"TTSVoiceLabel": ["voice.voice", "Voice"],
		"TTSTestLabel": ["voice.preview", "Preview"],
		"GeminiCredentialLabel": ["voice.credential.label", "Gemini API key"],
		"CloudCredentialLabel": ["ai.credential.label", "Cloud API key"],
	}
	for node_name in labels.keys():
		var label := ai_voice_page.find_child(str(node_name), true, false) as Label
		if is_instance_valid(label):
			var entry: Array = labels[node_name]
			label.text = _localized(str(entry[0]), str(entry[1]))
	var provider_title := ai_voice_page.find_child("AIProviderCard", true, false) as PanelContainer
	if is_instance_valid(provider_title):
		var title_label := provider_title.find_child("CardTitle", true, false) as Label
		if is_instance_valid(title_label):
			title_label.text = _localized("ai.provider_card", "AI Provider")
	var voice_card := ai_voice_page.find_child("VoiceCard", true, false) as PanelContainer
	if is_instance_valid(voice_card):
		var voice_title := voice_card.find_child("CardTitle", true, false) as Label
		if is_instance_valid(voice_title):
			voice_title.text = _localized("voice.card", "Voice (TTS)")
	if is_instance_valid(ai_provider_option) and ai_provider_option.item_count >= 3:
		ai_provider_option.set_item_text(0, _localized("ai.provider.offline", "Offline"))
		ai_provider_option.set_item_text(1, _localized("ai.provider.ollama", "Ollama · Local"))
		ai_provider_option.set_item_text(2, _localized("ai.provider.openai_compatible", "OpenAI-compatible · Cloud"))
	if is_instance_valid(ai_test_button):
		ai_test_button.text = _localized("ai.test", "Test connection")
	if is_instance_valid(ai_save_button):
		ai_save_button.text = _localized("ai.save", "Save AI settings")
	if is_instance_valid(tts_enabled_toggle):
		tts_enabled_toggle.text = _localized("voice.enable_tts", "Enable TTS")
	if is_instance_valid(tts_test_button):
		tts_test_button.text = _localized("voice.test", "Test voice")
	if is_instance_valid(tts_provider_option) and tts_provider_option.item_count >= 2:
		tts_provider_option.set_item_text(0, _localized("voice.provider.auto", "Automatic · Gemini → System"))
		tts_provider_option.set_item_text(1, _localized("voice.provider.system", "Windows system voice"))
	if is_instance_valid(tts_voice_option) and tts_voice_option.item_count >= 1:
		tts_voice_option.set_item_text(0, _localized("voice.auto", "Automatic"))
	if is_instance_valid(ai_voice_page):
		sync_provider_credential_status(
			"gemini-cloud",
			bool(ai_voice_page.get_meta("gemini_cloud_credential_present", false))
		)
		sync_provider_credential_status(
			"openai-compatible",
			bool(ai_voice_page.get_meta("openai_compatible_credential_present", false))
		)
	_on_ai_provider_selected(ai_provider_option.selected if is_instance_valid(ai_provider_option) else 0)


func _apply_behavior_row_language(
	row_name: String,
	title_key: String,
	title_fallback: String,
	detail_key: String,
	detail_fallback: String
) -> void:
	if not is_instance_valid(behavior_card):
		return
	var row := behavior_card.find_child(row_name, true, false) as HBoxContainer
	if not is_instance_valid(row):
		return
	var title_label := row.find_child("Title", true, false) as Label
	var detail_label := row.find_child("Detail", true, false) as Label
	if is_instance_valid(title_label):
		title_label.text = _localized(title_key, title_fallback)
	if is_instance_valid(detail_label):
		detail_label.text = _localized(detail_key, detail_fallback)


func _chat_greeting_text() -> String:
	var template := _localized("chat.greeting", "Hello! I’m {name}, your open companion.\nHow can I help you today?")
	return template.replace("{name}", current_companion_name)


func _localized(key: String, fallback: String) -> String:
	return str(current_catalog.get(key, fallback))


func apply_ocp_theme(palette: Dictionary, theme_name: String) -> void:
	current_palette = palette.duplicate(true)
	selected_theme = theme_name
	var surface: Color = palette.get("surface", Color("#08152b"))
	var strong: Color = palette.get("surface_strong", Color("#020817"))
	var border: Color = palette.get("border", Color("#236fb8"))
	var text: Color = palette.get("text", TEXT)
	var muted: Color = palette.get("muted", MUTED)
	var accent: Color = palette.get("accent", CYAN)
	var theme_key := theme_name.to_lower()
	var root_alpha := 1.0 if theme_key == "solid" else (0.95 if theme_key == "glass" else 0.96)
	var rail_alpha := 0.995 if theme_key == "solid" else 0.94
	var card_alpha := 0.90 if theme_key == "solid" else (0.66 if theme_key == "glass" else 0.71)
	var inner_alpha := 0.46 if theme_key == "solid" else (0.30 if theme_key == "glass" else 0.34)
	var card_shadow := 6 if theme_key == "solid" else (10 if theme_key == "glass" else 12)

	if is_instance_valid(title_bar) and title_bar.has_method("apply_ocp_theme"):
		title_bar.call("apply_ocp_theme", palette, theme_name)
	if is_instance_valid(chat_title_bar) and chat_title_bar.has_method("apply_ocp_theme"):
		chat_title_bar.call("apply_ocp_theme", palette, theme_name)
	if is_instance_valid(root_control):
		var root_style := _panel_style(Color(strong, root_alpha), Color(border, 0.60), 0, 0)
		root_style.border_width_top = 0
		root_control.add_theme_stylebox_override("panel", root_style)
	if is_instance_valid(rail):
		var rail_style := _panel_style(Color(strong, rail_alpha), Color(border, 0.42), 0, 0)
		rail_style.border_width_top = 0
		rail.add_theme_stylebox_override("panel", rail_style)
	if is_instance_valid(chat_root):
		chat_root.add_theme_stylebox_override("panel", _panel_style(Color(strong, root_alpha), Color(border, 0.64), 16, 0))
		var identity := chat_root.get_node_or_null("Chat/ChatLayout/ChatIdentityCard") as PanelContainer
		if is_instance_valid(identity):
			# Identity is a lightweight header strip, not a second full card.
			identity.add_theme_stylebox_override("panel", _panel_style(Color(surface, card_alpha * 0.56), Color(border, 0.20), 14, 1))
		var identity_avatar := chat_root.find_child("ChatIdentityAvatar", true, false) as PanelContainer
		if is_instance_valid(identity_avatar):
			identity_avatar.add_theme_stylebox_override("panel", _panel_style(Color(strong, 0.86), Color(accent, 0.78), 30, 5))
		var assistant_avatar := chat_root.find_child("AssistantAvatar", true, false) as PanelContainer
		if is_instance_valid(assistant_avatar):
			assistant_avatar.add_theme_stylebox_override("panel", _panel_style(Color(strong, 0.88), Color(accent, 0.68), 23, 4))
		var connection_badge := chat_root.find_child("ChatConnectionBadge", true, false) as PanelContainer
		if is_instance_valid(connection_badge):
			connection_badge.add_theme_stylebox_override("panel", _panel_style(Color(accent, 0.10), Color(accent, 0.56), 18, 2))
		var connection_label := chat_root.find_child("ChatConnectionBadgeLabel", true, false) as Label
		if is_instance_valid(connection_label):
			connection_label.add_theme_color_override("font_color", accent.lightened(0.18))
		var transcript_frame := chat_root.get_node_or_null("Chat/ChatLayout/ChatTranscriptFrame") as PanelContainer
		if is_instance_valid(transcript_frame):
			transcript_frame.add_theme_stylebox_override("panel", _panel_style(Color(strong, inner_alpha * 0.24), Color(border, 0.10), 16, 0))
		var assistant_card := chat_root.get_node_or_null("Chat/ChatLayout/ChatTranscriptFrame/TranscriptMargins/ChatTranscript/ChatMessages/AssistantRow/AssistantCard") as PanelContainer
		if is_instance_valid(assistant_card):
			assistant_card.add_theme_stylebox_override("panel", _panel_style(Color(surface, minf(card_alpha + 0.10, 0.90)), Color(border, 0.40), 14, 2))
		var composer := chat_root.get_node_or_null("Chat/ChatLayout/ChatInputRow/Composer") as PanelContainer
		if is_instance_valid(composer):
			composer.add_theme_stylebox_override("panel", _panel_style(Color(surface, minf(card_alpha + 0.03, 0.86)), Color(border, 0.34), 18, 2))
	for card in [appearance_card, behavior_card, resource_card]:
		if is_instance_valid(card):
			card.add_theme_stylebox_override("panel", _panel_style(Color(surface, card_alpha), Color(border, 0.60), 18, card_shadow))
	if is_instance_valid(ai_voice_page):
		for card_name in ["AIProviderCard", "VoiceCard"]:
			var ai_card := ai_voice_page.find_child(card_name, true, false) as PanelContainer
			if is_instance_valid(ai_card):
				ai_card.add_theme_stylebox_override("panel", _panel_style(Color(surface, card_alpha), Color(border, 0.60), 18, card_shadow))
	if is_instance_valid(resource_inner_panel):
		resource_inner_panel.add_theme_stylebox_override(
			"panel",
			_panel_style(Color(strong, inner_alpha), Color(border, 0.34), 14, 0)
		)
	_style_visible_tree(self, text, muted, surface, border, accent)
	if is_instance_valid(chat_window):
		_style_visible_tree(chat_window, text, muted, surface, border, accent)
	if is_instance_valid(chat_root):
		# Generic control styling runs first; the unified composer intentionally
		# owns the only input border, so restore ChatInput to a transparent canvas.
		var chat_input_control := chat_root.find_child("ChatInput", true, false) as TextEdit
		if is_instance_valid(chat_input_control):
			var chat_input_empty := StyleBoxEmpty.new()
			chat_input_control.add_theme_stylebox_override("normal", chat_input_empty)
			chat_input_control.add_theme_stylebox_override("focus", chat_input_empty)
			chat_input_control.add_theme_stylebox_override("read_only", chat_input_empty)
			chat_input_control.add_theme_color_override("font_color", text)
			chat_input_control.add_theme_color_override("font_placeholder_color", Color(muted, 0.78))
			_style_chat_scroll_bar(chat_input_control.get_v_scroll_bar(), accent)
		var chat_transcript_control := chat_root.find_child("ChatTranscript", true, false) as ScrollContainer
		if is_instance_valid(chat_transcript_control):
			_style_chat_scroll_bar(chat_transcript_control.get_v_scroll_bar(), accent)
		var connection_label := chat_root.find_child("ChatConnectionBadgeLabel", true, false) as Label
		if is_instance_valid(connection_label):
			connection_label.add_theme_color_override("font_color", accent.lightened(0.18))
		var model_option := chat_root.find_child("ChatModelOption", true, false) as OptionButton
		if is_instance_valid(model_option):
			# Provider/profile is context, not the primary action. Keep it quiet.
			model_option.add_theme_stylebox_override("normal", _panel_style(Color(surface, 0.18), Color(border, 0.16), 12, 0))
			model_option.add_theme_stylebox_override("hover", _panel_style(Color(surface, 0.42), Color(accent, 0.42), 12, 1))
			_style_option_popup(model_option)
		var voice_button := chat_root.find_child("VoiceChatButton", true, false) as Button
		if is_instance_valid(voice_button):
			voice_button.icon = _chat_action_icon("mic", accent.lightened(0.16))
			voice_button.add_theme_stylebox_override("normal", _panel_style(Color(surface, 0.12), Color(border, 0.14), 12, 0))
			voice_button.add_theme_stylebox_override("hover", _panel_style(Color(accent, 0.10), Color(accent, 0.48), 12, 1))
		var send_button := chat_root.find_child("SendChatButton", true, false) as Button
		if is_instance_valid(send_button):
			send_button.icon = _chat_action_icon("send", Color.WHITE)
			send_button.add_theme_stylebox_override("normal", _panel_style(Color(accent, 0.86), Color(accent.lightened(0.18), 0.90), 12, 4))
			send_button.add_theme_stylebox_override("hover", _panel_style(Color(accent.lightened(0.10), 0.96), Color.WHITE, 12, 6))
	# Nav state is refreshed after the generic button pass so exactly one page
	# owns the active glow. This also fixes stale Settings styling after switching
	# to Updates.
	_refresh_nav_styles()
	_refresh_update_card_styles()
	# Dropdowns and toggles are theme-aware components; refresh their generated
	# SVG accents after the generic tree pass so Glass/Liquid hover states stay
	# in the same visual family as the selected theme.
	for option in [font_option, text_scale_option, bubble_option, language_option, ai_provider_option, ai_timeout_option, tts_provider_option, tts_voice_option]:
		if is_instance_valid(option):
			_style_option_popup(option)
	for toggle in [click_through_toggle, start_with_windows_toggle, offline_presence_toggle, tts_enabled_toggle]:
		if is_instance_valid(toggle):
			_apply_toggle_icons(toggle, accent, border.lightened(0.16))
	if is_instance_valid(save_button):
		save_button.add_theme_stylebox_override("normal", _panel_style(Color(accent, 0.88), Color(accent.lightened(0.28), 1.0), 11, 10))
		save_button.add_theme_stylebox_override("hover", _panel_style(Color(accent.lightened(0.10), 0.98), Color.WHITE, 11, 12))
		save_button.add_theme_stylebox_override("pressed", _panel_style(Color(accent.darkened(0.10), 0.98), Color(accent, 1.0), 11, 6))
	if is_instance_valid(ai_save_button):
		ai_save_button.add_theme_stylebox_override("normal", _panel_style(Color(accent, 0.82), Color(accent.lightened(0.24), 0.96), 11, 8))
		ai_save_button.add_theme_stylebox_override("hover", _panel_style(Color(accent.lightened(0.09), 0.96), Color.WHITE, 11, 10))
		ai_save_button.add_theme_stylebox_override("pressed", _panel_style(Color(accent.darkened(0.10), 0.96), Color(accent, 1.0), 11, 5))
	if is_instance_valid(ai_test_button):
		ai_test_button.add_theme_stylebox_override("normal", _panel_style(Color(surface, 0.54), Color(accent, 0.54), 11, 1))
		ai_test_button.add_theme_stylebox_override("hover", _panel_style(Color(accent, 0.16), Color(accent, 0.88), 11, 5))
	set_theme_selection(theme_name)
	if is_instance_valid(cpu_gauge):
		cpu_gauge.apply_ocp_theme(palette, theme_name)
	if is_instance_valid(memory_gauge):
		memory_gauge.apply_ocp_theme(palette, theme_name)
	for wave in ambient_waves:
		if is_instance_valid(wave) and wave.has_method("apply_ocp_theme"):
			wave.call("apply_ocp_theme", palette, theme_name)


func _style_visible_tree(root: Node, text: Color, muted: Color, surface: Color, border: Color, accent: Color) -> void:
	for node in root.find_children("*", "Control", true, false):
		var control := node as Control
		if not control.visible:
			continue
		if control is Label:
			control.add_theme_color_override("font_color", text)
		if control is OptionButton or control is Button:
			control.add_theme_color_override("font_color", text)
			control.add_theme_color_override("font_hover_color", text)
			control.add_theme_stylebox_override("normal", _panel_style(Color(surface, 0.72), Color(border, 0.48), 10, 0))
			control.add_theme_stylebox_override("hover", _panel_style(Color(surface, 0.94), Color(accent, 0.76), 10, 4))
			control.add_theme_stylebox_override("pressed", _panel_style(Color(accent, 0.24), Color(accent, 0.92), 10, 6))
		if control is CheckButton:
			control.add_theme_color_override("font_color", text)
		if control is TextEdit:
			control.add_theme_color_override("font_color", text)
			control.add_theme_color_override("font_placeholder_color", muted)
			control.add_theme_stylebox_override("normal", _panel_style(Color(surface, 0.72), Color(border, 0.46), 12, 0))
			control.add_theme_stylebox_override("focus", _panel_style(Color(surface, 0.78), Color(accent, 0.88), 12, 5))
		if control is LineEdit:
			control.add_theme_color_override("font_color", text)
			control.add_theme_color_override("font_placeholder_color", Color(muted, 0.76))
			control.add_theme_color_override("font_uneditable_color", Color(muted, 0.62))
			control.add_theme_stylebox_override("normal", _panel_style(Color(surface, 0.72), Color(border, 0.46), 11, 0))
			control.add_theme_stylebox_override("focus", _panel_style(Color(surface, 0.80), Color(accent, 0.88), 11, 5))
			control.add_theme_stylebox_override("read_only", _panel_style(Color(surface, 0.34), Color(border, 0.22), 11, 0))
	var subtitle := rail.find_child("RailSubtitle", true, false) as Label if is_instance_valid(rail) else null
	if is_instance_valid(subtitle):
		subtitle.add_theme_color_override("font_color", accent)


func _theme_preview_texture(theme_name: String) -> Texture2D:
	var svg := ""
	match theme_name:
		"glass":
			svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="116" height="76" viewBox="0 0 116 76">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#0a1730"/><stop offset=".58" stop-color="#142b4d"/><stop offset="1" stop-color="#1e436b"/></linearGradient>
    <linearGradient id="s" x1="0" y1="0" x2="1" y2="0"><stop stop-color="#ffffff" stop-opacity=".08"/><stop offset=".45" stop-color="#b9eaff" stop-opacity=".8"/><stop offset="1" stop-color="#29bfff" stop-opacity=".15"/></linearGradient>
  </defs>
  <rect x="2" y="2" width="112" height="72" rx="12" fill="url(#g)" stroke="#73caff" stroke-opacity=".72"/>
  <g fill="none" stroke-linecap="round">
    <path d="M0 53 C20 19 35 62 58 32 S91 20 118 38" stroke="#1f8fff" stroke-opacity=".24" stroke-width="5"/>
    <path d="M-2 58 C18 25 36 66 58 37 S91 25 118 43" stroke="#5cd8ff" stroke-opacity=".48" stroke-width="1.6"/>
    <path d="M-4 45 C18 12 34 53 56 25 S91 14 120 31" stroke="#d9f6ff" stroke-opacity=".55" stroke-width="1.1"/>
    <path d="M0 65 C24 33 39 72 63 44 S96 34 120 51" stroke="#82bfff" stroke-opacity=".34" stroke-width="1"/>
    <path d="M3 36 C23 9 39 42 60 20 S94 10 116 24" stroke="url(#s)" stroke-width="1"/>
  </g>
  <circle cx="62" cy="30" r="2.4" fill="#dff9ff" fill-opacity=".72"/>
  <circle cx="62" cy="30" r="6" fill="#31bfff" fill-opacity=".08"/>
</svg>
"""
		"liquid":
			svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="116" height="76" viewBox="0 0 116 76">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#071633"/><stop offset=".55" stop-color="#09255a"/><stop offset="1" stop-color="#11183e"/></linearGradient>
    <linearGradient id="blob" x1=".12" y1=".08" x2=".9" y2=".92"><stop stop-color="#52e1ff" stop-opacity=".72"/><stop offset=".4" stop-color="#168cff" stop-opacity=".5"/><stop offset=".72" stop-color="#654dff" stop-opacity=".64"/><stop offset="1" stop-color="#0b1638" stop-opacity=".24"/></linearGradient>
    <radialGradient id="lens" cx=".28" cy=".22" r=".78"><stop stop-color="#ffffff" stop-opacity=".38"/><stop offset=".35" stop-color="#69dcff" stop-opacity=".18"/><stop offset="1" stop-color="#584dff" stop-opacity="0"/></radialGradient>
  </defs>
  <rect x="2" y="2" width="112" height="72" rx="12" fill="url(#bg)" stroke="#28c8ff"/>
  <path d="M21 50 C9 36 18 17 36 14 C49 12 52 26 64 25 C79 24 84 10 98 20 C112 30 106 53 92 59 C78 65 68 55 56 57 C43 59 30 62 21 50 Z" fill="url(#blob)" stroke="#68e5ff" stroke-opacity=".52" stroke-width="1.2"/>
  <path d="M29 44 C21 34 28 23 40 20 C50 18 54 29 65 29 C78 28 83 18 94 24 C101 29 99 41 92 47 C84 53 75 46 65 48 C52 51 38 54 29 44 Z" fill="url(#lens)"/>
  <path d="M28 27 C41 16 50 24 61 21 C76 17 82 12 95 23" fill="none" stroke="#ffffff" stroke-opacity=".42" stroke-width="1.6" stroke-linecap="round"/>
</svg>
"""
		_:
			svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="116" height="76" viewBox="0 0 116 76">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop stop-color="#132842"/><stop offset="1" stop-color="#0a1a30"/></linearGradient></defs>
  <rect x="2" y="2" width="112" height="72" rx="12" fill="url(#g)" stroke="#345f8d"/>
</svg>
"""
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _style_theme_preview_button(button: Button, theme_name: String, selected: bool) -> void:
	if not is_instance_valid(button):
		return
	var palette := current_palette if not current_palette.is_empty() else _fallback_palette()
	var border: Color = palette.get("border", Color("#236fb8"))
	var accent: Color = palette.get("accent", CYAN)
	var preview := Color("#14233d")
	if theme_name == "glass":
		preview = Color(0.14, 0.28, 0.48, 0.72)
	elif theme_name == "liquid":
		preview = Color(0.02, 0.24, 0.46, 0.86)
	button.add_theme_stylebox_override("normal", _panel_style(preview, Color(accent if selected else border, 0.96 if selected else 0.44), 12, 10 if selected else 0))
	button.add_theme_stylebox_override("pressed", _panel_style(preview.lightened(0.05), Color(accent, 1.0), 12, 12))
	button.add_theme_stylebox_override("hover", _panel_style(preview.lightened(0.04), Color(accent, 0.86), 12, 7))


func _apply_toggle_icons(toggle: CheckButton, accent: Color = Color("#168dff"), border: Color = Color("#50bfff")) -> void:
	var on_texture := _toggle_texture(true, accent, border)
	var off_texture := _toggle_texture(false, accent, border)
	if on_texture != null:
		toggle.add_theme_icon_override("checked", on_texture)
		toggle.add_theme_icon_override("checked_disabled", on_texture)
	if off_texture != null:
		toggle.add_theme_icon_override("unchecked", off_texture)
		toggle.add_theme_icon_override("unchecked_disabled", off_texture)


func _toggle_texture(enabled: bool, accent: Color = Color("#168dff"), border: Color = Color("#50bfff")) -> Texture2D:
	var track := accent.to_html(false) if enabled else Color("#24364f").to_html(false)
	var stroke := (border if enabled else border.darkened(0.18)).to_html(false)
	var knob_x := "39" if enabled else "15"
	var svg := """
<svg xmlns="http://www.w3.org/2000/svg" width="54" height="30" viewBox="0 0 54 30">
  <rect x="1" y="1" width="52" height="28" rx="14" fill="#%s" stroke="#%s" stroke-width="1"/>
  <circle cx="%s" cy="15" r="10" fill="#ffffff"/>
</svg>
""" % [track, stroke, knob_x]
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)


func _panel_style(background: Color, border: Color, radius: int, shadow: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0.0 else 0)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 10
	style.content_margin_right = 10
	if shadow > 0:
		style.shadow_color = Color(0.0, 0.48, 1.0, 0.20)
		style.shadow_size = shadow
	return style


func _fallback_palette() -> Dictionary:
	return {
		"surface": Color("#071a38"),
		"surface_alt": Color("#0a2448"),
		"surface_strong": Color("#020817"),
		"text": TEXT,
		"muted": MUTED,
		"accent": CYAN,
		"border": Color(0.16, 0.58, 1.0, 0.62),
	}


func _layout_shell() -> void:
	if not is_instance_valid(rail) or not is_instance_valid(root_control):
		return
	if is_instance_valid(title_bar):
		title_bar.position = Vector2.ZERO
		title_bar.size = Vector2(size.x, TITLE_BAR_HEIGHT)
	rail.position = Vector2(0, TITLE_BAR_HEIGHT)
	rail.size = Vector2(RAIL_WIDTH, maxf(0.0, size.y - TITLE_BAR_HEIGHT))
	root_control.set_anchors_preset(Control.PRESET_TOP_LEFT)
	root_control.position = Vector2(RAIL_WIDTH, TITLE_BAR_HEIGHT)
	root_control.size = Vector2(maxf(0.0, size.x - RAIL_WIDTH), maxf(0.0, size.y - TITLE_BAR_HEIGHT))
	if is_instance_valid(info_rail):
		info_rail.position = Vector2(size.x + 8.0, TITLE_BAR_HEIGHT)
		info_rail.size = Vector2(INFO_RAIL_WIDTH, maxf(0.0, size.y - TITLE_BAR_HEIGHT))


func _layout_chat_window() -> void:
	if not is_instance_valid(chat_window) or not is_instance_valid(chat_root):
		return
	if is_instance_valid(chat_title_bar):
		chat_title_bar.position = Vector2.ZERO
		chat_title_bar.size = Vector2(chat_window.size.x, TITLE_BAR_HEIGHT)
	chat_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	chat_root.position = Vector2(0, TITLE_BAR_HEIGHT)
	chat_root.size = Vector2(chat_window.size.x, maxf(0.0, chat_window.size.y - TITLE_BAR_HEIGHT))


func center_on_own_monitor() -> void:
	_center_native_window(self, self)


func _center_native_window(window: Window, reference_window: Window = null) -> void:
	if not is_instance_valid(window):
		return
	var reference := reference_window if is_instance_valid(reference_window) else window
	var screen := _screen_for_window_geometry(reference)
	var usable := DisplayServer.screen_get_usable_rect(screen)
	window.position = usable.position + Vector2i(
		maxi(0, (usable.size.x - window.size.x) / 2),
		maxi(0, (usable.size.y - window.size.y) / 2)
	)
	print("[OcpAppWindowGeometry] action=center window_id=%d screen=%d position=%s size=%s" % [window.get_window_id(), screen, window.position, window.size])


func _screen_for_window_geometry(window: Window) -> int:
	if not is_instance_valid(window):
		return DisplayServer.get_primary_screen()
	var screen_rects: Array[Rect2i] = []
	for screen_index in range(DisplayServer.get_screen_count()):
		screen_rects.append(Rect2i(
			DisplayServer.screen_get_position(screen_index),
			DisplayServer.screen_get_size(screen_index)
		))
	return OcpTitleBar.select_screen_for_rect(
		Rect2i(window.position, window.size),
		screen_rects,
		DisplayServer.get_primary_screen()
	)
