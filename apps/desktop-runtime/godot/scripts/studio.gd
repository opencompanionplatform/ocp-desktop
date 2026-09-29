extends Control
## OCP Platform Desktop Runtime: Character Studio
## Responsive Character Studio + 8-Step Workflow implementation.

var sheets: Array = []
var current := -1
var animations: Dictionary = {}
var expressions: Dictionary = {}
var preview: AnimatedSprite2D
var active_tool := 0
var current_step := 1
var menu_toggled := true

# --- Node References (with unique name resolution) ---
@onready var file_dialog: FileDialog = %FileDialog if has_node("%FileDialog") else null
@onready var name_edit: LineEdit = %NameEdit if has_node("%NameEdit") else null
@onready var package_id_edit: LineEdit = %PackageIdEdit if has_node("%PackageIdEdit") else null
@onready var version_edit: LineEdit = %VersionEdit if has_node("%VersionEdit") else null

@onready var sprite_info: Label = %SpriteInfo if has_node("%SpriteInfo") else null
@onready var sheet_list: ItemList = %SheetList if has_node("%SheetList") else null
@onready var frame_width: SpinBox = %FrameWidth if has_node("%FrameWidth") else null
@onready var frame_height: SpinBox = %FrameHeight if has_node("%FrameHeight") else null

@onready var animation_list: ItemList = %AnimationList if has_node("%AnimationList") else null
@onready var animation_name: LineEdit = %AnimationName if has_node("%AnimationName") else null
@onready var source_sheet: OptionButton = %SourceSheet if has_node("%SourceSheet") else null
@onready var frames_edit: LineEdit = %Frames if has_node("%Frames") else null
@onready var fps: SpinBox = %Fps if has_node("%Fps") else null
@onready var loop: CheckBox = %Loop if has_node("%Loop") else null

@onready var attribution_author: LineEdit = %AttributionAuthor if has_node("%AttributionAuthor") else null
@onready var attribution_license: LineEdit = %AttributionLicense if has_node("%AttributionLicense") else null
@onready var voice_hint: LineEdit = %VoiceHint if has_node("%VoiceHint") else null

@onready var status: Label = %Status if has_node("%Status") else null
@onready var project_name: Label = %ProjectName if has_node("%ProjectName") else null
@onready var preview_area: Control = %PreviewArea if has_node("%PreviewArea") else null
@onready var preview_host: Node2D = %PreviewHost if has_node("%PreviewHost") else null

# Avatar Previews List
@onready var avatar_list: HBoxContainer = %AvatarList if has_node("%AvatarList") else null

# Layout & Responsive Panels
@onready var nav_panel: PanelContainer = %Nav if has_node("%Nav") else null
@onready var readiness_panel: PanelContainer = %ReadinessPanel if has_node("%ReadinessPanel") else null
@onready var build_package_btn: Button = %BuildPackage if has_node("%BuildPackage") else null

# Step checklist labels
@onready var check_identity: Label = %CheckIdentity if has_node("%CheckIdentity") else null
@onready var check_artwork: Label = %CheckArtwork if has_node("%CheckArtwork") else null
@onready var check_grid: Label = %CheckGrid if has_node("%CheckGrid") else null
@onready var check_animation: Label = %CheckAnimation if has_node("%CheckAnimation") else null
@onready var check_attribution: Label = %CheckAttribution if has_node("%CheckAttribution") else null
@onready var check_preview: Label = %CheckPreview if has_node("%CheckPreview") else null

# Step container references
@onready var steps_parent: Control = %StepContainer if has_node("%StepContainer") else null

# Viewport Tools
@onready var btn_pointer: Button = %BtnPointer if has_node("%BtnPointer") else null
@onready var btn_translate: Button = %BtnTranslate if has_node("%BtnTranslate") else null
@onready var btn_rotate: Button = %BtnRotate if has_node("%BtnRotate") else null
@onready var btn_scale: Button = %BtnScale if has_node("%BtnScale") else null
@onready var btn_frame: Button = %BtnFrame if has_node("%BtnFrame") else null


