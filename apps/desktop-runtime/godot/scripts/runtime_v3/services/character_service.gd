extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3CharacterService
## Character-domain service. Controllers never read package files.

const LAZY_ANIMATION_CACHE_LIMIT := 2
const PackageVerification = preload("res://scripts/runtime/packages/installed_package_verification.gd")
const MAX_ANIMATION_THUMBNAIL_DIMENSION := 256
const MAX_ANIMATION_THUMBNAIL_PNG_BYTES := 49_152
const PREVIEW_PAYLOAD_CACHE_VERSION := 2
const PREVIEW_PAYLOAD_CACHE_DIR := "user://cache/preview-payload-v2"
const PREVIEW_PAYLOAD_DISK_CACHE_BYTES := 128 * 1024 * 1024
const MAX_PREVIEW_CACHE_FILE_BYTES := 12 * 1024 * 1024
const BIBLE_CHARACTER_ID := "character.bible"
const BIBLE_100_VERSION := "1.0.0"
const BIBLE_100_HANG_SURFACE_ANCHOR := [0.5, 0.26]
var lazy_package_root: String = ""
var lazy_entry: Dictionary = {}
var lazy_asset_hashes: Dictionary = {}
var lazy_managed := false
var lazy_animation_order: Array[StringName] = []
# Runtime-internal trust snapshot for the currently active package. Managed Store
# packages are immutable after installation, so preview/library code may reuse
# this snapshot during the same Runtime session instead of repeating native
# archive/signature/projection verification. It is never projected to Electron.
var active_verified_package_info: Dictionary = {}

func load_active_character(package_info: Dictionary) -> Dictionary:
	# A new activation/load attempt invalidates the prior in-memory trust snapshot
	# until the candidate passes native verification successfully.
	active_verified_package_info.clear()
	var load_started := Time.get_ticks_msec()
	var package_root: String = str(package_info.get("path", ""))
	var verify_started := Time.get_ticks_msec()
	var verification := PackageVerification.verify(package_root)
	var verify_ms := Time.get_ticks_msec() - verify_started
	if not bool(verification.get("ok", false)):
		return _failure(str(verification.get("error", "Package verification failed")))
	event_bus.publish(&"character.loading", package_info)

	var managed := bool(verification.get("managed", false))
	var manifest: Dictionary = package_info.get("manifest", {}) if package_info.get("manifest", {}) is Dictionary else {}
	var entry: Dictionary = {}
	var asset_hashes: Dictionary = {}
	if managed:
		var trusted_manifest: Variant = JSON.parse_string(str(verification.get("manifest_json", "")))
		var trusted_entry: Variant = JSON.parse_string(str(verification.get("entry_json", "")))
		if not trusted_manifest is Dictionary or not trusted_entry is Dictionary:
			return _failure("managed character verification snapshot is incomplete")
		manifest = trusted_manifest
		entry = trusted_entry
		asset_hashes = _asset_hashes_from_manifest(manifest)
	else:
		var entry_rel: String = str(manifest.get("entry", ""))
		if entry_rel.is_empty() and not package_root.is_empty():
			if FileAccess.file_exists(package_root.path_join("character.json")):
				entry_rel = "character.json"
		if package_root.is_empty() or entry_rel.is_empty():
			return _failure("active character package has no entry")
		var entry_path: String = package_root.path_join(entry_rel)
		if not FileAccess.file_exists(entry_path):
			return _failure("character entry not found: " + entry_path)
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
		if not parsed is Dictionary:
			return _failure("invalid character entry JSON")
		entry = parsed

	var animation_names: PackedStringArray = _declared_animation_names(entry)
	var initial_names: Array[StringName] = []
	for preferred in [&"idle", &"idle_neutral", &"appear"]:
		if animation_names.has(str(preferred)):
			initial_names.append(preferred)
	if initial_names.is_empty() and not animation_names.is_empty():
		initial_names.append(animation_names[0])
	var frames_started := Time.get_ticks_msec()
	var frames: SpriteFrames = _build_sprite_frames_after_verification(
		package_root,
		entry,
		initial_names,
		managed,
		asset_hashes
	)
	var frames_ms := Time.get_ticks_msec() - frames_started
	if frames == null:
		return _failure("could not build initial lazy SpriteFrames")

	lazy_package_root = package_root
	lazy_entry = entry.duplicate(true)
	lazy_asset_hashes = asset_hashes.duplicate(true)
	lazy_managed = managed
	lazy_animation_order.clear()
	for initial_name in initial_names:
		if initial_name not in [&"idle", &"idle_neutral"]:
			lazy_animation_order.append(initial_name)

	var runtime_meta: Dictionary = entry.get("runtime", {})
	if managed:
		active_verified_package_info = {
			"packageId": str(package_info.get("packageId", entry.get("id", ""))),
			"version": str(package_info.get("version", manifest.get("version", entry.get("version", "")))),
			"path": package_root,
			"manifest": manifest.duplicate(true),
			"_verification": verification.duplicate(true),
		}

	context.update_character({
		"id": str(entry.get("id", manifest.get("packageId", manifest.get("id", "")))),
		"name": str(entry.get("name", manifest.get("name", "Character"))),
		"version": str(manifest.get("version", entry.get("version", ""))),
		"scale": float(runtime_meta.get("scale", 0.6)),
		"render_size": _vector2i_from(runtime_meta.get("renderSize", [256, 256]), Vector2i(256, 256)),
		"visual_profiles": _runtime_visual_profiles(
			entry,
			str(entry.get("id", manifest.get("packageId", manifest.get("id", "")))),
			str(manifest.get("version", entry.get("version", "")))
		),
		"presentation": entry.get("presentation", {}),
		"soul_profile": _soul_profile_from_package(package_root, entry),
		"voice_profile": _voice_profile_from_entry(entry),
		"audio_profile": entry.get("audioProfile", {"clips": [], "bindings": {}}),
		"effects_profile": entry.get("effectsProfile", {"effects": [], "bindings": {}, "teleport": {}}),
		"bubble_anchor": _vector2_from(runtime_meta.get("bubbleAnchor", [0, -176]), Vector2(0, -176)),
		"hitbox": _rect2_from(runtime_meta.get("hitbox", [44, 40, 220, 248]), Rect2(44, 40, 220, 248)),
		"animations": animation_names,
	})
	context.update_package({
		"active_id": str(package_info.get("packageId", entry.get("id", ""))),
		"active_version": str(package_info.get("version", manifest.get("version", entry.get("version", "")))),
		"installed_path": package_root,
		"manifest": manifest,
		"entry": entry,
		"lazy_animation_loading": true,
	})

	var result := {
		"ok": true,
		"entry": entry,
		"package_root": package_root,
		"frames": frames,
	}
	print("[CharacterLoadTiming] package=%s verify_ms=%d frames_ms=%d total_ms=%d managed=%s" % [
		str(package_info.get("packageId", "-")),
		verify_ms,
		frames_ms,
		Time.get_ticks_msec() - load_started,
		managed,
	])
	event_bus.publish(&"character.loaded", result)
	return result


func get_active_verified_package_info(package_id: String = "", version: String = "") -> Dictionary:
	if active_verified_package_info.is_empty():
		return {}
	var verification_value: Variant = active_verified_package_info.get("_verification", {})
	var verification: Dictionary = verification_value if verification_value is Dictionary else {}
	if not bool(verification.get("ok", false)) or not bool(verification.get("managed", false)):
		return {}
	if not package_id.is_empty() and str(active_verified_package_info.get("packageId", "")) != package_id:
		return {}
	if not version.is_empty() and str(active_verified_package_info.get("version", "")) != version:
		return {}
	return active_verified_package_info.duplicate(true)


