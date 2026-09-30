extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3UpdateService

## Guarded bridge to the Rust staging-only updater and explicit apply helper.
## The Rust updater only verifies and stages. Apply runs in a separate process.
## Preview may discover/download/verify in the background. Stable is fail-closed
## until the packaged Production trust boundary explicitly enables it.

const AUTO_CHECK_START_DELAY_SECONDS := 45.0
const AUTO_CHECK_INTERVAL_SECONDS := 6.0 * 60.0 * 60.0
const AUTOMATIC_CHECK_ENV := "OCP_UPDATE_AUTOMATIC_CHECKS"
const PREVIEW_MANIFEST_ENV := "OCP_UPDATE_PREVIEW_MANIFEST_URL"
const PREVIEW_KEY_ID_ENV := "OCP_UPDATE_PREVIEW_KEY_ID"
const PREVIEW_PUBLIC_KEY_ENV := "OCP_UPDATE_PREVIEW_PUBLIC_KEY_B64"
const STABLE_TRUST_READY_ENV := "OCP_UPDATE_STABLE_TRUST_READY"
const USER_AUTOMATIC_CHECKS_SETTING := "automatic_update_checks"
const STABLE_CHANNEL := "stable"
const PREVIEW_CHANNEL := "preview"
const INSTALL_ON_RESTART_MARKER_FILE := "install-on-restart.json"

var _status_path := ""
var _last_status_signature := ""
var _staged_artifact_path := ""
var _staged_version := ""
var _last_state := "idle"
var _last_version := ""
var _check_in_flight := false
var _automatic_checks_enabled := false
var _next_automatic_check_msec := 0
var _install_on_restart := false


func start() -> void:
	_status_path = _configured_status_path()
	refresh_policy()
	if is_instance_valid(event_bus):
		event_bus.subscribe(&"window.exit_requested", Callable(self, "_on_window_exit_requested"))
	set_process(true)


func refresh_policy() -> void:
	_automatic_checks_enabled = _automatic_checks_allowed()
	_schedule_next_automatic_check(AUTO_CHECK_START_DELAY_SECONDS)


func stop() -> void:
	if is_instance_valid(event_bus):
		event_bus.unsubscribe(&"window.exit_requested", Callable(self, "_on_window_exit_requested"))
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
		_install_on_restart = _load_install_on_restart_marker(version)
	elif state in ["applied", "rolled_back", "rollback_failed", "failed", "error", "no_update"]:
		_staged_artifact_path = ""
		_staged_version = ""
		_clear_install_on_restart_marker()
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
	var channel := _selected_channel()
	if channel == STABLE_CHANNEL and not _stable_trust_ready():
		return _result(false, "stable update trust is not ready", -1)
	var manifest_url := _manifest_url_for_channel(channel)
	var key_id := _key_id_for_channel(channel)
	var public_key := _public_key_for_channel(channel)
	var updater := OS.get_environment("OCP_UPDATER_EXE")
	if manifest_url.is_empty() or key_id.is_empty() or public_key.is_empty():
		return _result(false, "%s update configuration is incomplete" % channel, -1)
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
	var channel := _selected_channel()
	if channel == STABLE_CHANNEL and not _stable_trust_ready():
		return "stable-trust-pending"
	var manifest_url := _manifest_url_for_channel(channel)
	var key_id := _key_id_for_channel(channel)
	var public_key := _public_key_for_channel(channel)
	if manifest_url.is_empty() or key_id.is_empty() or public_key.is_empty() or not manifest_url.begins_with("https://"):
		return "preview-config-incomplete" if channel == PREVIEW_CHANNEL else "config-incomplete"
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
		"channel": _selected_channel(),
		"state": _last_state,
		"targetVersion": _last_version,
		"canCheck": can_check(),
		"canApply": can_apply(),
		"checkAvailabilityCode": check_availability_code(),
		"automaticChecksEnabled": _automatic_checks_enabled,
		"nextAutomaticCheckSeconds": next_check_seconds,
		"stableTrustReady": _stable_trust_ready(),
		"installOnRestart": _install_on_restart and can_apply(),
	}


func _environment_flag_enabled(name: String) -> bool:
	return OS.get_environment(name).strip_edges().to_lower() in ["1", "true", "yes", "on"]


func _selected_channel() -> String:
	var raw := STABLE_CHANNEL
	if is_instance_valid(context):
		var settings_value: Variant = context.get("settings")
		if settings_value is Dictionary:
			raw = str((settings_value as Dictionary).get("update_channel", STABLE_CHANNEL)).strip_edges().to_lower()
	if raw in ["beta", "nightly"]:
		return PREVIEW_CHANNEL
	return raw if raw in [STABLE_CHANNEL, PREVIEW_CHANNEL] else STABLE_CHANNEL


