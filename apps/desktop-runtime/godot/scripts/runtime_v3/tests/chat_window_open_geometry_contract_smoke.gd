extends SceneTree

const SOURCE_PATH := "res://scripts/runtime_v3/ui/production_app_shell.gd"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var file := FileAccess.open(SOURCE_PATH, FileAccess.READ)
	if file == null:
		push_error("[CHAT-WINDOW-GEOMETRY] cannot open production_app_shell.gd")
		quit(1)
		return
	var source := file.get_as_text()
	file.close()

	var show_index := source.find("\tchat_window.show()")
	var avoid_index := source.find("\t_avoid_companion_overlap_for_window(chat_window)")
	var unsafe_target_screen := source.contains("window_get_current_screen(target.get_window_id())")
	var safe_main_fallback := source.contains("window_get_current_screen(DisplayServer.MAIN_WINDOW_ID)")
	var ok := show_index >= 0 \
		and avoid_index > show_index \
		and not unsafe_target_screen \
		and safe_main_fallback
	print("[CHAT-WINDOW-GEOMETRY] show_before_avoid=", avoid_index > show_index, " unsafe_target_screen=", unsafe_target_screen, " safe_main_fallback=", safe_main_fallback)
	quit(0 if ok else 1)
