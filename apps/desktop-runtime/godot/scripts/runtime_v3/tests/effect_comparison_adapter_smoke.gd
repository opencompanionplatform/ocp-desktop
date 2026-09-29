extends SceneTree
const Adapter = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")
const Context = preload("res://scripts/runtime_v3/core/runtime_context.gd")

class Sources extends "res://scripts/runtime_v3/services/effect_pack_service.gd":
	var items: Array = []
	var writes := 0
	func list_installed() -> Array:
		return items
	func _write_state(_state: Dictionary) -> bool:
		writes += 1
		return false
	func resolve_slot_for_preview(_slot: String, _include_disabled: bool = false, _character_id: String = "") -> Dictionary:
		return {}

class Services extends Node:
	var effect_pack_service: Node

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var folder := "user://comparison-fixture"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var sheet := Image.create(128, 96, false, Image.FORMAT_RGBA8)
	for frame in range(48):
		sheet.fill_rect(Rect2i((frame % 8) * 16, (frame / 8) * 16, 16, 16), Color.WHITE if frame % 2 == 0 else Color(1, 1, 1, 0.1))
	sheet.save_png(folder.path_join("atlas.png"))
	var video_slots := {}
	var mist_slots := {}
	for slot in ["bodyAura", "groundRune", "levelUpBurst"]:
		video_slots[slot] = {"renderer": "sprite-sheet-2d", "asset": "atlas.png", "frameWidth": 16, "frameHeight": 16, "frameCount": 48, "fps": 12, "looped": slot != "levelUpBurst", "zIndex": -20, "scale": 1.2}
		mist_slots[slot] = {"renderer": "procedural-rings-v1", "tint": "#38BDF8", "intensity": 90, "durationMs": 1400}
	var sources := Sources.new()
	sources.items = [
		{"packageId": "effect.video-neon", "version": "1.0.0", "path": folder, "entry": {"slots": video_slots}},
		{"packageId": "effect.starter-neon", "version": "1.0.0", "path": folder, "entry": {"slots": mist_slots}},
	]
	var character := Image.create(80, 160, false, Image.FORMAT_RGBA8)
	character.fill(Color.WHITE)
	var output_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output_dir = arg.trim_prefix("--output=")
		if arg.begins_with("--character="):
			character.load(arg.trim_prefix("--character="))
		if arg.begins_with("--effects="):
			var installed := arg.trim_prefix("--effects=")
			for item in sources.items:
				item.path = installed.path_join(item.packageId).path_join("1.0.0")
				item.entry = JSON.parse_string(FileAccess.get_file_as_string(item.path.path_join("assets/effect.json")))
	root.add_child(sources)
	var services := Services.new()
	services.effect_pack_service = sources
	root.add_child(services)
	var adapter := Adapter.new()
	root.add_child(adapter)
	adapter.services = services
	var context := Context.new()
	root.add_child(context)
	adapter.context = context
	adapter.preview_state = adapter._idle_preview_state()
	adapter.preview_state.merge({"packageId": "character.comparison", "version": "1.0.0", "selectedAnimation": "idle", "status": "ready"}, true)
	var encoded := Marshalls.raw_to_base64(character.save_png_to_buffer())
	adapter.preview_active_payload = {"animation": "idle", "encoded_frames": [encoded], "frame_width": character.get_width(), "frame_height": character.get_height(), "fps": 12.0}
	var frames := {}
	var passed := true
	for variant in ["video-original", "video-blend", "starter-mist"]:
		var result := adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "bodyAura", "variant": variant})
		passed = passed and result.status == "succeeded"
		adapter.effect_preview_elapsed = 0.04
		var rendered := adapter._compose_effect_preview_frame(encoded)
		frames[variant] = rendered.encoded
		if not output_dir.is_empty():
			var image := Image.new()
			image.load_png_from_buffer(Marshalls.base64_to_raw(rendered.encoded))
			image.save_png(output_dir.path_join("comparison-%s.png" % variant))
	passed = passed and frames["video-original"] != frames["video-blend"] and frames["video-blend"] != frames["starter-mist"]
	adapter.effect_preview_elapsed = 1.04
	passed = passed and frames["starter-mist"] != adapter._compose_effect_preview_frame(encoded).encoded
	context.settings["reduce_motion"] = true
	adapter._update_effect_preview(0.5)
	passed = passed and is_equal_approx(adapter.effect_preview_elapsed, 1.04)
	context.settings["reduce_motion"] = false
	adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "levelUpBurst", "variant": "video-blend"})
	adapter.effect_preview_elapsed = 4.1
	passed = passed and adapter._effect_preview_layer("levelUpBurst", Rect2(100, 100, 80, 160), Vector2(384, 384), 1.0).is_empty()
	var invalid := adapter._preview_effect_pack({"type": "effect-pack.preview", "variant": "unknown"})
	passed = passed and invalid.status == "failed"
	adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "off"})
	passed = passed and not is_instance_valid(adapter.effect_comparison_renderer) and adapter.effect_comparison_sources.is_empty() and sources.writes == 0
	adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "bodyAura", "variant": "starter-mist"})
	adapter._close_preview()
	passed = passed and adapter.effect_preview_variant == "equipped" and not is_instance_valid(adapter.effect_comparison_renderer)
	sources.items.clear()
	adapter.preview_active_payload = {"animation": "idle"}
	passed = passed and adapter._preview_effect_pack({"type": "effect-pack.preview", "mode": "bodyAura", "variant": "video-original"}).errorCode == "effect-comparison-source-unavailable"
	print("[EffectComparisonAdapter] three_images, moving_mist, reduced_motion, burst_once, invalid, stop, close, no_writes, missing_source: ", passed)
	adapter.free()
	services.free()
	sources.free()
	context.free()
	quit(0 if passed else 1)
