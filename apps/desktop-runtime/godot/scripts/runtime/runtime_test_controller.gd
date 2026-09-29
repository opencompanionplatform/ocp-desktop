extends Control
## RuntimeTestController — temporary end-to-end test UI (Step 5).
## Purpose: verify the full Install → Validate → Extract → Load → Display pipeline
## before building the final production UI.
##
## Flow:
##   [Install .ocp] → FileDialog → OcpPackageReader → OcpPackageValidator
##                 → CharacterPackageInstaller → reload companion frames
##   [Reload]       → re-reads state.json and reloads the sprite
##   [Play Idle]    → anim.play("idle") or "idle_neutral"
##   [Play Wave]    → anim.play("wave")
##   [Open Folder]  → OS.shell_open(install dir)

const OcpPackageReader      = preload("res://scripts/runtime/packages/ocp_package_reader.gd")
const OcpPackageValidator   = preload("res://scripts/runtime/packages/ocp_package_validator.gd")
const CharacterPackageInstaller = preload("res://scripts/runtime/packages/character_package_installer.gd")
const InstalledCharacterRepository = preload("res://scripts/runtime/packages/installed_character_repository.gd")

@onready var status_label:    Label          = %StatusLabel
@onready var char_label:      Label          = %CharLabel
@onready var preview_sprite:  AnimatedSprite2D = %PreviewSprite
@onready var file_dialog:     FileDialog     = %FileDialog

var _installed_path: String = ""


func _ready() -> void:
	_refresh_ui()


# ── button handlers ─────────────────────────────────────────────────────────

func _on_install_pressed() -> void:
	file_dialog.popup_centered_ratio(0.65)


func _on_file_selected(path: String) -> void:
	var norm_path := path.replace("\\", "/")
	_set_status("Reading %s …" % norm_path)

	# 1. Read
	var reader := OcpPackageReader.new()
	var read   := reader.read(norm_path)
	if not read.ok:
		_set_status("Read FAILED: " + read.error_message + "  (path: " + norm_path + ")")
		return

	# 2. Validate
	var validator  := OcpPackageValidator.new()
	var validation := validator.validate(read)
	if not validation.ok:
		if read.zip:
			read.zip.close()
		_set_status("Validation FAILED: " + validation.error_message)
		return

	# 3. Install
	var installer := CharacterPackageInstaller.new()
	var install   := installer.install(read)
	if read.zip:
		read.zip.close()
	if not install.ok:
		_set_status("Install FAILED: " + install.error_message)
		return

	_installed_path = install.installed_path
	_set_status("Installed: " + install.package_id + "@" + install.version + "  path: " + _installed_path)

	# 4. Reload sprite
	_reload_character()


func _on_reload_pressed() -> void:
	_reload_character()


func _on_play_idle_pressed() -> void:
	if not preview_sprite or not preview_sprite.sprite_frames:
		_set_status("⚠ No character loaded.")
		return
	var anim := "idle" if preview_sprite.sprite_frames.has_animation("idle") else "idle_neutral"
	if preview_sprite.sprite_frames.has_animation(anim):
		preview_sprite.play(anim)
		_set_status("▶ Playing: " + anim)
	else:
		_set_status("⚠ No idle animation found in loaded frames.")


func _on_play_wave_pressed() -> void:
	if not preview_sprite or not preview_sprite.sprite_frames:
		_set_status("⚠ No character loaded.")
		return
	if preview_sprite.sprite_frames.has_animation("wave"):
		preview_sprite.play("wave")
		_set_status("▶ Playing: wave")
	else:
		_set_status("⚠ No 'wave' animation in loaded frames.")


func _on_open_folder_pressed() -> void:
	var repo   := InstalledCharacterRepository.new()
	var active := repo.get_active()
	if active.is_empty():
		_set_status("⚠ No active character installed.")
		return
	var folder := ProjectSettings.globalize_path(str(active.get("path", "")))
	OS.shell_open(folder)
	_set_status("📂 Opened: " + folder)


# ── internal helpers ─────────────────────────────────────────────────────────

func _reload_character() -> void:
	var repo   := InstalledCharacterRepository.new()
	var active := repo.get_active()
	if active.is_empty():
		_set_status("⚠ No active character in state.json.")
		_update_char_label({})
		return

	var pkg_root := str(active.get("path", ""))
	_update_char_label(active)

	# Build frames using the same manifest-aware loader as companion.gd
	var frames := _load_character_frames(pkg_root)
	if frames == null:
		_set_status("❌ Failed to load frames from: " + pkg_root)
		return

	if preview_sprite:
		preview_sprite.sprite_frames = frames
		var anim := "idle_neutral" if frames.has_animation("idle_neutral") else \
					("idle"         if frames.has_animation("idle")         else "")
		if anim != "":
			preview_sprite.play(anim)
	_set_status("✅ Character loaded from: " + pkg_root)


