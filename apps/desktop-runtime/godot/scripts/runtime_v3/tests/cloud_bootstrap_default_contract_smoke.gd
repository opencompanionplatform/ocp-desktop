extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const SettingsScript = preload("res://scripts/runtime_v3/services/settings_service.gd")
const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")


func _initialize() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := BusScript.new()
	var settings := SettingsScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(settings)
	settings.configure(context, bus)
	settings.load_settings()
	var url := str(context.settings.get("ocp_cloud_api_url", "")).strip_edges()
	var ok := url == "https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api"
	print("[CLOUD-BOOTSTRAP] url=%s ok=%s" % [url, str(ok).to_lower()])
	quit(0 if ok else 1)
