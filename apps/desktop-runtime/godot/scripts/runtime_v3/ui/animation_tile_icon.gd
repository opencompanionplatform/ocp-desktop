extends Control
class_name RuntimeV3AnimationTileIcon

## Dependency-free semantic icons for every animation supplied by a package.
## They are intentionally drawn at runtime so a package with extra clips still
## receives a coherent fallback icon without shipping a second icon atlas.

const INK := Color("#dbeaff")
const CYAN := Color("#2bceff")
const VIOLET := Color("#9b6cff")

var animation_name := "":
	set(value):
		animation_name = value
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _draw() -> void:
	if size.x < 8.0 or size.y < 8.0:
		return
	var key := animation_name.to_lower()
	var center := Vector2(size.x * 0.5, size.y * 0.49)
	if key.contains("climb"):
		_draw_climb(center, key)
	elif key.contains("hang"):
		_draw_hang(center)
	elif key.contains("fall"):
		_draw_fall(center)
	elif key.contains("walk") or key.contains("move"):
		_draw_walk(center, -1.0 if key.contains("left") else 1.0)
	elif key.contains("jump"):
		_draw_jump(center)
	elif key.contains("land"):
		_draw_land(center)
	elif key.contains("appear") or key.contains("wake"):
		_draw_transition(center, 1.0)
	elif key.contains("disappear") or key.contains("sleep"):
		_draw_transition(center, -1.0)
	elif key.contains("speak"):
		_draw_speak(center)
	elif key.contains("think"):
		_draw_think(center)
	elif key.contains("angry"):
		_draw_face(center, -1.0)
	elif key.contains("happy"):
		_draw_face(center, 1.0)
	elif key.contains("sad"):
		_draw_face(center, 0.0)
	elif key.contains("surprised"):
		_draw_surprised(center)
	elif key.contains("sit"):
		_draw_sit(center)
	else:
		_draw_idle(center)


func _draw_person(center: Vector2, lean := 0.0, arm_pose := 0.0) -> void:
	var head := center + Vector2(lean * 2.0, -12.0)
	draw_circle(head, 5.0, INK)
	var neck := head + Vector2(0.0, 6.0)
	var hip := center + Vector2(lean * 4.0, 10.0)
	draw_line(neck, hip, INK, 2.5, true)
	draw_line(neck + Vector2(-1.0, 3.0), neck + Vector2(-9.0, 7.0 + arm_pose), CYAN, 2.3, true)
	draw_line(neck + Vector2(1.0, 3.0), neck + Vector2(9.0, 7.0 - arm_pose), CYAN, 2.3, true)
	draw_line(hip, hip + Vector2(-6.0, 11.0), INK, 2.5, true)
	draw_line(hip, hip + Vector2(6.0, 11.0), INK, 2.5, true)


func _draw_idle(center: Vector2) -> void:
	_draw_person(center)
	draw_line(center + Vector2(-14.0, 22.0), center + Vector2(14.0, 22.0), Color(CYAN, 0.72), 1.5, true)


func _draw_walk(center: Vector2, direction: float) -> void:
	_draw_person(center + Vector2(-direction * 2.0, 0.0), direction * 0.45, 3.0)
	var start := center + Vector2(-direction * 15.0, 21.0)
	var end := center + Vector2(direction * 15.0, 21.0)
	draw_line(start, end, CYAN, 2.0, true)
	draw_line(end, end + Vector2(-direction * 5.0, -4.0), CYAN, 2.0, true)
	draw_line(end, end + Vector2(-direction * 5.0, 4.0), CYAN, 2.0, true)


func _draw_climb(center: Vector2, key: String) -> void:
	var x := center.x + 10.0
	draw_line(Vector2(x, 4.0), Vector2(x, size.y - 3.0), VIOLET, 2.4, true)
	for y in range(9, int(size.y - 4), 8):
		draw_line(Vector2(x - 5.0, float(y)), Vector2(x + 5.0, float(y)), Color(CYAN, 0.86), 1.6, true)
	_draw_person(center + Vector2(-5.0, 2.0), -0.45, -4.0 if key.contains("up") else 4.0)


func _draw_hang(center: Vector2) -> void:
	draw_line(center + Vector2(-17.0, -16.0), center + Vector2(17.0, -16.0), VIOLET, 2.6, true)
	draw_circle(center + Vector2(0.0, -7.0), 4.4, INK)
	draw_line(center + Vector2(-5.0, -13.0), center + Vector2(-4.0, 0.0), CYAN, 2.3, true)
	draw_line(center + Vector2(5.0, -13.0), center + Vector2(4.0, 0.0), CYAN, 2.3, true)
	draw_line(center + Vector2(0.0, -2.0), center + Vector2(0.0, 10.0), INK, 2.4, true)
	draw_line(center + Vector2(0.0, 9.0), center + Vector2(-6.0, 18.0), INK, 2.2, true)
	draw_line(center + Vector2(0.0, 9.0), center + Vector2(6.0, 18.0), INK, 2.2, true)


