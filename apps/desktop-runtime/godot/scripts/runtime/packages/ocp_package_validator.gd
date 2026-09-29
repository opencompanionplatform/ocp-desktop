extends RefCounted
class_name OcpPackageValidator
## Validates manifest metadata, declared assets, hashes and character entry.

const ZipPathUtil = preload("res://scripts/runtime/packages/ocp_zip_path_util.gd")

const ERR_OK := 0
const ERR_READ_RESULT := 1
const ERR_MANIFEST := 2
const ERR_ENTRY := 3
const ERR_ASSET := 4
const ERR_HASH := 5
const ERR_SECURITY := 6


class ValidationResult:
	var ok: bool = false
	var error_code: int = ERR_OK
	var error_message: String = ""
	var warnings: PackedStringArray = PackedStringArray()
	var resolved_assets: Dictionary = {}


func validate(read_result: Object) -> ValidationResult:
	var result := ValidationResult.new()

	if read_result == null \
	or not bool(read_result.get("ok")):
		return _fail(
			result,
			ERR_READ_RESULT,
			"Package has not been read successfully"
		)

	var zip: ZIPReader = read_result.zip
	var manifest: Dictionary = read_result.manifest
	var entry: Dictionary = read_result.entry

	if zip == null:
		return _fail(
			result,
			ERR_READ_RESULT,
			"ZIPReader is closed"
		)

	var package_id: String = str(
		manifest.get("packageId", manifest.get("id", ""))
	).strip_edges()
	var version: String = str(
		manifest.get("version", "")
	).strip_edges()
	var package_type: String = str(
		manifest.get("type", "")
	).strip_edges()
	var entry_path: String = str(
		manifest.get("entry", "")
	).strip_edges()

	if package_id.is_empty():
		return _fail(
			result,
			ERR_MANIFEST,
			"Manifest package id is missing"
		)

	if version.is_empty():
		return _fail(
			result,
			ERR_MANIFEST,
			"Manifest version is missing"
		)

	if not package_type.is_empty() and package_type not in ["character", "effect-pack"]:
		return _fail(
			result,
			ERR_MANIFEST,
			"Unsupported package type: %s" % package_type
		)

	if entry_path.is_empty() \
	or not ZipPathUtil.is_safe_relative_path(entry_path):
		return _fail(
			result,
			ERR_SECURITY,
			"Invalid or unsafe manifest entry: %s" % entry_path
		)

	var resolved_entry: String = ZipPathUtil.resolve_from_zip(
		zip,
		entry_path
	)
	if resolved_entry.is_empty():
		return _fail(
			result,
			ERR_ENTRY,
			"Entry file not found in package: '%s'" % entry_path
		)

	result.resolved_assets[
		ZipPathUtil.normalize(entry_path)
	] = resolved_entry

	var assets_value: Variant = manifest.get("assets", [])
	if not assets_value is Array:
		return _fail(
			result,
			ERR_MANIFEST,
			"Manifest assets must be an array"
		)

	var assets: Array = assets_value

	for asset_value in assets:
		if not asset_value is Dictionary:
			return _fail(
				result,
				ERR_MANIFEST,
				"Manifest asset entry must be an object"
			)

		var asset: Dictionary = asset_value
		var requested_path: String = str(
			asset.get("path", "")
		).strip_edges()

		if requested_path.is_empty() \
		or not ZipPathUtil.is_safe_relative_path(requested_path):
			return _fail(
				result,
				ERR_SECURITY,
				"Invalid or unsafe asset path: '%s'"
				% requested_path
			)

		var actual_path: String = ZipPathUtil.resolve_from_zip(
			zip,
			requested_path
		)

		if actual_path.is_empty():
			return _fail(
				result,
				ERR_ASSET,
				"Asset file not found in package: '%s'"
				% requested_path
			)

		result.resolved_assets[
			ZipPathUtil.normalize(requested_path)
		] = actual_path

		var expected_hash: String = str(
			asset.get("sha256", "")
		).strip_edges().to_lower()

		if expected_hash.is_empty():
			result.warnings.append(
				"Asset has no SHA-256: %s" % requested_path
			)
			continue

		var data: PackedByteArray = zip.read_file(actual_path)
		var actual_hash: String = _sha256(data)

		if actual_hash != expected_hash:
			return _fail(
				result,
				ERR_HASH,
				"SHA-256 mismatch for '%s': expected %s, actual %s"
				% [
					requested_path,
					expected_hash,
					actual_hash,
				]
			)

	var entry_error := ""
	if package_type == "effect-pack":
		entry_error = _validate_effect_pack_entry(entry, zip, result, package_id, version)
	else:
		entry_error = _validate_character_entry(entry, zip, result)
	if not entry_error.is_empty():
		return _fail(
			result,
			ERR_ENTRY,
			entry_error
		)

	result.ok = true

	print(
		"OcpPackageValidator: validated '%s@%s' (%d assets)"
		% [package_id, version, assets.size()]
	)
	return result


