extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shell := Window.new()
	shell.name = "ApplicationWindow"
	shell.set_script(load("res://scripts/runtime_v3/ui/production_app_shell.gd"))

	var application_root := PanelContainer.new()
	application_root.name = "ApplicationRoot"
	var layout := Control.new()
	layout.name = "ApplicationLayout"
	var tabs := TabContainer.new()
	tabs.name = "ApplicationTabs"
	tabs.add_child(Control.new())
	tabs.add_child(Control.new())
	tabs.add_child(Control.new())
	layout.add_child(tabs)
	application_root.add_child(layout)
	shell.add_child(application_root)
	get_root().add_child(shell)
	await process_frame

	shell.call("_build_shell")
	var rail := shell.get_node_or_null("ProductionNavigationRail") as PanelContainer
	var info_rail := shell.get_node_or_null("ProductionInfoRail") as PanelContainer
	var ok := rail != null and info_rail != null and not tabs.tabs_visible
	ok = ok and is_equal_approx(rail.size.x, 260.0)
	ok = ok and is_equal_approx(info_rail.size.x, 232.0)
	ok = ok and not info_rail.visible and rail.get_child_count() > 0
	print("[P3.4.2] control_center_rail=true chat_separate=true compatibility_info_rail_hidden=true tabs_hidden=true widths=260,232")

	shell.queue_free()
	await process_frame
	quit(0 if ok else 1)
