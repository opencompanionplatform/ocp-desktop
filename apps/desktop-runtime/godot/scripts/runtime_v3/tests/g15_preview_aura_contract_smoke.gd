extends SceneTree

const PreviewAuraScript = preload("res://scripts/runtime_v3/ui/preview_aura_stage.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Control.new()
	holder.size = Vector2(640, 420)
	get_root().add_child(holder)
	var aura := PreviewAuraScript.new()
	holder.add_child(aura)
	await process_frame
	var ok := aura.mouse_filter == Control.MOUSE_FILTER_IGNORE \
		and aura.is_processing() and aura.size == holder.size
	print("[G15.8] preview_aura=%s input_safe=%s" % [
		str(is_instance_valid(aura)).to_lower(),
		str(ok).to_lower(),
	])
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
