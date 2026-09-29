extends RefCounted

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")

func run() -> bool:
	var context = ContextScript.new()
	context.update_character({"name": "Test"})
	context.update_window({"hidden_to_tray": true})
	return context.character.get("name") == "Test" \
		and bool(context.window.get("hidden_to_tray", false)) \
		and str(context.settings.get("ocp_cloud_api_url", "")).begins_with("https://") \
		and not bool(context.settings.get("progression_aura_enabled", true))
