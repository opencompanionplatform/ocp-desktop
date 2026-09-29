extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/runtime_v3/RuntimeApp.tscn") as PackedScene
	var app := packed.instantiate()
	var chat_window := app.get_node_or_null("ChatWindow") as Window
	var character_window := app.get_node_or_null("CharacterManagerWindow") as Window
	var control_center := app.get_node_or_null("ApplicationWindow") as Window
	var tabs := app.get_node_or_null("ApplicationWindow/ApplicationRoot/ApplicationLayout/ApplicationTabs") as TabContainer
	var chat_input := app.find_child("ChatInput", true, false) as TextEdit
	var titles: Array[String] = []
	if is_instance_valid(tabs):
		for index in range(tabs.get_tab_count()):
			titles.append(tabs.get_tab_title(index).to_lower())
	var ok: bool = (
		is_instance_valid(chat_window)
		and is_instance_valid(character_window)
		and is_instance_valid(control_center)
		and is_instance_valid(chat_input)
		and titles == ["settings", "updates"]
	)
	print("[P3.4.3] separate_windows=", ok, " control_center_tabs=", titles)
	app.free()
	quit(0 if ok else 1)