## Loads the dedicated Character/3 preview asset without constructing any sprite
## sheets. This is the cheap path used by Character Library / Store cards. Older
## Character/1-2 packages fall back to the first idle frame.
func build_preview_thumbnail(package_info: Dictionary) -> Dictionary:
	var verification_value: Variant = package_info.get("_verification", {})
	var verification: Dictionary = verification_value if verification_value is Dictionary else {}
	if not bool(verification.get("ok", false)):
		verification = PackageVerification.verify(str(package_info.get("path", "")))
	if not bool(verification.get("ok", false)):
		return verification
	var package_root: String = str(package_info.get("path", ""))
	var managed := bool(verification.get("managed", false))
	var manifest: Dictionary = package_info.get("manifest", {}) if package_info.get("manifest", {}) is Dictionary else {}
	var parsed: Dictionary = {}
	var asset_hashes: Dictionary = {}
	if managed:
		var trusted_manifest: Variant = JSON.parse_string(str(verification.get("manifest_json", "")))
		var trusted_entry: Variant = JSON.parse_string(str(verification.get("entry_json", "")))
		if not trusted_manifest is Dictionary or not trusted_entry is Dictionary:
			return {"ok": false, "error": "managed character preview verification snapshot is incomplete"}
		manifest = trusted_manifest
		parsed = trusted_entry
		asset_hashes = _asset_hashes_from_manifest(manifest)
	else:
		var entry_rel: String = str(manifest.get("entry", ""))
		if entry_rel.is_empty() and not package_root.is_empty() \
		and FileAccess.file_exists(package_root.path_join("character.json")):
			entry_rel = "character.json"
		if package_root.is_empty() or entry_rel.is_empty():
			return {"ok": false, "error": "character package has no preview entry"}
		var entry_path := package_root.path_join(entry_rel)
		if not FileAccess.file_exists(entry_path):
			return {"ok": false, "error": "character preview entry not found"}
		var parsed_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
		if not parsed_value is Dictionary:
			return {"ok": false, "error": "invalid character preview entry JSON"}
		parsed = parsed_value

	var presentation_value: Variant = parsed.get("presentation", {})
	var presentation: Dictionary = presentation_value if presentation_value is Dictionary else {}
	var preview_value: Variant = presentation.get("preview", {})
	var preview: Dictionary = preview_value if preview_value is Dictionary else {}
	var preview_rel := str(preview.get("path", "")).strip_edges()
	if not preview_rel.is_empty():
		var image := _load_sprite_image_after_verification(
			package_root,
			preview_rel,
			managed,
			asset_hashes
		)
		if image != null and not image.is_empty():
			return {
				"ok": true,
				"entry": parsed,
				"texture": ImageTexture.create_from_image(image),
				"source": "presentation.preview",
			}

	var animation_names := _declared_animation_names(parsed)
	var animation: StringName = &"idle" if animation_names.has("idle") else (
		StringName(animation_names[0]) if not animation_names.is_empty() else &""
	)
	var frames := _build_sprite_frames_after_verification(
		package_root,
		parsed,
		[animation] if animation != &"" else [],
		managed,
		asset_hashes
	)
	if frames == null:
		return {"ok": false, "error": "could not build preview fallback"}
	if animation == &"" or frames.get_frame_count(animation) <= 0:
		return {"ok": false, "error": "character has no previewable frame"}
	return {
		"ok": true,
		"entry": parsed,
		"texture": frames.get_frame_texture(animation, 0),
		"source": "idle-fallback",
	}


## Loads only the embedded Character/3 animation thumbnail assets requested by
## the caller. The package remains the source of truth: no thumbnail is derived
## from SpriteFrames here. This keeps Character Manager paging cheap and makes
## legacy packages without presentation.animationThumbnails explicitly return
## no preview rather than doing expensive sprite-sheet work.
func load_animation_thumbnail_png_bytes(package_info: Dictionary, requested_names: Array) -> Dictionary:
	var verification := PackageVerification.verify(str(package_info.get("path", "")))
	if not bool(verification.get("ok", false)):
		return verification
	var package_root: String = str(package_info.get("path", ""))
	var manifest: Dictionary = package_info.get("manifest", {})
	var entry_rel: String = str(manifest.get("entry", ""))
	if entry_rel.is_empty() and not package_root.is_empty() \
	and FileAccess.file_exists(package_root.path_join("character.json")):
		entry_rel = "character.json"
	if package_root.is_empty() or entry_rel.is_empty():
		return {"ok": false, "error": "character package has no thumbnail entry", "thumbnails": {}}
	var entry_path := package_root.path_join(entry_rel)
	if not FileAccess.file_exists(entry_path):
		return {"ok": false, "error": "character thumbnail entry not found", "thumbnails": {}}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not parsed is Dictionary:
		return {"ok": false, "error": "invalid character thumbnail entry JSON", "thumbnails": {}}

	var presentation_value: Variant = parsed.get("presentation", {})
	var presentation: Dictionary = presentation_value if presentation_value is Dictionary else {}
	var thumbnail_map_value: Variant = presentation.get("animationThumbnails", {})
	var thumbnail_map: Dictionary = thumbnail_map_value if thumbnail_map_value is Dictionary else {}
	if thumbnail_map.is_empty():
		return {"ok": true, "source": "legacy-no-animation-thumbnails", "thumbnails": {}}

	var thumbnails: Dictionary = {}
	for raw_name in requested_names:
		var animation_name := str(raw_name).strip_edges()
		if animation_name.is_empty() or animation_name.length() > 80 or not thumbnail_map.has(animation_name):
			continue
		var asset_value: Variant = thumbnail_map.get(animation_name, {})
		var asset: Dictionary = asset_value if asset_value is Dictionary else {}
		var asset_rel := str(asset.get("path", "")).strip_edges().replace("\\", "/")
		var path_parts := asset_rel.split("/", false)
		if asset_rel.is_empty() or asset_rel.begins_with("/") or asset_rel.contains(":") or path_parts.has(".."):
			continue
		var lower := asset_rel.to_lower()
		if not (lower.ends_with(".png") or lower.ends_with(".webp")):
			continue
		var asset_path := package_root.path_join(asset_rel)
		if not FileAccess.file_exists(asset_path):
			continue
		if lower.ends_with(".png"):
			var source_png_bytes := _validated_png_thumbnail_bytes(asset_path)
			if not source_png_bytes.is_empty():
				thumbnails[animation_name] = source_png_bytes
			continue
		var image := Image.load_from_file(asset_path)
		if image == null or image.is_empty() \
		or image.get_width() <= 0 or image.get_height() <= 0 \
		or image.get_width() > MAX_ANIMATION_THUMBNAIL_DIMENSION \
		or image.get_height() > MAX_ANIMATION_THUMBNAIL_DIMENSION:
			continue
		var converted_png_bytes := image.save_png_to_buffer()
		if not converted_png_bytes.is_empty():
			thumbnails[animation_name] = converted_png_bytes
	return {"ok": true, "source": "presentation.animationThumbnails", "thumbnails": thumbnails}


func _validated_png_thumbnail_bytes(asset_path: String) -> PackedByteArray:
	var file := FileAccess.open(asset_path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var byte_count := file.get_length()
	if byte_count < 24 or byte_count > MAX_ANIMATION_THUMBNAIL_PNG_BYTES:
		file.close()
		return PackedByteArray()
	var bytes := file.get_buffer(byte_count)
	file.close()
	var signature := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	if bytes.slice(0, 8) != signature or _png_u32_be(bytes, 8) != 13 \
	or bytes.slice(12, 16).get_string_from_ascii() != "IHDR":
		return PackedByteArray()
	var width := _png_u32_be(bytes, 16)
	var height := _png_u32_be(bytes, 20)
	if width <= 0 or height <= 0 or width > MAX_ANIMATION_THUMBNAIL_DIMENSION or height > MAX_ANIMATION_THUMBNAIL_DIMENSION:
		return PackedByteArray()
	return bytes


func _png_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) << 24) | (int(bytes[offset + 1]) << 16) | (int(bytes[offset + 2]) << 8) | int(bytes[offset + 3])


func _runtime_visual_profiles(entry: Dictionary, character_id: String, version: String) -> Dictionary:
	var profiles_value: Variant = entry.get("visualProfiles", {})
	var profiles: Dictionary = profiles_value.duplicate(true) if profiles_value is Dictionary else {}
	# Bible 1.0.0 was authored with the hang contact at y=0.18, but the actual
	# raised paw contact band in hang.webp sits around y=132..167 of the 512px
	# authored frame (roughly 0.26..0.33). Native presentation aligns
	# surfaceAnchor to the canonical top-edge contact; choosing an anchor above
	# the paws moves the whole HWND downward and leaves a visible gap. Keep the
	# installed package immutable/trusted and apply this narrow compatibility
	# correction; the next Bible package version should carry it in metadata.
	if character_id == BIBLE_CHARACTER_ID and version == BIBLE_100_VERSION:
		var hang_value: Variant = profiles.get("hang", {})
		if hang_value is Dictionary:
			var hang_profile: Dictionary = hang_value.duplicate(true)
			hang_profile["surfaceAnchor"] = BIBLE_100_HANG_SURFACE_ANCHOR.duplicate()
			profiles["hang"] = hang_profile
	return profiles


