extends SceneTree

const ThemeServiceScript = preload("res://scripts/runtime_v3/services/theme_service.gd")


class FakeContext:
	extends Node
	var settings: Dictionary = {"theme_preset": "solid", "font_family": "Noto Sans Thai", "language": "en", "text_scale": 1.15}
	var runtime_config: Dictionary = {}

	func update_runtime_config(values: Dictionary) -> void:
		runtime_config.merge(values, true)


class FakeBus:
	extends Node
	var events: Array = []

	func publish(event_name: StringName, payload: Dictionary = {}) -> void:
		events.append([event_name, payload])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := FakeBus.new()
	var service = ThemeServiceScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	service.context = context
	service.event_bus = bus

	var windows: Array[Window] = []
	var panels: Array[PanelContainer] = []
	var labels: Array[Label] = []
	for name in ["ControlCenter", "Chat", "CharacterManager"]:
		var window := Window.new()
		window.name = name
		var panel := PanelContainer.new()
		window.add_child(panel)
		var label := Label.new()
		label.text = name
		label.add_theme_font_size_override("font_size", 20)
		panel.add_child(label)
		holder.add_child(window)
		service.register_window(window)
		windows.append(window)
		panels.append(panel)
		labels.append(label)

	service.select_theme("glass")
	var glass_ok := true
	for panel in panels:
		glass_ok = glass_ok and panel.material is ShaderMaterial
	var registered_ok: bool = service.registered_windows.size() == 3
	service.select_theme("liquid")
	var liquid_ok: bool = str(context.runtime_config.get("theme_preset", "")) == "liquid"
	for panel in panels:
		liquid_ok = liquid_ok and panel.material is ShaderMaterial
	service.preview_text_scale(1.80)
	var text_scale_ok := true
	for label in labels:
		text_scale_ok = text_scale_ok and label.get_theme_font_size("font_size") == 36
	bus.events.clear()
	context.settings["language"] = "th"
	service._apply_from_settings()
	var language_state_ok: bool = service.current_language == "th"
	var language_event_ok: bool = false
	for event in bus.events:
		if event[0] == &"theme.changed" and str(event[1].get("language", "")) == "th":
			language_event_ok = true
			break
	var ok: bool = registered_ok and glass_ok and liquid_ok and text_scale_ok and language_state_ok and language_event_ok
	print("[P3.2.1] multi-window theme registered=", registered_ok, " glass=", glass_ok, " liquid=", liquid_ok, " text_scale=", text_scale_ok, " language_state=", language_state_ok, " language_event=", language_event_ok)
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
