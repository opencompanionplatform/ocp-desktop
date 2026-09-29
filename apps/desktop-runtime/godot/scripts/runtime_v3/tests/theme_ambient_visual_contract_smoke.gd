extends SceneTree

const AmbientScript = preload("res://scripts/runtime_v3/ui/ambient_wave.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Control.new()
	holder.size = Vector2(960, 640)
	get_root().add_child(holder)
	var ambient = AmbientScript.new()
	holder.add_child(ambient)
	ambient.configure("shell")
	var palette := {"accent": Color("#28b9ee")}

	ambient.apply_ocp_theme(palette, "solid")
	var solid_ok: bool = bool(not ambient.visible and not ambient.is_processing())
	ambient.apply_ocp_theme(palette, "glass")
	var glass_ok: bool = bool(ambient.visible and ambient.is_processing() and ambient.theme_name == "glass")
	ambient.apply_ocp_theme(palette, "liquid")
	var liquid_ok: bool = bool(ambient.visible and ambient.is_processing() and ambient.theme_name == "liquid")

	var ok: bool = solid_ok and glass_ok and liquid_ok
	print("[P3.4.8] ambient_theme_visual solid=", solid_ok, " glass=", glass_ok, " liquid=", liquid_ok)
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
