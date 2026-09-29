extends Control
## Application Shell Controller. Handles responsive layout, navigation sidebar, and sub-page loading.

@onready var menu_toggle: Button = %BtnMenuToggle
@onready var nav_panel: PanelContainer = %Nav
@onready var main_page_container: PanelContainer = %PageContainer
@onready var save_draft_btn: Button = %SaveDraft
@onready var build_package_btn: Button = %BuildPackage
@onready var project_name_label: Label = %ProjectName

var router: AppRouter
var menu_toggled: bool = true

func _ready() -> void:
	router = AppRouter.new()
	add_child(router)
	router.setup(main_page_container)
	router.page_changed.connect(_on_page_changed)

	resized.connect(_on_resized)
	_on_resized()

	# Connect sidebar buttons — null-safe: nodes may not exist when a
	# sub-scene is run directly with F6 instead of the full AppShell.
	var home_btn: Button = get_node_or_null("%Home")
	if home_btn:
		home_btn.pressed.connect(func(): router.go_to_page("home"))

	var studio_btn: Button = get_node_or_null("%StudioNav")
	if studio_btn:
		studio_btn.pressed.connect(func(): router.go_to_page("studio"))

	var rt_btn: Button = get_node_or_null("%RuntimeTestNav")
	if rt_btn:
		rt_btn.pressed.connect(func(): router.go_to_page("runtime_test"))


func _on_resized() -> void:
	var w := size.x
	if nav_panel:
		if w < 1180:
			nav_panel.visible = false
		else:
			nav_panel.visible = menu_toggled


func _on_btn_menu_toggle_pressed() -> void:
	menu_toggled = not menu_toggled
	if nav_panel:
		nav_panel.visible = menu_toggled


func _on_page_changed(page_name: String) -> void:
	# Show save/build buttons only when inside the Character Studio page
	var is_studio := (page_name == "studio")
	if save_draft_btn: save_draft_btn.visible = is_studio
	if build_package_btn: build_package_btn.visible = is_studio
	if project_name_label:
		if is_studio:
			project_name_label.text = "Aiko — Focus Companion ✏"
		else:
			project_name_label.text = "OCP Desktop Platform 🏠"

	# Highlight active sidebar button — null-safe
	for nav_name in ["Home", "StudioNav", "RuntimeTestNav"]:
		var btn := get_node_or_null("%" + nav_name)
		if btn:
			btn.remove_theme_stylebox_override("normal")

	var active_style := StyleBoxFlat.new()
	active_style.bg_color = Color(0.482, 0.38, 1.0, 0.25)
	active_style.border_width_left = 3
	active_style.border_color = Color(0.482, 0.38, 1.0, 1.0)

	var highlight_map := {"home": "Home", "studio": "StudioNav", "runtime_test": "RuntimeTestNav"}
	if highlight_map.has(page_name):
		var target := get_node_or_null("%" + highlight_map[page_name])
		if target:
			target.add_theme_stylebox_override("normal", active_style)


func _on_save_draft_pressed() -> void:
	if router.active_page_node and router.active_page_node.has_method("_on_save_draft_pressed"):
		router.active_page_node.call("_on_save_draft_pressed")


func _on_build_package_pressed() -> void:
	if router.active_page_node and router.active_page_node.has_method("_on_build_package_pressed"):
		router.active_page_node.call("_on_build_package_pressed")
