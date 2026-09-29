extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const SettingsScript = preload("res://scripts/runtime_v3/services/settings_service.gd")
const CharacterScript = preload("res://scripts/runtime_v3/services/character_service.gd")


func _initialize() -> void:
	var root_node := Node.new()
	get_root().add_child(root_node)

	var context = ContextScript.new()
	var bus = BusScript.new()
	var settings = SettingsScript.new()
	var character = CharacterScript.new()

	root_node.add_child(context)
	root_node.add_child(bus)
	root_node.add_child(settings)
	root_node.add_child(character)

	settings.configure(context, bus)
	character.configure(context, bus)

	var frames: SpriteFrames = character.build_fallback_frames()
	if frames == null or not frames.has_animation("idle"):
		push_error("[FAIL] fallback SpriteFrames")
		quit(1)
		return

	var expected := Vector2(1234.0, 567.0)
	if not settings.save_character_desktop_position(expected, 2, 1.5):
		push_error("[FAIL] save position")
		quit(1)
		return

	var loaded: Dictionary = settings.load_character_desktop_position()
	if loaded.get("position", Vector2.ZERO) != expected:
		push_error("[FAIL] restore position")
		quit(1)
		return

	print("[PASS] Runtime V3 Phase 3 integration")
	quit(0)