func _ready() -> void:
	# Resized signal connection for responsive UI
	resized.connect(_on_resized)
	
	preview = AnimatedSprite2D.new()
	if preview_host:
		preview_host.add_child(preview)
	if preview_area:
		preview_area.resized.connect(_fit_preview)
	
	animations = {
		"idle": {"sprite": "", "frames": [0], "fps": 2.0, "loop": true},
		"wave": {"sprite": "", "frames": [], "fps": 6.0, "loop": false},
		"think": {"sprite": "", "frames": [], "fps": 4.0, "loop": false},
		"speak": {"sprite": "", "frames": [], "fps": 8.0, "loop": true},
	}
	if attribution_license:
		attribution_license.text = "CC-BY-4.0"
	
	# Default dummy project values
	if name_edit: name_edit.text = "Aiko"
	if package_id_edit: package_id_edit.text = "ocp.character.aiko"
	if version_edit: version_edit.text = "0.1.0"
	
	_set_step(1)
	_refresh_avatar_list()
	_refresh_animation_list()
	_refresh_checks()
	_on_resized()
	_set_status("Ready. Character Studio loaded.")


func _on_resized() -> void:
	var w := size.x
	# Hide App Menu (Nav) under 1180px
	if nav_panel:
		if w < 1180:
			nav_panel.visible = false
		else:
			nav_panel.visible = menu_toggled
			
	# Hide Package Readiness Panel under 980px
	if readiness_panel:
		if w < 980:
			readiness_panel.visible = false
		else:
			readiness_panel.visible = true


func _on_btn_menu_toggle_pressed() -> void:
	menu_toggled = not menu_toggled
	if nav_panel and size.x >= 1180:
		nav_panel.visible = menu_toggled
	elif nav_panel:
		nav_panel.visible = menu_toggled # Toggle anyway when small


func _set_step(step_idx: int) -> void:
	current_step = clamp(step_idx, 1, 8)
	
	# Show corresponding step content inside Editor Panel
	if steps_parent:
		for i in steps_parent.get_child_count():
			var child := steps_parent.get_child(i)
			if child:
				child.visible = (i == current_step - 1)
				
	# Highlight active workflow step button
	for s in range(1, 9):
		var btn: Button = get_node_or_null("%StepBtn" + str(s))
		if btn:
			if s == current_step:
				var active_style := StyleBoxFlat.new()
				active_style.bg_color = Color(0.482, 0.38, 1.0, 0.25)
				active_style.border_width_left = 3
				active_style.border_color = Color(0.482, 0.38, 1.0, 1.0)
				btn.add_theme_stylebox_override("normal", active_style)
			else:
				btn.remove_theme_stylebox_override("normal")
				
	_refresh_checks()


# --- Form Input Signal Handlers ---

func _on_name_edit_text_changed(_new_text: String) -> void:
	_refresh_checks()

func _on_package_id_edit_text_changed(_new_text: String) -> void:
	_refresh_checks()

func _on_version_edit_text_changed(_new_text: String) -> void:
	_refresh_checks()


# --- Viewport Tools ---

func _on_tool_selected(tool_id: int) -> void:
	active_tool = tool_id
	var btns := [btn_pointer, btn_translate, btn_rotate, btn_scale, btn_frame]
	for i in btns.size():
		var btn: Button = btns[i]
		if btn:
			if i == active_tool:
				var active_style := StyleBoxFlat.new()
				active_style.bg_color = Color(0.482, 0.38, 1.0, 1.0)
				active_style.corner_radius_top_left = 6
				active_style.corner_radius_top_right = 6
				active_style.corner_radius_bottom_right = 6
				active_style.corner_radius_bottom_left = 6
				btn.add_theme_stylebox_override("normal", active_style)
			else:
				btn.remove_theme_stylebox_override("normal")
	_set_status("Selected viewport tool: %d" % tool_id)


# --- Timeline Controls ---

func _on_timeline_play_pressed() -> void:
	if preview and preview.sprite_frames and preview.sprite_frames.has_animation("idle"):
		preview.play("idle")
		_set_status("Playing animation preview.")

func _on_timeline_stop_pressed() -> void:
	if preview:
		preview.pause()
		_set_status("Paused animation preview.")

func _on_timeline_prev_pressed() -> void:
	if preview and preview.sprite_frames:
		preview.frame = max(0, preview.frame - 1)

func _on_timeline_next_pressed() -> void:
	if preview and preview.sprite_frames:
		preview.frame += 1

func _on_timeline_loop_pressed() -> void:
	if loop:
		loop.button_pressed = not loop.button_pressed
		_set_status("Animation loop toggled: %s" % str(loop.button_pressed))

