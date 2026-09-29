extends "res://scripts/runtime_v3/services/ai_provider_adapter.gd"
class_name RuntimeV3OpenAICompatibleAIProviderAdapter

## Secure cloud-chat adapter. Godot never reads the API key: this adapter sends
## prompt + endpoint/model metadata to the native bridge, Kernel resolves the
## provider credential from the OS keystore and performs the HTTPS request.

signal connection_tested(payload: Dictionary)

var bridge: Node
var base_url := "https://api.openai.com/v1"
var model := ""
var request_timeout_seconds := 45.0
var _active_message_id := ""
var _active_payload: Dictionary = {}
var _probe_message_id := ""
var _last_test_ok := false
var _last_test_message := "Not tested"


func _init() -> void:
	provider_id = "openai-compatible"
	display_name = "OpenAI-compatible"
	supports_streaming = false


func configure(runtime_context: Node) -> void:
	super.configure(runtime_context)
	if is_instance_valid(context):
		base_url = _normalize_base_url(str(context.settings.get("ai_base_url", base_url)))
		model = str(context.settings.get("ai_model", model)).strip_edges()
		request_timeout_seconds = clampf(float(context.settings.get("ai_timeout_seconds", 45.0)), 5.0, 300.0)


func configure_values(values: Dictionary) -> void:
	base_url = _normalize_base_url(str(values.get("ai_base_url", base_url)))
	model = str(values.get("ai_model", model)).strip_edges()
	request_timeout_seconds = clampf(float(values.get("ai_timeout_seconds", request_timeout_seconds)), 5.0, 300.0)


func bind_bridge(target: Node) -> void:
	if bridge == target:
		return
	_disconnect_bridge()
	bridge = target
	if not is_instance_valid(bridge):
		return
	if bridge.has_signal("ai_response_received"):
		bridge.connect("ai_response_received", Callable(self, "_on_bridge_response_received"))
	if bridge.has_signal("ai_response_failed"):
		bridge.connect("ai_response_failed", Callable(self, "_on_bridge_response_failed"))


func _exit_tree() -> void:
	_disconnect_bridge()


func request(payload: Dictionary) -> void:
	var prompt := str(payload.get("prompt", "")).strip_edges()
	var message_id := str(payload.get("message_id", "")).strip_edges()
	if prompt.is_empty() or message_id.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "Prompt or message id is empty",
			"request": payload,
			"provider_id": provider_id,
		})
		return
	if base_url.is_empty() or model.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "OpenAI-compatible Base URL and model are required",
			"request": payload,
			"provider_id": provider_id,
		})
		return
	if not _https_ready():
		response_failed.emit({
			"message_id": message_id,
			"error": "OpenAI-compatible cloud Base URL must use HTTPS",
			"request": payload,
			"provider_id": provider_id,
		})
		return
	if not _active_message_id.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "Cloud AI is already processing another request",
			"request": payload,
			"provider_id": provider_id,
		})
		return
	if not is_instance_valid(bridge) or not bridge.has_method("request_cloud_ai"):
		response_failed.emit({
			"message_id": message_id,
			"error": "Secure cloud AI bridge is unavailable",
			"request": payload,
			"provider_id": provider_id,
		})
		return

	_active_message_id = message_id
	_active_payload = payload.duplicate(true)
	stream_started.emit({
		"message_id": message_id,
		"request": payload,
		"provider_id": provider_id,
	})
	var accepted := bool(bridge.call(
		"request_cloud_ai",
		message_id,
		prompt,
		str(payload.get("system_prompt", "")),
		provider_id,
		base_url,
		model,
		int(request_timeout_seconds)
	))
	if not accepted:
		_fail_active("Kernel did not accept the cloud AI request")


func cancel(message_id: String) -> void:
	# The current kernel cloud slice is a single non-streaming HTTP turn. There
	# is no remote cancellation command yet, but clearing local ownership makes
	# a late response harmless to the current Chat session.
	if message_id == _active_message_id:
		_fail_active("Request cancelled")


