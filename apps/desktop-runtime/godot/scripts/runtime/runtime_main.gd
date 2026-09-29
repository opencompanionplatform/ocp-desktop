extends Node2D

const InstalledCharacterRepository = preload("res://scripts/runtime/packages/installed_character_repository.gd")

@onready var companion_sprite: AnimatedSprite2D = %CompanionSprite
@onready var companion_hit_box: Control = %CompanionHitBox
@onready var hover_menu: PanelContainer = %HoverMenu
@onready var status_label: Label = %StatusLabel

@onready var companion_controller: Node = %CompanionController
@onready var animation_controller: Node = %CompanionAnimationController
@onready var hover_menu_controller: Node = %HoverMenuController
@onready var overlay_controller: Node = %OverlayWindowController
@onready var click_through_controller: Node = %ClickThroughController
@onready var runtime_debug_controller: Node = %RuntimeDebugController

var _last_sprite_position := Vector2.ZERO

func _ready() -> void:
    _wire_buttons()
    _load_active_character()

    companion_controller.bind(companion_sprite, animation_controller)
    companion_controller.moved.connect(_on_companion_moved)
    companion_controller.visibility_changed.connect(_on_companion_visibility_changed)

    runtime_debug_controller.configure(
        companion_controller,
        animation_controller,
        hover_menu_controller,
        overlay_controller,
        click_through_controller,
        hover_menu,
        companion_hit_box
    )
    runtime_debug_controller.debug_message.connect(_set_status)

    # Phase A starts as an ordinary game window. No transparency or click-through.
    runtime_debug_controller.set_debug_mode(true)
    companion_controller.place_bottom_right(overlay_controller.get_logical_viewport_size())
    _sync_companion_hit_box()
    _place_menu_next_to_companion()
    _set_status("Debug runtime active — hover the character")

func _process(_delta: float) -> void:
    # Only synchronize the visual hit box if the controller moved the sprite.
    # Hover visibility itself is entirely event-driven.
    if companion_sprite.global_position != _last_sprite_position:
        _last_sprite_position = companion_sprite.global_position
        _sync_companion_hit_box()
        _place_menu_next_to_companion()

func _wire_buttons() -> void:
    %ShowButton.pressed.connect(func(): companion_controller.show_companion())
    %HideButton.pressed.connect(func(): companion_controller.hide_companion())
    %WalkLeftButton.pressed.connect(func(): companion_controller.walk_left())
    %CenterButton.pressed.connect(func(): companion_controller.center(overlay_controller.get_logical_viewport_size()))
    %WalkRightButton.pressed.connect(func(): companion_controller.walk_right())
    %IdleButton.pressed.connect(func(): animation_controller.play(&"idle", true))
    %NeutralButton.pressed.connect(func(): animation_controller.play(&"idle_neutral", true))
    %HappyButton.pressed.connect(func(): animation_controller.play(&"idle_happy", true))
    %WaveButton.pressed.connect(func(): animation_controller.play(&"wave", true))
    %ToggleModeButton.pressed.connect(_on_toggle_mode_pressed)

func _on_toggle_mode_pressed() -> void:
    runtime_debug_controller.toggle_debug_mode()
    var mode_text := "DEBUG WINDOW" if overlay_controller.debug_mode else "TRANSPARENT OVERLAY"
    %ToggleModeButton.text = "Mode: " + mode_text
    _set_status("Mode changed to " + mode_text)

func _on_companion_moved(_position: Vector2) -> void:
    _sync_companion_hit_box()
    _place_menu_next_to_companion()

func _on_companion_visibility_changed(is_visible: bool) -> void:
    companion_hit_box.visible = is_visible
    if not is_visible:
        hover_menu_controller.hide_menu_immediately()

func _sync_companion_hit_box() -> void:
    if companion_sprite == null or companion_hit_box == null:
        return
    var rect: Rect2 = companion_controller.get_interaction_rect(12.0)
    companion_hit_box.position = rect.position
    companion_hit_box.size = rect.size

