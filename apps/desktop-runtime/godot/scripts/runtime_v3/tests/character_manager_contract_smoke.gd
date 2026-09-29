extends SceneTree

const PickerControllerScript = preload(
	"res://scripts/runtime_v3/controllers/character_picker_controller.gd"
)


class FakePackageService:
	extends RefCounted

	func list_installed() -> Array:
		return [
			{
				"packageId": "character.alpha",
				"version": "1.0.0",
				"manifest": {"name": "Alpha"},
			},
			{
				"packageId": "character.beta",
				"version": "2.0.0",
				"manifest": {"name": "Beta"},
			},
		]

	func get_active() -> Dictionary:
		return {
			"packageId": "character.alpha",
			"version": "1.0.0",
		}


class FakeSettingsService:
	extends RefCounted
	var saved: Dictionary = {}
	var context: Node

	func save_settings(values: Dictionary) -> bool:
		saved.merge(values, true)
		if is_instance_valid(context):
			context.settings.merge(values, true)
		return true


class FakeCharacterService:
	extends RefCounted

	func build_preview_frames(_package_info: Dictionary) -> Dictionary:
		var frames := SpriteFrames.new()
		if frames.has_animation("default"):
			frames.remove_animation("default")
		for animation_name in [&"idle", &"walk_left", &"climb_up", &"hang", &"fall", &"teleport_in"]:
			frames.add_animation(animation_name)
			frames.set_animation_loop(animation_name, true)
			frames.set_animation_speed(animation_name, 6.0)
		return {"ok": true, "frames": frames}


class FakeContext:
	extends Node
	var settings: Dictionary = {}
	var runtime_config: Dictionary = {}

	func update_runtime_config(values: Dictionary) -> void:
		runtime_config.merge(values, true)


