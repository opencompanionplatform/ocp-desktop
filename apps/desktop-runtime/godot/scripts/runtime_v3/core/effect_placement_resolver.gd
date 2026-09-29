extends RefCounted
class_name RuntimeV3EffectPlacementResolver

static func default_scale_mode(slot_name: String) -> String:
	return "character-width" if slot_name == "groundRune" else "character-height"


static func default_scale(slot_name: String) -> float:
	if slot_name == "groundRune":
		return 1.40
	if slot_name == "levelUpBurst":
		return 1.10
	return 1.12


static func default_anchor(slot_name: String) -> String:
	if slot_name == "groundRune":
		return "character-feet"
	if slot_name == "levelUpBurst":
		return "character-feet-bottom"
	return "character-center"


static func default_z(slot_name: String) -> int:
	if slot_name == "groundRune":
		return -20
	if slot_name == "levelUpBurst":
		return 20
	return -10


static func infer_content_bounds(
	image: Image,
	frame_width: int,
	frame_height: int,
	columns: int,
	frame_count: int
) -> Rect2i:
	if image == null or image.is_empty() or frame_width <= 0 or frame_height <= 0 or columns <= 0 or frame_count <= 0:
		return Rect2i()
	var merged := Rect2i()
	for index in range(frame_count):
		var row := floori(float(index) / float(columns))
		var region_rect := Rect2i(
			(index % columns) * frame_width,
			row * frame_height,
			frame_width,
			frame_height
		).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		if region_rect.size.x <= 0 or region_rect.size.y <= 0:
			continue
		var region := image.get_region(region_rect)
		if region == null or region.is_empty():
			continue
		var used := region.get_used_rect()
		if used.size == Vector2i.ZERO:
			continue
		merged = used if merged.size == Vector2i.ZERO else merged.merge(used)
	return merged


static func anchor_position(character_rect: Rect2, anchor_mode: String, slot_name: String) -> Vector2:
	match anchor_mode:
		"character-feet", "character-feet-bottom":
			return Vector2(character_rect.get_center().x, character_rect.end.y)
		"character-above-head":
			return Vector2(character_rect.get_center().x, character_rect.position.y)
		"character-center":
			return character_rect.get_center()
		_:
			if slot_name == "groundRune":
				return Vector2(character_rect.get_center().x, character_rect.end.y)
			return character_rect.get_center()


static func resolve(
	slot_name: String,
	config: Dictionary,
	character_rect: Rect2,
	content_rect: Rect2,
	frame_size: Vector2,
	surface_size: Vector2,
	offset_scale: float = 1.0
) -> Dictionary:
	var safe_character_rect := Rect2(
		character_rect.position,
		Vector2(maxf(1.0, character_rect.size.x), maxf(1.0, character_rect.size.y))
	)
	var content_size := Vector2(maxf(1.0, content_rect.size.x), maxf(1.0, content_rect.size.y))
	var safe_surface := Vector2(maxf(1.0, surface_size.x), maxf(1.0, surface_size.y))
	var scale_mode := str(config.get("scaleMode", default_scale_mode(slot_name)))
	var authored_scale := clampf(float(config.get("scale", default_scale(slot_name))), 0.1, 4.0)
	var uniform_scale := 1.0
	match scale_mode:
		"character-width":
			uniform_scale = safe_character_rect.size.x * authored_scale / content_size.x
		"character-height":
			uniform_scale = safe_character_rect.size.y * authored_scale / content_size.y
		_:
			uniform_scale = minf(safe_surface.x, safe_surface.y) * authored_scale / maxf(content_size.x, content_size.y)

	var scale_vector := Vector2(uniform_scale, uniform_scale)
	var max_height_ratio := float(config.get("maxHeightRatio", 0.32 if slot_name == "groundRune" else 0.0))
	if slot_name == "groundRune" and max_height_ratio > 0.0:
		var max_height := safe_character_rect.size.y * clampf(max_height_ratio, 0.1, 3.0)
		scale_vector.y = minf(scale_vector.y, max_height / content_size.y)

	var anchor_mode := str(config.get("anchor", default_anchor(slot_name)))
	var anchor := anchor_position(safe_character_rect, anchor_mode, slot_name)
	var default_offset_y := 0.0 if slot_name in ["groundRune", "levelUpBurst"] else -6.0
	var user_offset := Vector2(
		float(config.get("offsetX", 0.0)),
		float(config.get("offsetY", default_offset_y))
	) * maxf(0.0, offset_scale)
	var content_half := Vector2(content_size.x * scale_vector.x, content_size.y * scale_vector.y) * 0.5
	var content_center := anchor + user_offset
	if anchor_mode == "character-feet-bottom":
		content_center.y -= content_half.y

	var safe_margin := 4.0 if slot_name == "groundRune" else 2.0
	var available_width := maxf(0.0, safe_surface.x - safe_margin * 2.0)
	var available_height := maxf(0.0, safe_surface.y - safe_margin * 2.0)
	if content_half.x * 2.0 <= available_width:
		content_center.x = clampf(content_center.x, content_half.x + safe_margin, safe_surface.x - content_half.x - safe_margin)
	if content_half.y * 2.0 <= available_height and slot_name != "groundRune":
		content_center.y = clampf(content_center.y, content_half.y + safe_margin, safe_surface.y - content_half.y - safe_margin)

	var safe_frame_size := Vector2(maxf(1.0, frame_size.x), maxf(1.0, frame_size.y))
	var content_center_offset := content_rect.position + content_rect.size * 0.5 - safe_frame_size * 0.5
	var effect_position := content_center - Vector2(
		content_center_offset.x * scale_vector.x,
		content_center_offset.y * scale_vector.y
	)
	return {
		"scale": scale_vector,
		"position": effect_position,
		"anchor": anchor,
		"contentCenter": content_center,
		"contentHalf": content_half,
		"z": int(config.get("zIndex", default_z(slot_name))),
	}
