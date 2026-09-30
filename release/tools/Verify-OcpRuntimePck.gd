extends SceneTree

const MAX_FILES := 20000

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("OCP_PCK_VERIFY_ERROR expected exactly one PCK path")
		quit(2)
		return

	var pck_path := str(args[0]).strip_edges()
	if pck_path.is_empty() or not FileAccess.file_exists(pck_path):
		printerr("OCP_PCK_VERIFY_ERROR PCK not found: %s" % pck_path)
		quit(3)
		return

	if not ProjectSettings.load_resource_pack(pck_path, true):
		printerr("OCP_PCK_VERIFY_ERROR could not mount PCK: %s" % pck_path)
		quit(4)
		return

	var files: Array[String] = []
	if not _collect_files("res://", files):
		quit(5)
		return

	var raw_gd := 0
	var compiled_gdc := 0
	var gdextension := 0
	var scenes := 0
	var has_project_binary := false
	for file_path in files:
		var lower := file_path.to_lower()
		if lower.ends_with(".gd"):
			raw_gd += 1
		elif lower.ends_with(".gdc"):
			compiled_gdc += 1
		elif lower.ends_with(".gdextension"):
			gdextension += 1
		elif lower.ends_with(".tscn") or lower.ends_with(".scn"):
			scenes += 1
		if lower == "res://project.binary":
			has_project_binary = true

	print("OCP_PCK_VERIFY files=%d raw_gd=%d compiled_gdc=%d gdextension=%d scenes=%d project_binary=%s" % [
		files.size(), raw_gd, compiled_gdc, gdextension, scenes, str(has_project_binary)
	])

	if raw_gd != 0:
		printerr("OCP_PCK_VERIFY_ERROR publishable PCK contains raw GDScript files: %d" % raw_gd)
		quit(10)
		return
	if compiled_gdc <= 0:
		printerr("OCP_PCK_VERIFY_ERROR publishable PCK contains no compiled GDScript bytecode")
		quit(11)
		return
	if gdextension <= 0:
		printerr("OCP_PCK_VERIFY_ERROR publishable PCK is missing the GDExtension descriptor")
		quit(12)
		return
	if scenes <= 0:
		printerr("OCP_PCK_VERIFY_ERROR publishable PCK contains no runtime scenes")
		quit(13)
		return

	print("OCP_PCK_VERIFY_OK")
	quit(0)


func _collect_files(root: String, output: Array[String]) -> bool:
	var dir := DirAccess.open(root)
	if dir == null:
		printerr("OCP_PCK_VERIFY_ERROR cannot open directory: %s" % root)
		return false
	if dir.list_dir_begin() != OK:
		printerr("OCP_PCK_VERIFY_ERROR cannot enumerate directory: %s" % root)
		return false
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry == "." or entry == "..":
			continue
		var path := root.path_join(entry)
		if dir.current_is_dir():
			if not _collect_files(path, output):
				dir.list_dir_end()
				return false
		else:
			output.append(path)
			if output.size() > MAX_FILES:
				printerr("OCP_PCK_VERIFY_ERROR file-count limit exceeded")
				dir.list_dir_end()
				return false
	dir.list_dir_end()
	return true
