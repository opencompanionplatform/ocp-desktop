extends Window

## Mock-aligned Character Manager presentation. Functional install/activate/
## uninstall controls remain owned by CharacterPickerController.

const TITLE_BAR_SCRIPT := preload("res://scripts/runtime_v3/ui/ocp_title_bar.gd")
const AMBIENT_WAVE_SCRIPT := preload("res://scripts/runtime_v3/ui/ambient_wave.gd")
const PREVIEW_AURA_SCRIPT := preload("res://scripts/runtime_v3/ui/preview_aura_stage.gd")
const PREVIEW_BACKDROP_SCRIPT := preload("res://scripts/runtime_v3/ui/preview_stage_backdrop.gd")
const TITLE_BAR_HEIGHT := 46.0
const RAIL_WIDTH := 0.0
const NAVY := Color("#07142a")
const NAVY_DEEP := Color("#020611")
const SURFACE := Color("#08162d")
const SURFACE_RAISED := Color("#0b1d38")
const TEXT := Color("#f4f7ff")
const MUTED := Color("#9aabc6")
const CYAN := Color("#27c7ff")
const VIOLET := Color("#8d63ff")
const BORDER := Color("#26517f")

var root_panel: PanelContainer
var rail: PanelContainer
var content: Control
var custom_title_bar: PanelContainer
var ambient_layers: Array[Control] = []
var current_palette: Dictionary = {}
var current_language := "en"
var current_catalog: Dictionary = {}


func _ready() -> void:
	borderless = true
	# The project root is a transparent companion overlay, while this manager is
	# an opaque native app window. Set this explicitly so modal child windows do
	# not expose a black unrendered parent surface on Windows.
	transparent = false
	min_size = Vector2i(1024, 680)
	# Character Manager is a separate native window, but animation inspection
	# needs room for a local package list, preview stage, and scrollable catalogue.
	if size.x < 1080 or size.y < 700 or size.x > 1280 or size.y > 900:
		size = Vector2i(1180, 760)
	_build_shell()
	if not size_changed.is_connected(_layout_shell):
		size_changed.connect(_layout_shell)


