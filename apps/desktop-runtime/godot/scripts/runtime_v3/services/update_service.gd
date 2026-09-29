extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3UpdateService

## Guarded bridge to the Rust staging-only updater and explicit apply helper.
## The Rust updater only verifies and stages. Apply runs in a separate process.
## Automatic update checks are intentionally staging-only: OCP may discover,
## download, and verify a signed update in the background, but installation
## remains an explicit user action.

const AUTO_CHECK_START_DELAY_SECONDS := 45.0
const AUTO_CHECK_INTERVAL_SECONDS := 6.0 * 60.0 * 60.0
const AUTOMATIC_CHECK_ENV := "OCP_UPDATE_AUTOMATIC_CHECKS"

var _status_path := ""
var _last_status_signature := ""
var _staged_artifact_path := ""
var _staged_version := ""
var _last_state := "idle"
var _last_version := ""
var _check_in_flight := false
var _automatic_checks_enabled := false
var _next_automatic_check_msec := 0


func start() -> void:
	_status_path = _configured_status_path()
	_automatic_checks_enabled = _environment_flag_enabled(AUTOMATIC_CHECK_ENV)
	_schedule_next_automatic_check(AUTO_CHECK_START_DELAY_SECONDS)
	set_process(true)


func stop() -> void:
	set_process(false)
	_check_in_flight = false
	_next_automatic_check_msec = 0


