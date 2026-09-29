extends Control
## Character Studio Controller (page script).
## Manages the 8-step workflow UI and updates the StudioProject data model.

var project: StudioProject
var current_step := 1
var active_tool := 0

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
@onready var preview_area: Control = %PreviewArea if has_node("%PreviewArea") else null
@onready var preview_host: Node2D = %PreviewHost if has_node("%PreviewHost") else null
@onready var preview_clip: OptionButton = %PreviewClip if has_node("%PreviewClip") else null

# Avatar Previews List
@onready var avatar_list: HBoxContainer = %AvatarList if has_node("%AvatarList") else null

# Layout & Readiness Panels
@onready var readiness_panel: PanelContainer = %ReadinessPanel if has_node("%ReadinessPanel") else null

# Step checklist labels
@onready var check_identity: Label = %CheckIdentity if has_node("%CheckIdentity") else null
@onready var check_artwork: Label = %CheckArtwork if has_node("%CheckArtwork") else null
@onready var check_grid: Label = %CheckGrid if has_node("%CheckGrid") else null
@onready var check_animation: Label = %CheckAnimation if has_node("%CheckAnimation") else null
@onready var check_attribution: Label = %CheckAttribution if has_node("%CheckAttribution") else null
@onready var check_preview: Label = %CheckPreview if has_node("%CheckPreview") else null

# Step container references
@onready var steps_parent: Control = %StepStack if has_node("%StepStack") else (%StepContainer if has_node("%StepContainer") else null)

# Viewport Tools
@onready var btn_pointer: Button = %BtnPointer if has_node("%BtnPointer") else null
@onready var btn_translate: Button = %BtnTranslate if has_node("%BtnTranslate") else null
@onready var btn_rotate: Button = %BtnRotate if has_node("%BtnRotate") else null
@onready var btn_scale: Button = %BtnScale if has_node("%BtnScale") else null
@onready var btn_frame: Button = %BtnFrame if has_node("%BtnFrame") else null

var preview: AnimatedSprite2D

func _ready() -> void:
	project = StudioProject.new()
	resized.connect(_on_resized)
	
	preview = AnimatedSprite2D.new()
	if preview_host:
		preview_host.add_child(preview)
	if preview_area:
		preview_area.resized.connect(_fit_preview)
		
	# Connect validation signals
	if name_edit: name_edit.text_changed.connect(_on_name_changed)
	if package_id_edit: package_id_edit.text_changed.connect(_on_package_id_changed)
	if version_edit: version_edit.text_changed.connect(_on_version_changed)
	if attribution_author: attribution_author.text_changed.connect(_on_author_changed)
	if attribution_license: attribution_license.text_changed.connect(_on_license_changed)
	if voice_hint: voice_hint.text_changed.connect(_on_voice_changed)
	
	_set_step(1)
	_refresh_avatar_list()
	_refresh_animation_list()
	_refresh_checks()
	_on_resized()
	_set_status("Ready. Character Studio loaded.")


func _on_resized() -> void:
	var w := size.x
	if readiness_panel:
		readiness_panel.visible = (w >= 980)


func _set_step(step_idx: int) -> void:
	current_step = clamp(step_idx, 1, 8)
	if steps_parent:
		for i in steps_parent.get_child_count():
			var child := steps_parent.get_child(i)
			if child:
				child.visible = (i == current_step - 1)
				
	# Update active workflow styling
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


func _on_name_changed(new_text: String) -> void:
	project.character_name = new_text
	_refresh_checks()

func _on_package_id_changed(new_text: String) -> void:
	project.package_id = new_text
	_refresh_checks()

func _on_version_changed(new_text: String) -> void:
	project.version = new_text
	_refresh_checks()

func _on_author_changed(new_text: String) -> void:
	project.creator_artist = new_text
	_refresh_checks()

func _on_license_changed(new_text: String) -> void:
	project.license = new_text
	_refresh_checks()

func _on_voice_changed(new_text: String) -> void:
	project.voice_hint = new_text
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