func _validate_character_entry(
	entry: Dictionary,
	zip: ZIPReader,
	result: ValidationResult
) -> String:
	var renderer: String = str(
		entry.get("renderer", "")
	)

	if not renderer.is_empty() \
	and renderer != "sprite-sheet-2d":
		return "Unsupported character renderer: %s" % renderer

	var sprites_value: Variant = entry.get("sprites", [])
	if not sprites_value is Array:
		return "Character sprites must be an array"

	var sprites: Array = sprites_value
	if sprites.is_empty():
		return "Character package has no sprites"

	var sprite_ids: Dictionary = {}

	for sprite_value in sprites:
		if not sprite_value is Dictionary:
			return "Character sprite definition must be an object"

		var sprite: Dictionary = sprite_value
		var sprite_id: String = str(
			sprite.get("id", "")
		).strip_edges()
		var sprite_path: String = str(
			sprite.get("path", "")
		).strip_edges()

		if sprite_id.is_empty():
			return "Character sprite id is missing"

		if sprite_ids.has(sprite_id):
			return "Duplicate character sprite id: %s" % sprite_id

		sprite_ids[sprite_id] = true

		if sprite_path.is_empty() \
		or not ZipPathUtil.is_safe_relative_path(sprite_path):
			return "Invalid sprite path: %s" % sprite_path

		var actual_sprite_path: String = (
			ZipPathUtil.resolve_from_zip(zip, sprite_path)
		)

		if actual_sprite_path.is_empty():
			return "Sprite file not found in package: '%s'" \
				% sprite_path

		result.resolved_assets[
			ZipPathUtil.normalize(sprite_path)
		] = actual_sprite_path

		var frame_size: Variant = sprite.get("frameSize", [])
		if not frame_size is Array \
		or frame_size.size() < 2 \
		or int(frame_size[0]) <= 0 \
		or int(frame_size[1]) <= 0:
			return "Invalid frameSize for sprite '%s'" % sprite_id

	var animations_value: Variant = entry.get("animations", {})
	if not animations_value is Dictionary:
		return "Character animations must be an object"

	var animations: Dictionary = animations_value
	for animation_name in animations:
		var animation_value: Variant = animations[animation_name]

		if not animation_value is Dictionary:
			return "Animation '%s' must be an object" \
				% animation_name

		var animation: Dictionary = animation_value
		var sprite_id: String = str(
			animation.get("sprite", "")
		)

		if not sprite_id.is_empty() \
		and not sprite_ids.has(sprite_id):
			return (
				"Animation '%s' references unknown sprite '%s'"
				% [animation_name, sprite_id]
			)

		var frames_value: Variant = animation.get("frames", [])
		if not frames_value is Array \
		or frames_value.is_empty():
			return "Animation '%s' has no frames" \
				% animation_name

	return ""


