extends SceneTree

const LocalizationServiceScript = preload("res://scripts/runtime_v3/services/localization_service.gd")
const ShellScript = preload("res://scripts/runtime_v3/ui/production_app_shell.gd")


class FakeContext:
	extends Node
	signal context_changed(section: StringName)
	var settings: Dictionary = {"language": "th"}
	var runtime_config: Dictionary = {}

	func update_runtime_config(values: Dictionary) -> void:
		runtime_config.merge(values, true)
		context_changed.emit(&"runtime_config")


class FakeBus:
	extends Node
	var published: Array[Dictionary] = []

	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)

	var context := FakeContext.new()
	var bus := FakeBus.new()
	var localization = LocalizationServiceScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(localization)
	localization.context = context
	localization.event_bus = bus
	localization.start()
	var language_ok: bool = (
		localization.current_locale == "th"
		and localization.text("settings.title") == "การตั้งค่า"
		and localization.text("text_scale.normal") == "ปกติ"
		and localization.text("text_scale.standard") == "มาตรฐาน"
		and localization.text("text_scale.comfortable") == "สบายตา"
		and localization.text("text_scale.large") == "ใหญ่"
		and localization.text("text_scale.extra") == "ใหญ่มาก"
		and localization.text("update.status.config_incomplete") == "การตั้งค่าอัปเดตแบบลงลายเซ็นยังไม่ครบถ้วน"
		and localization.normalize_locale("th-TH") == "th"
		and localization.normalize_locale("en-US") == "en"
	)

	var shell := Window.new()
	shell.set_script(ShellScript)
	var tabs := TabContainer.new()
	var settings := Control.new()
	settings.name = "Settings"
	var updates := Control.new()
	updates.name = "Updates"
	tabs.add_child(settings)
	tabs.add_child(updates)
	var settings_button := Button.new()
	settings_button.toggle_mode = true
	var updates_button := Button.new()
	updates_button.toggle_mode = true
	shell.tabs = tabs
	shell.nav_buttons = {
		"settings": settings_button,
		"updates": updates_button,
	}
	shell.current_palette = shell._fallback_palette()
	shell._select_control_page("settings", false)
	var first_ok: bool = settings_button.button_pressed and not updates_button.button_pressed
	shell._select_control_page("updates", false)
	var nav_ok: bool = (
		first_ok
		and not settings_button.button_pressed
		and updates_button.button_pressed
	)

	var ok: bool = language_ok and nav_ok
	print("[P3.4.12] localization_th_en=", language_ok, " nav_single_active=", nav_ok, " settings=", settings_button.button_pressed, " updates=", updates_button.button_pressed)
	tabs.free()
	settings_button.free()
	updates_button.free()
	shell.free()
	holder.free()
	quit(0 if ok else 1)