func _build_shell() -> void:
	root_panel = get_node_or_null("CharacterPicker") as PanelContainer
	if not is_instance_valid(root_panel):
		return
	# ThemeService walks every control in the registered native window. Lock this
	# manager subtree before registration so Liquid shader transparency cannot
	# bleed the desktop/bot through its dedicated opaque presentation.
	root_panel.set_meta("ocp_mock_theme_locked", true)
	_clear_theme_materials(root_panel)
	root_panel.add_theme_stylebox_override("panel", _shell_style())
	var root_ambient := AMBIENT_WAVE_SCRIPT.new()
	root_ambient.name = "CharacterAmbientVisual"
	root_ambient.configure("shell")
	root_ambient.z_index = 0
	root_ambient.visible = false
	root_panel.add_child(root_ambient)
	root_panel.move_child(root_ambient, 0)
	ambient_layers.append(root_ambient)
	content = root_panel
	custom_title_bar = TITLE_BAR_SCRIPT.new()
	custom_title_bar.configure(self, "Character Manager")
	custom_title_bar.close_requested.connect(_hide_manager_window)
	custom_title_bar.z_index = 100
	add_child(custom_title_bar)

	var picker_vbox := root_panel.get_node_or_null("PickerVBox") as VBoxContainer
	if is_instance_valid(picker_vbox):
		picker_vbox.add_theme_constant_override("separation", 12)
		var legacy_title_bar := picker_vbox.get_node_or_null("CharacterPickerDragHandle") as PanelContainer
		if is_instance_valid(legacy_title_bar):
			legacy_title_bar.visible = false
		var hero := PanelContainer.new()
		hero.name = "CharacterHeroCard"
		hero.custom_minimum_size = Vector2(0, 118)
		hero.add_theme_stylebox_override("panel", _glass_style(Color(0.04, 0.10, 0.23, 0.90), 18, Color(0.20, 0.64, 1.0, 0.48)))
		picker_vbox.add_child(hero)
		picker_vbox.move_child(hero, 1)
		var hero_margin := MarginContainer.new()
		hero_margin.add_theme_constant_override("margin_left", 18)
		hero_margin.add_theme_constant_override("margin_top", 14)
		hero_margin.add_theme_constant_override("margin_right", 18)
		hero_margin.add_theme_constant_override("margin_bottom", 14)
		hero.add_child(hero_margin)
		var hero_row := HBoxContainer.new()
		hero_row.add_theme_constant_override("separation", 16)
		hero_margin.add_child(hero_row)
		var badge := PanelContainer.new()
		badge.custom_minimum_size = Vector2(82, 82)
		badge.add_theme_stylebox_override("panel", _glass_style(Color(0.05, 0.16, 0.32, 0.96), 20, Color(0.24, 0.72, 1.0, 0.72)))
		hero_row.add_child(badge)
		var badge_center := CenterContainer.new()
		badge.add_child(badge_center)
		var badge_logo := TextureRect.new()
		badge_logo.custom_minimum_size = Vector2(54, 54)
		badge_logo.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		badge_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		badge_logo.texture = load("res://assets/icons/ocp.svg") as Texture2D
		badge_center.add_child(badge_logo)
		var hero_copy := VBoxContainer.new()
		hero_copy.alignment = BoxContainer.ALIGNMENT_CENTER
		hero_copy.add_theme_constant_override("separation", 3)
		hero_row.add_child(hero_copy)
		var hero_title := Label.new()
		hero_title.name = "HeroTitle"
		hero_title.text = "Your Companions"
		hero_title.add_theme_font_size_override("font_size", 24)
		hero_copy.add_child(hero_title)
		var hero_subtitle := Label.new()
		hero_subtitle.name = "HeroSubtitle"
		hero_subtitle.text = "Install, activate and manage .ocp character packages"
		hero_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hero_subtitle.add_theme_font_size_override("font_size", 13)
		hero_subtitle.add_theme_color_override("font_color", MUTED)
		hero_copy.add_child(hero_subtitle)
		var install := picker_vbox.get_node_or_null("InstallPackageButton") as Button
		if is_instance_valid(install):
			install.text = "⇩  Install .ocp"
			install.custom_minimum_size = Vector2(210, 48)
			install.add_theme_font_size_override("font_size", 16)
			install.add_theme_stylebox_override("normal", _secondary_button_style(false))
			install.add_theme_stylebox_override("hover", _secondary_button_style(true))
		var status := picker_vbox.get_node_or_null("PickerStatusLabel") as Label
		if is_instance_valid(status):
			status.add_theme_color_override("font_color", MUTED)
		var scroll := picker_vbox.get_node_or_null("PickerScroll") as ScrollContainer
		if is_instance_valid(scroll):
			scroll.custom_minimum_size = Vector2(0, 380)
			scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var list := picker_vbox.get_node_or_null("PickerScroll/CharacterList") as VBoxContainer
		if is_instance_valid(list):
			list.add_theme_constant_override("separation", 12)
			if not list.child_entered_tree.is_connected(_style_character_row):
				list.child_entered_tree.connect(_style_character_row)
		_build_character_workspace(picker_vbox)

	rail = PanelContainer.new()
	rail.name = "CharacterNavigationRail"
	rail.z_index = 20
	rail.mouse_filter = Control.MOUSE_FILTER_STOP
	# Character Manager is a separate compact utility window in the approved
	# mock. Keep the legacy rail node for compatibility, but do not surface it.
	rail.visible = false
	rail.add_theme_stylebox_override("panel", _rail_style())
	add_child(rail)
	var rail_ambient := AMBIENT_WAVE_SCRIPT.new()
	rail_ambient.name = "CharacterRailAmbientVisual"
	rail_ambient.configure("bottom_left")
	rail.add_child(rail_ambient)
	ambient_layers.append(rail_ambient)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 22)
	rail.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	margin.add_child(column)
	_add_brand(column)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 32)
	column.add_child(gap)
	_add_nav(column, "▣   Chat", func(): _open_app("chat"), false)
	_add_nav(column, "♙   Character", func(): pass, true)
	_add_nav(column, "⚙   Settings", func(): _open_app("settings"), false)
	_add_nav(column, "↻   Updates", func(): _open_app("updates"), false)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	var separator := HSeparator.new()
	separator.modulate = Color(0.12, 0.44, 0.76, 0.42)
	column.add_child(separator)
	var tray := Button.new()
	tray.text = "▱   Hide to Tray"
	tray.alignment = HORIZONTAL_ALIGNMENT_LEFT
	tray.custom_minimum_size = Vector2(0, 48)
	tray.add_theme_font_size_override("font_size", 15)
	tray.add_theme_color_override("font_color", TEXT)
	tray.add_theme_stylebox_override("normal", _nav_style(Color(0.01, 0.04, 0.10, 0.02), Color.TRANSPARENT))
	tray.add_theme_stylebox_override("hover", _nav_style(Color(0.03, 0.18, 0.38, 0.62), BORDER))
	tray.pressed.connect(hide)
	column.add_child(tray)
	_layout_shell()