## Reads the safe preview catalogue without decoding any sprite sheet. The
## returned data stays inside Runtime; package paths and raw entry data never
## cross the Desktop Shell projection boundary.
func load_preview_metadata(package_info: Dictionary) -> Dictionary:
	var loaded := _load_preview_entry(package_info)
	if not bool(loaded.get("ok", false)):
		return loaded
	var entry: Dictionary = loaded["entry"]
	var animations_value: Variant = entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	var names: Array[String] = []
	var loops: Dictionary = {}
	for raw_name in _declared_animation_names(entry):
		var name := str(raw_name).strip_edges()
		if name.is_empty() or name.length() > 80:
			continue
		var source_name := _resolve_animation_source(entry, name)
		var clip_value: Variant = animations.get(source_name, {})
		if not clip_value is Dictionary:
			continue
		names.append(name)
		loops[name] = bool(clip_value.get("loop", false))
	names.sort()
	if names.is_empty():
		return {"ok": false, "error": "character has no preview animations"}
	return {
		"ok": true,
		"animations": names,
		"loops": loops,
		"default_animation": "idle" if names.has("idle") else names[0],
		# Runtime-internal immutable trust snapshot. Desktop Shell adapter keeps
		# this for the preview session; it is never projected to the renderer.
		"prepared_entry": loaded.duplicate(true),
	}


## Decodes only one logical animation for an isolated preview. This deliberately
## does not reuse the active character's lazy state, so preview inspection cannot
## mutate or evict the desktop companion's resources.
func build_preview_animation_frames(package_info: Dictionary, animation_name: String) -> Dictionary:
	var normalized := animation_name.strip_edges()
	if normalized.is_empty() or normalized.length() > 80:
		return {"ok": false, "error": "invalid preview animation"}
	var loaded := _load_preview_entry(package_info)
	if not bool(loaded.get("ok", false)):
		return loaded
	var package_root := str(loaded.get("package_root", ""))
	var entry: Dictionary = loaded["entry"]
	if _resolve_animation_source(entry, normalized).is_empty():
		return {"ok": false, "error": "preview animation not declared"}
	var frames := build_sprite_frames(package_root, entry, [StringName(normalized)])
	if frames == null or not frames.has_animation(StringName(normalized)):
		return {"ok": false, "error": "could not build preview animation"}
	return {"ok": true, "frames": frames, "animation": normalized}


## CPU-only preview preparation for Desktop Shell. This method is safe to run
## on a Thread because it never touches SceneTree, RenderingServer, Texture2D,
## or shared Runtime state. The main thread receives bounded encoded frames.
func prepare_preview_entry(package_info: Dictionary) -> Dictionary:
	return _load_preview_entry(package_info)


func build_preview_animation_payload(package_info: Dictionary, animation_name: String, prepared_entry: Dictionary = {}) -> Dictionary:
	# 384 keeps real high-detail character PNGs under the existing 192 KiB
	# transport bound while remaining larger than the current preview viewport.
	const MAX_FRAME_WIDTH := 384
	const MAX_FRAME_HEIGHT := 384
	const MAX_FRAME_PNG_BYTES := 196_608
	const MAX_FRAME_BASE64_LENGTH := 262_144
	const MAX_ANIMATION_FRAMES := 512
	const MAX_PAYLOAD_BASE64_BYTES := 8 * 1024 * 1024
	var started_at_msec := Time.get_ticks_msec()
	var normalized := animation_name.strip_edges()
	if normalized.is_empty() or normalized.length() > 80:
		return {"ok": false, "error": "invalid preview animation"}
	var loaded := prepared_entry if not prepared_entry.is_empty() else _load_preview_entry(package_info)
	if not bool(loaded.get("ok", false)):
		return loaded
	var package_root := str(loaded.get("package_root", ""))
	var entry: Dictionary = loaded["entry"]
	var source_name := _resolve_animation_source(entry, normalized)
	if source_name.is_empty():
		return {"ok": false, "error": "preview animation not declared"}

	var animations_value: Variant = entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	var clip_value: Variant = animations.get(source_name, {})
	if not clip_value is Dictionary:
		return {"ok": false, "error": "invalid preview animation clip"}
	var clip: Dictionary = clip_value
	var sprites_value: Variant = entry.get("sprites", [])
	var sprites: Array = sprites_value if sprites_value is Array else []
	if sprites.is_empty():
		return {"ok": false, "error": "character has no preview sprite"}

	var default_sprite_id := ""
	for sprite_value in sprites:
		if sprite_value is Dictionary:
			default_sprite_id = str(sprite_value.get("id", ""))
			if not default_sprite_id.is_empty():
				break
	var requested_sprite_id := str(clip.get("sprite", default_sprite_id))
	if requested_sprite_id.is_empty():
		requested_sprite_id = default_sprite_id
	var sprite: Dictionary = {}
	for sprite_value in sprites:
		if sprite_value is Dictionary and str(sprite_value.get("id", "")) == requested_sprite_id:
			sprite = sprite_value
			break
	if sprite.is_empty():
		return {"ok": false, "error": "preview sprite not found"}

	var relative_path := str(sprite.get("path", "")).replace("\\", "/")
	var path_parts := relative_path.split("/", false)
	if relative_path.is_empty() or relative_path.is_absolute_path() or relative_path.contains(":") or path_parts.has(".."):
		return {"ok": false, "error": "invalid preview sprite path"}
	var payload_cache_key := _preview_payload_cache_key(package_info, normalized, package_root, relative_path, clip, sprite, loaded)
	if not payload_cache_key.is_empty():
		var cached_payload := _load_preview_payload_cache(payload_cache_key, normalized)
		if not cached_payload.is_empty():
			cached_payload["worker_ms"] = Time.get_ticks_msec() - started_at_msec
			cached_payload["cache_hit"] = true
			return cached_payload
	var image_path := package_root.path_join(relative_path)
	var atlas: Image
	if bool(loaded.get("managed", false)):
		# Decode the same bytes whose hash was checked against the signed snapshot.
		var image_bytes := FileAccess.get_file_as_bytes(image_path)
		var hasher := HashingContext.new()
		hasher.start(HashingContext.HASH_SHA256)
		hasher.update(image_bytes)
		if hasher.finish().hex_encode() != str(loaded.get("asset_hashes", {}).get(relative_path, "")):
			return {"ok": false, "error": "Preview sprite digest mismatch"}
		atlas = Image.new()
		var decode_error: Error = ERR_FILE_UNRECOGNIZED
		match relative_path.get_extension().to_lower():
			"png": decode_error = atlas.load_png_from_buffer(image_bytes)
			"webp": decode_error = atlas.load_webp_from_buffer(image_bytes)
			"jpg", "jpeg": decode_error = atlas.load_jpg_from_buffer(image_bytes)
			"bmp": decode_error = atlas.load_bmp_from_buffer(image_bytes)
			"tga": decode_error = atlas.load_tga_from_buffer(image_bytes)
			"svg": decode_error = atlas.load_svg_from_buffer(image_bytes)
		if decode_error != OK:
			return {"ok": false, "error": "Verified preview image could not be decoded"}
	else:
		atlas = Image.load_from_file(image_path)
	if atlas == null or atlas.is_empty():
		return {"ok": false, "error": "preview sprite could not be decoded"}

	var frame_width := atlas.get_width()
	var frame_height := atlas.get_height()
	var frame_size_value: Variant = sprite.get("frameSize", [])
	if frame_size_value is Array and frame_size_value.size() >= 2:
		frame_width = clampi(int(frame_size_value[0]), 1, atlas.get_width())
		frame_height = clampi(int(frame_size_value[1]), 1, atlas.get_height())
	var columns := maxi(1, atlas.get_width() / frame_width)
	var rows := maxi(1, atlas.get_height() / frame_height)
	var max_frame := columns * rows
	var indices_value: Variant = clip.get("frames", [0])
	var indices: Array = indices_value if indices_value is Array else [0]
	if indices.is_empty() or indices.size() > MAX_ANIMATION_FRAMES:
		return {"ok": false, "error": "preview frame count is outside bounds"}

	var source_frames: Array[Image] = []
	var source_used_rects: Array[Rect2i] = []
	var stable_used_rect := Rect2i()
	var found_used_pixels := false
	for raw_index in indices:
		var frame_index := clampi(int(raw_index), 0, maxi(0, max_frame - 1))
		var region := Rect2i(
			(frame_index % columns) * frame_width,
			(frame_index / columns) * frame_height,
			frame_width,
			frame_height
		)
		var frame := atlas.get_region(region)
		source_frames.append(frame)
		var used := frame.get_used_rect()
		source_used_rects.append(used)
		if used.size.x <= 0 or used.size.y <= 0:
			continue
		stable_used_rect = used if not found_used_pixels else stable_used_rect.merge(used)
		found_used_pixels = true

	var source_alpha_rect := Rect2i()
	for used_rect in source_used_rects:
		if used_rect.size.x <= 0 or used_rect.size.y <= 0:
			continue
		var runtime_rect := used_rect.grow(6).intersection(Rect2i(Vector2i.ZERO, Vector2i(frame_width, frame_height)))
		source_alpha_rect = runtime_rect if source_alpha_rect.size == Vector2i.ZERO else source_alpha_rect.merge(runtime_rect)
	if source_alpha_rect.size == Vector2i.ZERO:
		source_alpha_rect = Rect2i(0, 0, frame_width, frame_height)
	if found_used_pixels:
		var padding := 4
		var x0 := maxi(0, stable_used_rect.position.x - padding)
		var y0 := maxi(0, stable_used_rect.position.y - padding)
		var x1 := mini(frame_width, stable_used_rect.end.x + padding)
		var y1 := mini(frame_height, stable_used_rect.end.y + padding)
		stable_used_rect = Rect2i(x0, y0, x1 - x0, y1 - y0)
	else:
		stable_used_rect = Rect2i(0, 0, frame_width, frame_height)

	var source_alpha_rects: Array[Dictionary] = []
	var runtime_alpha_rects: Array[Dictionary] = []
	for used_rect in source_used_rects:
		var effective_rect := used_rect
		if effective_rect.size.x <= 0 or effective_rect.size.y <= 0:
			effective_rect = source_alpha_rect
		else:
			effective_rect = effective_rect.grow(6).intersection(Rect2i(Vector2i.ZERO, Vector2i(frame_width, frame_height)))
		source_alpha_rects.append({
			"x": effective_rect.position.x - stable_used_rect.position.x,
			"y": effective_rect.position.y - stable_used_rect.position.y,
			"width": effective_rect.size.x,
			"height": effective_rect.size.y,
		})
		runtime_alpha_rects.append({
			"x": effective_rect.position.x,
			"y": effective_rect.position.y,
			"width": effective_rect.size.x,
			"height": effective_rect.size.y,
		})

	var encoded_frames: Array[String] = []
	var output_width := 0
	var output_height := 0
	var encoded_bytes := 0
	for source_frame in source_frames:
		var output := source_frame.get_region(stable_used_rect)
		if output.get_width() > MAX_FRAME_WIDTH or output.get_height() > MAX_FRAME_HEIGHT:
			var factor := minf(
				float(MAX_FRAME_WIDTH) / float(output.get_width()),
				float(MAX_FRAME_HEIGHT) / float(output.get_height())
			)
			output.resize(
				maxi(1, int(round(output.get_width() * factor))),
				maxi(1, int(round(output.get_height() * factor))),
				Image.INTERPOLATE_LANCZOS
			)
		var png_bytes := output.save_png_to_buffer()
		if png_bytes.is_empty() or png_bytes.size() > MAX_FRAME_PNG_BYTES:
			return {"ok": false, "error": "preview frame exceeds PNG bound"}
		var encoded := Marshalls.raw_to_base64(png_bytes)
		if encoded.is_empty() or encoded.length() > MAX_FRAME_BASE64_LENGTH:
			return {"ok": false, "error": "preview frame exceeds base64 bound"}
		encoded_bytes += encoded.length()
		if encoded_bytes > MAX_PAYLOAD_BASE64_BYTES:
			return {"ok": false, "error": "preview animation exceeds memory bound"}
		encoded_frames.append(encoded)
		output_width = output.get_width()
		output_height = output.get_height()

	var visual_profiles_value: Variant = entry.get("visualProfiles", {})
	var visual_profiles: Dictionary = visual_profiles_value if visual_profiles_value is Dictionary else {}
	var idle_profile_value: Variant = visual_profiles.get("idle", {})
	var idle_profile: Dictionary = idle_profile_value if idle_profile_value is Dictionary else {}
	var payload := {
		"ok": true,
		"animation": normalized,
		"loop": bool(clip.get("loop", false)),
		"fps": clampf(float(clip.get("fps", 8.0)), 0.1, 60.0),
		"encoded_frames": encoded_frames,
		"frame_width": output_width,
		"frame_height": output_height,
		"source_frame_width": frame_width,
		"source_frame_height": frame_height,
		"source_crop_x": stable_used_rect.position.x,
		"source_crop_y": stable_used_rect.position.y,
		"source_crop_width": stable_used_rect.size.x,
		"source_crop_height": stable_used_rect.size.y,
		"source_alpha_x": source_alpha_rect.position.x - stable_used_rect.position.x,
		"source_alpha_y": source_alpha_rect.position.y - stable_used_rect.position.y,
		"source_alpha_width": source_alpha_rect.size.x,
		"source_alpha_height": source_alpha_rect.size.y,
		"source_alpha_rects": source_alpha_rects,
		"runtime_union_alpha": {
			"x": source_alpha_rect.position.x,
			"y": source_alpha_rect.position.y,
			"width": source_alpha_rect.size.x,
			"height": source_alpha_rect.size.y,
		},
		"runtime_alpha_rects": runtime_alpha_rects,
		"idle_profile_scale": clampf(float(idle_profile.get("scale", 1.0)), 0.25, 2.0),
		"encoded_bytes": encoded_bytes,
		"worker_ms": Time.get_ticks_msec() - started_at_msec,
		"cache_hit": false,
	}
	if not payload_cache_key.is_empty():
		_store_preview_payload_cache(payload_cache_key, payload)
	return payload


