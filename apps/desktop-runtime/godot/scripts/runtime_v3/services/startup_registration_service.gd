extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3StartupRegistrationService

## Per-user Windows startup registration. Uses HKCU so no administrator rights
## are required. Development runs register the G12 launcher; exported builds
## register the application executable itself.

const RUN_KEY := "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
const VALUE_NAME := "OpenCompanionPlatform"

var last_error := ""


func set_enabled(enabled: bool) -> bool:
	last_error = ""
	if OS.get_name() != "Windows":
		last_error = "Start with Windows is only supported on Windows"
		return false
	# Avoid touching the Run key when it already matches the requested state.
	# This keeps normal launches fast and avoids repeatedly invoking registry tools.
	if enabled == is_enabled():
		return true
	var command := startup_command() if enabled else ""
	if enabled and command.is_empty():
		last_error = "Unable to determine the OCP startup command"
		return false

	# Some managed Windows environments block reg.exe writes while still allowing
	# the current user to update HKCU through the PowerShell Registry provider.
	# Prefer that API and retain reg.exe as a compatibility fallback.
	var powershell_output: Array = []
	var powershell_exit := _set_enabled_with_powershell(enabled, command, powershell_output)
	if powershell_exit == 0:
		return true

	var reg_output: Array = []
	var reg_exit := _set_enabled_with_reg(enabled, command, reg_output)
	if reg_exit == 0:
		return true
	last_error = "Startup registration failed (PowerShell code %d: %s; reg.exe code %d: %s)" % [
		powershell_exit,
		" ".join(powershell_output),
		reg_exit,
		" ".join(reg_output),
	]
	push_warning("StartupRegistrationService: " + last_error)
	return false


func is_enabled() -> bool:
	if OS.get_name() != "Windows":
		return false
	var reg := _reg_executable()
	if reg.is_empty():
		return false
	var output: Array = []
	return OS.execute(reg, ["query", RUN_KEY, "/v", VALUE_NAME], output, true, false) == 0


func startup_command() -> String:
	var override := OS.get_environment("OCP_STARTUP_COMMAND").strip_edges()
	if not override.is_empty():
		return override
	var executable := OS.get_executable_path()
	var executable_name := executable.get_file().to_lower()
	if not executable.is_empty() and not executable_name.contains("godot"):
		# Packaged installs must start the native launcher, not ocp-runtime.exe
		# directly, so Kernel, native host, Desktop Shell and proxy bootstrap all
		# come up through the same authority used by Start Menu/Desktop shortcuts.
		var packaged_launcher := executable.get_base_dir().path_join("ocp-launcher.exe")
		if FileAccess.file_exists(packaged_launcher):
			return _quote(packaged_launcher)
		return _quote(executable)
	# Development runtime: res:// is .../apps/desktop-runtime/godot.
	var launcher := ProjectSettings.globalize_path("res://../../../start_g12_real_character_native_runtime.ps1").simplify_path()
	if not FileAccess.file_exists(launcher):
		last_error = "Development startup launcher was not found: %s" % launcher
		return ""
	return "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File %s" % _quote(launcher)


func _set_enabled_with_powershell(enabled: bool, command: String, output: Array) -> int:
	var powershell := _powershell_executable()
	if powershell.is_empty():
		output.append("powershell.exe was not found")
		return -1
	var key := "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
	var script := ""
	if enabled:
		script = "$ErrorActionPreference='Stop'; New-ItemProperty -Path '%s' -Name '%s' -PropertyType String -Value '%s' -Force | Out-Null" % [
			_ps_single_quote(key),
			_ps_single_quote(VALUE_NAME),
			_ps_single_quote(command),
		]
	else:
		script = "$ErrorActionPreference='Stop'; if (Get-ItemProperty -Path '%s' -Name '%s' -ErrorAction SilentlyContinue) { Remove-ItemProperty -Path '%s' -Name '%s' -ErrorAction Stop }" % [
			_ps_single_quote(key),
			_ps_single_quote(VALUE_NAME),
			_ps_single_quote(key),
			_ps_single_quote(VALUE_NAME),
		]
	return OS.execute(powershell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script], output, true, false)


func _set_enabled_with_reg(enabled: bool, command: String, output: Array) -> int:
	var reg := _reg_executable()
	if reg.is_empty():
		output.append("reg.exe was not found")
		return -1
	if enabled:
		return OS.execute(reg, ["add", RUN_KEY, "/v", VALUE_NAME, "/t", "REG_SZ", "/d", command, "/f"], output, true, false)
	return OS.execute(reg, ["delete", RUN_KEY, "/v", VALUE_NAME, "/f"], output, true, false)


func _powershell_executable() -> String:
	var system_root := OS.get_environment("SystemRoot")
	if not system_root.is_empty():
		var candidate := system_root.path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
		if FileAccess.file_exists(candidate):
			return candidate
	return "powershell.exe"


func _ps_single_quote(value: String) -> String:
	return value.replace("'", "''")


func _reg_executable() -> String:
	var system_root := OS.get_environment("SystemRoot")
	if not system_root.is_empty():
		var candidate := system_root.path_join("System32/reg.exe")
		if FileAccess.file_exists(candidate):
			return candidate
	return "reg.exe"


func _quote(value: String) -> String:
	return "\"%s\"" % value.replace("\"", "\\\"")
