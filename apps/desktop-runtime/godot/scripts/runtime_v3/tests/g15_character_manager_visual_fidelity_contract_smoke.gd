extends SceneTree

const ShellScript = preload("res://scripts/runtime_v3/ui/character_manager_shell.gd")
const AuraScript = preload("res://scripts/runtime_v3/ui/preview_aura_stage.gd")
const BackdropScript = preload("res://scripts/runtime_v3/ui/preview_stage_backdrop.gd")
const IconScript = preload("res://scripts/runtime_v3/ui/animation_tile_icon.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shell := ShellScript.new()
	var palette: Dictionary = shell._manager_palette()
	var holder := Control.new()
	holder.size = Vector2(720, 480)
	get_root().add_child(holder)
	var backdrop := BackdropScript.new()
	var aura := AuraScript.new()
	var icon := IconScript.new()
	icon.animation_name = "climb_up"
	holder.add_child(backdrop)
	holder.add_child(aura)
	holder.add_child(icon)
	await process_frame
	var local_palette: bool = palette.get("surface_strong") == Color("#020611") \
		and palette.get("accent") == Color("#27c7ff") \
		and palette.get("border") == Color("#26517f")
	var desktop_widths := ShellScript.responsive_side_widths(1920.0)
	var compact_widths := ShellScript.responsive_side_widths(1080.0)
	var layout_root := PanelContainer.new()
	var layout_content := Control.new()
	var layout_library := PanelContainer.new()
	layout_library.name = "InstalledCharacterLibrary"
	var layout_sidebar := PanelContainer.new()
	layout_sidebar.name = "AnimationPreviewPanel"
	layout_root.add_child(layout_library)
	layout_root.add_child(layout_sidebar)
	shell.root_panel = layout_root
	shell.content = layout_content
	shell.size = Vector2i(1920, 900)
	shell._layout_shell()
	var expanded_columns: bool = layout_library.custom_minimum_size.x == 340.0 \
		and layout_sidebar.custom_minimum_size.x == 420.0
	shell.prepare_for_window_rect(Vector2i(1080, 700))
	var restore_constraints_released: bool = layout_library.custom_minimum_size.x == 270.0 \
		and layout_sidebar.custom_minimum_size.x == 330.0
	var responsive_columns: bool = desktop_widths == Vector2(340.0, 420.0) \
		and compact_widths == Vector2(270.0, 330.0) \
		and expanded_columns \
		and restore_constraints_released
	var presentation_safe: bool = backdrop.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and aura.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and icon.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and backdrop.is_processing() and aura.is_processing()
	var ok: bool = local_palette and responsive_columns and presentation_safe
	print("[G15.10] local_palette=%s responsive_columns=%s presentation_safe=%s" % [
		str(local_palette).to_lower(), str(responsive_columns).to_lower(), str(presentation_safe).to_lower(),
	])
	layout_root.free()
	layout_content.free()
	holder.queue_free()
	shell.free()
	await process_frame
	quit(0 if ok else 1)
