extends SceneTree

const CharacterServiceScript = preload("res://scripts/runtime_v3/services/character_service.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const LocalBehaviorCatalogScript = preload("res://scripts/runtime_v3/core/local_behavior_catalog.gd")

const PACKAGE_ID := "character.scifi-woman"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var package_root := _latest_installed_package_root()
	if package_root.is_empty():
		print("[Character3Coverage] FAIL package-not-installed id=", PACKAGE_ID)
		quit(1)
		return

	var manifest_path := package_root.path_join("manifest.json")
	var manifest_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest_value is Dictionary:
		print("[Character3Coverage] FAIL invalid-manifest path=", manifest_path)
		quit(1)
		return
	var manifest: Dictionary = manifest_value
	var entry_rel := str(manifest.get("entry", "assets/character.json"))
	var entry_path := package_root.path_join(entry_rel)
	var entry_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not entry_value is Dictionary:
		print("[Character3Coverage] FAIL invalid-entry path=", entry_path)
		quit(1)
		return
	var entry: Dictionary = entry_value
	var clips_value: Variant = entry.get("animations", {})
	var clips: Dictionary = clips_value if clips_value is Dictionary else {}

	var holder := Node.new()
	get_root().add_child(holder)
	var bus := EventBusScript.new()
	var service := CharacterServiceScript.new()
	var sprite := AnimatedSprite2D.new()
	holder.add_child(bus)
	holder.add_child(service)
	holder.add_child(sprite)
	service.configure(null, bus)

	var required: Array = LocalBehaviorCatalogScript.CHARACTER3_ANIMATIONS
	var declared_exact := clips.size() == required.size()
	var mapping_exact := LocalBehaviorCatalogScript.mapped_animation_names().size() == required.size()
	var passed := 0
	var failures: Array[String] = []

	for index in range(required.size()):
		var animation_name := str(required[index])
		var clip_value: Variant = clips.get(animation_name, {})
		var clip: Dictionary = clip_value if clip_value is Dictionary else {}
		var frames := service.build_sprite_frames(package_root, entry, [StringName(animation_name)])
		var exists := not clip.is_empty() and frames != null and frames.has_animation(StringName(animation_name))
		var frame_count := frames.get_frame_count(StringName(animation_name)) if exists else 0
		var fps := frames.get_animation_speed(StringName(animation_name)) if exists else 0.0
		var texture_ok := exists and frame_count > 0 and frames.get_frame_texture(StringName(animation_name), 0) is Texture2D
		var effective_loop := frames.get_animation_loop(StringName(animation_name)) if exists else false
		var expected_loop := false if animation_name == "climb_top" else bool(clip.get("loop", false))
		var loop_ok := exists and effective_loop == expected_loop
		var owner := LocalBehaviorCatalogScript.owner_for(animation_name)
		var mapped := owner != "unmapped"
		var playback_ok := false
		if exists:
			sprite.sprite_frames = frames
			sprite.play(StringName(animation_name))
			await process_frame
			playback_ok = sprite.animation == StringName(animation_name)
			sprite.stop()
			sprite.sprite_frames = null
		var ok := exists and frame_count > 0 and fps > 0.0 and texture_ok and loop_ok and mapped and playback_ok
		if ok:
			passed += 1
		else:
			failures.append(animation_name)
		print("[Character3Coverage] %02d/%02d %s name=%s frames=%d fps=%.1f loop=%s owner=%s" % [
			index + 1,
			required.size(),
			"PASS" if ok else "FAIL",
			animation_name,
			frame_count,
			fps,
			effective_loop,
			owner,
		])

	var all_required_declared := true
	for animation_name in required:
		if not clips.has(str(animation_name)):
			all_required_declared = false
			break
	var no_unmapped_declared := true
	for animation_name in clips.keys():
		if LocalBehaviorCatalogScript.owner_for(str(animation_name)) == "unmapped":
			no_unmapped_declared = false
			failures.append("unmapped:%s" % str(animation_name))

	var ok := passed == required.size() \
		and declared_exact \
		and mapping_exact \
		and all_required_declared \
		and no_unmapped_declared
	print("[Character3Coverage] RESULT passed=%d/%d declared=%d mapped=%d package=%s version=%s failures=%s" % [
		passed,
		required.size(),
		clips.size(),
		LocalBehaviorCatalogScript.mapped_animation_names().size(),
		PACKAGE_ID,
		str(manifest.get("version", entry.get("version", ""))),
		failures,
	])
	holder.free()
	await process_frame
	quit(0 if ok else 1)


func _latest_installed_package_root() -> String:
	var base := ProjectSettings.globalize_path("user://packages/characters/%s" % PACKAGE_ID)
	var directory := DirAccess.open(base)
	if directory == null:
		return ""
	var versions := PackedStringArray()
	for name in directory.get_directories():
		if FileAccess.file_exists(base.path_join(name).path_join("manifest.json")):
			versions.append(name)
	if versions.is_empty():
		return ""
	versions.sort()
	return base.path_join(versions[versions.size() - 1])