# --- Imports & Frame Layout ---

func _on_import_sprite_pressed() -> void:
	if file_dialog:
		file_dialog.popup_centered_ratio(0.7)
	else:
		_set_status("Error: FileDialog node missing!")

func _on_files_selected(paths: PackedStringArray) -> void:
	var loaded_any := false
	for path in paths:
		var sheet := _add_sheet_from_path(path)
		if not sheet.is_empty():
			loaded_any = true
			
	if not loaded_any:
		_set_status("No images could be loaded.")
		return
		
	project.current = project.sheets.size() - 1
	var last_sheet: Dictionary = project.sheets[project.current]
	if frame_width and frame_height:
		frame_width.value = last_sheet["fw"]
		frame_height.value = last_sheet["fh"]
		
	_refresh_avatar_list()
	_refresh_sheets()
	_rebuild_preview()
	_refresh_checks()
	_set_status("Uploaded %d images." % paths.size())

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
	project.sheets.append(sheet)
	return sheet

func _unique_sheet_id(base_filename: String) -> String:
	var root := _slug(base_filename.get_basename())
	var candidate := root
	var n := 2
	while project.get_sheet_index(candidate) != -1:
		candidate = "%s%d" % [root, n]
		n += 1
	return candidate

func _slug(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "." or ch == "_":
			out += ch
		else:
			out += "_"
	return out

func _on_apply_frame_layout_pressed() -> void:
	if project.current < 0:
		_set_status("Import a PNG before applying frame layout.")
		return
	var sheet: Dictionary = project.sheets[project.current]
	var image: Image = sheet["image"]
	var fw := int(frame_width.value) if frame_width else image.get_width()
	var fh := int(frame_height.value) if frame_height else image.get_height()
	
	if fw <= 0 or fh <= 0 or image.get_width() % fw != 0 or image.get_height() % fh != 0:
		_set_status("Cell size W/H must divide image dimensions evenly.")
		return
		
	sheet["fw"] = fw
	sheet["fh"] = fh
	sheet["cols"] = floori(float(image.get_width()) / float(fw))
	sheet["rows"] = floori(float(image.get_height()) / float(fh))

	sheet["count"] = sheet["cols"] * sheet["rows"]
	sheet["tex"] = ImageTexture.create_from_image(image)
	
	if sprite_info:
		sprite_info.text = "%s: %d frames, %dx%d px" % [sheet["id"], sheet["count"], fw, fh]
		
	# Update default idle clip
	var clip_name := animation_name.text.strip_edges().to_lower() if (animation_name and animation_name.text.strip_edges() != "") else "idle"
	var clip_frames := _parse_frames(frames_edit.text if frames_edit else "0", int(sheet["count"]))
	if not clip_frames.is_empty():
		project.animations[clip_name] = {
			"sprite": sheet["id"],
			"frames": clip_frames,
			"fps": fps.value if fps else 6.0,
			"loop": loop.button_pressed if loop else true
		}
		_refresh_animation_list()
		
	_rebuild_preview()
	_refresh_checks()
	_set_status("Applied cell layout and previewing clip '%s'." % clip_name)

func _parse_frames(value: String, max_count: int) -> Array:
	var parsed: Array = []
	for part in value.split(",", false):
		var candidate := part.strip_edges()
		if candidate.is_valid_int():
			var index := candidate.to_int()
			if index >= 0 and index < max_count and not parsed.has(index):
				parsed.append(index)
	return parsed


# --- Animation & Saving ---

func _on_save_animation_pressed() -> void:
	if project.sheets.is_empty():
		_set_status("Import a sprite sheet before editing animations.")
		return
	var clip_name := animation_name.text.strip_edges().to_lower() if animation_name else ""
	if clip_name.is_empty() or not clip_name.is_valid_identifier():
		_set_status("Animation name must be a simple identifier.")
		return
	var source_id := _selected_source_id()
	var source: Dictionary = project.sheets[project.get_sheet_index(source_id)]
	var clip_frames := _parse_frames(frames_edit.text if frames_edit else "0", int(source["count"]))
	if clip_frames.is_empty():
		_set_status("Choose at least one valid frame index.")
		return
		
	project.animations[clip_name] = {
		"sprite": source_id,
		"frames": clip_frames,
		"fps": fps.value if fps else 6.0,
		"loop": loop.button_pressed if loop else true
	}
	_refresh_animation_list()
	_rebuild_preview()
	_refresh_checks()
	_set_status("Saved animation '%s'." % clip_name)

func _selected_source_id() -> String:
	if source_sheet and source_sheet.selected >= 0 and source_sheet.selected < project.sheets.size():
		return str(project.sheets[source_sheet.selected]["id"])
	return str(project.sheets[0]["id"]) if not project.sheets.is_empty() else ""

func _on_delete_animation_pressed() -> void:
	var selected := animation_list.get_selected_items()
	if selected.is_empty():
		_set_status("Select an animation to delete.")
		return
	var clip_name := animation_list.get_item_text(selected[0])
	project.animations.erase(clip_name)
	_refresh_animation_list()
	_rebuild_preview()
	_refresh_checks()
	_set_status("Deleted animation '%s'." % clip_name)

func _on_animation_selected(index: int) -> void:
	var clip_name := animation_list.get_item_text(index)
	var clip: Dictionary = project.animations[clip_name]
	if animation_name: animation_name.text = clip_name
	if frames_edit: frames_edit.text = ",".join(clip["frames"].map(func(v): return str(v)))
	if fps: fps.value = float(clip["fps"])
	if loop: loop.button_pressed = bool(clip["loop"])
	var sid := str(clip.get("sprite", ""))
	var si := project.get_sheet_index(sid)
	if si >= 0 and source_sheet:
		source_sheet.select(si)
	if preview and preview.sprite_frames != null and preview.sprite_frames.has_animation(clip_name):
		preview.play(clip_name)


# --- Rebuild Preview ---

func _rebuild_preview() -> void:
	if project.sheets.is_empty():
		return
	var default_id := str(project.sheets[0]["id"])
	var frames := SpriteFrames.new()
	if frames.has_animation("default"):
		frames.remove_animation("default")
		
	for clip_name in project.animations.keys():
		var clip: Dictionary = project.animations[clip_name]
		if clip["frames"].is_empty():
			continue
		var sheet: Dictionary = project.sheets[project.get_sheet_index(str(clip.get("sprite", default_id)))]
		if sheet.is_empty() or sheet["tex"] == null or int(sheet["cols"]) <= 0:
			continue
		frames.add_animation(clip_name)
		frames.set_animation_speed(clip_name, float(clip["fps"]))
		frames.set_animation_loop(clip_name, bool(clip["loop"]))
		for index in clip["frames"]:
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet["tex"]
			var col := int(index) % int(sheet["cols"])
			var row := floori(float(index) / float(sheet["cols"]))
			atlas.region = Rect2(col * int(sheet["fw"]), row * int(sheet["fh"]), int(sheet["fw"]), int(sheet["fh"]))
			frames.add_frame(clip_name, atlas)
			
	if preview:
		preview.sprite_frames = frames
		if frames.has_animation("idle"):
			preview.play("idle")
	_fit_preview()

func _fit_preview() -> void:
	if project.current < 0 or not preview_area or not preview_host or not preview:
		return
	var sheet: Dictionary = project.sheets[project.current]
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


# --- Validation and Updates ---

func _refresh_checks() -> void:
	var results := StudioValidator.validate(project)
	
	if check_identity:
		check_identity.text = "✓ Identity valid" if bool(results.get("identity", false)) else "○ Identity draft pending"
	if check_artwork:
		check_artwork.text = "✓ Sprite assets loaded" if bool(results.get("artwork", false)) else "○ Sprite assets pending"
	if check_grid:
		check_grid.text = "✓ Sprite grid configured" if bool(results.get("grid", false)) else "○ Sprite grid pending"
	if check_animation:
		check_animation.text = "✓ Idle animation configured" if bool(results.get("animations", results.get("idle", false))) else "○ Idle animation required"
	if check_attribution:
		check_attribution.text = "✓ Attribution & license set" if bool(results.get("attribution", false)) else "○ Creator & license required"
	if check_preview:
		check_preview.text = "✓ Preview generated" if bool(results.get("preview", false)) else "⚠ Preview recommended"
		
	# Notify the app shell about build status changes
	var parent_shell := get_parent().get_parent() # AppShell -> Margin/MainVBox/CenterArea/PageContainer
	var shell = get_node_or_null("/root/AppShell")
	if shell and shell.has_node("%BuildPackage"):
		shell.get_node("%BuildPackage").disabled = not bool(results.get("can_build", false))


func _on_save_draft_pressed() -> void:
	_refresh_checks()
	_set_status("Draft saved successfully.")


func _on_build_package_pressed() -> void:
	var msg := PackageBuilder.build(project)
	_set_status(msg)


func _on_sheet_selected(index: int) -> void:
	project.current = index
	var sheet: Dictionary = project.sheets[project.current]
	if frame_width and frame_height:
		frame_width.value = sheet["fw"]
		frame_height.value = sheet["fh"]
	if sprite_info:
		sprite_info.text = "%s: %d frames" % [sheet["id"], sheet["count"]]


func _refresh_sheets() -> void:
	if sheet_list:
		sheet_list.clear()
		for sheet in project.sheets:
			sheet_list.add_item("%s (%d frames)" % [sheet["id"], sheet["count"]])
		if project.current >= 0 and project.current < sheet_list.item_count:
			sheet_list.select(project.current)
	if source_sheet:
		source_sheet.clear()
		for sheet in project.sheets:
			source_sheet.add_item(str(sheet["id"]))
		if project.current >= 0:
			source_sheet.select(project.current)


func _refresh_avatar_list() -> void:
	if not avatar_list:
		return
	for child in avatar_list.get_children():
		child.queue_free()
		
	if project.sheets.is_empty():
		var lbl := Label.new()
		lbl.text = "👧"
		avatar_list.add_child(lbl)
		return
		
	for sheet in project.sheets:
		var tex_rect := TextureRect.new()
		tex_rect.texture = sheet["tex"]
		tex_rect.custom_minimum_size = Vector2(48, 48)
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(52, 52)
		panel.add_child(tex_rect)
		avatar_list.add_child(panel)

func _refresh_animation_list() -> void:
	if animation_list:
		animation_list.clear()
		for clip_name in project.animations.keys():
			animation_list.add_item(str(clip_name))

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

func _set_status(message: String) -> void:
	if status:
		status.text = message


# --- Signal handler aliases (CharacterStudioPage.tscn signal names) ---

## Wizard step buttons (binds=[1..8])
func _on_wizard_pressed(step: int) -> void:
	_set_step(step)

## Footer nav
func _on_back_pressed() -> void:
	_set_step(current_step - 1)

func _on_next_pressed() -> void:
	_set_step(current_step + 1)

func _on_build_pressed() -> void:
	_on_build_package_pressed()

## Artwork step
func _on_import_pressed() -> void:
	_on_import_sprite_pressed()

## Grid step
func _on_apply_grid_pressed() -> void:
	_on_apply_frame_layout_pressed()

## Animations step
func _on_add_animation_pressed() -> void:
	# Pre-fill defaults so the user can just hit Save
	if animation_name:
		animation_name.text = "anim_%d" % (project.animations.size() + 1)
	_set_status("Enter name, select frames, then click 'Save animation clip'.")

## Preview step
func _on_preview_play_pressed() -> void:
	_on_timeline_play_pressed()

func _on_preview_clip_selected(index: int) -> void:
	if not preview or not preview.sprite_frames:
		return
	if preview_clip:
		var clip_name := preview_clip.get_item_text(index)
		if preview.sprite_frames.has_animation(clip_name):
			preview.play(clip_name)
			_set_status("Playing: " + clip_name)
