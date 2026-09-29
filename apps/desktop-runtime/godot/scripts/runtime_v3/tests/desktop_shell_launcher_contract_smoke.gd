extends SceneTree

const LauncherScript = preload("res://scripts/runtime_v3/services/desktop_shell_launcher.gd")


func _initialize() -> void:
	var launcher = LauncherScript.new()
	var token := "a".repeat(64)
	var adapter_arguments := PackedStringArray([
		"--ocp-bridge-dir=C:/Users/example/OCP Runtime/session",
		"--ocp-bridge-token=%s" % token,
	])
	var functional_arguments: PackedStringArray = launcher.build_launch_arguments(
		&"settings",
		"C:/OCP/apps/desktop-shell",
		true,
		adapter_arguments
	)
	var warm_arguments: PackedStringArray = launcher.build_launch_arguments(
		&"chat",
		"C:/OCP/apps/desktop-shell",
		true,
		adapter_arguments,
		true
	)
	var ok := launcher.is_allowed_view(&"home") \
		and launcher.is_allowed_view(&"characters") \
		and launcher.is_allowed_view(&"chat") \
		and launcher.is_allowed_view(&"settings") \
		and launcher.is_allowed_view(&"updates") \
		and not launcher.is_allowed_view(&"physics") \
		and not launcher.is_allowed_view(&"powershell") \
		and functional_arguments.size() == 5 \
		and functional_arguments[3].begins_with("--ocp-bridge-dir=") \
		and functional_arguments[4].begins_with("--ocp-bridge-token=") \
		and warm_arguments.size() == 6 \
		and warm_arguments[1] == "--ocp-open=chat" \
		and warm_arguments[2] == "--ocp-source=command-line" \
		and warm_arguments[3] == "--ocp-warm=1" \
		and warm_arguments[4].begins_with("--ocp-bridge-dir=") \
		and warm_arguments[5].begins_with("--ocp-bridge-token=") \
		and launcher.build_launch_arguments(&"settings", "C:/OCP/apps/desktop-shell", true, PackedStringArray()).is_empty() \
		and launcher.build_launch_arguments(&"settings", "C:/OCP/apps/desktop-shell", true, PackedStringArray([adapter_arguments[0]])).is_empty()
	print("[G16.4B] desktop shell launcher allowlist %s" % ("passed" if ok else "failed"))
	if launcher is Object and is_instance_valid(launcher):
		launcher.free()
	quit(0 if ok else 1)