func _preview_payload_cache_key(package_info: Dictionary, animation: String, package_root: String, relative_path: String, clip: Dictionary, sprite: Dictionary, loaded: Dictionary) -> String:
	var hashes_value: Variant = loaded.get("asset_hashes", {})
	var hashes: Dictionary = hashes_value if hashes_value is Dictionary else {}
	var asset_hash := str(hashes.get(relative_path, ""))
	# Managed Store packages reuse the signed manifest digest. Local/starter
	# packages do not carry that immutable projection, so derive the same cache
	# invalidation property from the actual source bytes. Hashing a ~0.5-1 MB
	# WebP is far cheaper than decoding, cropping and PNG-encoding 32-48 frames.
	if asset_hash.is_empty():
		var source_bytes := FileAccess.get_file_as_bytes(package_root.path_join(relative_path))
		if source_bytes.is_empty():
			return ""
		var source_hasher := HashingContext.new()
		source_hasher.start(HashingContext.HASH_SHA256)
		source_hasher.update(source_bytes)
		asset_hash = source_hasher.finish().hex_encode()
	var descriptor := JSON.stringify({
		"cacheVersion": PREVIEW_PAYLOAD_CACHE_VERSION,
		"packageId": str(package_info.get("packageId", package_info.get("id", ""))),
		"version": str(package_info.get("version", "")),
		"animation": animation,
		"path": relative_path,
		"assetHash": asset_hash,
		"clip": clip,
		"sprite": sprite,
		"maxFrame": [384, 384],
	})
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(descriptor.to_utf8_buffer())
	return hasher.finish().hex_encode()


func _preview_payload_cache_path(cache_key: String) -> String:
	return PREVIEW_PAYLOAD_CACHE_DIR.path_join(cache_key + ".cache")


func _load_preview_payload_cache(cache_key: String, animation: String) -> Dictionary:
	var cache_path := _preview_payload_cache_path(cache_key)
	if not FileAccess.file_exists(cache_path):
		return {}
	var file := FileAccess.open(cache_path, FileAccess.READ)
	if file == null:
		return {}
	var length := file.get_length()
	if length <= 0 or length > MAX_PREVIEW_CACHE_FILE_BYTES:
		file.close()
		return {}
	var value: Variant = file.get_var(false)
	file.close()
	if not value is Dictionary:
		return {}
	var payload: Dictionary = value
	if not _preview_payload_cache_valid(payload, animation):
		return {}
	return payload.duplicate(true)


