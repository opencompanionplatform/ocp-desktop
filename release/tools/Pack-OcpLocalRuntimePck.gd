extends SceneTree

const TOP_LEVEL_DIRS := ["assets", "scenes", "scripts", "shaders", "themes"]
const TOP_LEVEL_FILES := ["project.godot", "ocp_runtime.gdextension", "ocp_runtime.gdextension.uid"]
const GODOT_CACHE_FILES := ["uid_cache.bin", "global_script_class_cache.cfg", "scene_groups_cache.cfg", "extension_list.cfg"]

var _source_root := ""
var _output_pck := ""
var _files: Array[Dictionary] = []

func _initialize() -> void:
    var args := OS.get_cmdline_user_args()
    if args.size() != 2:
        push_error("usage: -- <source-project-root> <output-pck>")
        quit(2)
        return

    _source_root = args[0].replace("\\", "/").trim_suffix("/")
    _output_pck = args[1].replace("\\", "/")
    if not FileAccess.file_exists(_source_root.path_join("project.godot")):
        push_error("source project.godot not found: %s" % _source_root)
        quit(3)
        return

    for relative in TOP_LEVEL_FILES:
        _queue_file(relative)
    for directory in TOP_LEVEL_DIRS:
        _walk_directory(directory)

    var godot_cache := _source_root.path_join(".godot")
    if DirAccess.dir_exists_absolute(godot_cache.path_join("imported")):
        _walk_directory(".godot/imported")
    for relative in GODOT_CACHE_FILES:
        var cache_relative := ".godot/%s" % relative
        if FileAccess.file_exists(_source_root.path_join(cache_relative)):
            _queue_file(cache_relative)

    _files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["pck"]) < str(b["pck"]))
    if _files.is_empty():
        push_error("no files were selected for PCK")
        quit(4)
        return

    var parent := _output_pck.get_base_dir()
    if not DirAccess.dir_exists_absolute(parent):
        var mkdir_err := DirAccess.make_dir_recursive_absolute(parent)
        if mkdir_err != OK:
            push_error("could not create output directory: %s (%s)" % [parent, mkdir_err])
            quit(5)
            return

    if FileAccess.file_exists(_output_pck):
        DirAccess.remove_absolute(_output_pck)

    var packer := PCKPacker.new()
    var start_err := packer.pck_start(_output_pck)
    if start_err != OK:
        push_error("pck_start failed: %s" % start_err)
        quit(6)
        return

    var gd_count := 0
    for entry in _files:
        var pck_path := str(entry["pck"])
        var source_path := str(entry["source"])
        var err := packer.add_file(pck_path, source_path)
        if err != OK:
            push_error("add_file failed: %s <- %s (%s)" % [pck_path, source_path, err])
            quit(7)
            return
        if pck_path.ends_with(".gd"):
            gd_count += 1

    var flush_err := packer.flush(false)
    if flush_err != OK:
        push_error("PCK flush failed: %s" % flush_err)
        quit(8)
        return

    print("OCP_LOCAL_PCK_OK files=%d gd_source=%d output=%s" % [_files.size(), gd_count, _output_pck])
    quit(0)

func _walk_directory(relative_dir: String) -> void:
    var absolute := _source_root.path_join(relative_dir)
    var dir := DirAccess.open(absolute)
    if dir == null:
        return
    dir.list_dir_begin()
    while true:
        var name := dir.get_next()
        if name.is_empty():
            break
        if name == "." or name == "..":
            continue
        var child_relative := relative_dir.path_join(name)
        if dir.current_is_dir():
            _walk_directory(child_relative)
        else:
            if _should_include(child_relative):
                _queue_file(child_relative)
    dir.list_dir_end()

func _should_include(relative: String) -> bool:
    var lower := relative.to_lower()
    if lower.ends_with(".log") or lower.contains(".backup") or lower.contains(".before-") or lower.contains(".corrupt-backup"):
        return false
    if lower.ends_with(".tmp") or lower.ends_with("~"):
        return false
    return true

func _queue_file(relative: String) -> void:
    var normalized := relative.replace("\\", "/")
    var source := _source_root.path_join(normalized)
    if not FileAccess.file_exists(source):
        push_error("required PCK input missing: %s" % source)
        quit(9)
        return
    _files.append({"pck": "res://%s" % normalized, "source": source})
