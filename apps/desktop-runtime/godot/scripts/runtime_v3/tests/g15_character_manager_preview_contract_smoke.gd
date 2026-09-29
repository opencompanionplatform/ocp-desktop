extends SceneTree

const PickerControllerScript = preload(
	"res://scripts/runtime_v3/controllers/character_picker_controller.gd"
)


class FakeCharacterService:
	extends RefCounted

	func build_preview_frames(_package_info: Dictionary) -> Dictionary:
		var frames := SpriteFrames.new()
		if frames.has_animation("default"):
			frames.remove_animation("default")
		for index in range(22):
			var animation_name := "walk_%02d" % index if index < 8 else "emote_%02d" % index
			frames.add_animation(animation_name)
			frames.set_animation_loop(animation_name, true)
			frames.set_animation_speed(animation_name, 6.0)
		return {"ok": true, "frames": frames}


class FakeServices:
	extends Node
	var character_service = FakeCharacterService.new()


class FakeContext:
	extends Node
	var settings: Dictionary = {}


class FakeEventBus:
	extends Node
	var published: Array[Dictionary] = []

	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var controller = PickerControllerScript.new()
	var services := FakeServices.new()
	var context := FakeContext.new()
	var bus := FakeEventBus.new()
	var sprite := AnimatedSprite2D.new()
	var list := GridContainer.new()
	list.columns = 3
	var search := LineEdit.new()
	var category := OptionButton.new()
	var status := Label.new()
	var play := Button.new()
	var loop := CheckButton.new()
	var speed := OptionButton.new()
	var apply := Button.new()
	var store := Button.new()
	for category_name in ["All", "Movement", "Surface", "Transitions", "Other"]:
		category.add_item(category_name)
	for speed_item in [["0.5x", 0.5], ["1x", 1.0], ["1.5x", 1.5], ["2x", 2.0]]:
		speed.add_item(str(speed_item[0]))
		speed.set_item_metadata(speed.item_count - 1, float(speed_item[1]))
	speed.select(1)
	for node in [controller, services, context, bus, sprite, list, search, category, status, play, loop, speed, apply, store]:
		holder.add_child(node)
	controller.services = services
	controller.context = context
	controller.event_bus = bus
	controller.bind_preview(sprite, list, search, category, status, play, loop, speed, apply, store)
	controller._select_preview_package({"packageId": "character.alpha", "version": "1.0.0"})
	var dynamic_catalogue: bool = controller.preview_frames != null and list.get_child_count() == 22
	var first_tile: Button = list.get_child(0) as Button
	var semantic_icon: bool = is_instance_valid(first_tile) and is_instance_valid(
		first_tile.find_child("AnimationTileIcon", true, false)
	)
	search.text = "walk"
	controller._rebuild_animation_list("")
	var search_works: bool = list.get_child_count() == 8
	apply.pressed.emit()
	var apply_only: bool = bus.published.size() == 1 \
		and bus.published[0].topic == &"character.activate_requested"
	var uri_validation: bool = PickerControllerScript.is_valid_store_url("https://store.example.com/characters") \
		and PickerControllerScript.is_valid_store_url("http://127.0.0.1:3000") \
		and PickerControllerScript.is_valid_store_url("http://localhost:3000/") \
		and not PickerControllerScript.is_valid_store_url("http://store.example.com") \
		and not PickerControllerScript.is_valid_store_url("https://")
	var store_safe_by_default: bool = not store.disabled
	var runtime_wiring_source: String = FileAccess.get_file_as_string("res://scripts/runtime_v3/runtime_app.gd")
	var grid_wiring: bool = runtime_wiring_source.contains(
		"find_child(\"AnimationCatalog\", true, false) as Container"
	)
	var ok: bool = dynamic_catalogue and semantic_icon and search_works and apply_only and uri_validation and store_safe_by_default and grid_wiring
	print("[G15.8] catalogue22=%s icons=%s grid_wiring=%s search=%s apply_only=%s uri=%s store_safe=%s" % [
		str(dynamic_catalogue).to_lower(), str(search_works).to_lower(),
		str(semantic_icon).to_lower(), str(grid_wiring).to_lower(),
		str(apply_only).to_lower(), str(uri_validation).to_lower(), str(store_safe_by_default).to_lower(),
	])
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