## Thin copy of companion.gd's manifest-aware loader (no circular dependency).
func _load_character_frames(package_root: String) -> SpriteFrames:
	# Read manifest → resolve entry
	var manifest_path := package_root.path_join("manifest.json")
	if not FileAccess.file_exists(manifest_path):
		return null
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary:
		return null
	var entry_rel := str((manifest as Dictionary).get("entry", ""))
	if entry_rel.is_empty():
		return null
	var entry_path := package_root.path_join(entry_rel)
	if not FileAccess.file_exists(entry_path):
		return null

	# Read character entry
	var entry_parsed = JSON.parse_string(FileAccess.get_file_as_string(entry_path))
	if not entry_parsed is Dictionary:
		return null
	var entry: Dictionary = entry_parsed

	var sprite_list: Array = entry.get("sprites", [])
	if sprite_list.is_empty():
		return null

	var sheets: Dictionary = {}
	var default_id := ""
	for sprite_raw in sprite_list:
		if not sprite_raw is Dictionary:
			continue
		var sprite: Dictionary = sprite_raw
		var sid := str(sprite.get("id", ""))
		if sid.is_empty():
			continue
		var img_path := package_root.path_join(str(sprite.get("path", "")))
		var img := Image.load_from_file(img_path)
		if img == null:
			continue
		var fs = sprite.get("frameSize", [])
		var fw: int = int(fs[0]) if (fs is Array and fs.size() >= 2) else img.get_width()
		var fh: int = int(fs[1]) if (fs is Array and fs.size() >= 2) else img.get_height()
		fw = clampi(fw, 1, img.get_width())
		fh = clampi(fh, 1, img.get_height())
		var cols: int = maxi(1, img.get_width()  / fw)
		var rows: int = maxi(1, img.get_height() / fh)
		sheets[sid] = {"tex": ImageTexture.create_from_image(img),
			"fw": fw, "fh": fh, "cols": cols, "rows": rows}
		if default_id == "":
			default_id = sid

	if sheets.is_empty():
		return null

	var sf := SpriteFrames.new()
	if sf.has_animation("default"):
		sf.remove_animation("default")

	var animations_raw = entry.get("animations", {})
	var animations: Dictionary = animations_raw if animations_raw is Dictionary else {}

	for anim_name: String in animations:
		var clip_raw = animations[anim_name]
		if not clip_raw is Dictionary:
			continue
		var clip: Dictionary = clip_raw
		# Note: PackageBuilder may write sprite:null when no sheet explicitly selected
		var sid_raw = clip.get("sprite", null)
		var sid: String = str(sid_raw) if (sid_raw != null and str(sid_raw) != "null") else ""
		if sid.is_empty() or not sheets.has(sid):
			sid = default_id
		var sheet: Dictionary = sheets[sid]
		sf.add_animation(anim_name)
		sf.set_animation_loop(anim_name, bool(clip.get("loop", false)))
		sf.set_animation_speed(anim_name, float(clip.get("fps", 4.0)))
		var frames_raw = clip.get("frames", [])
		var frames_arr: Array = frames_raw if frames_raw is Array else []
		if frames_arr.is_empty():
			frames_arr = [0]
		var max_frame: int = int(sheet["cols"]) * int(sheet["rows"])
		for idx_raw in frames_arr:
			var idx: int = clampi(int(idx_raw), 0, maxi(0, max_frame - 1))
			var at := AtlasTexture.new()
			at.atlas = sheet["tex"]
			at.region = Rect2(
				(idx % int(sheet["cols"])) * int(sheet["fw"]),
				(idx / int(sheet["cols"])) * int(sheet["fh"]),
				int(sheet["fw"]), int(sheet["fh"]))
			sf.add_frame(anim_name, at)

	# Auto-idle if no animations declared
	if sf.get_animation_names().size() == 0:
		var sheet: Dictionary = sheets[default_id]
		sf.add_animation("idle")
		sf.set_animation_loop("idle", true)
		sf.set_animation_speed("idle", 2.0)
		var at := AtlasTexture.new()
		at.atlas = sheet["tex"]
		at.region = Rect2(0, 0, int(sheet["fw"]), int(sheet["fh"]))
		sf.add_frame("idle", at)

	# Alias idle_neutral → idle if missing
	if not sf.has_animation("idle_neutral") and sf.has_animation("idle"):
		sf.add_animation("idle_neutral")
		sf.set_animation_loop("idle_neutral", true)
		sf.set_animation_speed("idle_neutral", 2.0)
		for i in sf.get_frame_count("idle"):
			sf.add_frame("idle_neutral", sf.get_frame_texture("idle", i))

	return sf


func _refresh_ui() -> void:
	var repo   := InstalledCharacterRepository.new()
	var active := repo.get_active()
	_update_char_label(active)
	if not active.is_empty():
		_reload_character()


func _update_char_label(active: Dictionary) -> void:
	if active.is_empty():
		if char_label:
			char_label.text = "Installed Character: (none)"
	else:
		var name_val := str(active.get("manifest", {}).get("name",      active.get("packageId", "?")))
		var pkg_id   := str(active.get("packageId", "?"))
		var version  := str(active.get("version",   "?"))
		if char_label:
			char_label.text = "Installed Character:  %s  /  %s  /  v%s" % [name_val, pkg_id, version]


func _set_status(msg: String) -> void:
	print("[RuntimeTest] " + msg)
	if status_label:
		status_label.text = "Status: " + msg
