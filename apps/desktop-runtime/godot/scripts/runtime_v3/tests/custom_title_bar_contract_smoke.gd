extends SceneTree

const TITLE_BAR_SCRIPT := preload("res://scripts/runtime_v3/ui/ocp_title_bar.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var window := Window.new()
	window.name = "TitleBarSmokeWindow"
	window.borderless = true
	window.size = Vector2i(900, 600)
	get_root().add_child(window)
	var bar := TITLE_BAR_SCRIPT.new()
	bar.configure(window, "Chat")
	bar.size = Vector2(900, 46)
	window.add_child(bar)
	await process_frame
	var buttons := bar.find_children("*", "Button", true, false)
	var title_labels := bar.find_children("WindowTitle", "Label", true, false)
	var ok := window.borderless and is_equal_approx(bar.custom_minimum_size.y, 46.0)
	ok = ok and buttons.size() == 3 and title_labels.size() == 1
	ok = ok and str((title_labels[0] as Label).text) == "Chat"
	print("[P3.4.4] custom_title_bar=%s borderless=%s controls=%d" % [str(ok).to_lower(), str(window.borderless).to_lower(), buttons.size()])
	window.queue_free()
	await process_frame
	quit(0 if ok else 1)
