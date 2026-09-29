extends SceneTree

const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")


class FakeContext:
	extends Node
	var settings := {"update_channel": "beta"}
	var runtime_config := {}


class FakeBus:
	extends Node
	var published: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})
	func subscribe(_topic: StringName, _callback: Callable) -> void:
		pass
	func unsubscribe(_topic: StringName, _callback: Callable) -> void:
		pass


class FakeUpdate:
	extends Node
	var check_calls := 0
	var apply_calls := 0
	var state := "idle"
	var target_version := ""
	var check_ready := true
	var apply_ready := false
	func request_check() -> Dictionary:
		check_calls += 1
		state = "checking"
		target_version = ""
		return {"ok": true, "message": "raw updater detail must not cross", "pid": 123}
	func request_apply() -> Dictionary:
		apply_calls += 1
		if not apply_ready:
			return {"ok": false, "message": "No verified staged update is available", "pid": -1}
		state = "apply_requested"
		return {"ok": true, "message": "raw helper detail must not cross", "pid": 456}
	func can_apply() -> bool:
		return apply_ready
	func safe_status() -> Dictionary:
		return {
			"currentVersion": "0.1.0", "state": state, "targetVersion": target_version,
			"canCheck": check_ready, "canApply": apply_ready, "checkAvailabilityCode": "ready",
		}


class FakeServices:
	extends Node
	var update_service := FakeUpdate.new()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := FakeBus.new()
	var services := FakeServices.new()
	var adapter := AdapterScript.new()
	for node in [context, bus, services, adapter]:
		holder.add_child(node)
	services.add_child(services.update_service)
	adapter.configure(context, bus)
	adapter.bind_services(services)

	adapter._handle_command({"type": "control.update.check", "url": "https://must-not-cross.test"}, "check-invalid")
	var strict_check: bool = services.update_service.check_calls == 0 \
		and adapter.command_results.any(func(result: Dictionary) -> bool:
			return result.get("id", "") == "check-invalid" and result.get("status", "") == "failed"
	)

	adapter._handle_command({"type": "control.update.check"}, "check-1")
	var check_started: bool = services.update_service.check_calls == 1 \
		and not adapter.pending_update_check.is_empty() \
		and adapter.command_results.any(func(result: Dictionary) -> bool:
			return result.get("id", "") == "check-1" and result.get("status", "") == "accepted"
	)
	services.update_service.state = "staged"
	services.update_service.target_version = "0.2.0"
	services.update_service.apply_ready = true
	adapter._on_update_status_changed({
		"state": "staged", "version": "0.2.0", "message": "staged at C:\\private\\update.zip",
		"artifactPath": "C:\\private\\update.zip", "signingKey": "must-not-cross",
	})
	adapter._on_update_check_finished({
		"state": "staged", "version": "0.2.0", "message": "raw release URL must not cross",
		"artifactPath": "C:\\private\\update.zip",
	})
	var ready_projection: Dictionary = adapter._update_control_snapshot()
	var check_finished: bool = adapter.command_results.any(func(result: Dictionary) -> bool:
		return result.get("id", "") == "check-1" and result.get("status", "") == "succeeded"
	) and ready_projection.get("state", "") == "ready" \
		and ready_projection.get("targetVersion", "") == "0.2.0" \
		and bool(ready_projection.get("canApply", false)) \
		and ready_projection.get("messageCode", "") == "update-ready"
	var serialized_projection := JSON.stringify(ready_projection)
	var redacted: bool = not serialized_projection.contains("private") \
		and not serialized_projection.contains("artifact") \
		and not serialized_projection.contains("signing") \
		and not serialized_projection.contains("https://")

	services.update_service.apply_ready = false
	adapter._handle_command({"type": "control.update.apply"}, "apply-not-ready")
	var apply_revalidated: bool = services.update_service.apply_calls == 0 \
		and adapter.command_results.any(func(result: Dictionary) -> bool:
			return result.get("id", "") == "apply-not-ready" and result.get("status", "") == "failed" \
				and result.get("errorCode", "") == "update-not-ready"
	)

	services.update_service.apply_ready = true
	services.update_service.state = "staged"
	services.update_service.target_version = "0.2.0"
	adapter._set_update_state("staged", "0.2.0")
	adapter._handle_command({"type": "control.update.apply"}, "apply-1")
	await process_frame
	var apply_accepted: bool = services.update_service.apply_calls == 1 \
		and adapter.command_results.any(func(result: Dictionary) -> bool:
			return result.get("id", "") == "apply-1" and result.get("status", "") == "accepted"
	) \
		and not adapter.command_results.any(func(result: Dictionary) -> bool:
			return result.get("id", "") == "apply-1" and result.get("status", "") == "succeeded"
	) \
		and bus.published.any(func(entry: Dictionary) -> bool:
			return entry.get("topic", &"") == &"window.exit_requested" \
				and entry.get("payload", {}).get("source", "") == "electron-update-apply"
	)
	var applying_projection: Dictionary = adapter._update_control_snapshot()
	var applying_safe: bool = applying_projection.get("state", "") == "apply-requested" \
		and not bool(applying_projection.get("canApply", true)) \
		and applying_projection.get("messageCode", "") == "update-apply-requested"

	var ok: bool = strict_check and check_started and check_finished and redacted and apply_revalidated and apply_accepted and applying_safe
	print("[G16.13C] strict=", strict_check, " check=", check_started and check_finished, " redacted=", redacted, " revalidate=", apply_revalidated, " apply=", apply_accepted, " projection=", applying_safe, " ok=", ok)
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
