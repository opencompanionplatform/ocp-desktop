extends SceneTree

const CharacterServiceScript = preload("res://scripts/runtime_v3/services/character_service.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var bus := EventBusScript.new()
	var service := CharacterServiceScript.new()
	holder.add_child(bus)
	holder.add_child(service)
	service.configure(null, bus)

	var root := ProjectSettings.globalize_path("user://character-lazy-loading-smoke")
	DirAccess.make_dir_recursive_absolute(root)
	var names := ["idle", "appear", "walk_left", "walk_right", "happy", "sad", "wave"]
	var sprites: Array = []
	var animations: Dictionary = {}
	for index in range(names.size()):
		var name: String = names[index]
		var image := Image.create(1024, 512, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.08 + index * 0.07, 0.35, 0.72, 1.0))
		var path := root.path_join(name + ".webp")
		var save_error := image.save_webp(path, false, 0.92)
		if save_error != OK:
			print("[CharacterLazyLoading] save-webp-failed name=", name, " error=", save_error)
			holder.free()
			quit(1)
			return
		sprites.append({"id": name, "path": name + ".webp", "frameSize": [512, 512]})
		animations[name] = {
			"sprite": name,
			"frames": [0, 1],
			"fps": 8.0,
			"loop": name not in ["appear"],
		}

	var entry := {
		"schema": "character/3",
		"sprites": sprites,
		"animations": animations,
		"animationFallbacks": {"idle_neutral": "idle"},
		"presentation": {
			"animationThumbnails": {
				"idle": {"path": "thumbnails/idle.png"},
				"wave": {"path": "thumbnails/wave.png"},
			}
		},
	}
	DirAccess.make_dir_recursive_absolute(root.path_join("thumbnails"))
	var thumbnail_image := Image.create(112, 112, false, Image.FORMAT_RGBA8)
	thumbnail_image.fill(Color("27c7ff"))
	thumbnail_image.save_png(root.path_join("thumbnails/idle.png"))
	thumbnail_image.fill(Color("ff6bb5"))
	thumbnail_image.save_png(root.path_join("thumbnails/wave.png"))
	var idle_thumbnail_bytes := FileAccess.get_file_as_bytes(root.path_join("thumbnails/idle.png"))
	var entry_file := FileAccess.open(root.path_join("character.json"), FileAccess.WRITE)
	entry_file.store_string(JSON.stringify(entry))
	entry_file.close()
	# Public character loading always crosses the installed-package verification
	# boundary, even for this unsigned local fixture. Keep the fixture layout
	# realistic instead of bypassing production trust checks.
	var manifest_file := FileAccess.open(root.path_join("manifest.json"), FileAccess.WRITE)
	manifest_file.store_string(JSON.stringify({"entry": "character.json"}))
	manifest_file.close()
	var package_info := {"path": root, "manifest": {"entry": "character.json"}}
	var thumbnail_result: Dictionary = service.load_animation_thumbnail_png_bytes(package_info, ["idle", "wave", "happy"])
	var thumbnail_values: Dictionary = thumbnail_result.get("thumbnails", {})
	var embedded_thumbnails_ok: bool = bool(thumbnail_result.get("ok", false)) \
		and thumbnail_values.has("idle") and thumbnail_values.has("wave") \
		and not thumbnail_values.has("happy") \
		and thumbnail_values.get("idle", PackedByteArray()) == idle_thumbnail_bytes
	var preview_metadata: Dictionary = service.load_preview_metadata(package_info)
	var metadata_animations_value: Variant = preview_metadata.get("animations", [])
	var metadata_animations: Array = metadata_animations_value if metadata_animations_value is Array else []
	var metadata_loops_value: Variant = preview_metadata.get("loops", {})
	var metadata_loops: Dictionary = metadata_loops_value if metadata_loops_value is Dictionary else {}
	var prepared_preview_value: Variant = preview_metadata.get("prepared_entry", {})
	var prepared_preview: Dictionary = prepared_preview_value if prepared_preview_value is Dictionary else {}
	var preview_metadata_ok := bool(preview_metadata.get("ok", false)) \
		and not prepared_preview.is_empty() \
		and metadata_animations.size() == names.size() + 1 \
		and metadata_animations.has("idle_neutral") \
		and str(preview_metadata.get("default_animation", "")) == "idle" \
		and bool(metadata_loops.get("idle", false)) \
		and not bool(metadata_loops.get("appear", true))
	var legacy_entry := entry.duplicate(true)
	legacy_entry.erase("presentation")
	entry_file = FileAccess.open(root.path_join("character.json"), FileAccess.WRITE)
	entry_file.store_string(JSON.stringify(legacy_entry))
	entry_file.close()
	var legacy_thumbnail_result: Dictionary = service.load_animation_thumbnail_png_bytes(package_info, ["idle"])
	var legacy_thumbnails_ok := bool(legacy_thumbnail_result.get("ok", false)) \
		and (legacy_thumbnail_result.get("thumbnails", {}) as Dictionary).is_empty()
	var isolated_preview_result: Dictionary = service.build_preview_animation_frames(package_info, "wave")
	var isolated_preview_frames := isolated_preview_result.get("frames") as SpriteFrames
	var isolated_preview_ok := bool(isolated_preview_result.get("ok", false)) \
		and isolated_preview_frames != null \
		and isolated_preview_frames.has_animation(&"wave") \
		and isolated_preview_frames.get_animation_names().size() == 1
	var encoded_preview_thread := Thread.new()
	var encoded_preview_start := encoded_preview_thread.start(
		Callable(service, "build_preview_animation_payload").bind(
			package_info.duplicate(true), "wave", prepared_preview.duplicate(true)
		),
		Thread.PRIORITY_LOW
	)
	while encoded_preview_start == OK and encoded_preview_thread.is_alive():
		await process_frame
	var encoded_preview_value: Variant = encoded_preview_thread.wait_to_finish() if encoded_preview_start == OK else {}
	var encoded_preview_result: Dictionary = encoded_preview_value if encoded_preview_value is Dictionary else {}
	var encoded_preview_frames_value: Variant = encoded_preview_result.get("encoded_frames", [])
	var encoded_preview_frames: Array = encoded_preview_frames_value if encoded_preview_frames_value is Array else []
	var encoded_preview_ok := encoded_preview_start == OK and bool(encoded_preview_result.get("ok", false)) \
		and str(encoded_preview_result.get("animation", "")) == "wave" \
		and encoded_preview_frames.size() == 2 \
		and encoded_preview_frames.all(func(value: Variant) -> bool: return not str(value).is_empty()) \
		and int(encoded_preview_result.get("frame_width", 0)) <= 512 \
		and int(encoded_preview_result.get("frame_height", 0)) <= 512 \
		and int(encoded_preview_result.get("encoded_bytes", 0)) <= 8 * 1024 * 1024
	# The second request must come from the persistent binary payload cache, not
	# repeat image decode/crop/PNG/base64 work. This is the P4 regression guard.
	var encoded_preview_cached: Dictionary = service.build_preview_animation_payload(
		package_info.duplicate(true), "wave", prepared_preview.duplicate(true)
	)
	var encoded_preview_cache_hit := bool(encoded_preview_cached.get("ok", false)) \
		and bool(encoded_preview_cached.get("cache_hit", false)) \
		and (encoded_preview_cached.get("encoded_frames", []) as Array).size() == 2
	var legacy_static_preview: Dictionary = service.build_preview_thumbnail(package_info)
	var legacy_static_preview_ok := bool(legacy_static_preview.get("ok", false)) \
		and legacy_static_preview.get("texture") is Texture2D \
		and str(legacy_static_preview.get("source", "")) == "idle-fallback"

	var initial := service.build_sprite_frames(root, entry, [&"idle", &"appear"])
	var initial_ok := initial != null \
		and initial.has_animation(&"idle") \
		and initial.has_animation(&"appear") \
		and not initial.has_animation(&"walk_left")

	service.lazy_package_root = root
	service.lazy_entry = entry.duplicate(true)
	service.lazy_animation_order.clear()
	service.lazy_animation_order.append(&"appear")
	var walk_loaded := service.ensure_animation_loaded(&"walk_left", initial) \
		and initial.has_animation(&"walk_left")
	service.trim_animation_cache(initial, &"walk_left")

	for animation_name in [&"happy", &"sad", &"wave", &"walk_right"]:
		if not service.ensure_animation_loaded(animation_name, initial):
			print("[CharacterLazyLoading] failed-to-load=", animation_name)
			holder.free()
			quit(1)
			return
		service.trim_animation_cache(initial, animation_name)

	var loaded_names := initial.get_animation_names()
	var cache_bounded := loaded_names.size() <= CharacterServiceScript.LAZY_ANIMATION_CACHE_LIMIT + 1
	var active_kept := initial.has_animation(&"walk_right")
	var idle_kept := initial.has_animation(&"idle")
	var declared := service._declared_animation_names(entry)
	var fallback_declared := declared.has("idle_neutral")
	var fallback_loaded := service.ensure_animation_loaded(&"idle_neutral", initial) \
		and initial.has_animation(&"idle_neutral")
	var predictive_prefetch_ok := service.prefetch_animation(
		&"happy",
		initial,
		&"walk_right",
		"contract:drag-release"
	) \
		and initial.has_animation(&"happy") \
		and initial.has_animation(&"walk_right") \
		and service.lazy_animation_order.size() <= CharacterServiceScript.LAZY_ANIMATION_CACHE_LIMIT

	# Model Drag Hold -> Drag Release -> predicted edge transition. The third
	# clip is warmed only after the release clip becomes active, allowing the
	# bounded two-entry cache to evict Hold instead of evicting Release.
	var transition_frames := service.build_sprite_frames(root, entry, [&"idle"])
	service.lazy_animation_order.clear()
	var transition_hold_ok := transition_frames != null \
		and service.prefetch_animation(&"walk_left", transition_frames, &"walk_left", "contract:hold")
	var transition_release_ok := transition_hold_ok \
		and service.prefetch_animation(&"happy", transition_frames, &"walk_left", "contract:release") \
		and transition_frames.has_animation(&"walk_left") \
		and transition_frames.has_animation(&"happy")
	var transition_edge_ok := transition_release_ok \
		and service.prefetch_animation(&"sad", transition_frames, &"happy", "contract:edge") \
		and not transition_frames.has_animation(&"walk_left") \
		and transition_frames.has_animation(&"happy") \
		and transition_frames.has_animation(&"sad") \
		and service.lazy_animation_order.size() <= CharacterServiceScript.LAZY_ANIMATION_CACHE_LIMIT
	var bounded_transition_chain_ok := transition_hold_ok and transition_release_ok and transition_edge_ok

	# Two logical animations backed by one sprite sheet must reuse the same
	# decoded/uploaded atlas. This prevents climb_ready -> climb_up from briefly
	# retaining two full 48 MB textures and paying the decode cost twice.
	var shared_image := Image.create(1024, 512, false, Image.FORMAT_RGBA8)
	shared_image.fill(Color("7ac7ff"))
	var shared_path := root.path_join("climb_shared.webp")
	var shared_save_ok := shared_image.save_webp(shared_path, false, 0.92) == OK
	var shared_entry := {
		"schema": "character/3",
		"sprites": [{"id": "climb_shared", "path": "climb_shared.webp", "frameSize": [512, 512]}],
		"animations": {
			"climb_ready": {"sprite": "climb_shared", "frames": [0], "fps": 8.0, "loop": false},
			"climb_up": {"sprite": "climb_shared", "frames": [0, 1], "fps": 8.0, "loop": true},
		},
	}
	var shared_frames := service.build_sprite_frames(root, shared_entry, [&"climb_ready"])
	var shared_atlas_reused := shared_save_ok and shared_frames != null \
		and shared_frames.has_animation(&"climb_ready") \
		and shared_frames.has_animation(&"climb_up")
	if shared_atlas_reused:
		var ready_texture := shared_frames.get_frame_texture(&"climb_ready", 0)
		var up_texture := shared_frames.get_frame_texture(&"climb_up", 0)
		shared_atlas_reused = ready_texture is AtlasTexture and up_texture is AtlasTexture \
			and (ready_texture as AtlasTexture).atlas == (up_texture as AtlasTexture).atlas
	service.lazy_entry = entry.duplicate(true)

	# Only managed immutable Store projections may reuse an in-memory trust snapshot.
	service.active_verified_package_info = {
		"packageId": "character.local-fixture",
		"version": "1.0.0",
		"_verification": {"ok": true, "managed": false},
	}
	var unmanaged_snapshot_rejected := service.get_active_verified_package_info("character.local-fixture", "1.0.0").is_empty()

	# Persistent preview payloads are Runtime-private, bounded, and keyed by a
	# verified immutable package identity. Probe the binary cache transport here
	# without weakening the unsigned fixture's trust classification.
	var cache_probe_key := "contract-%d" % Time.get_ticks_usec()
	var cache_probe_payload := {
		"ok": true, "animation": "wave", "loop": true, "fps": 8.0,
		"encoded_frames": ["AAAA"], "frame_width": 8, "frame_height": 8,
		"encoded_bytes": 4, "worker_ms": 1, "cache_hit": false,
	}
	service._store_preview_payload_cache(cache_probe_key, cache_probe_payload)
	var cache_probe_loaded := service._load_preview_payload_cache(cache_probe_key, "wave")
	var persistent_preview_cache_ok := bool(cache_probe_loaded.get("ok", false)) \
		and str(cache_probe_loaded.get("animation", "")) == "wave" \
		and (cache_probe_loaded.get("encoded_frames", []) as Array).size() == 1
	DirAccess.remove_absolute(ProjectSettings.globalize_path(service._preview_payload_cache_path(cache_probe_key)))
	var bible_profiles := service._runtime_visual_profiles(
		{"visualProfiles": {"hang": {"surfaceAnchor": [0.5, 0.18], "scale": 1.0}}},
		"character.bible", "1.0.0"
	)
	var bible_hang_profile: Dictionary = bible_profiles.get("hang", {})
	var bible_hang_anchor: Array = bible_hang_profile.get("surfaceAnchor", [])
	var bible_hang_anchor_ok := bible_hang_anchor.size() == 2 \
		and is_equal_approx(float(bible_hang_anchor[0]), 0.5) \
		and is_equal_approx(float(bible_hang_anchor[1]), 0.26)

	var ok := initial_ok and walk_loaded and cache_bounded and active_kept and idle_kept \
		and fallback_declared and fallback_loaded and predictive_prefetch_ok \
		and bounded_transition_chain_ok and embedded_thumbnails_ok and legacy_thumbnails_ok \
		and preview_metadata_ok and isolated_preview_ok and encoded_preview_ok and encoded_preview_cache_hit and legacy_static_preview_ok \
		and unmanaged_snapshot_rejected and persistent_preview_cache_ok and bible_hang_anchor_ok \
		and shared_atlas_reused
	print(
		"[CharacterLazyLoading] initial=", initial_ok,
		" walk=", walk_loaded,
		" cache_bounded=", cache_bounded,
		" loaded=", loaded_names,
		" fallback=", fallback_loaded,
		" transition_chain=", bounded_transition_chain_ok,
		" embedded_thumbnails=", embedded_thumbnails_ok,
		" legacy_no_preview=", legacy_thumbnails_ok,
		" metadata_only=", preview_metadata_ok,
		" isolated_preview=", isolated_preview_ok,
		" encoded_preview=", encoded_preview_ok,
		" encoded_preview_cache_hit=", encoded_preview_cache_hit,
		" legacy_static_preview=", legacy_static_preview_ok,
		" unmanaged_snapshot_rejected=", unmanaged_snapshot_rejected,
		" persistent_preview_cache=", persistent_preview_cache_ok,
		" bible_hang_anchor=", bible_hang_anchor_ok,
		" shared_atlas=", shared_atlas_reused
	)
	holder.free()
	await process_frame
	quit(0 if ok else 1)