func _build_character_workspace(picker_vbox: VBoxContainer) -> void:
	if not is_instance_valid(picker_vbox) or is_instance_valid(picker_vbox.get_node_or_null("CharacterWorkspace")):
		return
	var install := picker_vbox.get_node_or_null("InstallPackageButton") as Button
	var status := picker_vbox.get_node_or_null("PickerStatusLabel") as Label
	var legacy_scroll := picker_vbox.get_node_or_null("PickerScroll") as ScrollContainer
	if not is_instance_valid(install) or not is_instance_valid(status) or not is_instance_valid(legacy_scroll):
		return
	for child in picker_vbox.get_children():
		if child != install and child != status and child != legacy_scroll:
			child.visible = false

	var workspace := VBoxContainer.new()
	workspace.name = "CharacterWorkspace"
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 16)
	picker_vbox.add_child(workspace)

	var header := HBoxContainer.new()
	header.name = "CharacterWorkspaceHeader"
	header.custom_minimum_size = Vector2(0, 54)
	header.add_theme_constant_override("separation", 10)
	workspace.add_child(header)
	var heading_copy := VBoxContainer.new()
	heading_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_copy.add_theme_constant_override("separation", 0)
	header.add_child(heading_copy)
	var heading := Label.new()
	heading.name = "CharacterWorkspaceTitle"
	heading.text = "Characters"
	heading.add_theme_font_size_override("font_size", 25)
	heading_copy.add_child(heading)
	var heading_subtitle := Label.new()
	heading_subtitle.name = "CharacterWorkspaceSubtitle"
	heading_subtitle.text = "Manage your companions"
	heading_subtitle.add_theme_font_size_override("font_size", 13)
	heading_subtitle.add_theme_color_override("font_color", MUTED)
	heading_copy.add_child(heading_subtitle)
	install.reparent(header)
	install.text = "Install .ocp"
	install.custom_minimum_size = Vector2(148, 40)
	var store := Button.new()
	store.name = "ExploreCharacterStoreButton"
	store.text = "Explore Store  ↗"
	store.custom_minimum_size = Vector2(154, 40)
	store.tooltip_text = "Opens in your browser"
	header.add_child(store)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	workspace.add_child(body)
	var library := PanelContainer.new()
	library.name = "InstalledCharacterLibrary"
	library.custom_minimum_size = Vector2(286, 0)
	library.add_theme_stylebox_override("panel", _panel_style(SURFACE, 20, BORDER))
	body.add_child(library)
	var library_box := VBoxContainer.new()
	library_box.add_theme_constant_override("separation", 8)
	library.add_child(library_box)
	var library_title := Label.new()
	library_title.name = "CharacterLibraryTitle"
	library_title.text = "Characters"
	library_title.add_theme_font_size_override("font_size", 19)
	library_box.add_child(library_title)
	var library_tabs := HBoxContainer.new()
	library_tabs.name = "CharacterLibraryTabs"
	library_tabs.add_theme_constant_override("separation", 6)
	library_box.add_child(library_tabs)
	var library_tab_group := ButtonGroup.new()
	library_tab_group.allow_unpress = false
	var installed_tab := Button.new()
	installed_tab.name = "InstalledLibraryTab"
	installed_tab.text = "Installed"
	installed_tab.toggle_mode = true
	installed_tab.button_group = library_tab_group
	installed_tab.button_pressed = true
	installed_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_tabs.add_child(installed_tab)
	var cloud_tab := Button.new()
	cloud_tab.name = "CloudLibraryTab"
	cloud_tab.text = "Library"
	cloud_tab.toggle_mode = true
	cloud_tab.button_group = library_tab_group
	cloud_tab.button_pressed = false
	cloud_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	library_tabs.add_child(cloud_tab)

	var library_stack := VBoxContainer.new()
	library_stack.name = "CharacterLibraryStack"
	library_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	library_box.add_child(library_stack)
	var installed_view := VBoxContainer.new()
	installed_view.name = "InstalledLibraryView"
	installed_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	library_stack.add_child(installed_view)
	legacy_scroll.reparent(installed_view)
	legacy_scroll.custom_minimum_size = Vector2(0, 0)
	legacy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var cloud_view := VBoxContainer.new()
	cloud_view.name = "CloudLibraryView"
	cloud_view.visible = false
	cloud_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cloud_view.add_theme_constant_override("separation", 8)
	library_stack.add_child(cloud_view)
	var cloud_status := Label.new()
	cloud_status.name = "CloudLibraryStatus"
	cloud_status.text = "Sign in to sync your cloud library."
	cloud_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cloud_status.add_theme_color_override("font_color", MUTED)
	cloud_view.add_child(cloud_status)
	var cloud_auth_box := VBoxContainer.new()
	cloud_auth_box.name = "CloudAuthBox"
	cloud_auth_box.add_theme_constant_override("separation", 6)
	cloud_view.add_child(cloud_auth_box)
	var cloud_email := LineEdit.new()
	cloud_email.name = "CloudEmailInput"
	cloud_email.placeholder_text = "Email"
	cloud_email.clear_button_enabled = true
	cloud_auth_box.add_child(cloud_email)
	var cloud_password := LineEdit.new()
	cloud_password.name = "CloudPasswordInput"
	cloud_password.placeholder_text = "Password"
	cloud_password.secret = true
	cloud_auth_box.add_child(cloud_password)
	var cloud_auth_actions := HBoxContainer.new()
	cloud_auth_actions.name = "CloudAuthActions"
	cloud_auth_actions.add_theme_constant_override("separation", 6)
	cloud_auth_box.add_child(cloud_auth_actions)
	var cloud_sign_in := Button.new()
	cloud_sign_in.name = "CloudSignInButton"
	cloud_sign_in.text = "Sign In"
	cloud_sign_in.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cloud_auth_actions.add_child(cloud_sign_in)
	var cloud_sign_out := Button.new()
	cloud_sign_out.name = "CloudSignOutButton"
	cloud_sign_out.text = "Sign Out"
	cloud_sign_out.visible = false
	cloud_sign_out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cloud_auth_actions.add_child(cloud_sign_out)
	var cloud_refresh := Button.new()
	cloud_refresh.name = "RefreshCloudLibraryButton"
	cloud_refresh.text = "Refresh Library"
	cloud_refresh.disabled = true
	cloud_view.add_child(cloud_refresh)
	var cloud_scroll := ScrollContainer.new()
	cloud_scroll.name = "CloudLibraryScroll"
	cloud_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cloud_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	cloud_view.add_child(cloud_scroll)
	var cloud_list := VBoxContainer.new()
	cloud_list.name = "CloudLibraryList"
	cloud_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cloud_list.add_theme_constant_override("separation", 8)
	cloud_scroll.add_child(cloud_list)

	var stage_panel := PanelContainer.new()
	stage_panel.name = "CharacterPreviewStage"
	stage_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage_panel.add_theme_stylebox_override("panel", _panel_style(NAVY_DEEP, 24, Color(CYAN, 0.72)))
	body.add_child(stage_panel)
	var stage_layout := VBoxContainer.new()
	stage_layout.name = "CharacterPreviewLayout"
	stage_layout.add_theme_constant_override("separation", 10)
	stage_panel.add_child(stage_layout)
	var selected_header := VBoxContainer.new()
	selected_header.name = "SelectedCharacterHeader"
	selected_header.add_theme_constant_override("separation", 3)
	stage_layout.add_child(selected_header)
	var selected_title := Label.new()
	selected_title.name = "SelectedCharacterTitle"
	selected_title.text = "Character"
	selected_title.add_theme_font_size_override("font_size", 24)
	selected_header.add_child(selected_title)
	var selected_badges := Label.new()
	selected_badges.name = "SelectedCharacterBadges"
	selected_badges.text = "Installed"
	selected_badges.add_theme_font_size_override("font_size", 13)
	selected_badges.add_theme_color_override("font_color", CYAN)
	selected_header.add_child(selected_badges)
	var selected_meta := Label.new()
	selected_meta.name = "SelectedCharacterMeta"
	selected_meta.add_theme_font_size_override("font_size", 12)
	selected_meta.add_theme_color_override("font_color", MUTED)
	selected_header.add_child(selected_meta)
	var stage := Control.new()
	stage.name = "PreviewCanvas"
	stage.custom_minimum_size = Vector2(0, 360)
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage_layout.add_child(stage)
	var backdrop := PREVIEW_BACKDROP_SCRIPT.new()
	backdrop.name = "PreviewBackdrop"
	backdrop.z_index = 0
	stage.add_child(backdrop)
	var aura := PREVIEW_AURA_SCRIPT.new()
	aura.name = "PreviewAura"
	aura.z_index = 1
	stage.add_child(aura)
	var stage_hint := Label.new()
	stage_hint.text = "Preview only — Apply character to change the desktop companion"
	stage_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stage_hint.position = Vector2(12, 16)
	stage_hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	stage_hint.add_theme_color_override("font_color", MUTED)
	stage.add_child(stage_hint)
	var sprite := AnimatedSprite2D.new()
	sprite.name = "PreviewSprite"
	sprite.scale = Vector2(1.45, 1.45)
	sprite.z_index = 2
	stage.add_child(sprite)
	stage.resized.connect(func(): sprite.position = Vector2(stage.size.x * 0.5, stage.size.y * 0.42))
	stage.call_deferred("emit_signal", "resized")
	var quick_title := Label.new()
	quick_title.text = "Quick Actions"
	quick_title.add_theme_font_size_override("font_size", 14)
	stage_layout.add_child(quick_title)
	var quick_actions := HBoxContainer.new()
	quick_actions.name = "SelectedCharacterActions"
	quick_actions.add_theme_constant_override("separation", 8)
	stage_layout.add_child(quick_actions)
	for action_data in [
		["SelectedPreviewAction", "Preview"],
		["SelectedUseAction", "Use This Character"],
		["SelectedSecondaryAction", "Details"],
		["SelectedUninstallAction", "Uninstall"],
	]:
		var action := Button.new()
		action.name = str(action_data[0])
		action.text = str(action_data[1])
		action.custom_minimum_size = Vector2(0, 48)
		action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		quick_actions.add_child(action)

	var sidebar := PanelContainer.new()
	sidebar.name = "AnimationPreviewPanel"
	sidebar.custom_minimum_size = Vector2(300, 0)
	sidebar.add_theme_stylebox_override("panel", _panel_style(SURFACE, 20, BORDER))
	body.add_child(sidebar)
	var controls := VBoxContainer.new()
	controls.add_theme_constant_override("separation", 10)
	sidebar.add_child(controls)
	var preview_title := Label.new()
	preview_title.text = "Preview animation"
	preview_title.add_theme_font_size_override("font_size", 19)
	controls.add_child(preview_title)
	var playback_hero := CenterContainer.new()
	playback_hero.name = "PreviewPlaybackHero"
	playback_hero.custom_minimum_size = Vector2(0, 104)
	controls.add_child(playback_hero)
	var play := Button.new()
	play.name = "PreviewPlayButton"
	play.text = ">"
	play.tooltip_text = "Pause animation"
	play.custom_minimum_size = Vector2(76, 76)
	play.add_theme_font_size_override("font_size", 28)
	play.add_theme_stylebox_override("normal", _playback_button_style(false))
	play.add_theme_stylebox_override("hover", _playback_button_style(true))
	playback_hero.add_child(play)
	var search := LineEdit.new()
	search.name = "AnimationSearch"
	search.placeholder_text = "Search animations…"
	controls.add_child(search)
	var category := OptionButton.new()
	category.name = "AnimationCategory"
	for category_name in ["All", "Movement", "Surface", "Transitions", "Other"]:
		category.add_item(category_name)
	var gallery_label := Label.new()
	gallery_label.name = "AnimationGalleryLabel"
	gallery_label.text = "Animation library — all available clips"
	gallery_label.add_theme_font_size_override("font_size", 13)
	gallery_label.add_theme_color_override("font_color", MUTED)
	controls.add_child(gallery_label)
	var animation_scroll := ScrollContainer.new()
	animation_scroll.name = "AnimationCatalogScroll"
	animation_scroll.custom_minimum_size = Vector2(0, 338)
	animation_scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	animation_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	controls.add_child(animation_scroll)
	var animation_list := GridContainer.new()
	animation_list.name = "AnimationCatalog"
	animation_list.columns = 3
	animation_list.add_theme_constant_override("h_separation", 7)
	animation_list.add_theme_constant_override("v_separation", 7)
	animation_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	animation_scroll.add_child(animation_list)
	# Keep the filter below the gallery. Opening its menu must never hide the
	# animation icon tiles the user is trying to choose from.
	controls.add_child(category)
	var preview_status_label := Label.new()
	preview_status_label.name = "PreviewStatusLabel"
	preview_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_status_label.add_theme_color_override("font_color", MUTED)
	controls.add_child(preview_status_label)
	var playback := HBoxContainer.new()
	playback.add_theme_constant_override("separation", 8)
	controls.add_child(playback)
	var loop := CheckButton.new()
	loop.name = "PreviewLoopToggle"
	loop.text = "Loop"
	loop.button_pressed = true
	playback.add_child(loop)
	var speed := OptionButton.new()
	speed.name = "PreviewSpeed"
	for speed_item in [["0.5×", 0.5], ["1×", 1.0], ["1.5×", 1.5], ["2×", 2.0]]:
		speed.add_item(str(speed_item[0]))
		speed.set_item_metadata(speed.item_count - 1, float(speed_item[1]))
	speed.select(1)
	controls.add_child(speed)
	var about_separator := HSeparator.new()
	about_separator.modulate = Color(BORDER, 0.72)
	controls.add_child(about_separator)
	var about_title := Label.new()
	about_title.text = "About"
	about_title.add_theme_font_size_override("font_size", 16)
	controls.add_child(about_title)
	var about := Label.new()
	about.name = "SelectedCharacterAbout"
	about.text = "Select a character to view package details."
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.add_theme_font_size_override("font_size", 12)
	about.add_theme_color_override("font_color", MUTED)
	controls.add_child(about)
	status.reparent(controls)
	status.name = "PickerStatusLabel"
	var apply := Button.new()
	apply.name = "ApplyCharacterButton"
	apply.text = "Apply character"
	apply.custom_minimum_size = Vector2(0, 52)
	apply.visible = false
	controls.add_child(apply)
	_style_workspace_controls(workspace)