func _validate_effect_pack_entry(
	entry: Dictionary,
	zip: ZIPReader,
	result: ValidationResult,
	package_id: String,
	version: String
) -> String:
	if str(entry.get("schemaVersion", "")) != "1.0":
		return "Unsupported effect-pack schemaVersion"
	if str(entry.get("id", "")) != package_id or str(entry.get("version", "")) != version:
		return "Effect-pack entry identity does not match manifest"
	var name := str(entry.get("name", "")).strip_edges()
	if name.is_empty() or name.length() > 120:
		return "Effect-pack name is invalid"

	var slots_value: Variant = entry.get("slots", {})
	if not slots_value is Dictionary:
		return "Effect-pack slots must be an object"
	var slots: Dictionary = slots_value
	var supported_slots := ["bodyAura", "groundRune", "levelUpBurst"]
	var defined := 0
	for slot_name in slots.keys():
		if str(slot_name) not in supported_slots:
			return "Unsupported effect-pack slot: %s" % slot_name
		var slot_value: Variant = slots.get(slot_name)
		if not slot_value is Dictionary:
			return "Effect-pack slot '%s' must be an object" % slot_name
		defined += 1
		var slot_error := _validate_effect_pack_slot(str(slot_name), slot_value as Dictionary, zip, result)
		if not slot_error.is_empty():
			return slot_error
	if defined == 0:
		return "Effect-pack must define at least one slot"

	var progression_value: Variant = entry.get("progression", null)
	if progression_value != null:
		if not progression_value is Dictionary:
			return "Effect-pack progression must be an object"
		var progression := progression_value as Dictionary
		var mode := str(progression.get("mode", "none"))
		if mode not in ["none", "level", "bond-rank", "level-and-bond"]:
			return "Unsupported effect-pack progression mode"
		var variants_value: Variant = progression.get("variants", [])
		if not variants_value is Array or (variants_value as Array).size() > 16:
			return "Effect-pack progression variants are invalid"
		var variants := variants_value as Array
		if mode == "none" and not variants.is_empty():
			return "Effect-pack progression mode 'none' cannot define variants"
		if mode != "none" and variants.is_empty():
			return "Effect-pack progression mode '%s' requires at least one variant" % mode
		var previous_level := 0
		for variant_value in variants:
			if not variant_value is Dictionary:
				return "Effect-pack progression variant must be an object"
			var variant := variant_value as Dictionary
			var min_level := int(variant.get("minLevel", 0))
			if min_level < 1 or min_level > 200 or min_level < previous_level:
				return "Effect-pack progression minLevel is invalid"
			previous_level = min_level
			if str(variant.get("minBondRank", "")) not in ["stranger", "friend", "close-friend", "partner", "best-companion"]:
				return "Effect-pack progression bond rank is invalid"
			var overrides_value: Variant = variant.get("slotOverrides", {})
			if not overrides_value is Dictionary:
				return "Effect-pack progression slotOverrides must be an object"
			for override_name in (overrides_value as Dictionary).keys():
				if str(override_name) not in supported_slots:
					return "Effect-pack progression references unknown slot"
				var override_value: Variant = (overrides_value as Dictionary).get(override_name)
				if not override_value is Dictionary:
					return "Effect-pack progression slot override must be an object"
				if override_value.has("tint") and not _is_effect_color(str(override_value.get("tint", ""))):
					return "Effect-pack progression tint is invalid"
				if override_value.has("intensity"):
					var intensity := int(override_value.get("intensity", -1))
					if intensity < 0 or intensity > 100:
						return "Effect-pack progression intensity is invalid"
	return ""


