extends SceneTree

func _initialize() -> void:
	var points := PackedVector2Array([
		Vector2(100, 100), Vector2(300, 100), Vector2(300, 300), Vector2(100, 300),
		Vector2(500, 120), Vector2(700, 120), Vector2(700, 280), Vector2(500, 280),
	])
	var hull: PackedVector2Array = Geometry2D.convex_hull(points)

	if hull.size() < 4:
		push_error("[FAIL] click-through convex hull")
		quit(1)
		return

	# Convex hull must enclose representative centers of both islands.
	if not Geometry2D.is_point_in_polygon(Vector2(200, 200), hull):
		push_error("[FAIL] hull excludes character island")
		quit(1)
		return
	if not Geometry2D.is_point_in_polygon(Vector2(600, 200), hull):
		push_error("[FAIL] hull excludes menu island")
		quit(1)
		return

	print("[PASS] click-through convex hull")
	quit(0)
