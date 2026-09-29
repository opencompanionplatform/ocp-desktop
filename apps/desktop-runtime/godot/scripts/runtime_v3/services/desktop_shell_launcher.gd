extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name DesktopShellLauncherService

## G16.4B starts a bounded Shell view. ADR-0039 may append a Runtime-created
## functional-adapter session; without that explicit opt-in this remains the
## presentation-only launcher and Godot remains the fallback.

const ENABLED_ENV := "OCP_DESKTOP_SHELL_ENABLED"
const EXECUTABLE_ENV := "OCP_DESKTOP_SHELL_EXECUTABLE"
const ROOT_ENV := "OCP_DESKTOP_SHELL_ROOT"
const ALLOWED_VIEWS := [&"home", &"characters", &"chat", &"settings", &"updates"]


func try_open(view: StringName) -> bool:
	return _launch(view, false)


func try_warm(view: StringName = &"chat") -> bool:
	return _launch(view, true)


func _launch(view: StringName, warm: bool) -> bool:
	if OS.get_environment(ENABLED_ENV) != "1":
		return false
	if not is_allowed_view(view):
		push_warning("DesktopShellLauncher rejected view: %s" % view)
		return false
	var executable := OS.get_environment(EXECUTABLE_ENV).strip_edges()
	var shell_root := OS.get_environment(ROOT_ENV).strip_edges()
	if executable.is_empty() or shell_root.is_empty():
		print("[DesktopShellLauncher] unavailable: set %s and %s" % [EXECUTABLE_ENV, ROOT_ENV])
		return false
	if not FileAccess.file_exists(executable) or not DirAccess.dir_exists_absolute(shell_root):
		print("[DesktopShellLauncher] unavailable: configured shell path does not exist")
		return false
	# OS.create_process receives a fixed executable plus fixed arguments; it does
	# not invoke a command shell and therefore does not interpret user text.
	var functional_adapter_enabled := OS.get_environment("OCP_DESKTOP_SHELL_FUNCTIONAL_ADAPTER") == "1"
	var adapter_arguments := DesktopShellFunctionalAdapter.launch_arguments() if functional_adapter_enabled else PackedStringArray()
	var arguments := build_launch_arguments(view, shell_root, functional_adapter_enabled, adapter_arguments, warm)
	if arguments.is_empty():
		print("[DesktopShellLauncher] unavailable: functional-adapter-arguments-missing")
		return false
	if functional_adapter_enabled:
		print("[DesktopShellLauncher] functional-adapter=attached")
	var started_at := Time.get_ticks_msec()
	var process_id := OS.create_process(executable, arguments)
	if process_id <= 0:
		print("[DesktopShellLauncher] launch-failed view=%s warm=%s" % [view, warm])
		return false
	print("[DesktopShellLauncher] %s-requested view=%s create_process_ms=%d" % ["warm" if warm else "open", view, Time.get_ticks_msec() - started_at])
	return true


static func is_allowed_view(view: StringName) -> bool:
	return ALLOWED_VIEWS.has(view)


static func build_launch_arguments(
	view: StringName,
	shell_root: String,
	functional_adapter_enabled: bool,
	adapter_arguments: PackedStringArray,
	warm: bool = false
) -> PackedStringArray:
	if not is_allowed_view(view) or shell_root.strip_edges().is_empty():
		return PackedStringArray()
	if functional_adapter_enabled and not _has_functional_adapter_arguments(adapter_arguments):
		return PackedStringArray()
	var arguments := PackedStringArray([shell_root, "--ocp-open=%s" % view, "--ocp-source=%s" % ("command-line" if warm else "hover-menu")])
	if warm:
		arguments.append("--ocp-warm=1")
	if functional_adapter_enabled:
		arguments.append_array(adapter_arguments)
	return arguments


static func _has_functional_adapter_arguments(arguments: PackedStringArray) -> bool:
	var has_directory := false
	var has_token := false
	for argument in arguments:
		has_directory = has_directory or argument.begins_with("--ocp-bridge-dir=")
		has_token = has_token or argument.begins_with("--ocp-bridge-token=")
	return has_directory and has_token
