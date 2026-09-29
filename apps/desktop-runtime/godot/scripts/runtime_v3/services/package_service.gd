extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3PackageService

const ReaderScript = preload("res://scripts/runtime/packages/ocp_package_reader.gd")
const ValidatorScript = preload("res://scripts/runtime/packages/ocp_package_validator.gd")
const InstallerScript = preload("res://scripts/runtime/packages/character_package_installer.gd")
const RepositoryScript = preload("res://scripts/runtime/packages/installed_character_repository.gd")

const EMBEDDED_STARTER_ID := "character.bible"
const EMBEDDED_STARTER_VERSION := "1.0.0"
const EMBEDDED_STARTER_FILENAME := "character.bible-1.0.0.ocp"
const EMBEDDED_STARTER_ENV := "OCP_EMBEDDED_STARTER_PACKAGE"


func start() -> void:
	event_bus.subscribe(&"character.activate_requested", Callable(self, "_on_activate_requested"))
	event_bus.subscribe(&"character.uninstall_requested", Callable(self, "_on_uninstall_requested"))
	event_bus.subscribe(&"package.install_requested", Callable(self, "_on_install_requested"))


func stop() -> void:
	event_bus.unsubscribe(&"character.activate_requested", Callable(self, "_on_activate_requested"))
	event_bus.unsubscribe(&"character.uninstall_requested", Callable(self, "_on_uninstall_requested"))
	event_bus.unsubscribe(&"package.install_requested", Callable(self, "_on_install_requested"))


func list_installed(verified_package_info: Dictionary = {}) -> Array:
	return RepositoryScript.new().list_installed(verified_package_info)


func is_installed_exact(package_id: String, version: String) -> bool:
	if package_id.strip_edges().is_empty() or version.strip_edges().is_empty():
		return false
	return not RepositoryScript.new().find_exact(package_id.strip_edges(), version.strip_edges()).is_empty()


func get_active() -> Dictionary:
	return RepositoryScript.new().get_active()


func get_active_candidate() -> Dictionary:
	return RepositoryScript.new().get_active_candidate()


func ensure_embedded_starter() -> Dictionary:
	return _ensure_embedded_starter(true)


func recover_to_embedded_starter() -> Dictionary:
	# Startup trust recovery is intentionally stronger than normal bootstrap.
	# A persisted Store character can still exist on disk after it has been
	# unpublished, revoked, or otherwise rejected by native verification. In
	# that case we must replace the stale active selection with the trusted
	# embedded Bible instead of surfacing the procedural emergency mock.
	return _ensure_embedded_starter(false)


func _ensure_embedded_starter(preserve_existing_active: bool) -> Dictionary:
	# Normal first-run bootstrap never replaces a valid user selection. Trust
	# recovery explicitly opts out of that preservation so a stale/revoked
	# package can self-heal back to the embedded starter.
	var active: Dictionary = get_active_candidate()
	if preserve_existing_active and not active.is_empty():
		return {
			"ok": true,
			"status": "active-preserved",
			"packageId": str(active.get("packageId", "")),
			"version": str(active.get("version", "")),
		}

	var installed: Dictionary = RepositoryScript.new().find_exact(
		EMBEDDED_STARTER_ID,
		EMBEDDED_STARTER_VERSION
	)
	if not installed.is_empty():
		if activate(EMBEDDED_STARTER_ID, EMBEDDED_STARTER_VERSION, false):
			return {
				"ok": true,
				"status": "activated-existing",
				"packageId": EMBEDDED_STARTER_ID,
				"version": EMBEDDED_STARTER_VERSION,
			}
		return {"ok": false, "error": "Embedded Bible is installed but could not be activated"}

	var package_path := _embedded_starter_path()
	if package_path.is_empty():
		return {"ok": false, "error": "Embedded Bible package is unavailable"}

	var result: Dictionary = _install_expected_embedded_starter(package_path)
	if not bool(result.get("ok", false)):
		return result
	if not activate(EMBEDDED_STARTER_ID, EMBEDDED_STARTER_VERSION, false):
		return {"ok": false, "error": "Embedded Bible installed but could not be activated"}
	result["status"] = "installed-and-activated"
	return result