func _draw_fall(center: Vector2) -> void:
	_draw_person(center + Vector2(-4.0, -1.0), -0.75, 5.0)
	var top := center + Vector2(17.0, -16.0)
	var bottom := center + Vector2(17.0, 17.0)
	draw_line(top, bottom, VIOLET, 2.2, true)
	draw_line(bottom, bottom + Vector2(-4.0, -6.0), VIOLET, 2.2, true)
	draw_line(bottom, bottom + Vector2(4.0, -6.0), VIOLET, 2.2, true)


func _draw_jump(center: Vector2) -> void:
	_draw_person(center + Vector2(0.0, -3.0), 0.0, -5.0)
	var bottom := center + Vector2(17.0, 17.0)
	var top := center + Vector2(17.0, -15.0)
	draw_line(bottom, top, CYAN, 2.2, true)
	draw_line(top, top + Vector2(-4.0, 6.0), CYAN, 2.2, true)
	draw_line(top, top + Vector2(4.0, 6.0), CYAN, 2.2, true)


func _draw_land(center: Vector2) -> void:
	_draw_person(center + Vector2(0.0, 2.0), 0.0, 5.0)
	draw_line(center + Vector2(-18.0, 21.0), center + Vector2(18.0, 21.0), CYAN, 2.0, true)
	draw_line(center + Vector2(-14.0, 16.0), center + Vector2(-8.0, 20.0), VIOLET, 1.6, true)
	draw_line(center + Vector2(14.0, 16.0), center + Vector2(8.0, 20.0), VIOLET, 1.6, true)


func _draw_transition(center: Vector2, direction: float) -> void:
	for index in range(3):
		var radius := 5.0 + index * 5.0
		var color := CYAN.lerp(VIOLET, float(index) * 0.5)
		color.a = 0.9 - index * 0.22
		draw_arc(center, radius, 0.0, TAU, 24, color, 1.6, true)
	var origin := center + Vector2(-direction * 14.0, 0.0)
	var target := center + Vector2(direction * 14.0, 0.0)
	draw_line(origin, target, INK, 2.1, true)
	draw_line(target, target + Vector2(-direction * 5.0, -5.0), INK, 2.1, true)
	draw_line(target, target + Vector2(-direction * 5.0, 5.0), INK, 2.1, true)


func _draw_speak(center: Vector2) -> void:
	_draw_person(center + Vector2(-6.0, 0.0), 0.0, 2.0)
	draw_circle(center + Vector2(13.0, -8.0), 5.2, Color(CYAN, 0.76))
	draw_circle(center + Vector2(11.0, -6.0), 1.2, Color("#07172b"))


func _draw_think(center: Vector2) -> void:
	_draw_person(center + Vector2(-4.0, 1.0), 0.0, -2.0)
	draw_circle(center + Vector2(11.0, -16.0), 4.0, Color(VIOLET, 0.82))
	draw_circle(center + Vector2(16.0, -21.0), 2.4, Color(VIOLET, 0.72))


func _draw_face(center: Vector2, mood: float) -> void:
	draw_circle(center + Vector2(0.0, -2.0), 14.0, Color(INK, 0.94))
	draw_circle(center + Vector2(-5.0, -5.0), 1.5, Color("#07172b"))
	draw_circle(center + Vector2(5.0, -5.0), 1.5, Color("#07172b"))
	if mood < 0.0:
		draw_line(center + Vector2(-8.0, -10.0), center + Vector2(-2.0, -12.0), VIOLET, 1.8, true)
		draw_line(center + Vector2(8.0, -10.0), center + Vector2(2.0, -12.0), VIOLET, 1.8, true)
		draw_line(center + Vector2(-5.0, 5.0), center + Vector2(5.0, 5.0), VIOLET, 1.8, true)
	elif mood > 0.0:
		draw_arc(center + Vector2(0.0, 1.0), 6.0, 0.15, PI - 0.15, 16, CYAN, 1.8, true)
	else:
		draw_arc(center + Vector2(0.0, 8.0), 6.0, PI + 0.25, TAU - 0.25, 16, VIOLET, 1.8, true)


func _draw_surprised(center: Vector2) -> void:
	_draw_face(center, 0.0)
	draw_circle(center + Vector2(0.0, 4.0), 3.0, VIOLET)


func _draw_sit(center: Vector2) -> void:
	_draw_person(center + Vector2(-3.0, 5.0), 0.0, 3.0)
	draw_line(center + Vector2(-15.0, 20.0), center + Vector2(15.0, 20.0), Color(CYAN, 0.78), 2.0, true)