func _automatic_checks_allowed() -> bool:
	if not _environment_flag_enabled(AUTOMATIC_CHECK_ENV):
		return false
	if is_instance_valid(context):
		var settings_value: Variant = context.get("settings")
		if settings_value is Dictionary and not bool((settings_value as Dictionary).get(USER_AUTOMATIC_CHECKS_SETTING, true)):
			return false
	return check_availability_code() == "ready"


func _stable_trust_ready() -> bool:
	return _environment_flag_enabled(STABLE_TRUST_READY_ENV)


func _manifest_url_for_channel(channel: String) -> String:
	if channel == PREVIEW_CHANNEL:
		return OS.get_environment(PREVIEW_MANIFEST_ENV).strip_edges()
	return OS.get_environment("OCP_UPDATE_MANIFEST_URL").strip_edges()


func _key_id_for_channel(channel: String) -> String:
	if channel == PREVIEW_CHANNEL:
		var preview := OS.get_environment(PREVIEW_KEY_ID_ENV).strip_edges()
		if not preview.is_empty():
			return preview
	return OS.get_environment("OCP_UPDATE_KEY_ID").strip_edges()


func _public_key_for_channel(channel: String) -> String:
	if channel == PREVIEW_CHANNEL:
		var preview := OS.get_environment(PREVIEW_PUBLIC_KEY_ENV).strip_edges()
		if not preview.is_empty():
			return preview
	return OS.get_environment("OCP_UPDATE_PUBLIC_KEY_B64").strip_edges()


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


func request_install_on_restart(enabled: bool) -> Dictionary:
	if enabled:
		if not can_apply():
			return _result(false, "No verified staged update is available", -1)
		var marker_path := _install_on_restart_marker_path()
		var marker_dir := marker_path.get_base_dir()
		if not marker_dir.is_empty():
			DirAccess.make_dir_recursive_absolute(marker_dir)
		var file := FileAccess.open(marker_path, FileAccess.WRITE)
		if file == null:
			return _result(false, "Could not persist install-on-restart policy", -1)
		file.store_string(JSON.stringify({"version": _staged_version}))
		file.close()
		_install_on_restart = true
	else:
		_clear_install_on_restart_marker()
	if is_instance_valid(event_bus):
		event_bus.publish(&"update.install_on_restart_changed", {
			"enabled": _install_on_restart,
			"version": _staged_version if _install_on_restart else "",
		})
	return _result(true, "Install-on-restart policy updated", -1)


func request_apply(source: String = "updates-page") -> Dictionary:
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
	_clear_install_on_restart_marker()
	_last_state = "apply_requested"
	_last_version = _staged_version
	event_bus.publish(&"update.apply_requested", {
		"pid": pid,
		"version": _staged_version,
		"source": source,
	})
	return _result(true, "Update apply started; OCP will restart after verification", pid)


func _on_window_exit_requested(_payload: Dictionary) -> void:
	if not _install_on_restart or not can_apply() or _last_state == "apply_requested":
		return
	var result := request_apply("install-on-restart")
	if not bool(result.get("ok", false)) and is_instance_valid(event_bus):
		event_bus.publish(&"update.install_on_restart_failed", {
			"version": _staged_version,
		})


func _install_on_restart_marker_path() -> String:
	var staging_dir := OS.get_environment("OCP_UPDATE_STAGING_DIR")
	if staging_dir.is_empty():
		staging_dir = _staged_artifact_path.get_base_dir() if not _staged_artifact_path.is_empty() else "user://updates"
	if staging_dir.begins_with("user://"):
		staging_dir = ProjectSettings.globalize_path(staging_dir)
	return staging_dir.path_join(INSTALL_ON_RESTART_MARKER_FILE)


func _load_install_on_restart_marker(expected_version: String) -> bool:
	var marker_path := _install_on_restart_marker_path()
	if not FileAccess.file_exists(marker_path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(marker_path))
	if not parsed is Dictionary or str((parsed as Dictionary).get("version", "")) != expected_version:
		DirAccess.remove_absolute(marker_path)
		return false
	return true


func _clear_install_on_restart_marker() -> void:
	_install_on_restart = false
	var marker_path := _install_on_restart_marker_path()
	if FileAccess.file_exists(marker_path):
		DirAccess.remove_absolute(marker_path)


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