func _place_menu_next_to_companion() -> void:
    if hover_menu == null or companion_sprite == null:
        return
    var hit_rect: Rect2 = companion_controller.get_interaction_rect(12.0)
    var menu_size: Vector2 = hover_menu.size
    var viewport_size: Vector2 = overlay_controller.get_logical_viewport_size()
    var desired: Vector2 = Vector2(hit_rect.position.x - menu_size.x - 18.0, hit_rect.position.y)
    if desired.x < 12.0:
        desired.x = hit_rect.end.x + 18.0
    desired.y = clampf(desired.y, 12.0, maxf(12.0, viewport_size.y - menu_size.y - 12.0))
    hover_menu.position = desired

func _load_active_character() -> void:
    var repo := InstalledCharacterRepository.new()
    var active := repo.get_active()
    if active.is_empty():
        push_warning("RuntimeMain: no active installed character; using generated debug frames")
        companion_sprite.sprite_frames = _create_debug_frames()
        companion_sprite.play("idle")
        return

    var frames := _load_character_frames(str(active.get("path", "")))
    if frames == null:
        push_warning("RuntimeMain: failed to load active character; using generated debug frames")
        companion_sprite.sprite_frames = _create_debug_frames()
        companion_sprite.play("idle")
        return

    companion_sprite.sprite_frames = frames
    companion_sprite.scale = Vector2(0.60, 0.60)
    animation_controller.bind(companion_sprite)
    _set_status("Loaded %s@%s" % [active.get("packageId", "?"), active.get("version", "?")])

func _create_debug_frames() -> SpriteFrames:
    var image := Image.create(180, 220, false, Image.FORMAT_RGBA8)
    image.fill(Color(0.32, 0.62, 0.95, 1.0))
    var texture := ImageTexture.create_from_image(image)
    var frames := SpriteFrames.new()
    if frames.has_animation("default"):
        frames.remove_animation("default")
    for name in ["idle", "idle_neutral", "idle_happy", "wave"]:
        frames.add_animation(name)
        frames.set_animation_loop(name, true)
        frames.set_animation_speed(name, 2.0)
        frames.add_frame(name, texture)
    return frames

func _load_character_frames(package_root: String) -> SpriteFrames:
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
        sheets[sid] = {
            "tex": ImageTexture.create_from_image(img),
            "fw": fw,
            "fh": fh,
            "cols": maxi(1, img.get_width() / fw),
            "rows": maxi(1, img.get_height() / fh)
        }
        if default_id.is_empty():
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
        var sid_raw = clip.get("sprite", null)
        var sid := str(sid_raw) if sid_raw != null else ""
        if sid.is_empty() or not sheets.has(sid):
            sid = default_id
        var sheet: Dictionary = sheets[sid]
        sf.add_animation(anim_name)
        sf.set_animation_loop(anim_name, bool(clip.get("loop", false)))
        sf.set_animation_speed(anim_name, float(clip.get("fps", 4.0)))
        var source_frames = clip.get("frames", [0])
        var frame_indices: Array = source_frames if source_frames is Array else [0]
        var max_frame: int = int(sheet["cols"]) * int(sheet["rows"])
        for idx_raw in frame_indices:
            var idx: int = clampi(int(idx_raw), 0, maxi(0, max_frame - 1))
            var atlas: AtlasTexture = AtlasTexture.new()
            atlas.atlas = sheet["tex"]
            atlas.region = Rect2(
                (idx % int(sheet["cols"])) * int(sheet["fw"]),
                (idx / int(sheet["cols"])) * int(sheet["fh"]),
                int(sheet["fw"]), int(sheet["fh"])
            )
            sf.add_frame(anim_name, atlas)
    if sf.get_animation_names().is_empty():
        return null
    if not sf.has_animation("idle_neutral") and sf.has_animation("idle"):
        sf.add_animation("idle_neutral")
        sf.set_animation_loop("idle_neutral", true)
        sf.set_animation_speed("idle_neutral", sf.get_animation_speed("idle"))
        for index in range(sf.get_frame_count("idle")):
            sf.add_frame("idle_neutral", sf.get_frame_texture("idle", index))
    return sf

func _set_status(text: String) -> void:
    print("[RuntimeMain] " + text)
    if status_label != null:
        status_label.text = text
