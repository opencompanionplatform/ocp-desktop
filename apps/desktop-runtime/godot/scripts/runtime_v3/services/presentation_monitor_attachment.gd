extends RefCounted
class_name RuntimeV3PresentationMonitorAttachment
## Hybrid presentation boundary.
##
## Physics remains in canonical desktop coordinates. This value object only
## maps a companion into the currently attached monitor's local canvas.

var descriptor: Dictionary = {}


func attach(next_descriptor: Dictionary) -> bool:
	var screen_index := int(next_descriptor.get("screen", -1))
	var logical: Rect2 = next_descriptor.get("logical", Rect2())
	var physical: Rect2 = next_descriptor.get("physical", Rect2())
	if screen_index < 0 or logical.size == Vector2.ZERO or physical.size == Vector2.ZERO:
		return false

	var changed := int(descriptor.get("screen", -1)) != screen_index
	descriptor = next_descriptor.duplicate(true)
	return changed


func detach() -> void:
	descriptor.clear()


func is_attached() -> bool:
	return not descriptor.is_empty()


func screen_index() -> int:
	return int(descriptor.get("screen", -1))


func desktop_to_local(desktop_point: Vector2) -> Vector2:
	if not is_attached():
		return desktop_point
	var logical: Rect2 = descriptor.get("logical", Rect2())
	var physical: Rect2 = descriptor.get("physical", Rect2())
	var normalized := Vector2(
		_ratio(desktop_point.x - logical.position.x, logical.size.x),
		_ratio(desktop_point.y - logical.position.y, logical.size.y)
	)
	return normalized * physical.size


func local_to_desktop(local_point: Vector2) -> Vector2:
	if not is_attached():
		return local_point
	var logical: Rect2 = descriptor.get("logical", Rect2())
	var physical: Rect2 = descriptor.get("physical", Rect2())
	var normalized := Vector2(
		_ratio(local_point.x, physical.size.x),
		_ratio(local_point.y, physical.size.y)
	)
	return logical.position + normalized * logical.size


func clamp_desktop_point(desktop_point: Vector2) -> Vector2:
	if not is_attached():
		return desktop_point
	var logical: Rect2 = descriptor.get("logical", Rect2())
	return Vector2(
		clampf(desktop_point.x, logical.position.x, logical.end.x),
		clampf(desktop_point.y, logical.position.y, logical.end.y)
	)


func _ratio(value: float, extent: float) -> float:
	return clampf(value / maxf(extent, 0.001), 0.0, 1.0)
