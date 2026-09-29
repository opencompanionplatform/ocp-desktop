extends SceneTree

const ProviderScript = preload("res://scripts/runtime_v3/services/ollama_ai_provider_adapter.gd")

var last_payload: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var provider := ProviderScript.new()
	holder.add_child(provider)
	provider.models_discovered.connect(func(payload: Dictionary) -> void:
		last_payload = payload.duplicate(true))

	var raw_models: Array = []
	for index in range(20):
		raw_models.append({"name": "model-%02d" % index})
	raw_models.insert(1, {"name": "model-00"})
	raw_models.insert(2, {"name": "bad\nmodel"})
	raw_models.insert(3, {"name": ""})
	provider._on_models_discovered(
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray(),
		JSON.stringify({"models": raw_models}).to_utf8_buffer()
	)
	var models: Array = last_payload.get("models", [])
	var success_ok: bool = bool(last_payload.get("ok", false)) \
		and str(last_payload.get("provider_id", "")) == "ollama" \
		and models.size() == 16 \
		and models[0] == "model-00" \
		and models[1] == "model-01" \
		and not models.has("bad\nmodel") \
		and models.count("model-00") == 1

	last_payload.clear()
	provider._on_models_discovered(
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray(),
		JSON.stringify({"models": {"unexpected": true}}).to_utf8_buffer()
	)
	var invalid_shape_ok: bool = not bool(last_payload.get("ok", true)) \
		and last_payload.get("models", []) == []

	var ok := success_ok and invalid_shape_ok
	print("[OLLAMA-DISCOVERY] bounded=", success_ok, " invalid_shape=", invalid_shape_ok, " ok=", ok)
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