func _add_brand(column: VBoxContainer) -> void:
	var center := CenterContainer.new()
	center.custom_minimum_size = Vector2(0, 78)
	column.add_child(center)
	var logo := TextureRect.new()
	logo.custom_minimum_size = Vector2(66, 66)
	logo.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.texture = load("res://assets/icons/ocp.svg") as Texture2D
	center.add_child(logo)
	var brand := Label.new()
	brand.text = "OCP"
	brand.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	brand.add_theme_font_size_override("font_size", 31)
	brand.add_theme_color_override("font_color", TEXT)
	column.add_child(brand)
	var subtitle := Label.new()
	subtitle.text = "Open Companion Platform"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 10)
	subtitle.add_theme_color_override("font_color", CYAN)
	column.add_child(subtitle)


func _add_nav(column: VBoxContainer, text: String, action: Callable, active: bool) -> void:
	var button := Button.new()
	button.text = text
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0, 54)
	button.toggle_mode = true
	button.button_pressed = active
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_stylebox_override("normal", _nav_style(Color(0.01, 0.04, 0.10, 0.02), Color.TRANSPARENT))
	button.add_theme_stylebox_override("hover", _nav_style(Color(0.03, 0.20, 0.43, 0.72), BORDER))
	button.add_theme_stylebox_override("pressed", _nav_style(Color(0.04, 0.24, 0.52, 0.94), Color(0.22, 0.75, 1.0, 0.96)))
	button.pressed.connect(action)
	column.add_child(button)


