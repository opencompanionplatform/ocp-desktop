extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3TrayService

const MENU_CHAT := 30
const MENU_CHANGE_CHARACTER := 40
const MENU_SETTINGS := 50
const MENU_UPDATES := 60
const MENU_COMPANION_VISIBILITY := 70
const MENU_EXIT := 90

var indicator: Object
var popup: PopupMenu
var icon: Texture2D


func start() -> void:
	if not ClassDB.class_exists("StatusIndicator"):
		push_warning("TrayService: StatusIndicator is unavailable")
		return

	popup = PopupMenu.new()
	popup.name = "RuntimeTrayMenu"
	add_child(popup)
	popup.add_item("Chat", MENU_CHAT)
	popup.add_item("Change Character", MENU_CHANGE_CHARACTER)
	popup.add_item("Settings", MENU_SETTINGS)
	popup.add_item("Updates...", MENU_UPDATES)
	popup.add_separator()
	popup.add_item("Hide Companion", MENU_COMPANION_VISIBILITY)
	popup.add_separator()
	popup.add_item("Exit OCP", MENU_EXIT)
	popup.id_pressed.connect(_on_menu_id)
	if popup.has_signal("about_to_popup"):
		popup.about_to_popup.connect(_refresh_menu)

	if is_instance_valid(context) and context.has_signal("context_changed"):
		var callback := Callable(self, "_on_context_changed")
		if not context.is_connected("context_changed", callback):
			context.connect("context_changed", callback)
	_refresh_menu()

	indicator = ClassDB.instantiate("StatusIndicator")
	if indicator == null:
		return
	add_child(indicator)

	icon = _build_icon()
	indicator.set("icon", icon)
	indicator.set("tooltip", "Open Companion Platform")
	indicator.set("menu", popup.get_path())
	indicator.set("visible", true)
	# Direct tray-icon clicks restore the companion. The popup owns Control
	# Center, Settings, Chat, Character Manager and update navigation.
	if indicator.has_signal("pressed"):
		var callback := Callable(self, "_on_indicator_pressed")
		if not indicator.is_connected("pressed", callback):
			indicator.connect("pressed", callback)


func stop() -> void:
	if is_instance_valid(context) and context.has_signal("context_changed"):
		var callback := Callable(self, "_on_context_changed")
		if context.is_connected("context_changed", callback):
			context.disconnect("context_changed", callback)
	if indicator != null:
		indicator.set("visible", false)


func _on_menu_id(id: int) -> void:
	match id:
		MENU_CHAT:
			event_bus.publish(&"chat_window.open_requested", {"source": "tray"})
		MENU_CHANGE_CHARACTER:
			event_bus.publish(&"character_picker.open_requested", {"source": "tray"})
		MENU_SETTINGS:
			event_bus.publish(&"application_window.open_requested", {"page": "settings", "source": "tray"})
		MENU_UPDATES:
			event_bus.publish(&"application_window.open_requested", {"page": "updates", "source": "tray"})
		MENU_COMPANION_VISIBILITY:
			if _companion_hidden():
				event_bus.publish(&"window.restore_requested", {"source": "tray"})
			else:
				event_bus.publish(&"window.hide_to_tray_requested", {"source": "tray"})
		MENU_EXIT:
			event_bus.publish(&"window.exit_requested", {"source": "tray"})


func _on_indicator_pressed(_mouse_button: int = 0, _mouse_position: Vector2i = Vector2i.ZERO) -> void:
	event_bus.publish(&"window.restore_requested", {"source": "tray-icon"})


func _on_context_changed(section: StringName) -> void:
	if section in [&"window", &"settings"]:
		_refresh_menu()


func _refresh_menu() -> void:
	if not is_instance_valid(popup):
		return
	var thai := _is_thai()
	_set_menu_text(MENU_CHAT, "แชต" if thai else "Chat")
	_set_menu_text(MENU_CHANGE_CHARACTER, "เปลี่ยนตัวละคร" if thai else "Change Character")
	_set_menu_text(MENU_SETTINGS, "การตั้งค่า" if thai else "Settings")
	_set_menu_text(MENU_UPDATES, "อัปเดต..." if thai else "Updates...")
	var visibility_text := (
		("แสดงคู่หู" if thai else "Show Companion")
		if _companion_hidden()
		else ("ซ่อนคู่หู" if thai else "Hide Companion")
	)
	_set_menu_text(MENU_COMPANION_VISIBILITY, visibility_text)
	_set_menu_text(MENU_EXIT, "ออกจาก OCP" if thai else "Exit OCP")


func _set_menu_text(id: int, text: String) -> void:
	var index := popup.get_item_index(id)
	if index >= 0:
		popup.set_item_text(index, text)


func _companion_hidden() -> bool:
	return is_instance_valid(context) and bool(context.window.get("hidden_to_tray", false))


func _is_thai() -> bool:
	return is_instance_valid(context) and str(context.settings.get("language", "en")).to_lower() == "th"


func _build_icon() -> Texture2D:
	# Load through Godot's resource system so the icon also works inside the
	# exported PCK. Filesystem paths such as globalize_path(res://...) do not
	# address resources packed into ocp-runtime.pck.
	var branded_texture := load("res://assets/icons/ocp.png") as Texture2D
	if branded_texture != null:
		return branded_texture
	# Keep the filesystem fallback for development environments where the asset
	# has not been imported yet.
	var branded_image := Image.new()
	var branded_path := ProjectSettings.globalize_path("res://assets/icons/ocp.png")
	if branded_image.load(branded_path) == OK:
		return ImageTexture.create_from_image(branded_image)
	var svg := """
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">
  <rect width="64" height="64" rx="16" fill="#2563eb"/>
  <circle cx="24" cy="28" r="6" fill="white"/>
  <circle cx="40" cy="28" r="6" fill="white"/>
  <rect x="22" y="42" width="20" height="4" rx="2" fill="white"/>
</svg>
"""
	var image := Image.new()
	if image.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(image)