func _embedded_starter_path() -> String:
	var explicit_path := OS.get_environment(EMBEDDED_STARTER_ENV).strip_edges()
	if not explicit_path.is_empty():
		var resolved_explicit := ProjectSettings.globalize_path(explicit_path)
		if FileAccess.file_exists(resolved_explicit):
			return resolved_explicit

	var executable_dir := OS.get_executable_path().get_base_dir()
	var bundled_path := executable_dir.path_join("starter").path_join(EMBEDDED_STARTER_FILENAME)
	if FileAccess.file_exists(bundled_path):
		return bundled_path
	return ""


func _install_expected_embedded_starter(path: String) -> Dictionary:
	var reader = ReaderScript.new()
	var read_result = reader.read(path)
	if not read_result.ok:
		return {"ok": false, "error": str(read_result.error_message)}

	var validation = ValidatorScript.new().validate(read_result)
	if not validation.ok:
		if read_result.zip:
			read_result.zip.close()
		return {"ok": false, "error": str(validation.error_message)}

	var manifest: Dictionary = read_result.manifest
	var package_id := str(manifest.get("packageId", manifest.get("id", ""))).strip_edges()
	var version := str(manifest.get("version", "")).strip_edges()
	if package_id != EMBEDDED_STARTER_ID or version != EMBEDDED_STARTER_VERSION:
		if read_result.zip:
			read_result.zip.close()
		return {
			"ok": false,
			"error": "Embedded starter identity mismatch: %s@%s" % [package_id, version],
		}

	var install_result = InstallerScript.new().install(read_result)
	if read_result.zip:
		read_result.zip.close()
	if not install_result.ok:
		return {"ok": false, "error": str(install_result.error_message)}

	return {
		"ok": true,
		"packageId": install_result.package_id,
		"version": install_result.version,
		"path": install_result.installed_path,
	}


static func _activation_already_live(
	persisted_candidate: Dictionary,
	runtime_package: Dictionary,
	package_id: String,
	version: String
) -> bool:
	return str(persisted_candidate.get("packageId", "")) == package_id 		and str(persisted_candidate.get("version", "")) == version 		and str(runtime_package.get("active_id", "")) == package_id 		and str(runtime_package.get("active_version", "")) == version


func activate(package_id: String, version: String, publish_change: bool = true) -> bool:
	var exact: Dictionary = RepositoryScript.new().find_exact(package_id, version)
	if exact.is_empty():
		return false
	var current := RepositoryScript.new().get_active_candidate()
	var persisted_same := str(current.get("packageId", "")) == package_id 		and str(current.get("version", "")) == version
	var runtime_same := str(context.package.get("active_id", "")) == package_id 		and str(context.package.get("active_version", "")) == version
	if _activation_already_live(current, context.package, package_id, version):
		# Truly idempotent only when both persisted selection and the live Runtime
		# agree. CharacterPackageInstaller.install() persists the newly installed
		# package identity before PackageService activates it; treating that disk
		# pointer alone as "already active" skipped context update + character.changed
		# and left the old companion (for example Sabai) alive on screen.
		return true

	if not persisted_same:
		InstallerScript.new().set_active(package_id, version)
	context.update_package({
		"active_id": package_id,
		"active_version": version,
		"installed_path": exact.get("path", ""),
		"manifest": exact.get("manifest", {}),
	})
	if publish_change:
		print("[PackageService] activated %s@%s persisted_same=%s runtime_was_same=%s" % [
			package_id,
			version,
			str(persisted_same).to_lower(),
			str(runtime_same).to_lower(),
		])
		event_bus.publish(&"character.changed", exact)
	return true