func _open_app(page: String) -> void:
	if page.to_lower() == "chat":
		var chat := get_parent().get_node_or_null("ChatWindow") as Window
		if is_instance_valid(chat):
			chat.show()
			chat.grab_focus()
			hide()
		return
	var app := get_parent().get_node_or_null("ApplicationWindow") as Window
	if not is_instance_valid(app):
		return
	if app.has_method("select_control_page"):
		app.call("select_control_page", page, false)
	else:
		var tabs := app.get_node_or_null("ApplicationRoot/ApplicationLayout/ApplicationTabs") as TabContainer
		if is_instance_valid(tabs):
			for index in range(tabs.get_tab_count()):
				if tabs.get_tab_title(index).to_lower() == page:
					tabs.current_tab = index
					break
	app.show()
	app.grab_focus()
	hide()


func _hide_manager_window() -> void:
	# Route title-bar close through the same runtime event as the native close
	# button so CharacterPickerController restores the companion surface.
	close_requested.emit()


static func responsive_side_widths(window_width: float) -> Vector2:
	return Vector2(
		clampf(window_width * 0.18, 270.0, 340.0),
		clampf(window_width * 0.25, 330.0, 420.0)
	)


func prepare_for_window_rect(target_size: Vector2i) -> void:
	# OcpTitleBar calls this before WM_SIZE. Responsive widths are preferred
	# layout sizes, not permanent window minima; precomputing them for the target
	# rect prevents the maximized values from locking Restore at full screen.
	_apply_responsive_constraints(Vector2(target_size))


