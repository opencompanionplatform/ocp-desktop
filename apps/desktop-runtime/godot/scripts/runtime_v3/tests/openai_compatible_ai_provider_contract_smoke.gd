extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const ProviderScript = preload("res://scripts/runtime_v3/services/openai_compatible_ai_provider_adapter.gd")

class FakeBridge:
	extends Node
	signal ai_response_received(message_id: String, text: String, provider_id: String, model: String)
	signal ai_response_failed(message_id: String, error: String, provider_id: String)
	var request_args: Dictionary = {}
	var credential_present := true

	func provider_credential_present(provider_id: String) -> bool:
		return credential_present and provider_id == "openai-compatible"

	func request_cloud_ai(message_id: String, prompt: String, system_prompt: String, provider_id: String, base_url: String, model: String, timeout_seconds: int) -> bool:
		request_args = {
			"message_id": message_id,
			"prompt": prompt,
			"system_prompt": system_prompt,
			"provider_id": provider_id,
			"base_url": base_url,
			"model": model,
			"timeout_seconds": timeout_seconds,
		}
		call_deferred("_complete", message_id, provider_id, model)
		return true

	func _complete(message_id: String, provider_id: String, model: String) -> void:
		ai_response_received.emit(message_id, "cloud reply", provider_id, model)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bridge := FakeBridge.new()
	var provider := ProviderScript.new()
	holder.add_child(context)
	holder.add_child(bridge)
	holder.add_child(provider)
	context.update_settings({
		"ai_provider_id": "openai-compatible",
		"ai_base_url": "https://example.test/v1/",
		"ai_model": "cloud-model",
		"ai_timeout_seconds": 60,
	})
	provider.configure(context)
	provider.bind_bridge(bridge)
	var deltas: Array[String] = []
	var completed: Array[Dictionary] = []
	var failed: Array[Dictionary] = []
	var connection_results: Array[Dictionary] = []
	provider.stream_delta.connect(func(payload: Dictionary) -> void:
		deltas.append(str(payload.get("delta", ""))))
	provider.response_completed.connect(func(payload: Dictionary) -> void:
		completed.append(payload.duplicate(true)))
	provider.response_failed.connect(func(payload: Dictionary) -> void:
		failed.append(payload.duplicate(true)))
	provider.connection_tested.connect(func(payload: Dictionary) -> void:
		connection_results.append(payload.duplicate(true)))
	provider.request({"message_id": "msg-cloud", "prompt": "hello cloud", "system_prompt": "trusted companion style"})
	await process_frame
	await process_frame
	var status: Dictionary = provider.status()
	var secure_bridge_ok := not bridge.request_args.has("credential")
	var live_contract_ok: bool = status.get("configured", false) \
		and bridge.request_args.get("message_id", "") == "msg-cloud" \
		and bridge.request_args.get("provider_id", "") == "openai-compatible" \
		and bridge.request_args.get("base_url", "") == "https://example.test/v1" \
		and bridge.request_args.get("model", "") == "cloud-model" \
		and bridge.request_args.get("system_prompt", "") == "trusted companion style" \
		and secure_bridge_ok \
		and deltas == ["cloud reply"] \
		and completed.size() == 1 \
		and completed[0].get("text", "") == "cloud reply"

	bridge.request_args.clear()
	provider.test_connection()
	await process_frame
	await process_frame
	var connection_test_ok: bool = connection_results.size() == 1 \
		and bool(connection_results[0].get("ok", false)) \
		and bridge.request_args.get("prompt", "") == "Reply with OK." \
		and bridge.request_args.get("system_prompt", "invalid") == "" \
		and not bridge.request_args.has("credential") \
		and bool(provider.status().get("reachable", false))

	bridge.request_args.clear()
	provider.configure_values({
		"ai_base_url": "http://insecure.example/v1",
		"ai_model": "cloud-model",
	})
	provider.request({"message_id": "msg-insecure", "prompt": "must not leave runtime"})
	var insecure_rejected: bool = bridge.request_args.is_empty() \
		and failed.size() == 1 \
		and str(failed[0].get("error", "")).contains("must use HTTPS") \
		and not bool(provider.status().get("configured", true))
	var ok: bool = live_contract_ok and connection_test_ok and insecure_rejected
	print("[OPENAI-COMPATIBLE] configured=", status.get("configured", false), " secure_bridge=", secure_bridge_ok, " completed=", completed.size(), " live_test=", connection_test_ok, " https_guard=", insecure_rejected, " ok=", ok)
	holder.free()
	await process_frame
	quit(0 if ok else 1)
