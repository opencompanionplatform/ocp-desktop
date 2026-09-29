extends SceneTree

const PackageServiceScript = preload("res://scripts/runtime_v3/services/package_service.gd")
const RepositoryScript = preload("res://scripts/runtime/packages/installed_character_repository.gd")

class FakeContext:
	extends Node
	var package: Dictionary = {}
	var package_state: Dictionary = {}
	func update_package(value: Dictionary) -> void:
		package = value.duplicate(true)
		package_state = value.duplicate(true)

class FakeBus:
	extends Node
	var events: Array[Dictionary] = []
	func publish(topic: StringName, payload: Dictionary) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)})

func _init() -> void:
	var starter_path := OS.get_environment("OCP_EMBEDDED_STARTER_PACKAGE").strip_edges()
	if starter_path.is_empty() or not FileAccess.file_exists(starter_path):
		push_error("embedded starter test requires OCP_EMBEDDED_STARTER_PACKAGE")
		quit(2)
		return

	var context := FakeContext.new()
	var bus := FakeBus.new()
	root.add_child(context)
	root.add_child(bus)
	var service = PackageServiceScript.new()
	root.add_child(service)
	service.configure(context, bus)

	var result: Dictionary = service.ensure_embedded_starter()
	if not bool(result.get("ok", false)):
		push_error("embedded starter install failed: %s" % str(result.get("error", "unknown")))
		quit(3)
		return

	var active: Dictionary = RepositoryScript.new().get_active_candidate()
	if str(active.get("packageId", "")) != "character.bible" or str(active.get("version", "")) != "1.0.0":
		push_error("embedded starter active identity mismatch: %s" % str(active))
		quit(4)
		return

	if bus.events.any(func(event: Dictionary) -> bool: return event.get("topic", &"") == &"character.changed"):
		push_error("bootstrap starter activation must not recursively publish character.changed")
		quit(5)
		return

	var second: Dictionary = service.ensure_embedded_starter()
	if not bool(second.get("ok", false)) or str(second.get("status", "")) != "active-preserved":
		push_error("embedded starter bootstrap is not idempotent: %s" % str(second))
		quit(6)
		return

	# Simulate a Store package that still exists on disk but is no longer trusted
	# or published. Startup recovery must replace its persisted selection with the
	# embedded Bible rather than falling through to the procedural emergency mock.
	var stale_id := "character.revoked-startup-test"
	var stale_version := "1.0.0"
	var stale_dir := "user://packages/characters/%s/%s" % [stale_id, stale_version]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(stale_dir))
	var state_file := FileAccess.open("user://runtime/state.json", FileAccess.WRITE)
	if state_file == null:
		push_error("could not write stale activeCharacter test state")
		quit(7)
		return
	state_file.store_string(JSON.stringify({
		"activeCharacter": {"packageId": stale_id, "version": stale_version},
	}, "\t"))
	state_file.close()
	var stale_active: Dictionary = service.get_active_candidate()
	if str(stale_active.get("packageId", "")) != stale_id:
		push_error("stale activeCharacter fixture was not resolved: %s" % str(stale_active))
		quit(8)
		return

	var recovered: Dictionary = service.recover_to_embedded_starter()
	var recovered_active: Dictionary = service.get_active_candidate()
	if not bool(recovered.get("ok", false)) \
	or str(recovered_active.get("packageId", "")) != "character.bible" \
	or str(recovered_active.get("version", "")) != "1.0.0":
		push_error("embedded starter trust recovery failed: result=%s active=%s" % [str(recovered), str(recovered_active)])
		quit(9)
		return
	if bus.events.any(func(event: Dictionary) -> bool: return event.get("topic", &"") == &"character.changed"):
		push_error("startup trust recovery must not recursively publish character.changed")
		quit(10)
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(stale_dir))

	print("[EMBEDDED-STARTER] PASS package=character.bible@1.0.0 first=%s second=%s recovery=%s" % [
		str(result.get("status", "")),
		str(second.get("status", "")),
		str(recovered.get("status", "")),
	])
	quit(0)