func prepare_for_native_resize() -> void:
	# A native edge drag has no target rect yet. Start from the compact contract
	# so Windows can shrink freely; _layout_shell() expands the columns again as
	# size_changed events arrive.
	_apply_responsive_constraints(Vector2(min_size))


func _layout_shell() -> void:
	if not is_instance_valid(content):
		return
	if is_instance_valid(custom_title_bar):
		custom_title_bar.position = Vector2.ZERO
		custom_title_bar.size = Vector2(size.x, TITLE_BAR_HEIGHT)
	if is_instance_valid(rail):
		rail.position = Vector2.ZERO
		rail.size = Vector2.ZERO
	content.set_anchors_preset(Control.PRESET_TOP_LEFT)
	content.position = Vector2(0, TITLE_BAR_HEIGHT)
	content.size = Vector2(size.x, maxf(0.0, size.y - TITLE_BAR_HEIGHT))
	# The side regions contain dense controls, so scale their columns instead
	# of stretching every card. Clamp both sides to keep a useful preview stage
	# at smaller sizes and remove excess empty space at desktop widths.
	_apply_responsive_constraints(Vector2(size))


func _apply_responsive_constraints(layout_size: Vector2) -> void:
	if not is_instance_valid(root_panel):
		return
	var side_widths := responsive_side_widths(layout_size.x)
	var library := root_panel.find_child("InstalledCharacterLibrary", true, false) as Control
	if is_instance_valid(library):
		library.custom_minimum_size.x = side_widths.x
	var sidebar := root_panel.find_child("AnimationPreviewPanel", true, false) as Control
	if is_instance_valid(sidebar):
		sidebar.custom_minimum_size.x = side_widths.y
	var animation_scroll := root_panel.find_child("AnimationCatalogScroll", true, false) as ScrollContainer
	if is_instance_valid(animation_scroll):
		animation_scroll.custom_minimum_size.y = clampf(layout_size.y * 0.28, 170.0, 338.0)


func _style_character_row(node: Node) -> void:
	var card := node as PanelContainer
	if is_instance_valid(card):
		card.custom_minimum_size = Vector2(0, 126)
		var is_selected := bool(card.get_meta("ocp_selected", false))
		card.add_theme_stylebox_override(
			"panel",
			_panel_style(
				Color("#0c203c") if is_selected else SURFACE_RAISED,
				15,
				Color(CYAN, 0.96) if is_selected else Color(BORDER, 0.88)
			)
		)
		for child in card.find_children("*", "Control", true, false):
			if child is Label:
				var card_label := child as Label
				card_label.add_theme_font_size_override("font_size", 13)
				if card_label.name == "CharacterStatus":
					card_label.add_theme_color_override("font_color", Color("#54dfaf"))
				elif card_label.name == "CharacterVersion":
					card_label.add_theme_color_override("font_color", MUTED)
				else:
					card_label.add_theme_color_override("font_color", TEXT)
				card_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			elif child is Button:
				var card_button := child as Button
				card_button.custom_minimum_size = Vector2(0, 32)
				card_button.add_theme_font_size_override("font_size", 11)
				var accent := CYAN
				if card_button.name == "CustomizeButton":
					accent = VIOLET
				elif card_button.name == "UninstallButton":
					accent = Color("#cf668a")
				card_button.add_theme_stylebox_override("normal", _card_button_style(accent, false))
				card_button.add_theme_stylebox_override("hover", _card_button_style(accent, true))
				card_button.add_theme_color_override("font_color", TEXT if not card_button.disabled else MUTED)
		return
	var row := node as HBoxContainer
	if not is_instance_valid(row):
		return
	row.custom_minimum_size = Vector2(0, 76)
	row.add_theme_constant_override("separation", 10)
	var palette := current_palette if not current_palette.is_empty() else {
		"surface": NAVY,
		"border": BORDER,
		"accent": CYAN,
		"text": TEXT,
		"muted": MUTED,
	}
	var accent: Color = palette.get("accent", CYAN)
	var border: Color = palette.get("border", BORDER)
	var text: Color = palette.get("text", TEXT)
	for child in row.get_children():
		if child is Label:
			var label := child as Label
			label.add_theme_font_size_override("font_size", 15)
			label.add_theme_color_override("font_color", Color("#56e3b1") if label.text.begins_with("●") else text)
		if child is Button:
			var button := child as Button
			button.custom_minimum_size = Vector2(104, 42)
			button.add_theme_font_size_override("font_size", 14)
			var button_accent := accent
			if button.get_index() == 1:
				button_accent = Color("#7d79ff")
			elif button.get_index() == 3:
				button_accent = Color("#c65a84")
			button.add_theme_stylebox_override("normal", _glass_style(Color(button_accent, 0.12), 10, Color(button_accent, 0.58)))
			button.add_theme_stylebox_override("hover", _glass_style(Color(button_accent, 0.22), 10, Color(button_accent, 0.88)))


