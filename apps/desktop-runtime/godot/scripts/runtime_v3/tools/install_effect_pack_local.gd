extends SceneTree

const EffectPackServiceScript = preload("res://scripts/runtime_v3/services/effect_pack_service.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var package_path := OS.get_environment("OCP_EFFECT_PACK_LOCAL_PATH").strip_edges()
	if package_path.is_empty():
		push_error("[EFFECT-INSTALL] OCP_EFFECT_PACK_LOCAL_PATH is required")
		quit(2)
		return
	if not FileAccess.file_exists(package_path):
		push_error("[EFFECT-INSTALL] package not found: %s" % package_path)
		quit(3)
		return

	var service = EffectPackServiceScript.new()
	var installed: Dictionary = service.install(package_path)
	if not bool(installed.get("ok", false)):
		push_error("[EFFECT-INSTALL] install failed: %s" % str(installed.get("error", "unknown error")))
		quit(4)
		return

	var package_id := str(installed.get("packageId", ""))
	var version := str(installed.get("version", ""))
	var installed_path := str(installed.get("path", ""))
	# Local Creator testing is intentionally separate from the Cloud-managed
	# immutable install boundary. Preserve the signed manifest for inspection,
	# then use an unsigned projection so InstalledEffectPackRepository treats this
	# copy like the existing local/starter data-only packs. The source .ocp is
	# never modified.
	var manifest_path := installed_path.path_join("manifest.json")
	var manifest_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if manifest_value is Dictionary and (manifest_value as Dictionary).has("signature"):
		var signed_manifest := FileAccess.get_file_as_string(manifest_path)
		FileAccess.open(installed_path.path_join("manifest.signed.json"), FileAccess.WRITE).store_string(signed_manifest)
		var local_manifest := (manifest_value as Dictionary).duplicate(true)
		local_manifest.erase("signature")
		FileAccess.open(manifest_path, FileAccess.WRITE).store_string(JSON.stringify(local_manifest))
		print("[EFFECT-INSTALL] local-dev projection created; signed manifest preserved")
	if not service.equip(package_id, version, ""):
		push_error("[EFFECT-INSTALL] package installed but equip failed")
		quit(5)
		return
	for slot_name in ["bodyAura", "groundRune", "levelUpBurst"]:
		service.set_slot_enabled(slot_name, true)

	print("[EFFECT-INSTALL] ok package=%s version=%s path=%s" % [
		package_id,
		version,
		str(installed.get("path", "")),
	])
	print(JSON.stringify(service.snapshot()))
	quit(0)