func test_connection() -> void:
	if not _https_ready() or model.is_empty() or not _credential_present():
		_last_test_ok = false
		_last_test_message = "Configure HTTPS Base URL, model, and a secure API key first."
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": _last_test_message,
			"model": model,
		})
		return
	if not _active_message_id.is_empty() or not _probe_message_id.is_empty():
		_last_test_ok = false
		_last_test_message = "Cloud provider is busy. Try the connection test again after the current request finishes."
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": _last_test_message,
			"model": model,
		})
		return
	if not is_instance_valid(bridge) or not bridge.has_method("request_cloud_ai"):
		_last_test_ok = false
		_last_test_message = "Secure cloud AI bridge is unavailable."
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": _last_test_message,
			"model": model,
		})
		return

	_probe_message_id = "cloud_probe_%d" % Time.get_ticks_msec()
	_last_test_message = "Testing cloud endpoint…"
	var accepted := bool(bridge.call(
		"request_cloud_ai",
		_probe_message_id,
		"Reply with OK.",
		"",
		provider_id,
		base_url,
		model,
		mini(int(request_timeout_seconds), 20)
	))
	if not accepted:
		_probe_message_id = ""
		_last_test_ok = false
		_last_test_message = "Kernel did not accept the cloud connection test."
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": _last_test_message,
			"model": model,
		})


func status() -> Dictionary:
	var credential_present := _credential_present()
	return {
		"provider_id": provider_id,
		"display_name": display_name,
		"supports_streaming": supports_streaming,
		"configured": _https_ready() and not model.is_empty() and credential_present,
		"credential_present": credential_present,
		"reachable": _last_test_ok,
		"mode": "cloud",
		"base_url": base_url,
		"model": model,
		"status_message": _last_test_message,
	}


func _on_bridge_response_received(message_id: String, text: String, response_provider_id: String, response_model: String) -> void:
	if response_provider_id.strip_edges().to_lower() != provider_id:
		return
	if message_id == _probe_message_id:
		_probe_message_id = ""
		_last_test_ok = true
		_last_test_message = "Connected to cloud provider · %s" % response_model
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": true,
			"message": _last_test_message,
			"model": response_model,
		})
		return
	if message_id != _active_message_id:
		return
	var request_payload := _active_payload.duplicate(true)
	_active_message_id = ""
	_active_payload.clear()
	stream_delta.emit({
		"message_id": message_id,
		"delta": text,
		"text": text,
		"request": request_payload,
		"provider_id": provider_id,
	})
	response_completed.emit({
		"message_id": message_id,
		"text": text,
		"request": request_payload,
		"provider_id": provider_id,
		"model": response_model,
	})


func _on_bridge_response_failed(message_id: String, error: String, response_provider_id: String) -> void:
	if response_provider_id.strip_edges().to_lower() != provider_id:
		return
	if message_id == _probe_message_id:
		_probe_message_id = ""
		_last_test_ok = false
		_last_test_message = error
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": error,
			"model": model,
		})
		return
	if message_id != _active_message_id:
		return
	_fail_active(error)


func _fail_active(message: String) -> void:
	var message_id := _active_message_id
	var request_payload := _active_payload.duplicate(true)
	_active_message_id = ""
	_active_payload.clear()
	response_failed.emit({
		"message_id": message_id,
		"error": message,
		"request": request_payload,
		"provider_id": provider_id,
	})


func _https_ready() -> bool:
	return base_url.strip_edges().to_lower().begins_with("https://")


func _credential_present() -> bool:
	return is_instance_valid(bridge) \
		and bridge.has_method("provider_credential_present") \
		and bool(bridge.call("provider_credential_present", provider_id))


func _disconnect_bridge() -> void:
	if not is_instance_valid(bridge):
		bridge = null
		return
	if bridge.has_signal("ai_response_received") and bridge.is_connected("ai_response_received", Callable(self, "_on_bridge_response_received")):
		bridge.disconnect("ai_response_received", Callable(self, "_on_bridge_response_received"))
	if bridge.has_signal("ai_response_failed") and bridge.is_connected("ai_response_failed", Callable(self, "_on_bridge_response_failed")):
		bridge.disconnect("ai_response_failed", Callable(self, "_on_bridge_response_failed"))
	bridge = null


func _normalize_base_url(value: String) -> String:
	var normalized := value.strip_edges()
	while normalized.ends_with("/") and normalized.length() > 0:
		normalized = normalized.substr(0, normalized.length() - 1)
	return normalized