func apply_ocp_language(locale: String, catalog: Dictionary) -> void:
	current_language = "th" if locale.to_lower().begins_with("th") else "en"
	current_catalog = catalog.duplicate(true)
	if is_instance_valid(custom_title_bar):
		var window_title := custom_title_bar.find_child("WindowTitle", true, false) as Label
		if is_instance_valid(window_title):
			window_title.text = _localized("character.title", "Character Manager")
	if is_instance_valid(root_panel):
		var hero_title := root_panel.find_child("HeroTitle", true, false) as Label
		if is_instance_valid(hero_title):
			hero_title.text = _localized("character.hero_title", "Your Companions")
		var hero_subtitle := root_panel.find_child("HeroSubtitle", true, false) as Label
		if is_instance_valid(hero_subtitle):
			hero_subtitle.text = _localized("character.hero_subtitle", "Install, activate and manage .ocp character packages")
		var install := root_panel.find_child("InstallPackageButton", true, false) as Button
		if is_instance_valid(install):
			install.text = _localized("character.install", "Install .ocp")
		var workspace_title := root_panel.find_child("CharacterWorkspaceTitle", true, false) as Label
		if is_instance_valid(workspace_title):
			workspace_title.text = _localized("character.workspace_title", "Characters")
		var workspace_subtitle := root_panel.find_child("CharacterWorkspaceSubtitle", true, false) as Label
		if is_instance_valid(workspace_subtitle):
			workspace_subtitle.text = _localized("character.workspace_subtitle", "Manage your companions")
		var list := root_panel.find_child("CharacterList", true, false) as VBoxContainer
		if is_instance_valid(list):
			for child in list.get_children():
				var card := child as PanelContainer
				if is_instance_valid(card):
					var card_customize := card.find_child("CustomizeButton", true, false) as Button
					var card_activate := card.find_child("ActivateButton", true, false) as Button
					var card_uninstall := card.find_child("UninstallButton", true, false) as Button
					if is_instance_valid(card_customize) and card_customize.text == "Edit":
						card_customize.text = _localized("character.customize", "Edit")
					if is_instance_valid(card_activate):
						card_activate.text = _localized("character.active", "Active") if card_activate.disabled else _localized("character.activate", "Use")
					if is_instance_valid(card_uninstall):
						card_uninstall.text = _localized("character.uninstall", "Uninstall")
					continue
				var row := child as HBoxContainer
				if not is_instance_valid(row) or row.get_child_count() < 4:
					continue
				var customize := row.get_child(1) as Button
				var activate := row.get_child(2) as Button
				var uninstall := row.get_child(3) as Button
				if is_instance_valid(customize):
					customize.text = _localized("character.customize", "Customize")
				if is_instance_valid(activate):
					activate.text = _localized("character.active", "Active") if activate.disabled else _localized("character.activate", "Activate")
				if is_instance_valid(uninstall):
					uninstall.text = _localized("character.uninstall", "Uninstall")


func _localized(key: String, fallback: String) -> String:
	return str(current_catalog.get(key, fallback))


func apply_ocp_theme(_palette: Dictionary, _theme_name: String) -> void:
	# ADR-0034: Character Manager keeps a stable local visual hierarchy. The
	# application theme may still be selected elsewhere, but cannot wash this
	# asset-preview workspace into the global Liquid teal.
	current_palette = _manager_palette()
	if is_instance_valid(custom_title_bar) and custom_title_bar.has_method("apply_ocp_theme"):
		custom_title_bar.call("apply_ocp_theme", current_palette, "solid")
	if is_instance_valid(root_panel):
		var root_style := _panel_style(NAVY_DEEP, 18, Color(CYAN, 0.78))
		root_style.content_margin_left = 28
		root_style.content_margin_top = 18
		root_style.content_margin_right = 28
		root_style.content_margin_bottom = 24
		root_panel.add_theme_stylebox_override("panel", root_style)
		var workspace := root_panel.find_child("CharacterWorkspace", true, false) as VBoxContainer
		if is_instance_valid(workspace):
			_style_workspace_controls(workspace)
		var list := root_panel.find_child("CharacterList", true, false) as VBoxContainer
		if is_instance_valid(list):
			for row in list.get_children():
				_style_character_row(row)
	if is_instance_valid(rail):
		rail.add_theme_stylebox_override("panel", _panel_style(NAVY_DEEP, 0, BORDER))


func _manager_palette() -> Dictionary:
	return {
		"surface_strong": NAVY_DEEP,
		"surface": SURFACE,
		"border": BORDER,
		"accent": CYAN,
		"text": TEXT,
		"muted": MUTED,
	}


func _clear_theme_materials(scope: Control) -> void:
	# Remove only shader materials created by ThemeService on an earlier theme
	# pass; authored materials outside this window are never touched.
	if bool(scope.get_meta("ocp_theme_material_owned", false)):
		scope.material = null
		scope.remove_meta("ocp_theme_material_owned")
	for node in scope.find_children("*", "Control", true, false):
		var control := node as Control
		if bool(control.get_meta("ocp_theme_material_owned", false)):
			control.material = null
			control.remove_meta("ocp_theme_material_owned")