func _process(_delta: float) -> void:
	_maybe_run_automatic_check()
	if _status_path.is_empty() or not FileAccess.file_exists(_status_path):
		return
	var file := FileAccess.open(_status_path, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return
	var state := str(parsed.get("state", ""))
	if state.is_empty() or state == "checking":
		return
	var message := str(parsed.get("message", "Update check finished"))
	var version := str(parsed.get("version", ""))
	var artifact_path := str(parsed.get("artifactPath", ""))
	var signature := "%s|%s|%s|%s" % [state, message, version, artifact_path]
	if signature == _last_status_signature:
		return
	_last_status_signature = signature
	_last_state = state
	_last_version = version
	if state == "staged":
		_staged_artifact_path = artifact_path
		_staged_version = version
	elif state in ["applied", "rolled_back", "rollback_failed", "failed", "error", "no_update"]:
		_staged_artifact_path = ""
		_staged_version = ""
	_check_in_flight = false
	_schedule_next_automatic_check(AUTO_CHECK_INTERVAL_SECONDS)
	event_bus.publish(&"update.status_changed", {
		"state": state,
		"message": message,
		"version": version,
		"artifactPath": artifact_path,
		"source": "rust-updater",
	})
	event_bus.publish(&"update.check_finished", {
		"state": state,
		"message": message,
		"version": version,
		"artifactPath": artifact_path,
		"source": "rust-updater",
	})

func request_check() -> Dictionary:
	return _request_check("updates-page")


func _request_check(source: String) -> Dictionary:
	if _check_in_flight or _last_state == "checking":
		return _result(false, "Update check is already running", -1)
	if can_apply():
		return _result(false, "A verified staged update is already ready to install", -1)
	var manifest_url := OS.get_environment("OCP_UPDATE_MANIFEST_URL")
	var key_id := OS.get_environment("OCP_UPDATE_KEY_ID")
	var public_key := OS.get_environment("OCP_UPDATE_PUBLIC_KEY_B64")
	var updater := OS.get_environment("OCP_UPDATER_EXE")
	if manifest_url.is_empty() or key_id.is_empty() or public_key.is_empty():
		return _result(false, "signed update configuration is incomplete", -1)
	if not manifest_url.begins_with("https://"):
		return _result(false, "manifest URL must use HTTPS", -1)
	if updater.is_empty() or not FileAccess.file_exists(updater):
		return _result(false, "Rust updater executable is not installed", -1)

	var current_version := _application_version()
	var platform := "windows" if OS.get_name() == "Windows" else "macos"
	var arch := OS.get_environment("OCP_UPDATE_ARCH")
	if arch.is_empty():
		arch = "arm64"
	var staging_dir := OS.get_environment("OCP_UPDATE_STAGING_DIR")
	if staging_dir.is_empty():
		staging_dir = "user://updates"
	if staging_dir.begins_with("user://"):
		staging_dir = ProjectSettings.globalize_path(staging_dir)
	_status_path = _configured_status_path(staging_dir)
	_last_status_signature = ""
	_staged_artifact_path = ""
	_staged_version = ""
	_last_state = "checking"
	_last_version = ""
	_check_in_flight = true
	if FileAccess.file_exists(_status_path):
		DirAccess.remove_absolute(_status_path)
	var args := [
		"check",
		"--manifest-url", manifest_url,
		"--current-version", current_version,
		"--platform", platform,
		"--arch", arch,
		"--key-id", key_id,
		"--public-key-base64", public_key,
		"--staging-dir", staging_dir,
		"--status-file", _status_path,
	]
	var pid := OS.create_process(updater, args)
	if pid <= 0:
		_check_in_flight = false
		_last_state = "error"
		_schedule_next_automatic_check(AUTO_CHECK_INTERVAL_SECONDS)
		return _result(false, "could not start Rust updater", pid)
	_schedule_next_automatic_check(AUTO_CHECK_INTERVAL_SECONDS)
	event_bus.publish(&"update.check_started", {"pid": pid, "source": source})
	return _result(true, "Rust updater started; installation was not modified", pid)


func can_check() -> bool:
	return check_availability_code() == "ready"


func check_availability_code() -> String:
	var manifest_url := OS.get_environment("OCP_UPDATE_MANIFEST_URL")
	var key_id := OS.get_environment("OCP_UPDATE_KEY_ID")
	var public_key := OS.get_environment("OCP_UPDATE_PUBLIC_KEY_B64")
	if manifest_url.is_empty() or key_id.is_empty() or public_key.is_empty() or not manifest_url.begins_with("https://"):
		return "config-incomplete"
	var updater := OS.get_environment("OCP_UPDATER_EXE")
	if updater.is_empty() or not FileAccess.file_exists(updater):
		return "updater-missing"
	return "ready"


func safe_status() -> Dictionary:
	var next_check_seconds := 0
	if _automatic_checks_enabled and _next_automatic_check_msec > 0:
		next_check_seconds = maxi(0, int(ceil(float(_next_automatic_check_msec - Time.get_ticks_msec()) / 1000.0)))
	return {
		"currentVersion": _application_version(),
		"state": _last_state,
		"targetVersion": _last_version,
		"canCheck": can_check(),
		"canApply": can_apply(),
		"checkAvailabilityCode": check_availability_code(),
		"automaticChecksEnabled": _automatic_checks_enabled,
		"nextAutomaticCheckSeconds": next_check_seconds,
	}


func _environment_flag_enabled(name: String) -> bool:
	return OS.get_environment(name).strip_edges().to_lower() in ["1", "true", "yes", "on"]


func _schedule_next_automatic_check(delay_seconds: float) -> void:
	if not _automatic_checks_enabled:
		_next_automatic_check_msec = 0
		return
	_next_automatic_check_msec = Time.get_ticks_msec() + int(maxf(1.0, delay_seconds) * 1000.0)


func _maybe_run_automatic_check() -> void:
	if not _automatic_checks_enabled or _next_automatic_check_msec <= 0:
		return
	if Time.get_ticks_msec() < _next_automatic_check_msec:
		return
	if can_apply():
		# A verified update is already staged. Never replace it or install it
		# automatically; the user owns the apply decision.
		_next_automatic_check_msec = 0
		return
	if _check_in_flight or _last_state in ["checking", "apply_requested"]:
		_schedule_next_automatic_check(AUTO_CHECK_INTERVAL_SECONDS)
		return
	if not can_check():
		_schedule_next_automatic_check(AUTO_CHECK_INTERVAL_SECONDS)
		return
	var result := _request_check("automatic")
	if not bool(result.get("ok", false)):
		_schedule_next_automatic_check(AUTO_CHECK_INTERVAL_SECONDS)


func can_apply() -> bool:
	return not _staged_artifact_path.is_empty() \
		and not _staged_version.is_empty() \
		and FileAccess.file_exists(_staged_artifact_path)


func request_apply() -> Dictionary:
	if not can_apply():
		return _result(false, "No verified staged update is available", -1)
	var apply_script := OS.get_environment("OCP_UPDATE_APPLY_SCRIPT")
	var install_root := OS.get_environment("OCP_UPDATE_INSTALL_ROOT")
	var start_script := OS.get_environment("OCP_UPDATE_START_SCRIPT")
	var staging_dir := OS.get_environment("OCP_UPDATE_STAGING_DIR")
	var status_file := OS.get_environment("OCP_UPDATE_STATUS_FILE")
	var health_file := OS.get_environment("OCP_UPDATE_HEALTH_FILE")
	if apply_script.is_empty() or install_root.is_empty() or start_script.is_empty():
		return _result(false, "Update apply is not configured in this installation", -1)
	if staging_dir.is_empty():
		staging_dir = _staged_artifact_path.get_base_dir()
	if status_file.is_empty():
		status_file = staging_dir.path_join("ocp-update-status.json")
	if health_file.is_empty():
		health_file = staging_dir.path_join("startup-ok.json")
	if not FileAccess.file_exists(apply_script):
		return _result(false, "Update apply helper is not installed", -1)
	var peer_ids := OS.get_environment("OCP_UPDATE_PEER_PROCESS_IDS")
	var process_ids := str(OS.get_process_id())
	if not peer_ids.is_empty():
		process_ids += "," + peer_ids
	_status_path = status_file
	_last_status_signature = ""
	var args := [
		"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", apply_script,
		"-InstallRoot", install_root,
		"-ArtifactPath", _staged_artifact_path,
		"-StagingDirectory", staging_dir,
		"-StartScript", start_script,
		"-CurrentVersion", _application_version(),
		"-TargetVersion", _staged_version,
		"-StatusFile", status_file,
		"-HealthFile", health_file,
		"-ProcessIds", process_ids,
	]
	var pid := OS.create_process("powershell.exe", args)
	if pid <= 0:
		return _result(false, "Could not start update apply helper", pid)
	_last_state = "apply_requested"
	_last_version = _staged_version
	event_bus.publish(&"update.apply_requested", {
		"pid": pid,
		"version": _staged_version,
		"source": "updates-page",
	})
	return _result(true, "Update apply started; OCP will restart after verification", pid)


func _result(ok: bool, message: String, pid: int) -> Dictionary:
	return {"ok": ok, "message": message, "pid": pid}


func _application_version() -> String:
	var build_info_path := OS.get_executable_path().get_base_dir().path_join("BUILD-INFO.json")
	if FileAccess.file_exists(build_info_path):
		var file := FileAccess.open(build_info_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and not str(parsed.get("version", "")).is_empty():
				return str(parsed.get("version"))
	var configured := str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
	return configured if not configured.is_empty() else "0.1.0"


func _configured_status_path(staging_dir: String = "") -> String:
	var configured := OS.get_environment("OCP_UPDATE_STATUS_FILE")
	if not configured.is_empty():
		return configured
	var directory := staging_dir
	if directory.is_empty():
		directory = OS.get_environment("OCP_UPDATE_STAGING_DIR")
	if directory.is_empty():
		directory = "user://updates"
	if directory.begins_with("user://"):
		directory = ProjectSettings.globalize_path(directory)
	return directory.path_join("ocp-update-status.json")
