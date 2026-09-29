extends SceneTree

const NativeHostLifecycleScript = preload("res://scripts/runtime_v3/services/native_host_lifecycle.gd")


class FakeContext:
	extends Node
	var runtime_config: Dictionary = {
		"native_presentation_enabled": true,
		"theme_preset": "liquid",
	}
	var settings: Dictionary = {
		"font_family": "Noto Sans Thai",
		"language": "th",
		"text_scale": 1.15,
		"bubble_style": "Rounded",
		"reduce_motion": false,
	}
	var character: Dictionary = {
		"presentation_scale": 1.0,
	}


func _initialize() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var lifecycle = NativeHostLifecycleScript.new()
	holder.add_child(context)
	holder.add_child(lifecycle)
	lifecycle.context = context
	lifecycle.host_token = "native-hover-localization-contract"
	var command_path := ProjectSettings.globalize_path("user://native-hover-localization-contract.json")
	lifecycle.ui_command_path = command_path
	DirAccess.remove_absolute(command_path)

	lifecycle._on_theme_changed({"name": "liquid"})
	var payload: Dictionary = {}
	var file := FileAccess.open(command_path, FileAccess.READ)
	if file != null:
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary:
			payload = parsed

	var ok := str(payload.get("status", "")) == "theme-request" 		and str(payload.get("language", "")) == "th" 		and str(payload.get("font_family", "")) == "Noto Sans Thai" 		and is_equal_approx(float(payload.get("text_scale", 0.0)), 1.15)
	print("[NATIVE-HOVER-I18N] language=", payload.get("language", ""),
		" font=", payload.get("font_family", ""),
		" text_scale=", payload.get("text_scale", 0.0),
		" ok=", ok)
	DirAccess.remove_absolute(command_path)
	holder.queue_free()
	quit(0 if ok else 1)