func _style_workspace_controls(workspace: VBoxContainer) -> void:
	for control in workspace.find_children("*", "Control", true, false):
		if control is LineEdit:
			var line_edit := control as LineEdit
			line_edit.add_theme_stylebox_override("normal", _panel_style(Color("#061225"), 10, Color(BORDER, 0.88)))
			line_edit.add_theme_stylebox_override("focus", _panel_style(Color("#081a32"), 10, CYAN))
			line_edit.add_theme_color_override("font_color", TEXT)
			line_edit.add_theme_color_override("font_placeholder_color", MUTED)
		elif control is OptionButton:
			var option := control as OptionButton
			option.add_theme_stylebox_override("normal", _panel_style(Color("#07172d"), 10, Color(BORDER, 0.88)))
			option.add_theme_stylebox_override("hover", _panel_style(Color("#0a2445"), 10, CYAN))
			option.add_theme_color_override("font_color", TEXT)
		elif control is Button:
			var button := control as Button
			if button.name == "PreviewPlayButton":
				button.add_theme_stylebox_override("normal", _playback_button_style(false))
				button.add_theme_stylebox_override("hover", _playback_button_style(true))
			elif button.name in ["ApplyCharacterButton", "SelectedUseAction"]:
				button.add_theme_stylebox_override("normal", _primary_button_style(false))
				button.add_theme_stylebox_override("hover", _primary_button_style(true))
			elif button.name == "SelectedPreviewAction":
				button.add_theme_stylebox_override("normal", _secondary_button_style(false))
				button.add_theme_stylebox_override("hover", _secondary_button_style(true))
			elif button.name == "SelectedSecondaryAction":
				button.add_theme_stylebox_override("normal", _card_button_style(VIOLET, false))
				button.add_theme_stylebox_override("hover", _card_button_style(VIOLET, true))
			elif button.name == "SelectedUninstallAction":
				button.add_theme_stylebox_override("normal", _card_button_style(Color("#cf668a"), false))
				button.add_theme_stylebox_override("hover", _card_button_style(Color("#cf668a"), true))
			elif button.name == "ExploreCharacterStoreButton":
				button.add_theme_stylebox_override("normal", _secondary_button_style(false))
				button.add_theme_stylebox_override("hover", _secondary_button_style(true))
			elif button.name in ["InstalledLibraryTab", "CloudLibraryTab"]:
				button.add_theme_stylebox_override("normal", _quiet_button_style(false))
				button.add_theme_stylebox_override("hover", _quiet_button_style(true))
				button.add_theme_stylebox_override("pressed", _secondary_button_style(true))
			else:
				button.add_theme_stylebox_override("normal", _quiet_button_style(false))
				button.add_theme_stylebox_override("hover", _quiet_button_style(true))
			button.add_theme_color_override("font_color", TEXT if not button.disabled else MUTED)


func _nav_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(13)
	style.content_margin_left = 16
	style.content_margin_right = 10
	style.shadow_color = Color(0.0, 0.53, 1.0, 0.22) if border.a > 0.0 else Color.TRANSPARENT
	style.shadow_size = 9 if border.a > 0.0 else 0
	return style


func _shell_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = NAVY_DEEP
	style.border_color = Color(0.13, 0.55, 0.96, 0.86)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	return style


func _rail_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = NAVY
	style.border_color = Color(0.10, 0.32, 0.58, 0.66)
	style.border_width_right = 1
	return style


func _glass_style(background: Color, radius: int, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.shadow_color = Color(0.0, 0.32, 0.75, 0.18)
	style.shadow_size = 12
	return style


func _panel_style(background: Color, radius: int, border: Color) -> StyleBoxFlat:
	var style := _glass_style(background, radius, border)
	style.shadow_color = Color(0.0, 0.04, 0.14, 0.72)
	style.shadow_size = 16
	style.content_margin_left = 14
	style.content_margin_top = 14
	style.content_margin_right = 14
	style.content_margin_bottom = 14
	return style


func _primary_button_style(hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#159fe0") if not hovered else Color("#29caff")
	style.border_color = Color("#67dcff")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(CYAN, 0.34)
	style.shadow_size = 12
	return style


func _playback_button_style(hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#101c45") if not hovered else Color("#172d61")
	style.border_color = CYAN if not hovered else VIOLET
	style.set_border_width_all(3)
	style.set_corner_radius_all(38)
	style.shadow_color = Color(CYAN.lerp(VIOLET, 0.5), 0.48)
	style.shadow_size = 18
	return style


func _quiet_button_style(hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#0a1b33") if not hovered else Color("#102b4e")
	style.border_color = Color(BORDER, 0.88) if not hovered else CYAN
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	return style


func _card_button_style(accent: Color, hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(accent, 0.14 if not hovered else 0.26)
	style.border_color = Color(accent, 0.58 if not hovered else 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	return style


func _secondary_button_style(hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.14, 0.34, 0.96) if not hovered else Color(0.10, 0.24, 0.50, 0.98)
	style.border_color = Color(0.30, 0.52, 1.0, 0.78)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0.12, 0.25, 1.0, 0.28)
	style.shadow_size = 10
	return style