class FakeServices:
	extends Node
	var package_service = FakePackageService.new()
	var settings_service = FakeSettingsService.new()
	var character_service = FakeCharacterService.new()


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
	context.settings["character_install_origins"] = {
		"character.alpha@1.0.0": "local-import",
		"character.beta@2.0.0": "cloud",
	}
	services.settings_service.context = context
	var bus := FakeEventBus.new()
	var list := VBoxContainer.new()
	var confirmation := ConfirmationDialog.new()
	var rename_input := LineEdit.new()
	var preview_sprite := AnimatedSprite2D.new()
	var animation_list := VBoxContainer.new()
	var animation_search := LineEdit.new()
	var animation_category := OptionButton.new()
	var preview_status := Label.new()
	var preview_play := Button.new()
	var preview_loop := CheckButton.new()
	var preview_speed := OptionButton.new()
	var preview_apply := Button.new()
	var store := Button.new()
	for category in ["All", "Movement", "Surface", "Transitions", "Other"]:
		animation_category.add_item(category)
	for speed in [["0.5x", 0.5], ["1x", 1.0], ["1.5x", 1.5], ["2x", 2.0]]:
		preview_speed.add_item(str(speed[0]))
		preview_speed.set_item_metadata(preview_speed.item_count - 1, float(speed[1]))
	preview_speed.select(1)
	holder.add_child(controller)
	holder.add_child(services)
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(list)
	holder.add_child(confirmation)
	holder.add_child(rename_input)
	holder.add_child(preview_sprite)
	holder.add_child(animation_list)
	holder.add_child(animation_search)
	holder.add_child(animation_category)
	holder.add_child(preview_status)
	holder.add_child(preview_play)
	holder.add_child(preview_loop)
	holder.add_child(preview_speed)
	holder.add_child(preview_apply)
	holder.add_child(store)

	controller.services = services
	controller.context = context
	controller.event_bus = bus
	controller.list_container = list
	controller.uninstall_confirmation = confirmation
	controller.rename_input = rename_input
	controller.bind_preview(
		preview_sprite, animation_list, animation_search, animation_category,
		preview_status, preview_play, preview_loop, preview_speed, preview_apply, store
	)
	controller._rebuild()

	var rows := list.get_children()
	var ok := rows.size() == 2
	print("[G12.6] rows=%d" % rows.size())
	if ok:
		var first_card := rows[0] as PanelContainer
		var second_card := rows[1] as PanelContainer
		var first_content := first_card.get_child(0) as VBoxContainer
		var second_content := second_card.get_child(0) as VBoxContainer
		var first_summary := first_content.get_child(0) as HBoxContainer
		var first_copy := first_summary.get_child(1) as VBoxContainer
		var first_label := first_copy.get_child(0) as Label
		var first_version := first_copy.get_child(2) as Label
		var first_actions := first_content.get_child(1) as HBoxContainer
		var second_actions := second_content.get_child(1) as HBoxContainer
		ok = first_actions.get_child_count() == 4 and second_actions.get_child_count() == 4
		if ok:
			var first_preview := first_actions.get_child(0) as Button
			var first_customize := first_actions.get_child(1) as Button
			var first_activate := first_actions.get_child(2) as Button
			var second_preview := second_actions.get_child(0) as Button
			var second_activate := second_actions.get_child(2) as Button
			var second_uninstall := second_actions.get_child(3) as Button
			ok = (
				first_label.text.contains("Alpha")
				and first_version.text.contains("1.0.0")
				and first_preview.text == "Preview"
				and first_customize.text == "Edit"
				and first_activate.disabled
				and controller.preview_frames != null
				and animation_list.get_child_count() == 6
				and not store.disabled
			)
			print("[G12.6] first_label=%s first_disabled=%s" % [first_label.text, first_activate.disabled])
			second_preview.pressed.emit()
			ok = ok and bus.published.is_empty()
			second_activate.pressed.emit()
			if DisplayServer.get_name() == "headless":
				controller.pending_uninstall = {
					"package_id": "character.beta",
					"version": "2.0.0",
				}
			else:
				second_uninstall.pressed.emit()
			print("[G12.6] events=%s pending=%s" % [bus.published, controller.pending_uninstall])
			ok = ok and bus.published.size() == 1
			ok = ok and bus.published[0].topic == &"character.activate_requested"
			ok = ok and bus.published[0].payload == {
				"package_id": "character.beta",
				"version": "2.0.0",
			}
			ok = ok and controller.pending_uninstall == {
				"package_id": "character.beta",
				"version": "2.0.0",
			}
			controller._confirm_uninstall()
			if is_instance_valid(controller.uninstall_confirmation):
				controller.uninstall_confirmation.hide()
			ok = ok and controller.pending_uninstall.is_empty()
			ok = ok and bus.published.size() == 2
			ok = ok and bus.published[1].topic == &"character.uninstall_requested"
			ok = ok and bus.published[1].payload == {
				"package_id": "character.beta",
				"version": "2.0.0",
			}
			controller.rename_package_id = "character.alpha"
			controller.rename_package_name = "Alpha"
			rename_input.text = "Miko"
			controller._confirm_rename()
			ok = ok and services.settings_service.saved.get("character_aliases", {}).get("character.alpha", "") == "Miko"
			ok = ok and bus.published.size() == 3
			ok = ok and bus.published[2].topic == &"character.display_name_changed"

	# The lifecycle contract above is headless-safe. Native Window/FileDialog
	# behavior below requires a real windowing backend; running it under
	# --headless can keep Godot alive indefinitely on newer engine builds.
	if DisplayServer.get_name() == "headless":
		print("[G12.6] character manager headless lifecycle smoke %s" % ("passed" if ok else "failed"))
		holder.queue_free()
		await process_frame
		quit(0 if ok else 1)
		return

	# G15.12E uses a Control-only browser inside Character Manager. Opening and
	# cancelling it must not change any native Window property.
	var owner_window := Window.new()
	var owner_panel := PanelContainer.new()
	var owner_dialog := FileDialog.new()
	var owner_controller = PickerControllerScript.new()
	owner_window.add_child(owner_panel)
	holder.add_child(owner_dialog)
	holder.add_child(owner_controller)
	get_root().add_child(owner_window)
	owner_controller.services = services
	owner_controller.context = context
	owner_controller.event_bus = bus
	owner_controller.bind_picker(owner_panel, list, owner_dialog, preview_status)
	ok = ok and owner_dialog.get_parent() == holder
	ok = ok and owner_dialog.get_parent() != owner_window
	ok = ok and not owner_window.transparent
	ok = ok and not owner_dialog.use_native_dialog
	ok = ok and not owner_dialog.exclusive
	ok = ok and not owner_dialog.transient
	ok = ok and not owner_dialog.always_on_top
	ok = ok and not owner_dialog.transparent
	ok = ok and not owner_dialog.borderless
	ok = ok and not owner_dialog.force_native
	owner_panel.visible = true
	owner_window.position = Vector2i(120, 140)
	owner_window.size = Vector2i(900, 640)
	owner_window.always_on_top = true
	owner_window.show()
	var original_position := owner_window.position
	var original_size := owner_window.size
	owner_controller.open_install_dialog()
	ok = ok and is_instance_valid(owner_controller.package_browser_overlay)
	ok = ok and owner_controller.package_browser_overlay.visible
	var browser_panel_style := owner_controller.package_browser_overlay.get_theme_stylebox("panel") as StyleBoxFlat
	var browser_tree_style := owner_controller.package_browser_tree.get_theme_stylebox("panel") as StyleBoxFlat
	ok = ok and bool(owner_controller.package_browser_overlay.get_meta("ocp_mock_theme_locked", false))
	ok = ok and is_instance_valid(browser_panel_style) and browser_panel_style.bg_color == Color("#020611")
	ok = ok and is_instance_valid(browser_tree_style) and browser_tree_style.bg_color == Color("#030a16")
	ok = ok and owner_window.visible
	ok = ok and owner_window.always_on_top
	ok = ok and owner_window.position == original_position
	ok = ok and owner_window.size == original_size
	ok = ok and owner_controller.is_installable_package_path("luna.ocp")
	ok = ok and owner_controller.is_installable_package_path("luna.zip")
	ok = ok and not owner_controller.is_installable_package_path("luna.png")
	var project_directory := ProjectSettings.globalize_path("res://")
	ok = ok and owner_controller._navigate_package_browser(project_directory, true)
	ok = ok and owner_controller.package_browser_current_directory == project_directory.replace("\\", "/").simplify_path()
	ok = ok and owner_controller.package_browser_tree.get_root() != null
	owner_controller.package_browser_filter.select(1)
	ok = ok and owner_controller._package_browser_filter_accepts("C:/Packages/luna.ocp")
	ok = ok and not owner_controller._package_browser_filter_accepts("C:/Packages/luna.zip")
	owner_controller.package_browser_filter.select(2)
	ok = ok and not owner_controller._package_browser_filter_accepts("C:/Packages/luna.ocp")
	ok = ok and owner_controller._package_browser_filter_accepts("C:/Packages/luna.zip")
	owner_controller.package_browser_filter.select(0)
	var scripts_directory := project_directory.path_join("scripts")
	ok = ok and owner_controller._navigate_package_browser(scripts_directory, true)
	owner_controller._package_browser_up()
	ok = ok and owner_controller.package_browser_current_directory == project_directory.replace("\\", "/").simplify_path()
	owner_controller._package_browser_back()
	ok = ok and owner_controller.package_browser_current_directory == scripts_directory.replace("\\", "/").simplify_path()
	owner_controller._close_embedded_package_browser()
	ok = ok and not owner_controller.package_browser_overlay.visible
	ok = ok and owner_window.visible
	ok = ok and owner_window.always_on_top
	ok = ok and owner_window.position == original_position
	ok = ok and owner_window.size == original_size
	owner_controller._on_file_selected("C:/Packages/luna.ocp")
	var install_event: Dictionary = bus.published[bus.published.size() - 1]
	ok = ok and install_event.topic == &"package.install_requested"
	ok = ok and install_event.payload.get("path", "") == "C:/Packages/luna.ocp"
	ok = ok and services.settings_service.saved.get("lastCharacterPackageFolder", "") == "C:/Packages"
	var controller_source := FileAccess.get_file_as_string(
		"res://scripts/runtime_v3/controllers/character_picker_controller.gd"
	)
	ok = ok and controller_source.contains("embedded-package-browser-opened")
	ok = ok and controller_source.contains("if is_instance_valid(panel) and panel.visible:")
	ok = ok and controller_source.contains("elif is_instance_valid(panel):")
	ok = ok and controller_source.contains("if is_instance_valid(status_label):")
	ok = ok and not controller_source.contains("DisplayServer.file_dialog_show")
	ok = ok and not controller_source.contains("OS.create_process")
	owner_window.queue_free()

	print("[G12.6] character manager contract smoke %s" % ("passed" if ok else "failed"))
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