func _validate_effect_pack_slot(
	slot_name: String,
	slot: Dictionary,
	zip: ZIPReader,
	result: ValidationResult
) -> String:
	var renderer := str(slot.get("renderer", ""))
	if renderer not in ["procedural-rings-v1", "sprite-sheet-2d"]:
		return "Unsupported effect-pack renderer in '%s'" % slot_name
	if str(slot.get("anchor", "")) not in ["character-center", "character-feet", "character-feet-bottom", "character-above-head"]:
		return "Invalid effect-pack anchor in '%s'" % slot_name
	if str(slot.get("layer", "")) not in ["front-fx", "back-aura", "ground-rune"]:
		return "Invalid effect-pack layer in '%s'" % slot_name
	var fps := int(slot.get("fps", 0))
	var duration_ms := int(slot.get("durationMs", 0))
	var intensity := int(slot.get("intensity", -1))
	var speed_permille := int(slot.get("speedPermille", 0))
	if fps < 1 or fps > 60 or duration_ms < 100 or duration_ms > 30000:
		return "Invalid effect-pack timing in '%s'" % slot_name
	if intensity < 0 or intensity > 100 or speed_permille < 100 or speed_permille > 3000:
		return "Invalid effect-pack style in '%s'" % slot_name
	if not _is_effect_color(str(slot.get("tint", ""))):
		return "Invalid effect-pack tint in '%s'" % slot_name
	if slot.has("scaleMode") and str(slot.get("scaleMode", "")) not in ["character-width", "character-height", "native-surface"]:
		return "Invalid effect-pack scale mode in '%s'" % slot_name
	if slot.has("scale") and (float(slot.get("scale", 0.0)) < 0.1 or float(slot.get("scale", 0.0)) > 4.0):
		return "Invalid effect-pack scale in '%s'" % slot_name
	if slot.has("offsetX") and absf(float(slot.get("offsetX", 0.0))) > 512.0:
		return "Invalid effect-pack X offset in '%s'" % slot_name
	if slot.has("offsetY") and absf(float(slot.get("offsetY", 0.0))) > 512.0:
		return "Invalid effect-pack Y offset in '%s'" % slot_name
	if slot.has("zIndex") and (int(slot.get("zIndex", 0)) < -100 or int(slot.get("zIndex", 0)) > 100):
		return "Invalid effect-pack z-index in '%s'" % slot_name
	if slot.has("maxHeightRatio") and (float(slot.get("maxHeightRatio", 0.0)) < 0.1 or float(slot.get("maxHeightRatio", 0.0)) > 3.0):
		return "Invalid effect-pack max-height ratio in '%s'" % slot_name

	if renderer == "procedural-rings-v1":
		if str(slot.get("preset", "")) not in ["halo", "rune", "burst"]:
			return "Unsupported effect-pack preset in '%s'" % slot_name
		if slot.has("asset") or slot.has("frameWidth") or slot.has("frameHeight") or slot.has("frameCount"):
			return "Procedural effect slot '%s' cannot declare sprite fields" % slot_name
		return ""

	var asset_path := str(slot.get("asset", "")).strip_edges()
	if asset_path.is_empty() or not ZipPathUtil.is_safe_relative_path(asset_path):
		return "Invalid effect-pack sprite asset in '%s'" % slot_name
	var actual_path := ZipPathUtil.resolve_from_zip(zip, asset_path)
	if actual_path.is_empty():
		return "Effect-pack sprite asset not found: '%s'" % asset_path
	result.resolved_assets[ZipPathUtil.normalize(asset_path)] = actual_path
	var frame_width := int(slot.get("frameWidth", 0))
	var frame_height := int(slot.get("frameHeight", 0))
	var frame_count := int(slot.get("frameCount", 0))
	if frame_width < 1 or frame_width > 2048 or frame_height < 1 or frame_height > 2048 or frame_count < 1 or frame_count > 120:
		return "Invalid effect-pack sprite frame metadata in '%s'" % slot_name
	# Bound worst-case decoded source pressure before Runtime performs its own
	# 32 MiB atlas downscale. This prevents metadata that could imply multi-GB
	# RGBA allocations even when each individual frame is within limits.
	var authored_rgba_bytes := int(frame_width) * int(frame_height) * int(frame_count) * 4
	if authored_rgba_bytes > 256 * 1024 * 1024:
		return "Effect-pack sprite source exceeds decoded memory budget in '%s'" % slot_name
	if slot.has("contentBounds"):
		var bounds_value: Variant = slot.get("contentBounds", {})
		if not bounds_value is Dictionary:
			return "Invalid effect-pack content bounds in '%s'" % slot_name
		var bounds := bounds_value as Dictionary
		if bounds.size() != 4 or not bounds.has("x") or not bounds.has("y") or not bounds.has("width") or not bounds.has("height"):
			return "Invalid effect-pack content bounds in '%s'" % slot_name
		var bx := int(bounds.get("x", -1))
		var by := int(bounds.get("y", -1))
		var bw := int(bounds.get("width", 0))
		var bh := int(bounds.get("height", 0))
		if bx < 0 or by < 0 or bw < 1 or bh < 1 or bx + bw > frame_width or by + bh > frame_height:
			return "Effect-pack content bounds exceed frame in '%s'" % slot_name
	return ""


func _is_effect_color(value: String) -> bool:
	if value.length() not in [7, 9] or not value.begins_with("#"):
		return false
	for index in range(1, value.length()):
		var code := value.unicode_at(index)
		var is_digit := code >= 48 and code <= 57
		var is_lower := code >= 97 and code <= 102
		var is_upper := code >= 65 and code <= 70
		if not (is_digit or is_lower or is_upper):
			return false
	return true


func _sha256(data: PackedByteArray) -> String:
	var context := HashingContext.new()
	var start_error: Error = context.start(
		HashingContext.HASH_SHA256
	)

	if start_error != OK:
		return ""

	var update_error: Error = context.update(data)
	if update_error != OK:
		return ""

	return context.finish().hex_encode()


func _fail(
	result: ValidationResult,
	code: int,
	message: String
) -> ValidationResult:
	result.ok = false
	result.error_code = code
	result.error_message = message
	push_warning("OcpPackageValidator: " + message)
	return result