func install(path: String) -> Dictionary:
	var reader = ReaderScript.new()
	var read_result = reader.read(path)
	if not read_result.ok:
		return {"ok": false, "error": str(read_result.error_message)}

	var validation = ValidatorScript.new().validate(read_result)
	if not validation.ok:
		if read_result.zip:
			read_result.zip.close()
		return {"ok": false, "error": str(validation.error_message)}

	var result = InstallerScript.new().install(read_result)
	if read_result.zip:
		read_result.zip.close()

	if not result.ok:
		return {"ok": false, "error": str(result.error_message)}

	return {
		"ok": true,
		"packageId": result.package_id,
		"version": result.version,
		"path": result.installed_path,
	}


func uninstall(package_id: String, version: String) -> bool:
	# Never derive a delete target directly from an event payload. Resolve the
	# exact installed package first so malformed/native events cannot escape the
	# character repository root.
	if package_id.is_empty() or version.is_empty():
		return false
	if RepositoryScript.new().find_exact(package_id, version).is_empty():
		return false
	return RepositoryScript.new().uninstall(package_id, version)


func _on_activate_requested(payload: Dictionary) -> void:
	# activate() publishes character.changed. RuntimeApp is the single owner that
	# translates that state change into one character reload.
	activate(str(payload.get("package_id", "")), str(payload.get("version", "")))


func _on_uninstall_requested(payload: Dictionary) -> void:
	var package_id: String = str(payload.get("package_id", ""))
	var version: String = str(payload.get("version", ""))
	var request_id: String = str(payload.get("request_id", ""))
	var active_before: Dictionary = get_active()
	var target_was_active: bool = active_before.get("packageId", "") == package_id \
		and active_before.get("version", "") == version
	var fallback: Dictionary = {}

	# Windows cannot reliably remove a package while Runtime still presents that
	# package. Switch to another verified installed character first so sprite/SFX
	# resources are released before Repository deletes the target directory.
	if target_was_active:
		for candidate_value in list_installed():
			if not candidate_value is Dictionary:
				continue
			var candidate := candidate_value as Dictionary
			if str(candidate.get("packageId", "")) == package_id and str(candidate.get("version", "")) == version:
				continue
			fallback = candidate
			break
		if fallback.is_empty():
			event_bus.publish(&"character.uninstall_result", {"request_id": request_id, "package_id": package_id, "version": version, "ok": false, "error_code": "last-active-character"})
			event_bus.publish(&"notification.requested", {"text": "Install or activate another character before uninstalling the last active character."})
			return
		if not activate(str(fallback.get("packageId", "")), str(fallback.get("version", ""))):
			event_bus.publish(&"character.uninstall_result", {"request_id": request_id, "package_id": package_id, "version": version, "ok": false, "error_code": "fallback-activation-failed"})
			event_bus.publish(&"notification.requested", {"text": "Unable to switch characters before uninstalling %s@%s" % [package_id, version]})
			return

	if not uninstall(package_id, version):
		# Best-effort restore of the user's previous active character when deletion
		# failed after the protective pre-switch.
		if target_was_active:
			activate(package_id, version)
		event_bus.publish(&"character.uninstall_result", {"request_id": request_id, "package_id": package_id, "version": version, "ok": false, "error_code": "delete-failed"})
		event_bus.publish(&"notification.requested", {"text": "Unable to uninstall %s@%s" % [package_id, version]})
		return

	event_bus.publish(&"character.uninstalled", {"package_id": package_id, "version": version})
	event_bus.publish(&"character.uninstall_result", {"request_id": request_id, "package_id": package_id, "version": version, "ok": true, "error_code": ""})
	event_bus.publish(&"notification.requested", {"text": "Uninstalled %s@%s" % [package_id, version]})


func _on_install_requested(payload: Dictionary) -> void:
	var path: String = str(payload.get("path", ""))
	if path.is_empty():
		event_bus.publish(&"package.install_failed", {"error": "No package path selected"})
		return

	var result: Dictionary = install(path)
	if not bool(result.get("ok", false)):
		event_bus.publish(&"package.install_failed", result)
		return

	var package_id: String = str(result.get("packageId", ""))
	var version: String = str(result.get("version", ""))
	activate(package_id, version)
	event_bus.publish(&"package.installed", result)
