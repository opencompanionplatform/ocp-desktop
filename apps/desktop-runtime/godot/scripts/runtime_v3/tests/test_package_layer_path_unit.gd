extends SceneTree

const ZipPathUtil = preload(
	"res://scripts/runtime/packages/ocp_zip_path_util.gd"
)


func _initialize() -> void:
	var files := PackedStringArray([
		"assets\\character.json",
		"assets\\idle.png",
		"./assets/wave.png",
		"manifest.json",
	])

	var passed: bool = true

	passed = _expect(
		ZipPathUtil.normalize("assets\\idle.png"),
		"assets/idle.png",
		"normalize backslash"
	) and passed

	passed = _expect(
		ZipPathUtil.normalize("./assets//wave.png"),
		"assets/wave.png",
		"normalize relative and duplicate slash"
	) and passed

	passed = _expect(
		ZipPathUtil.resolve(
			files,
			"assets/character.json"
		),
		"assets\\character.json",
		"resolve actual Windows ZIP entry"
	) and passed

	passed = _expect(
		ZipPathUtil.resolve(files, "assets/wave.png"),
		"./assets/wave.png",
		"resolve dot-relative ZIP entry"
	) and passed

	passed = _expect_bool(
		ZipPathUtil.is_safe_relative_path(
			"assets/idle.png"
		),
		true,
		"accept safe relative path"
	) and passed

	passed = _expect_bool(
		ZipPathUtil.is_safe_relative_path(
			"../outside.txt"
		),
		false,
		"reject traversal"
	) and passed

	passed = _expect_bool(
		ZipPathUtil.is_safe_relative_path(
			"C:/outside.txt"
		),
		false,
		"reject drive path"
	) and passed

	if passed:
		print("[PASS] Package Layer ZIP path utility")

	quit(0 if passed else 1)


func _expect(
	actual: String,
	expected: String,
	label: String
) -> bool:
	if actual == expected:
		print("[PASS] ", label)
		return true

	push_error(
		"[FAIL] %s: expected '%s', actual '%s'"
		% [label, expected, actual]
	)
	return false


func _expect_bool(
	actual: bool,
	expected: bool,
	label: String
) -> bool:
	if actual == expected:
		print("[PASS] ", label)
		return true

	push_error(
		"[FAIL] %s: expected %s, actual %s"
		% [label, expected, actual]
	)
	return false