func _preview_payload_cache_valid(payload: Dictionary, animation: String) -> bool:
	if not bool(payload.get("ok", false)) or str(payload.get("animation", "")) != animation:
		return false
	var frames_value: Variant = payload.get("encoded_frames", [])
	if not frames_value is Array:
		return false
	var encoded_frames: Array = frames_value
	if encoded_frames.is_empty() or encoded_frames.size() > 512:
		return false
	var total_bytes := 0
	for encoded_value in encoded_frames:
		var encoded := str(encoded_value)
		if encoded.is_empty() or encoded.length() > 262_144:
			return false
		total_bytes += encoded.length()
		if total_bytes > 8 * 1024 * 1024:
			return false
	var width := int(payload.get("frame_width", 0))
	var height := int(payload.get("frame_height", 0))
	var fps := float(payload.get("fps", 0.0))
	return width > 0 and width <= 512 \
		and height > 0 and height <= 512 \
		and fps >= 0.1 and fps <= 60.0


func _store_preview_payload_cache(cache_key: String, payload: Dictionary) -> void:
	if cache_key.is_empty() or not _preview_payload_cache_valid(payload, str(payload.get("animation", ""))):
		return
	var cache_root := ProjectSettings.globalize_path(PREVIEW_PAYLOAD_CACHE_DIR)
	if DirAccess.make_dir_recursive_absolute(cache_root) != OK and not DirAccess.dir_exists_absolute(cache_root):
		return
	var cache_path := _preview_payload_cache_path(cache_key)
	var file := FileAccess.open(cache_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_var(payload)
	file.close()
	_trim_preview_payload_disk_cache()


func _trim_preview_payload_disk_cache() -> void:
	var dir := DirAccess.open(PREVIEW_PAYLOAD_CACHE_DIR)
	if dir == null:
		return
	var entries: Array[Dictionary] = []
	var total_bytes := 0
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".cache"):
			var path := PREVIEW_PAYLOAD_CACHE_DIR.path_join(file_name)
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				var size := int(file.get_length())
				file.close()
				total_bytes += size
				entries.append({"name": file_name, "size": size, "mtime": int(FileAccess.get_modified_time(path))})
		file_name = dir.get_next()
	dir.list_dir_end()
	if total_bytes <= PREVIEW_PAYLOAD_DISK_CACHE_BYTES:
		return
	entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("mtime", 0)) < int(right.get("mtime", 0))
	)
	for entry in entries:
		if total_bytes <= PREVIEW_PAYLOAD_DISK_CACHE_BYTES:
			break
		if dir.remove(str(entry.get("name", ""))) == OK:
			total_bytes -= int(entry.get("size", 0))


## Builds preview-only resources from an installed package. Unlike
## load_active_character(), this does not publish events or mutate Runtime
## Context, so UI inspection cannot change the desktop companion before Apply.
func build_preview_frames(package_info: Dictionary) -> Dictionary:
	var verification := PackageVerification.verify(str(package_info.get("path", "")))
	if not bool(verification.get("ok", false)):
		return verification
	var package_root: String = str(package_info.get("path", ""))
	var manifest: Dictionary = package_info.get("manifest", {})
	var entry_rel: String = str(manifest.get("entry", ""))
	if entry_rel.is_empty() and not package_root.is_empty() \
	and FileAccess.file_exists(package_root.path_join("character.json")):
		entry_rel = "character.json"
	if package_root.is_empty() or entry_rel.is_empty():
		return {"ok": false, "error": "character package has no preview entry"}
	var entry_path := package_root.path_join(entry_rel)
	if not FileAccess.file_exists(entry_path):
		return {"ok": false, "error": "character preview entry not found"}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not parsed is Dictionary:
		return {"ok": false, "error": "invalid character preview entry JSON"}
	var frames := build_sprite_frames(package_root, parsed)
	if frames == null:
		return {"ok": false, "error": "could not build preview SpriteFrames"}
	return {
		"ok": true,
		"entry": parsed,
		"frames": frames,
		"animations": frames.get_animation_names(),
	}


func _load_preview_entry(package_info: Dictionary) -> Dictionary:
	var verification_value: Variant = package_info.get("_verification", {})
	var verification: Dictionary = verification_value if verification_value is Dictionary else {}
	if not bool(verification.get("ok", false)):
		verification = PackageVerification.verify(str(package_info.get("path", "")))
	if not bool(verification.get("ok", false)):
		return verification
	if bool(verification.get("managed", false)):
		var trusted_manifest: Dictionary = JSON.parse_string(str(verification.get("manifest_json", "")))
		var trusted_entry: Dictionary = JSON.parse_string(str(verification.get("entry_json", "")))
		var hashes: Dictionary = {}
		for asset in trusted_manifest.get("assets", []):
			hashes[str(asset.get("path", ""))] = str(asset.get("sha256", ""))
		return {"ok": true, "managed": true, "package_root": str(package_info.get("path", "")), "entry": trusted_entry, "asset_hashes": hashes}
	var package_root: String = str(package_info.get("path", ""))
	var manifest: Dictionary = package_info.get("manifest", {})
	var entry_rel: String = str(manifest.get("entry", ""))
	if entry_rel.is_empty() and not package_root.is_empty() \
	and FileAccess.file_exists(package_root.path_join("character.json")):
		entry_rel = "character.json"
	if package_root.is_empty() or entry_rel.is_empty():
		return {"ok": false, "error": "character package has no preview entry"}
	var entry_path := package_root.path_join(entry_rel)
	if not FileAccess.file_exists(entry_path):
		return {"ok": false, "error": "character preview entry not found"}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not parsed is Dictionary:
		return {"ok": false, "error": "invalid character preview entry JSON"}
	return {"ok": true, "package_root": package_root, "entry": parsed}


func _effective_animation_loop(logical_name: StringName, clip: Dictionary) -> bool:
	# `climb_top` and `drag_release` are visual transitions, never persistent
	# movement states. Runtime waits for animation_finished before returning to
	# physics-owned animation selection, so legacy packages that accidentally
	# marked either clip as looping must be normalized here.
	if logical_name in [&"climb_top", &"drag_release"]:
		return false
	return bool(clip.get("loop", false))


func build_sprite_frames(package_root: String, entry: Dictionary, requested_names: Array = []) -> SpriteFrames:
	var verification := PackageVerification.verify(package_root)
	if not bool(verification.get("ok", false)):
		return null
	var managed := bool(verification.get("managed", false))
	var effective_entry := entry
	var asset_hashes: Dictionary = {}
	if managed:
		var trusted_entry: Variant = JSON.parse_string(str(verification.get("entry_json", "")))
		var trusted_manifest: Variant = JSON.parse_string(str(verification.get("manifest_json", "")))
		if not trusted_entry is Dictionary or not trusted_manifest is Dictionary:
			return null
		effective_entry = trusted_entry
		asset_hashes = _asset_hashes_from_manifest(trusted_manifest)
	return _build_sprite_frames_after_verification(
		package_root,
		effective_entry,
		requested_names,
		managed,
		asset_hashes
	)


func _asset_hashes_from_manifest(manifest: Dictionary) -> Dictionary:
	var hashes: Dictionary = {}
	var assets_value: Variant = manifest.get("assets", [])
	if not assets_value is Array:
		return hashes
	for asset_value in assets_value:
		if not asset_value is Dictionary:
			continue
		var relative_path := str(asset_value.get("path", "")).replace("\\", "/")
		var digest := str(asset_value.get("sha256", "")).strip_edges().to_lower()
		if not relative_path.is_empty() and digest.length() == 64:
			hashes[relative_path] = digest
	return hashes


func _load_sprite_image_after_verification(
	package_root: String,
	relative_path: String,
	managed: bool,
	asset_hashes: Dictionary
) -> Image:
	var normalized := relative_path.replace("\\", "/")
	var image_path := package_root.path_join(normalized)
	if not managed:
		return Image.load_from_file(image_path)
	var expected := str(asset_hashes.get(normalized, "")).strip_edges().to_lower()
	if expected.length() != 64 or not FileAccess.file_exists(image_path):
		return null
	var image_bytes := FileAccess.get_file_as_bytes(image_path)
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(image_bytes)
	if hasher.finish().hex_encode() != expected:
		return null
	var image := Image.new()
	var decode_error: Error = ERR_FILE_UNRECOGNIZED
	match normalized.get_extension().to_lower():
		"png": decode_error = image.load_png_from_buffer(image_bytes)
		"webp": decode_error = image.load_webp_from_buffer(image_bytes)
		"jpg", "jpeg": decode_error = image.load_jpg_from_buffer(image_bytes)
	if decode_error != OK or image.is_empty():
		return null
	return image


