extends SceneTree

const UpdateServiceScript = preload("res://scripts/runtime_v3/services/update_service.gd")


class FakeBus:
	extends Node
	var published: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root := ProjectSettings.globalize_path("user://g16-13c-update-service-smoke")
	var status_path := root.path_join("status.json")
	var updater_path := root.path_join("ocp-release-check.exe")
	var artifact_path := root.path_join("verified-update.zip")
	DirAccess.make_dir_recursive_absolute(root)
	_write_text(updater_path, "test updater")
	_write_text(artifact_path, "verified fixture")

	var names := ["OCP_UPDATE_MANIFEST_URL", "OCP_UPDATE_KEY_ID", "OCP_UPDATE_PUBLIC_KEY_B64", "OCP_UPDATER_EXE", "OCP_UPDATE_STATUS_FILE", "OCP_UPDATE_AUTOMATIC_CHECKS"]
	var previous := {}
	for name in names:
		previous[name] = OS.get_environment(name)
	OS.set_environment("OCP_UPDATE_MANIFEST_URL", "https://updates.example.test/manifest.json")
	OS.set_environment("OCP_UPDATE_KEY_ID", "test-key")
	OS.set_environment("OCP_UPDATE_PUBLIC_KEY_B64", "test-public-key")
	OS.set_environment("OCP_UPDATER_EXE", updater_path)
	OS.set_environment("OCP_UPDATE_STATUS_FILE", status_path)
	OS.set_environment("OCP_UPDATE_AUTOMATIC_CHECKS", "true")

	var holder := Node.new()
	get_root().add_child(holder)
	var context := Node.new()
	var bus := FakeBus.new()
	var service := UpdateServiceScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	service.configure(context, bus)
	service.start()
	_write_text(status_path, JSON.stringify({
		"state": "staged", "message": "verified at C:\\private\\must-not-project.zip",
		"version": "0.2.0", "artifactPath": artifact_path,
	}))
	service._process(0.0)
	var staged: Dictionary = service.safe_status()
	var staged_ok: bool = staged.get("state", "") == "staged" \
		and staged.get("targetVersion", "") == "0.2.0" \
		and bool(staged.get("canCheck", false)) \
		and bool(staged.get("canApply", false)) \
		and bool(staged.get("automaticChecksEnabled", false)) \
		and int(staged.get("nextAutomaticCheckSeconds", 0)) > 0 \
		and UpdateServiceScript.AUTO_CHECK_START_DELAY_SECONDS >= 30.0 \
		and UpdateServiceScript.AUTO_CHECK_INTERVAL_SECONDS >= 3600.0 \
		and not JSON.stringify(staged).contains("private") \
		and not JSON.stringify(staged).contains("artifactPath")

	# A background check must never replace a verified staged update.
	var staged_event_count := bus.published.size()
	service._next_automatic_check_msec = Time.get_ticks_msec()
	service._maybe_run_automatic_check()
	var staged_suppresses_auto_check: bool = bus.published.size() == staged_event_count \
		and service._next_automatic_check_msec == 0 \
		and bool(service.can_apply())

	_write_text(status_path, JSON.stringify({
		"state": "rolled_back", "message": "raw rollback exception and path must remain internal",
		"version": "0.1.0", "previousVersion": "0.2.0",
	}))
	service._process(0.0)
	var rolled_back: Dictionary = service.safe_status()
	var rollback_ok: bool = rolled_back.get("state", "") == "rolled_back" \
		and not bool(rolled_back.get("canApply", true)) \
		and not JSON.stringify(rolled_back).contains("exception")

	# When due and no staged update exists, automatic checks must enter the same
	# signed updater path and identify their source as automatic. `cmd.exe` is a
	# short-lived executable fixture; the contract only needs OS.create_process
	# to accept the spawn so no network or install mutation occurs.
	var comspec := OS.get_environment("ComSpec")
	OS.set_environment("OCP_UPDATER_EXE", comspec)
	service._last_state = "idle"
	service._check_in_flight = false
	service._next_automatic_check_msec = Time.get_ticks_msec()
	var auto_event_start := bus.published.size()
	service._maybe_run_automatic_check()
	var automatic_started := false
	for index in range(auto_event_start, bus.published.size()):
		var event := bus.published[index]
		if event.get("topic") == &"update.check_started" \
		and str((event.get("payload", {}) as Dictionary).get("source", "")) == "automatic":
			automatic_started = true
			break
	var automatic_scheduler_ok: bool = not comspec.is_empty() \
		and automatic_started \
		and service._last_state == "checking" \
		and service._check_in_flight

	service.stop()
	holder.queue_free()
	for name in names:
		OS.set_environment(name, str(previous[name]))
	for path in [status_path, updater_path, artifact_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(root)
	var ok: bool = staged_ok and staged_suppresses_auto_check and rollback_ok and automatic_scheduler_ok
	print("[G16.13C-SERVICE] staged=", staged_ok, " staged_auto_block=", staged_suppresses_auto_check, " rollback=", rollback_ok, " automatic=", automatic_scheduler_ok, " ok=", ok)
	await process_frame
	quit(0 if ok else 1)


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(content)
		file.close()