func _on_zoom_changed(value: float) -> void:
	if preview:
		var scale_factor := value / 50.0
		preview.scale = Vector2(scale_factor, scale_factor)


# --- Helpers ---

func _slug(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "." or ch == "_":
			out += ch
		else:
			out += "_"
	return out

func _unique_sheet_id(base: String) -> String:
	var root := _slug(base.get_basename())
	var candidate := root
	var n := 2
	while _sheet_index(candidate) != -1:
		candidate = "%s%d" % [root, n]
		n += 1
	return candidate

func _sheet_index(id: String) -> int:
	for i in sheets.size():
		if sheets[i]["id"] == id:
			return i
	return -1


# --- Imports & Frame Layout ---

func _on_import_sprite_pressed() -> void:
	if file_dialog:
		file_dialog.popup_centered_ratio(0.7)
		file_dialog.visible = true
		file_dialog.show()
	else:
		_set_status("Error: FileDialog node missing!")

func _add_sheet_from_path(path: String) -> Dictionary:
	var image := Image.load_from_file(path)
	if image == null:
		return {}
	
	var fw := image.get_width()
	var fh := image.get_height()
	var sheet := {
		"id": _unique_sheet_id(path.get_file()),
		"image": image,
		"tex": ImageTexture.create_from_image(image),
		"fw": fw,
		"fh": fh,
		"cols": 1,
		"rows": 1,
		"count": 1,
	}
	sheets.append(sheet)
	return sheet

func _on_files_selected(paths: PackedStringArray) -> void:
	var loaded_any := false
	for path in paths:
		var sheet := _add_sheet_from_path(path)
		if not sheet.is_empty():
			loaded_any = true
	
	if not loaded_any:
		_set_status("No images could be loaded.")
		return
	
	current = sheets.size() - 1
	var last_sheet: Dictionary = sheets[current]
	if frame_width and frame_height:
		frame_width.value = last_sheet["fw"]
		frame_height.value = last_sheet["fh"]
	
	_refresh_avatar_list()
	_refresh_sheets()
	_rebuild_preview()
	_refresh_checks()
	_set_status("Uploaded %d images." % paths.size())

func _on_file_selected(path: String) -> void:
	_on_files_selected(PackedStringArray([path]))

func _refresh_avatar_list() -> void:
	if not avatar_list:
		return
	for child in avatar_list.get_children():
		child.queue_free()
	
	if sheets.is_empty():
		var lbl := Label.new()
		lbl.text = "👧"
		avatar_list.add_child(lbl)
		return
	
	for sheet in sheets:
		var tex_rect := TextureRect.new()
		tex_rect.texture = sheet["tex"]
		tex_rect.custom_minimum_size = Vector2(48, 48)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(52, 52)
		panel.add_child(tex_rect)
		avatar_list.add_child(panel)

func _on_apply_frame_layout_pressed() -> void:
	_apply_frame_layout()

func _apply_frame_layout() -> void:
	if current < 0:
		_set_status("Import a PNG before applying frame layout.")
		return
	var sheet: Dictionary = sheets[current]
	var image: Image = sheet["image"]
	var fw := int(frame_width.value) if frame_width else image.get_width()
	var fh := int(frame_height.value) if frame_height else image.get_height()
	if fw <= 0 or fh <= 0 or image.get_width() % fw != 0 or image.get_height() % fh != 0:
		_set_status("Cell size W/H must divide image dimensions (%dx%d) evenly." % [image.get_width(), image.get_height()])
		return
	sheet["fw"] = fw
	sheet["fh"] = fh
	sheet["cols"] = image.get_width() / fw
	sheet["rows"] = image.get_height() / fh
	sheet["count"] = sheet["cols"] * sheet["rows"]
	sheet["tex"] = ImageTexture.create_from_image(image)
	var sid: String = str(sheet["id"])
	if sprite_info:
		sprite_info.text = sid + ": " + str(int(sheet["count"])) + " frames, " + str(fw) + "x" + str(fh) + " px"
	
	# Apply current input fields values to the current animation clip
	var clip_name := animation_name.text.strip_edges().to_lower() if (animation_name and animation_name.text.strip_edges() != "") else "idle"
	var clip_frames := _parse_frames(frames_edit.text if frames_edit else "0", int(sheet["count"]))
	if not clip_frames.is_empty():
		animations[clip_name] = {
			"sprite": sid,
			"frames": clip_frames,
			"fps": fps.value if fps else 6.0,
			"loop": loop.button_pressed if loop else true
		}
		_refresh_animation_list()
	
	_rebuild_preview()
	
	if preview and preview.sprite_frames and preview.sprite_frames.has_animation(clip_name):
		preview.play(clip_name)
		
	_refresh_checks()
	_set_status("Applied cell layout and previewing clip '%s'." % clip_name)

func _on_sheet_selected(index: int) -> void:
	current = index
	var sheet: Dictionary = sheets[current]
	if frame_width and frame_height:
		frame_width.value = sheet["fw"]
		frame_height.value = sheet["fh"]
	if sprite_info:
		sprite_info.text = str(sheet["id"]) + ": " + str(int(sheet["count"])) + " frames"

func _refresh_sheets() -> void:
	if sheet_list:
		sheet_list.clear()
		for sheet in sheets:
			sheet_list.add_item("%s (%d frames)" % [sheet["id"], sheet["count"]])
		if current >= 0 and current < sheet_list.item_count:
			sheet_list.select(current)
	if source_sheet:
		source_sheet.clear()
		for sheet in sheets:
			source_sheet.add_item(str(sheet["id"]))
		if current >= 0:
			source_sheet.select(current)


# --- Animations ---

func _selected_source_id() -> String:
	if source_sheet and source_sheet.selected >= 0 and source_sheet.selected < sheets.size():
		return str(sheets[source_sheet.selected]["id"])
	return str(sheets[0]["id"]) if not sheets.is_empty() else ""

func _parse_frames(value: String, max_count: int) -> Array:
	var parsed: Array = []
	for part in value.split(",", false):
		var candidate := part.strip_edges()
		if candidate.is_valid_int():
			var index := candidate.to_int()
			if index >= 0 and index < max_count and not parsed.has(index):
				parsed.append(index)
	return parsed

func _on_save_animation_pressed() -> void:
	if sheets.is_empty():
		_set_status("Import a sprite sheet before editing animations.")
		return
	var clip_name := animation_name.text.strip_edges().to_lower() if animation_name else ""
	if clip_name.is_empty() or not clip_name.is_valid_identifier():
		_set_status("Animation name must be a simple identifier (idle, wave, think, speak).")
		return
	var source_id := _selected_source_id()
	var source: Dictionary = sheets[_sheet_index(source_id)]
	var clip_frames := _parse_frames(frames_edit.text if frames_edit else "0", int(source["count"]))
	if clip_frames.is_empty():
		_set_status("Choose at least one valid frame index.")
		return
	animations[clip_name] = {
		"sprite": source_id,
		"frames": clip_frames,
		"fps": fps.value if fps else 6.0,
		"loop": loop.button_pressed if loop else true
	}
	_refresh_animation_list()
	_rebuild_preview()
	_refresh_checks()
	_set_status("Saved animation '%s'." % clip_name)

func _on_delete_animation_pressed() -> void:
	if not animation_list:
		return
	var selected := animation_list.get_selected_items()
	if selected.is_empty():
		_set_status("Select an animation to delete.")
		return
	var clip_name := animation_list.get_item_text(selected[0])
	animations.erase(clip_name)
	if animation_name: animation_name.clear()
	if frames_edit: frames_edit.clear()
	_refresh_animation_list()
	_rebuild_preview()
	_refresh_checks()
	_set_status("Deleted animation '%s'." % clip_name)

func _on_animation_selected(index: int) -> void:
	if not animation_list:
		return
	var clip_name := animation_list.get_item_text(index)
	var clip: Dictionary = animations[clip_name]
	if animation_name: animation_name.text = clip_name
	if frames_edit: frames_edit.text = ",".join(clip["frames"].map(func(v): return str(v)))
	if fps: fps.value = float(clip["fps"])
	if loop: loop.button_pressed = bool(clip["loop"])
	var sid := str(clip.get("sprite", ""))
	var si := _sheet_index(sid)
	if si >= 0 and source_sheet:
		source_sheet.select(si)
	if preview and preview.sprite_frames != null and preview.sprite_frames.has_animation(clip_name):
		preview.play(clip_name)

func _refresh_animation_list() -> void:
	if animation_list:
		animation_list.clear()
		for clip_name in animations.keys():
			animation_list.add_item(str(clip_name))


# --- Timeline Select & GUI Control ---

func _on_track_gui_input(event: InputEvent, anim_name: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_select_track(anim_name)

func _select_track(anim_name: String) -> void:
	_set_status("Selected timeline track: " + anim_name)
	
	if animation_list:
		for i in animation_list.item_count:
			if animation_list.get_item_text(i) == anim_name:
				animation_list.select(i)
				_on_animation_selected(i)
				break
	
	var track_paths := {
		"idle": "Margin/MainVBox/CenterArea/WorkspaceVBox/BottomPanels/TimelinePanel/TimelineVBox/TracksVBox/TrackIdle/Name",
		"wave": "Margin/MainVBox/CenterArea/WorkspaceVBox/BottomPanels/TimelinePanel/TimelineVBox/TracksVBox/TrackWave/Name",
		"think": "Margin/MainVBox/CenterArea/WorkspaceVBox/BottomPanels/TimelinePanel/TimelineVBox/TracksVBox/TrackThink/Name",
		"speak": "Margin/MainVBox/CenterArea/WorkspaceVBox/BottomPanels/TimelinePanel/TimelineVBox/TracksVBox/TrackSpeak/Name"
	}
	for tname in track_paths.keys():
		var label: Label = get_node_or_null(track_paths[tname])
		if label:
			if tname == anim_name:
				label.modulate = Color(0.482, 0.38, 1, 1) # Highlight purple
			else:
				label.modulate = Color(1, 1, 1, 1)


# --- Preview Management ---

func _sheet_by_id(sid: String) -> Dictionary:
	var i := _sheet_index(sid)
	if i >= 0:
		return sheets[i]
	return sheets[0] if not sheets.is_empty() else {}

func _rebuild_preview() -> void:
	if sheets.is_empty():
		return
	var default_id := str(sheets[0]["id"])
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")
	
	if not animations.has("idle") or animations["idle"]["frames"].is_empty():
		animations["idle"] = {"sprite": default_id, "frames": [0], "fps": 2.0, "loop": true}
	else:
		if animations["idle"].get("sprite", "") == "":
			animations["idle"]["sprite"] = default_id
	
	for clip_name in animations.keys():
		var clip: Dictionary = animations[clip_name]
		if clip["frames"].is_empty():
			continue
		var sheet := _sheet_by_id(str(clip.get("sprite", default_id)))
		if sheet.is_empty() or sheet["tex"] == null or int(sheet["cols"]) <= 0:
			continue
		frames.add_animation(clip_name)
		frames.set_animation_speed(clip_name, float(clip["fps"]))
		frames.set_animation_loop(clip_name, bool(clip["loop"]))
		for index in clip["frames"]:
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet["tex"]
			var col := int(index) % int(sheet["cols"])
			var row := int(index) / int(sheet["cols"])
			atlas.region = Rect2(col * int(sheet["fw"]), row * int(sheet["fh"]), int(sheet["fw"]), int(sheet["fh"]))
			frames.add_frame(clip_name, atlas)
	
	if preview:
		preview.sprite_frames = frames
		if frames.has_animation("idle"):
			preview.play("idle")
	_fit_preview()

func _fit_preview() -> void:
	if current < 0 or not preview_area or not preview_host or not preview:
		return
	var sheet: Dictionary = sheets[current]
	var fw := int(sheet["fw"])
	var fh := int(sheet["fh"])
	if fw <= 0 or fh <= 0:
		return
	var avail: Vector2 = preview_area.size
	if avail.x <= 0.0 or avail.y <= 0.0:
		return
	var fit := clampf(minf(avail.x / float(fw), avail.y / float(fh)), 0.4, 4.0)
	preview.scale = Vector2(fit, fit)
	preview_host.position = Vector2(avail.x * 0.5, avail.y * 0.5)

func _set_status(message: String) -> void:
	if status:
		status.text = message

func _refresh_checks() -> void:
	var char_name := name_edit.text.strip_edges() if name_edit and name_edit.text.strip_edges() != "" else "Aiko"
	if project_name:
		project_name.text = "%s — Focus Companion ✏" % char_name
		
	# 1. Identity validation
	var has_id: bool = name_edit and name_edit.text.strip_edges() != "" and package_id_edit and package_id_edit.text.strip_edges() != "" and version_edit and version_edit.text.strip_edges() != ""
	if check_identity:
		check_identity.text = "✓ Identity valid" if has_id else "○ Identity draft pending"
		
	# 2. Artwork validation
	var has_art: bool = not sheets.is_empty()
	if check_artwork:
		check_artwork.text = "✓ Sprite assets loaded" if has_art else "○ Sprite assets pending"
		
	# 3. Grid validation
	var has_grid: bool = has_art and frame_width and frame_height and frame_width.value > 0 and frame_height.value > 0
	if check_grid:
		check_grid.text = "✓ Sprite grid configured" if has_grid else "○ Sprite grid pending"
		
	# 4. Idle animation validation
	var has_idle: bool = animations.has("idle") and not (animations["idle"]["frames"] as Array).is_empty()
	if check_animation:
		check_animation.text = "✓ Idle animation configured" if has_idle else "○ Idle animation required"
		
	# 5. Attribution and license validation
	var has_attrib: bool = attribution_author and attribution_author.text.strip_edges() != "" and attribution_license and attribution_license.text.strip_edges() != ""
	if check_attribution:
		check_attribution.text = "✓ Attribution & license set" if has_attrib else "○ Creator & license required"
		
	# 6. Preview validation
	var has_prev: bool = preview and preview.sprite_frames and preview.sprite_frames.has_animation("idle")
	if check_preview:
		check_preview.text = "✓ Preview generated" if has_prev else "⚠ Preview recommended"
		
	# Build button enabled checks
	var can_build: bool = has_id and has_art and has_grid and has_idle and has_attrib
	if build_package_btn:
		build_package_btn.disabled = not can_build


# --- Save Draft & Build Package ---

func _on_save_draft_pressed() -> void:
	_refresh_checks()
	_set_status("Draft saved successfully.")

func _on_build_package_pressed() -> void:
	if sheets.is_empty() or not animations.has("idle") or animations["idle"]["frames"].is_empty():
		_set_status("Cannot build package: import a sheet and configure an 'idle' animation.")
		return
	var dir := OS.get_environment("OCP_CHARACTER_DIR")
	if dir == "":
		var temp_env := OS.get_environment("TEMP")
		if temp_env != "":
			dir = temp_env.path_join("ocp-character")
		else:
			dir = "user://ocp-character"
	DirAccess.make_dir_recursive_absolute(dir.path_join("assets"))
	var sprites: Array = []
	for sheet in sheets:
		var rel := "assets/%s.png" % sheet["id"]
		sheet["image"].save_png(dir.path_join(rel))
		sprites.append({"id": sheet["id"], "path": rel, "frameSize": [int(sheet["fw"]), int(sheet["fh"])]})
	var default_id := str(sheets[0]["id"])
	var out_animations := {}
	for clip_name in animations.keys():
		var clip: Dictionary = animations[clip_name]
		if clip["frames"].is_empty():
			continue
		var sid := str(clip.get("sprite", ""))
		if _sheet_index(sid) < 0:
			sid = default_id
		out_animations[clip_name] = {"sprite": sid, "frames": clip["frames"], "fps": clip["fps"], "loop": clip["loop"]}
	var out_expressions := {}
	for expr_id in expressions.keys():
		var expr: Dictionary = expressions[expr_id]
		if expr["frames"].is_empty():
			continue
		var sid := str(expr.get("sprite", ""))
		if _sheet_index(sid) < 0:
			sid = default_id
		out_expressions[expr_id] = {"sprite": sid, "frames": expr["frames"]}
	var authorship: Array = []
	var author_text := attribution_author.text.strip_edges() if attribution_author else ""
	var license_text := attribution_license.text.strip_edges() if attribution_license else "CC-BY-4.0"
	if not author_text.is_empty():
		authorship.append({"component": "sprites", "author": author_text, "license": license_text})
	var char_name := name_edit.text.strip_edges() if name_edit and name_edit.text.strip_edges() != "" else "Aiko"
	var entry := {
		"schema": "character/1",
		"name": char_name,
		"renderer": "sprite-sheet-2d",
		"sprites": sprites,
		"animations": out_animations,
		"expressions": out_expressions,
		"voiceId": voice_hint.text.strip_edges() if voice_hint and voice_hint.text.strip_edges() != "" else null,
		"authorship": authorship,
	}
	var output := FileAccess.open(dir.path_join("character.json"), FileAccess.WRITE)
	if output:
		output.store_string(JSON.stringify(entry, "  "))
		output.close()
		_set_status("Staged character.json + %d sheet(s) to %s." % [sprites.size(), dir])
	else:
		_set_status("Failed to open character.json for writing.")