func _build_sprite_frames_after_verification(
	package_root: String,
	entry: Dictionary,
	requested_names: Array,
	managed: bool,
	asset_hashes: Dictionary
) -> SpriteFrames:
	var sprite_list: Array = entry.get("sprites", [])
	if sprite_list.is_empty():
		return null

	var animations_value: Variant = entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	if animations.is_empty():
		return null

	var default_id := ""
	for raw_sprite in sprite_list:
		if raw_sprite is Dictionary:
			var candidate_id := str(raw_sprite.get("id", ""))
			if not candidate_id.is_empty():
				default_id = candidate_id
				break
	if default_id.is_empty():
		return null

	var logical_names: Array[StringName] = []
	if requested_names.is_empty():
		for animation_name_value in animations.keys():
			logical_names.append(StringName(animation_name_value))
		var fallback_value: Variant = entry.get("animationFallbacks", {})
		var fallbacks: Dictionary = fallback_value if fallback_value is Dictionary else {}
		for fallback_name_value in fallbacks.keys():
			var fallback_name := StringName(fallback_name_value)
			if fallback_name not in logical_names:
				logical_names.append(fallback_name)
	else:
		for requested in requested_names:
			var logical_name := StringName(requested)
			if logical_name not in logical_names and not _resolve_animation_source(entry, str(logical_name)).is_empty():
				logical_names.append(logical_name)
	if logical_names.is_empty():
		return null

	var needed_sprite_ids: Dictionary = {}
	for logical_name in logical_names:
		var source_name := _resolve_animation_source(entry, str(logical_name))
		if source_name.is_empty():
			continue
		var clip_value: Variant = animations.get(source_name, {})
		if not clip_value is Dictionary:
			continue
		var sprite_id := str(clip_value.get("sprite", default_id))
		if sprite_id.is_empty():
			sprite_id = default_id
		needed_sprite_ids[sprite_id] = true
	if needed_sprite_ids.is_empty():
		needed_sprite_ids[default_id] = true

	# A requested logical animation already pays the cost of decoding its whole
	# authored sprite sheet. Materialize sibling animations that reference the
	# same sheet now so transitions such as climb_ready -> climb_up can reuse one
	# ImageTexture instead of decoding/uploading the same 48 MB RGBA atlas twice.
	if not requested_names.is_empty():
		for candidate_name_value in animations.keys():
			var candidate_name := StringName(candidate_name_value)
			if candidate_name in logical_names:
				continue
			var candidate_value: Variant = animations.get(str(candidate_name), {})
			if not candidate_value is Dictionary:
				continue
			var candidate_sprite_id := str((candidate_value as Dictionary).get("sprite", default_id))
			if candidate_sprite_id.is_empty():
				candidate_sprite_id = default_id
			if needed_sprite_ids.has(candidate_sprite_id):
				logical_names.append(candidate_name)

	var sheets: Dictionary = {}
	for raw_sprite in sprite_list:
		if not raw_sprite is Dictionary:
			continue
		var sprite_data: Dictionary = raw_sprite
		var sprite_id: String = str(sprite_data.get("id", ""))
		var relative_path: String = str(sprite_data.get("path", ""))
		if sprite_id.is_empty() or relative_path.is_empty() or not needed_sprite_ids.has(sprite_id):
			continue

		var image: Image = _load_sprite_image_after_verification(
			package_root,
			relative_path,
			managed,
			asset_hashes
		)
		if image == null or image.is_empty():
			continue

		var frame_size_value: Variant = sprite_data.get("frameSize", [])
		var frame_width: int = image.get_width()
		var frame_height: int = image.get_height()
		if frame_size_value is Array and frame_size_value.size() >= 2:
			frame_width = clampi(int(frame_size_value[0]), 1, image.get_width())
			frame_height = clampi(int(frame_size_value[1]), 1, image.get_height())

		var columns: int = maxi(1, image.get_width() / frame_width)
		var rows: int = maxi(1, image.get_height() / frame_height)
		# Precompute per-frame alpha bounds while the verified CPU image is already
		# resident. CharacterController used to call Texture2D.get_image() for every
		# frame when an animation started; with a large local LLM loaded this GPU
		# readback could fail allocations and destabilize the Runtime.
		var frame_alpha_rects: Array[Rect2i] = []
		for sheet_frame_index in range(columns * rows):
			var frame_region := Rect2i(
				(sheet_frame_index % columns) * frame_width,
				(sheet_frame_index / columns) * frame_height,
				frame_width,
				frame_height
			)
			var frame_image := image.get_region(frame_region)
			var used_rect := frame_image.get_used_rect()
			if used_rect.size != Vector2i.ZERO:
				used_rect = used_rect.grow(6).intersection(Rect2i(Vector2i.ZERO, Vector2i(frame_width, frame_height)))
			frame_alpha_rects.append(used_rect)
		sheets[sprite_id] = {
			"texture": ImageTexture.create_from_image(image),
			"frame_width": frame_width,
			"frame_height": frame_height,
			"columns": columns,
			"rows": rows,
			"frame_alpha_rects": frame_alpha_rects,
		}

	if sheets.is_empty():
		return null

	var result := SpriteFrames.new()
	if result.has_animation("default"):
		result.remove_animation("default")

	for logical_name in logical_names:
		var source_name := _resolve_animation_source(entry, str(logical_name))
		if source_name.is_empty():
			continue
		var clip_value: Variant = animations.get(source_name, {})
		if not clip_value is Dictionary:
			continue
		var clip: Dictionary = clip_value
		var sprite_id: String = str(clip.get("sprite", default_id))
		if sprite_id.is_empty() or not sheets.has(sprite_id):
			sprite_id = default_id
		if not sheets.has(sprite_id):
			continue

		var sheet: Dictionary = sheets[sprite_id]
		result.add_animation(logical_name)
		result.set_animation_loop(logical_name, _effective_animation_loop(logical_name, clip))
		result.set_animation_speed(logical_name, clampf(float(clip.get("fps", 8.0)), 0.1, 60.0))

		var frame_indices_value: Variant = clip.get("frames", [0])
		var frame_indices: Array = frame_indices_value if frame_indices_value is Array else [0]
		var max_frame: int = int(sheet["columns"]) * int(sheet["rows"])
		for raw_index in frame_indices:
			var frame_index: int = clampi(int(raw_index), 0, maxi(0, max_frame - 1))
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet["texture"]
			atlas.region = Rect2(
				(frame_index % int(sheet["columns"])) * int(sheet["frame_width"]),
				(frame_index / int(sheet["columns"])) * int(sheet["frame_height"]),
				int(sheet["frame_width"]),
				int(sheet["frame_height"])
			)
			var alpha_rects_value: Variant = sheet.get("frame_alpha_rects", [])
			if alpha_rects_value is Array and frame_index < (alpha_rects_value as Array).size():
				var alpha_rect_value: Variant = (alpha_rects_value as Array)[frame_index]
				if alpha_rect_value is Rect2i:
					atlas.set_meta(&"ocp_alpha_rect", alpha_rect_value)
			result.add_frame(logical_name, atlas)

	return result if not result.get_animation_names().is_empty() else null


func ensure_animation_loaded(animation_name: StringName, target_frames: SpriteFrames) -> bool:
	if target_frames == null:
		return false
	if target_frames.has_animation(animation_name):
		_touch_lazy_animation(animation_name)
		_publish_animation_load_measurement(animation_name, target_frames, 0.0, true, true, "resident")
		return true
	if lazy_package_root.is_empty() or lazy_entry.is_empty():
		_publish_animation_load_measurement(animation_name, target_frames, 0.0, false, false, "unavailable")
		return false

	var source_name := StringName(_resolve_animation_source(lazy_entry, str(animation_name)))
	if source_name != &"" and source_name != animation_name and target_frames.has_animation(source_name):
		_copy_animation(target_frames, source_name, animation_name)
		_touch_lazy_animation(animation_name)
		_publish_animation_load_measurement(animation_name, target_frames, 0.0, true, true, "shared-source")
		return true

	# The active managed package was fully verified before lazy state was armed.
	# Re-hash only the sprite sheet requested by this animation against the
	# signed manifest instead of rescanning the entire 60+ file projection.
	var lazy_started_us := Time.get_ticks_usec()
	var loaded := _build_sprite_frames_after_verification(
		lazy_package_root,
		lazy_entry,
		[animation_name],
		lazy_managed,
		lazy_asset_hashes
	)
	var lazy_ms := float(Time.get_ticks_usec() - lazy_started_us) / 1000.0
	if loaded == null or not loaded.has_animation(animation_name):
		print("[CharacterLazyLoad] animation=%s ok=false ms=%.2f" % [animation_name, lazy_ms])
		_publish_animation_load_measurement(animation_name, target_frames, lazy_ms, false, false, "lazy-load")
		return false
	var requested_sprite_id := _animation_sprite_id(animation_name)
	var shared_loaded := 0
	for loaded_name in loaded.get_animation_names():
		if loaded_name != animation_name and _animation_sprite_id(loaded_name) != requested_sprite_id:
			continue
		_copy_animation_between(loaded, target_frames, loaded_name)
		_touch_lazy_animation(loaded_name)
		shared_loaded += 1
	print("[CharacterLazyLoad] animation=%s sprite=%s frames=%d shared=%d ms=%.2f" % [
		animation_name,
		requested_sprite_id,
		loaded.get_frame_count(animation_name),
		shared_loaded,
		lazy_ms,
	])
	_publish_animation_load_measurement(animation_name, target_frames, lazy_ms, false, true, "lazy-load")
	return true


func _publish_animation_load_measurement(
	animation_name: StringName,
	target_frames: SpriteFrames,
	load_ms: float,
	cache_hit: bool,
	ok: bool,
	source: String
) -> void:
	if event_bus == null:
		return
	event_bus.publish(&"character.animation_load_measured", {
		"name": animation_name,
		"loadMs": load_ms,
		"cacheHit": cache_hit,
		"ok": ok,
		"source": source,
		"cacheEntries": lazy_animation_order.size(),
		"loadedAnimations": target_frames.get_animation_names().size() if target_frames != null else 0,
	})


func prefetch_animation(
	animation_name: StringName,
	target_frames: SpriteFrames,
	active_animation: StringName = &"",
	reason: String = "predictive"
) -> bool:
	if target_frames == null or animation_name == &"":
		return false
	var started_us := Time.get_ticks_usec()
	var already_resident := target_frames.has_animation(animation_name)
	var ok := ensure_animation_loaded(animation_name, target_frames)
	if ok:
		var protected_animation := active_animation
		if protected_animation == &"" or not target_frames.has_animation(protected_animation):
			protected_animation = animation_name
		trim_animation_cache(target_frames, protected_animation)
	var elapsed_ms := float(Time.get_ticks_usec() - started_us) / 1000.0
	if event_bus != null:
		event_bus.publish(&"character.animation_prefetched", {
			"name": animation_name,
			"reason": reason,
			"ok": ok,
			"alreadyResident": already_resident,
			"elapsedMs": elapsed_ms,
			"activeAnimation": active_animation,
			"cacheEntries": lazy_animation_order.size(),
			"loadedAnimations": target_frames.get_animation_names().size(),
		})
	return ok


func trim_animation_cache(target_frames: SpriteFrames, active_animation: StringName) -> void:
	if target_frames == null:
		return
	_touch_lazy_animation(active_animation)
	# Logical transitions may reuse the same authored sprite sheet. Each lazy
	# load owns a separate ImageTexture, so keeping both logical animations would
	# retain duplicate decoded atlases (for example climb_ready -> climb_up).
	# Once the new animation is active, evict older non-idle animations backed by
	# the same sprite id before applying the normal LRU bound.
	var active_sprite_id := _animation_sprite_id(active_animation)
	if not active_sprite_id.is_empty():
		for candidate in lazy_animation_order.duplicate():
			if candidate == active_animation or candidate in [&"idle", &"idle_neutral"]:
				continue
			if _animation_sprite_id(candidate) != active_sprite_id:
				continue
			if _animations_share_atlas(target_frames, candidate, active_animation):
				continue
			lazy_animation_order.erase(candidate)
			if target_frames.has_animation(candidate):
				target_frames.remove_animation(candidate)
			event_bus.publish(&"character.animation_cache_evicted", {
				"name": candidate,
				"reason": "shared-sprite-superseded",
			})
	var attempts := lazy_animation_order.size() + 2
	while lazy_animation_order.size() > LAZY_ANIMATION_CACHE_LIMIT and attempts > 0:
		attempts -= 1
		var candidate: StringName = lazy_animation_order.pop_front()
		if candidate == active_animation or candidate in [&"idle", &"idle_neutral"]:
			lazy_animation_order.append(candidate)
			continue
		if target_frames.has_animation(candidate):
			target_frames.remove_animation(candidate)
		event_bus.publish(&"character.animation_cache_evicted", {"name": candidate})


func _animations_share_atlas(target_frames: SpriteFrames, left: StringName, right: StringName) -> bool:
	if target_frames == null \
	or not target_frames.has_animation(left) \
	or not target_frames.has_animation(right) \
	or target_frames.get_frame_count(left) <= 0 \
	or target_frames.get_frame_count(right) <= 0:
		return false
	var left_texture := target_frames.get_frame_texture(left, 0)
	var right_texture := target_frames.get_frame_texture(right, 0)
	if left_texture is AtlasTexture and right_texture is AtlasTexture:
		return (left_texture as AtlasTexture).atlas == (right_texture as AtlasTexture).atlas
	return left_texture == right_texture


func _animation_sprite_id(animation_name: StringName) -> String:
	if lazy_entry.is_empty() or animation_name == &"":
		return ""
	var source_name := _resolve_animation_source(lazy_entry, str(animation_name))
	if source_name.is_empty():
		return ""
	var animations_value: Variant = lazy_entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	var clip_value: Variant = animations.get(source_name, {})
	if not clip_value is Dictionary:
		return ""
	return str((clip_value as Dictionary).get("sprite", ""))


func _touch_lazy_animation(animation_name: StringName) -> void:
	if animation_name in [&"", &"idle", &"idle_neutral"]:
		return
	lazy_animation_order.erase(animation_name)
	lazy_animation_order.append(animation_name)


func _declared_animation_names(entry: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	var animations_value: Variant = entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	for animation_name in animations.keys():
		var text := str(animation_name)
		if not result.has(text):
			result.append(text)
	var fallback_value: Variant = entry.get("animationFallbacks", {})
	var fallbacks: Dictionary = fallback_value if fallback_value is Dictionary else {}
	for fallback_name in fallbacks.keys():
		var text := str(fallback_name)
		if not result.has(text):
			result.append(text)
	if result.has("idle") and not result.has("idle_neutral"):
		result.append("idle_neutral")
	elif result.has("idle_neutral") and not result.has("idle"):
		result.append("idle")
	return result


func _resolve_animation_source(entry: Dictionary, logical_name: String) -> String:
	var animations_value: Variant = entry.get("animations", {})
	var animations: Dictionary = animations_value if animations_value is Dictionary else {}
	if animations.has(logical_name):
		return logical_name
	var fallback_value: Variant = entry.get("animationFallbacks", {})
	var fallbacks: Dictionary = fallback_value if fallback_value is Dictionary else {}
	var current := logical_name
	var visited: Dictionary = {}
	for _index in range(16):
		if visited.has(current):
			break
		visited[current] = true
		if not fallbacks.has(current):
			break
		current = str(fallbacks[current])
		if animations.has(current):
			return current
	if logical_name == "idle" and animations.has("idle_neutral"):
		return "idle_neutral"
	if logical_name == "idle_neutral" and animations.has("idle"):
		return "idle"
	return ""


func _copy_animation_between(source_frames: SpriteFrames, target_frames: SpriteFrames, animation_name: StringName) -> void:
	if source_frames == null or target_frames == null or not source_frames.has_animation(animation_name):
		return
	if target_frames.has_animation(animation_name):
		target_frames.remove_animation(animation_name)
	target_frames.add_animation(animation_name)
	target_frames.set_animation_loop(animation_name, source_frames.get_animation_loop(animation_name))
	target_frames.set_animation_speed(animation_name, source_frames.get_animation_speed(animation_name))
	for index in range(source_frames.get_frame_count(animation_name)):
		target_frames.add_frame(animation_name, source_frames.get_frame_texture(animation_name, index))


func build_fallback_frames() -> SpriteFrames:
	var svg := """
<svg xmlns="http://www.w3.org/2000/svg" width="220" height="260" viewBox="0 0 220 260">
  <rect width="220" height="260" fill="none"/>
  <rect x="45" y="70" width="130" height="130" rx="28" fill="#539bea"/>
  <rect x="65" y="25" width="90" height="80" rx="24" fill="#75baff"/>
  <circle cx="91" cy="58" r="9" fill="#111827"/>
  <circle cx="129" cy="58" r="9" fill="#111827"/>
  <rect x="94" y="82" width="32" height="7" rx="3.5" fill="#111827"/>
  <rect x="22" y="92" width="28" height="95" rx="14" fill="#539bea"/>
  <rect x="170" y="92" width="28" height="95" rx="14" fill="#539bea"/>
  <rect x="58" y="190" width="42" height="55" rx="14" fill="#539bea"/>
  <rect x="120" y="190" width="42" height="55" rx="14" fill="#539bea"/>
  <circle cx="110" cy="135" r="20" fill="#b9dcff"/>
</svg>
"""
	var image := Image.new()
	var error: Error = image.load_svg_from_string(svg, 1.0)
	if error != OK:
		push_error("CharacterService: fallback SVG failed")
		return null

	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")

	for animation_name in [&"idle", &"idle_neutral", &"wave"]:
		frames.add_animation(animation_name)
		frames.set_animation_loop(animation_name, animation_name != &"wave")
		frames.set_animation_speed(animation_name, 2.0)
		frames.add_frame(animation_name, texture)

	context.update_character({
		"id": "runtime-v3-fallback",
		"name": "Runtime V3 Fallback",
		"version": "0.1.0",
		"scale": 0.7,
		"bubble_anchor": Vector2(0, -165),
		"hitbox": Rect2(22, 25, 176, 220),
		"animations": frames.get_animation_names(),
	})
	return frames


func _failure(message: String) -> Dictionary:
	var result := {"ok": false, "error": message}
	event_bus.publish(&"character.load_failed", result)
	return result


func _legacy_soul_profile_from_entry(entry: Dictionary) -> Dictionary:
	var presentation_value: Variant = entry.get("presentation", {})
	var presentation: Dictionary = presentation_value if presentation_value is Dictionary else {}
	var descriptions_value: Variant = presentation.get("descriptions", {})
	var descriptions_raw: Dictionary = descriptions_value if descriptions_value is Dictionary else {}
	var descriptions := {}
	for locale in ["en", "th"]:
		var text := str(descriptions_raw.get(locale, "")).strip_edges()
		if not text.is_empty():
			descriptions[locale] = text.left(1200)
	return {
		"schema": "soul/1",
		"mode": "legacy-description",
		"source": "character-presentation",
		"identity": {"name": str(entry.get("name", "OCP Companion")), "descriptions": descriptions},
		"traits": {
			"warmth": 0.65,
			"humor": 0.45,
			"formality": 0.45,
			"initiative": 0.5,
			"energy": 0.5,
			"talkativeness": 0.45,
			"movement": 0.5,
		},
		"speakingStyle": {"concise": true, "maxSentences": 3, "formality": 0.45, "humor": 0.45, "warmth": 0.65},
		"behavior": {"initiative": 0.5, "energy": 0.5, "movement": 0.5, "restSeconds": 20.0, "walkSeconds": 11.0, "hangSettleSeconds": 1.0},
	}


func _soul_profile_from_package(package_root: String, entry: Dictionary) -> Dictionary:
	var fallback := _legacy_soul_profile_from_entry(entry)
	var soul_path := package_root.path_join("assets").path_join("soul.json")
	if not FileAccess.file_exists(soul_path):
		return fallback
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(soul_path))
	if not (parsed is Dictionary):
		push_warning("CharacterService: invalid assets/soul.json; using presentation fallback")
		return fallback
	var raw: Dictionary = parsed
	if str(raw.get("schema", "")) != "soul/1":
		push_warning("CharacterService: unsupported Soul schema; using presentation fallback")
		return fallback

	var fallback_identity: Dictionary = fallback.get("identity", {})
	var identity_value: Variant = raw.get("identity", {})
	var identity_raw: Dictionary = identity_value if identity_value is Dictionary else {}
	var descriptions_value: Variant = identity_raw.get("descriptions", fallback_identity.get("descriptions", {}))
	var descriptions_raw: Dictionary = descriptions_value if descriptions_value is Dictionary else {}
	var descriptions := {}
	for locale in ["en", "th"]:
		var text := str(descriptions_raw.get(locale, "")).strip_edges()
		if not text.is_empty():
			descriptions[locale] = text.left(1200)

	var traits_value: Variant = raw.get("traits", {})
	var traits_raw: Dictionary = traits_value if traits_value is Dictionary else {}
	var traits := {
		"warmth": clampf(float(traits_raw.get("warmth", 0.65)), 0.0, 1.0),
		"humor": clampf(float(traits_raw.get("humor", 0.45)), 0.0, 1.0),
		"formality": clampf(float(traits_raw.get("formality", 0.45)), 0.0, 1.0),
		"initiative": clampf(float(traits_raw.get("initiative", 0.5)), 0.0, 1.0),
		"energy": clampf(float(traits_raw.get("energy", 0.5)), 0.0, 1.0),
		"talkativeness": clampf(float(traits_raw.get("talkativeness", 0.45)), 0.0, 1.0),
		"movement": clampf(float(traits_raw.get("movement", 0.5)), 0.0, 1.0),
	}
	var speaking_value: Variant = raw.get("speakingStyle", {})
	var speaking_raw: Dictionary = speaking_value if speaking_value is Dictionary else {}
	var behavior_value: Variant = raw.get("behavior", {})
	var behavior_raw: Dictionary = behavior_value if behavior_value is Dictionary else {}
	return {
		"schema": "soul/1",
		"mode": str(raw.get("mode", "auto")),
		"source": str(raw.get("source", "package")),
		"customText": str(raw.get("customText", "")).strip_edges().left(2400),
		"identity": {
			"name": str(identity_raw.get("name", entry.get("name", "OCP Companion"))).strip_edges().left(160),
			"descriptions": descriptions,
		},
		"traits": traits,
		"speakingStyle": {
			"concise": bool(speaking_raw.get("concise", true)),
			"maxSentences": clampi(int(speaking_raw.get("maxSentences", 3)), 1, 6),
			"formality": clampf(float(speaking_raw.get("formality", traits.get("formality", 0.45))), 0.0, 1.0),
			"humor": clampf(float(speaking_raw.get("humor", traits.get("humor", 0.45))), 0.0, 1.0),
			"warmth": clampf(float(speaking_raw.get("warmth", traits.get("warmth", 0.65))), 0.0, 1.0),
		},
		"behavior": {
			"initiative": clampf(float(behavior_raw.get("initiative", traits.get("initiative", 0.5))), 0.0, 1.0),
			"energy": clampf(float(behavior_raw.get("energy", traits.get("energy", 0.5))), 0.0, 1.0),
			"movement": clampf(float(behavior_raw.get("movement", traits.get("movement", 0.5))), 0.0, 1.0),
			"restSeconds": clampf(float(behavior_raw.get("restSeconds", 20.0)), 8.0, 45.0),
			"walkSeconds": clampf(float(behavior_raw.get("walkSeconds", 11.0)), 5.0, 20.0),
			"hangSettleSeconds": clampf(float(behavior_raw.get("hangSettleSeconds", 1.0)), 0.4, 2.0),
		},
	}


func _voice_profile_from_entry(entry: Dictionary) -> Dictionary:
	if str(entry.get("schema", "")) != "character/3":
		return {"gender": "neutral", "age": "adult", "thaiSpeechStyle": "neutral"}
	var raw: Variant = entry.get("voiceProfile", {})
	var profile: Dictionary = raw if raw is Dictionary else {}
	var gender := str(profile.get("presentation", "neutral")).strip_edges().to_lower()
	var age := str(profile.get("age", "adult")).strip_edges().to_lower()
	var thai_style := str(profile.get("thaiSpeechStyle", "neutral")).strip_edges().to_lower()
	if gender not in ["female", "male", "neutral"]:
		gender = "neutral"
	if age not in ["child", "adult"]:
		age = "adult"
	if thai_style not in ["feminine", "masculine", "neutral"]:
		thai_style = "neutral"
	return {"gender": gender, "age": age, "thaiSpeechStyle": thai_style}


func _copy_animation(frames: SpriteFrames, source: StringName, target: StringName) -> void:
	frames.add_animation(target)
	frames.set_animation_loop(target, frames.get_animation_loop(source))
	frames.set_animation_speed(target, frames.get_animation_speed(source))
	for index in range(frames.get_frame_count(source)):
		frames.add_frame(target, frames.get_frame_texture(source, index))


func _vector2_from(value: Variant, fallback: Vector2) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


func _vector2i_from(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback


func _rect2_from(value: Variant, fallback: Rect2) -> Rect2:
	if value is Array and value.size() >= 4:
		return Rect2(float(value[0]), float(value[1]), float(value[2]), float(value[3]))
	return fallback
