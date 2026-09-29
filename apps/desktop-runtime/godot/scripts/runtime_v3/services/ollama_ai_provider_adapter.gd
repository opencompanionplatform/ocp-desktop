extends "res://scripts/runtime_v3/services/ai_provider_adapter.gd"
class_name RuntimeV3OllamaAIProviderAdapter

## Local Ollama transport for the Chat provider boundary.
##
## Chat uses Ollama's NDJSON streaming endpoint directly through HTTPClient so
## response tokens are emitted as soon as they arrive. TTS is downstream of
## this boundary and must never block or control the Chat stream lifecycle.

signal connection_tested(payload: Dictionary)
signal models_discovered(payload: Dictionary)

const COMPANION_SYSTEM_PROMPT := "You are the user's OCP desktop companion. Reply in the same language as the user. Be warm and concise: use 1 to 3 short sentences unless the user asks for detail. Return plain text without Markdown. Do not identify yourself as Qwen or Ollama unless the user asks."
const LOW_MEMORY_HOST_BYTES := 24 * 1024 * 1024 * 1024
const LOW_MEMORY_CONTEXT_TOKENS := 2048
const STANDARD_CONTEXT_TOKENS := 4096
const CHAT_MAX_OUTPUT_TOKENS := 128
const REASONING_CHAT_MAX_OUTPUT_TOKENS := 384
const OLLAMA_KEEP_ALIVE := "15m"

var base_url := "http://127.0.0.1:11434"
var model := ""
var request_timeout_seconds := 45.0
var context_tokens := 8192
var _test_http: HTTPRequest
var _discover_http: HTTPRequest
var _active_message_id := ""
var _active_payload: Dictionary = {}
var _last_test_ok := false
var _last_test_message := "Not tested"

var _client: HTTPClient
var _stream_buffer := ""
var _stream_started_ms := 0
var _stream_last_activity_ms := 0
var _stream_first_delta_ms := 0
var _stream_url := ""
var _stream_host := ""
var _stream_port := 0
var _stream_https := false
var _stream_finished := false


func _init() -> void:
	provider_id = "ollama"
	display_name = "Ollama"
	supports_streaming = true


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	_poll_stream()


func configure(runtime_context: Node) -> void:
	super.configure(runtime_context)
	if is_instance_valid(context):
		base_url = _normalize_base_url(str(context.settings.get("ai_base_url", base_url)))
		model = str(context.settings.get("ai_model", model)).strip_edges()
		request_timeout_seconds = clampf(float(context.settings.get("ai_timeout_seconds", 45.0)), 5.0, 300.0)
		# Keep the Ollama KV/prompt-cache footprint bounded for the host. On 16 GB
		# shared-memory Windows systems qwen3.5 can load at 4096 tokens but fail
		# allocating prompt-cache state once Godot + Electron are active. Use 2048
		# on hosts below 24 GB; larger hosts retain the 4096 desktop ceiling.
		var context_limit := _host_context_limit()
		context_tokens = mini(clampi(int(context.settings.get("ai_context_tokens", context_limit)), 1024, 32768), context_limit)
	_ensure_http_nodes()


func configure_values(values: Dictionary) -> void:
	base_url = _normalize_base_url(str(values.get("ai_base_url", base_url)))
	model = str(values.get("ai_model", model)).strip_edges()
	request_timeout_seconds = clampf(float(values.get("ai_timeout_seconds", request_timeout_seconds)), 5.0, 300.0)
	var context_limit := _host_context_limit()
	context_tokens = mini(clampi(int(values.get("ai_context_tokens", context_tokens)), 1024, 32768), context_limit)
	_ensure_http_nodes()


func request(payload: Dictionary) -> void:
	var prompt := str(payload.get("prompt", "")).strip_edges()
	var message_id := str(payload.get("message_id", ""))
	if prompt.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "Prompt is empty",
			"request": payload,
			"provider_id": provider_id,
		})
		return
	if base_url.is_empty() or model.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "Ollama is not configured",
			"request": payload,
			"provider_id": provider_id,
		})
		return
	if not _active_message_id.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "Ollama is already processing another request",
			"request": payload,
			"provider_id": provider_id,
		})
		return

	if not _prepare_stream_url():
		response_failed.emit({
			"message_id": message_id,
			"error": "Invalid Ollama Base URL",
			"request": payload,
			"provider_id": provider_id,
		})
		return

	_active_message_id = message_id
	_active_payload = payload.duplicate(true)
	_stream_buffer = ""
	_stream_finished = false
	_stream_started_ms = Time.get_ticks_msec()
	_stream_last_activity_ms = _stream_started_ms
	_stream_first_delta_ms = 0
	print("[OllamaTiming] request-start at_ms=%d model=%s ctx=%d timeout_s=%.1f" % [_stream_started_ms, model, context_tokens, request_timeout_seconds])

	stream_started.emit({
		"message_id": message_id,
		"request": payload,
		"provider_id": provider_id,
	})

	_client = HTTPClient.new()
	var tls_options: TLSOptions = TLSOptions.client() if _stream_https else null
	var connect_error := _client.connect_to_host(_stream_host, _stream_port, tls_options)
	if connect_error != OK:
		_fail_active("Could not connect to Ollama (%s)" % error_string(connect_error))
		return


func cancel(message_id: String) -> void:
	if message_id.is_empty() or message_id != _active_message_id:
		return
	if is_instance_valid(_client):
		_client.close()
	_fail_active("Request cancelled")


func test_connection() -> void:
	_ensure_http_nodes()
	if base_url.is_empty() or model.is_empty():
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": "Ollama Base URL and model are required",
		})
		return
	# Connection test intentionally remains a normal bounded request. It only
	# verifies model readiness; production Chat uses the streaming transport.
	_test_http.timeout = minf(request_timeout_seconds, 60.0)
	var body := {
		"model": model,
		"stream": false,
		"think": false,
		"keep_alive": OLLAMA_KEEP_ALIVE,
		"options": {
			"num_ctx": context_tokens,
			"num_predict": 8,
		},
		"messages": [
			{"role": "user", "content": "Reply with OK only."},
		],
	}
	var error := _test_http.request(
		"%s/api/chat" % base_url,
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify(body)
	)
	if error != OK:
		_last_test_ok = false
		_last_test_message = "Could not start connection test (%s)" % error_string(error)
		connection_tested.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": _last_test_message,
		})


func discover_models() -> void:
	_ensure_http_nodes()
	if base_url.is_empty():
		models_discovered.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": "Ollama Base URL is required",
			"models": [],
		})
		return
	_discover_http.timeout = minf(request_timeout_seconds, 30.0)
	var error := _discover_http.request(
		"%s/api/tags" % base_url,
		PackedStringArray(),
		HTTPClient.METHOD_GET
	)
	if error != OK:
		models_discovered.emit({
			"provider_id": provider_id,
			"ok": false,
			"message": "Could not start Ollama model discovery (%s)" % error_string(error),
			"models": [],
		})


func adopt_connection_test_result(payload: Dictionary) -> void:
	_last_test_ok = bool(payload.get("ok", false))
	_last_test_message = str(payload.get("message", "Connected to Ollama" if _last_test_ok else "Ollama connection failed"))


func status() -> Dictionary:
	return {
		"provider_id": provider_id,
		"display_name": display_name,
		"supports_streaming": supports_streaming,
		"configured": not base_url.is_empty() and not model.is_empty(),
		"mode": "local",
		"base_url": base_url,
		"model": model,
		"context_tokens": context_tokens,
		"reachable": _last_test_ok,
		"status_message": _last_test_message,
	}


func _ensure_http_nodes() -> void:
	if not is_instance_valid(_test_http):
		_test_http = HTTPRequest.new()
		_test_http.name = "OllamaConnectionTest"
		add_child(_test_http)
		_test_http.request_completed.connect(_on_test_completed)
	if not is_instance_valid(_discover_http):
		_discover_http = HTTPRequest.new()
		_discover_http.name = "OllamaModelDiscovery"
		add_child(_discover_http)
		_discover_http.request_completed.connect(_on_models_discovered)


func _chat_output_token_limit() -> int:
	var normalized_model := model.strip_edges().to_lower()
	# DeepSeek-R1 style models spend part of num_predict on hidden reasoning
	# before message.content starts. 128 tokens frequently terminates inside the
	# reasoning phase and produces an empty user-visible reply. Give reasoning
	# models a larger bounded budget while keeping normal desktop models concise.
	if normalized_model.contains("deepseek-r1") or normalized_model.contains("deepseek_r1"):
		return REASONING_CHAT_MAX_OUTPUT_TOKENS
	return CHAT_MAX_OUTPUT_TOKENS


func _stream_stalled(now_ms: int) -> bool:
	if _stream_last_activity_ms <= 0:
		return false
	return now_ms - _stream_last_activity_ms > int(request_timeout_seconds * 1000.0)


func _poll_stream() -> void:
	if _active_message_id.is_empty() or not is_instance_valid(_client):
		return
	# Treat the configured timeout as a stall/first-byte timeout, not a total
	# generation deadline. A healthy local model may stream a longer answer for
	# more than 45s on CPU; killing an active stream made Chat report a false
	# timeout even while Ollama was still producing tokens.
	if _stream_stalled(Time.get_ticks_msec()):
		_client.close()
		_fail_active("Ollama stream stalled for %.1fs without data" % request_timeout_seconds)
		return

	_client.poll()
	var status_code := _client.get_status()
	if status_code == HTTPClient.STATUS_RESOLVING or status_code == HTTPClient.STATUS_CONNECTING:
		return
	if status_code == HTTPClient.STATUS_CONNECTED:
		var body := {
			"model": model,
			"stream": true,
			"think": false,
			"keep_alive": OLLAMA_KEEP_ALIVE,
			"options": {
				"num_ctx": context_tokens,
				"num_predict": _chat_output_token_limit(),
			},
			"messages": _chat_messages(
				str(_active_payload.get("prompt", "")),
				str(_active_payload.get("system_prompt", COMPANION_SYSTEM_PROMPT))
			),
		}
		var error := _client.request(
			HTTPClient.METHOD_POST,
			_stream_url,
			["Content-Type: application/json", "Accept: application/x-ndjson"],
			JSON.stringify(body)
		)
		if error != OK:
			_client.close()
			_fail_active("Could not start Ollama streaming request (%s)" % error_string(error))
		return
	if status_code == HTTPClient.STATUS_REQUESTING:
		return
	if status_code != HTTPClient.STATUS_BODY:
		if status_code == HTTPClient.STATUS_DISCONNECTED:
			_finish_stream()
		return

	var chunk := _client.read_response_body_chunk()
	if chunk.size() > 0:
		_stream_last_activity_ms = Time.get_ticks_msec()
		_stream_buffer += chunk.get_string_from_utf8()
		_process_ndjson_lines()
		if _stream_finished:
			return
	elif _client.get_status() == HTTPClient.STATUS_DISCONNECTED:
		_process_ndjson_lines(true)
		_finish_stream()


func _process_ndjson_lines(flush_partial: bool = false) -> void:
	# Ollama normally emits newline-delimited JSON, but Windows/local transports
	# can coalesce multiple JSON objects into one body chunk without preserving
	# the newline boundary. Parse complete top-level objects by brace depth so
	# both true NDJSON and concatenated objects are accepted.
	while true:
		_stream_buffer = _stream_buffer.lstrip(" \t\r\n")
		if _stream_buffer.is_empty():
			break
		var object_start := _stream_buffer.find("{")
		if object_start < 0:
			break
		if object_start > 0:
			_stream_buffer = _stream_buffer.substr(object_start)
		var object_end := _complete_json_object_end(_stream_buffer)
		if object_end < 0:
			break
		var packet_text := _stream_buffer.substr(0, object_end + 1)
		_stream_buffer = _stream_buffer.substr(object_end + 1)
		_process_ndjson_line(packet_text)
		if _stream_finished:
			break

	if _stream_buffer.length() > 1_048_576:
		_fail_active("Ollama streaming buffer exceeded 1 MiB")
		return
	if flush_partial and not _stream_buffer.strip_edges().is_empty() and not _stream_finished:
		var packet_text := _stream_buffer.strip_edges()
		_stream_buffer = ""
		_process_ndjson_line(packet_text)


func _complete_json_object_end(buffer: String) -> int:
	var depth := 0
	var in_string := false
	var escaped := false
	for index in range(buffer.length()):
		var code := buffer.unicode_at(index)
		if in_string:
			if escaped:
				escaped = false
			elif code == 92:
				escaped = true
			elif code == 34:
				in_string = false
			continue
		if code == 34:
			in_string = true
		elif code == 123:
			depth += 1
		elif code == 125:
			depth -= 1
			if depth == 0:
				return index
			if depth < 0:
				return -1
	return -1


func _process_ndjson_line(line: String) -> void:
	if line.is_empty():
		return
	var parsed: Variant = JSON.parse_string(line)
	if not parsed is Dictionary:
		_fail_active("Ollama returned invalid streaming JSON")
		return
	var packet: Dictionary = parsed
	if packet.has("error"):
		var detail := str(packet.get("error", "Unknown error"))
		var normalized_detail := detail.to_lower()
		if normalized_detail.contains("bad_alloc") or normalized_detail.contains("failed to allocate") or normalized_detail.contains("out of memory"):
			_fail_active("Ollama ran out of memory while running %s. OCP reduced the local context to %d tokens; close memory-heavy apps or choose a smaller local model." % [model, context_tokens])
		else:
			_fail_active("Ollama streaming error: %s" % detail)
		return

	var message_value: Variant = packet.get("message", {})
	var delta := ""
	if message_value is Dictionary:
		delta = str((message_value as Dictionary).get("content", ""))
	if not delta.is_empty():
		_stream_last_activity_ms = Time.get_ticks_msec()
		if _stream_first_delta_ms == 0:
			_stream_first_delta_ms = _stream_last_activity_ms
			print("[OllamaTiming] first-token model=%s ttfb_ms=%d" % [model, _stream_first_delta_ms - _stream_started_ms])
		stream_delta.emit({
			"message_id": _active_message_id,
			"delta": delta,
			"request": _active_payload.duplicate(true),
			"provider_id": provider_id,
		})

	if bool(packet.get("done", false)):
		_stream_finished = true
		_stream_last_activity_ms = Time.get_ticks_msec()
		print("[OllamaTiming] complete model=%s total_ms=%d" % [model, _stream_last_activity_ms - _stream_started_ms])
		var final_text := str(packet.get("response", ""))
		# Ollama's /api/chat stream normally puts the final text in message.content
		# packets, not in response. Each packet above is a delta, never cumulative
		# text. The orchestrator owns accumulation, so only provide the terminal
		# metadata here and avoid replacing the accumulated response with the last
		# token.
		response_completed.emit({
			"message_id": _active_message_id,
			"text": final_text,
			"request": _active_payload.duplicate(true),
			"provider_id": provider_id,
			"model": model,
		})
		_finish_stream()


func _finish_stream() -> void:
	if _active_message_id.is_empty():
		return
	_active_message_id = ""
	_active_payload.clear()
	_stream_buffer = ""
	_stream_finished = false
	_stream_started_ms = 0
	_stream_last_activity_ms = 0
	_stream_first_delta_ms = 0
	if is_instance_valid(_client):
		_client.close()
	_client = null


func _on_test_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_last_test_ok = result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if _last_test_ok:
		var reply := ""
		var thinking := ""
		if parsed is Dictionary:
			var message_value: Variant = (parsed as Dictionary).get("message", {})
			if message_value is Dictionary:
				reply = str((message_value as Dictionary).get("content", "")).strip_edges()
				thinking = str((message_value as Dictionary).get("thinking", "")).strip_edges()
		# Reasoning models such as deepseek-r1 may spend a tiny connection-test
		# budget entirely in message.thinking and leave message.content empty.
		# HTTP 2xx + a valid message with either field proves the selected model is
		# installed and executable; Chat has a larger reasoning-aware output budget.
		if reply.is_empty() and thinking.is_empty():
			_last_test_ok = false
			_last_test_message = "Ollama model probe returned an empty response"
		else:
			_last_test_message = "Connected to Ollama · %s · ctx %d" % [model, context_tokens]
	else:
		var detail := ""
		if parsed is Dictionary:
			detail = str((parsed as Dictionary).get("error", "")).strip_edges()
		_last_test_message = (
			"Ollama connection failed: %s" % detail
			if not detail.is_empty()
			else "Ollama connection failed (HTTP %d, result %d)" % [response_code, result]
		)
	connection_tested.emit({
		"provider_id": provider_id,
		"ok": _last_test_ok,
		"message": _last_test_message,
		"models": [model] if _last_test_ok else [],
		"model": model,
		"context_tokens": context_tokens,
	})


func _on_models_discovered(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var ok := result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300
	var models: Array[String] = []
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if ok and parsed is Dictionary:
		var raw_models: Variant = (parsed as Dictionary).get("models", [])
		if raw_models is Array:
			for item in raw_models:
				if not item is Dictionary:
					continue
				var safe_name := _safe_discovered_model_name((item as Dictionary).get("name", ""))
				if safe_name.is_empty() or models.has(safe_name):
					continue
				models.append(safe_name)
				if models.size() >= 16:
					break
		else:
			ok = false
	else:
		ok = false
	var message := ""
	if ok:
		message = "Discovered %d Ollama model%s" % [models.size(), "" if models.size() == 1 else "s"]
	else:
		message = "Ollama model discovery failed (HTTP %d, result %d)" % [response_code, result]
	models_discovered.emit({
		"provider_id": provider_id,
		"ok": ok,
		"message": message,
		"models": models,
	})


func _safe_discovered_model_name(value: Variant) -> String:
	var candidate := str(value).strip_edges()
	if candidate.is_empty() or candidate.length() > 160:
		return ""
	for index in range(candidate.length()):
		if candidate.unicode_at(index) < 32:
			return ""
	return candidate


func _fail_active(message: String) -> void:
	var message_id := _active_message_id
	var request_payload := _active_payload.duplicate(true)
	var elapsed_ms := Time.get_ticks_msec() - _stream_started_ms if _stream_started_ms > 0 else 0
	if not message_id.is_empty():
		print("[OllamaTiming] failed model=%s elapsed_ms=%d reason=%s" % [model, elapsed_ms, message])
	_active_message_id = ""
	_active_payload.clear()
	_stream_buffer = ""
	_stream_finished = false
	_stream_started_ms = 0
	_stream_last_activity_ms = 0
	_stream_first_delta_ms = 0
	if is_instance_valid(_client):
		_client.close()
	_client = null
	if message_id.is_empty():
		return
	response_failed.emit({
		"message_id": message_id,
		"error": message,
		"request": request_payload,
		"provider_id": provider_id,
	})


func _prepare_stream_url() -> bool:
	var normalized := _normalize_base_url(base_url)
	var scheme_end := normalized.find("://")
	if scheme_end <= 0:
		return false
	var scheme := normalized.substr(0, scheme_end).to_lower()
	_stream_https = scheme == "https"
	if scheme != "http" and scheme != "https":
		return false
	var authority := normalized.substr(scheme_end + 3)
	var slash := authority.find("/")
	if slash >= 0:
		authority = authority.substr(0, slash)
	if authority.is_empty():
		return false
	_stream_host = authority
	_stream_port = 443 if _stream_https else 80
	if authority.begins_with("["):
		var close := authority.find("]")
		if close < 0:
			return false
		_stream_host = authority.substr(1, close - 1)
		if close + 1 < authority.length() and authority.substr(close + 1, 1) == ":":
			_stream_port = int(authority.substr(close + 2))
	elif authority.count(":") == 1:
		var parts := authority.split(":")
		_stream_host = parts[0]
		_stream_port = int(parts[1])
	_stream_url = "/api/chat"
	return not _stream_host.is_empty() and _stream_port > 0


func _chat_messages(prompt: String, system_prompt: String = COMPANION_SYSTEM_PROMPT) -> Array[Dictionary]:
	return [
		{"role": "system", "content": system_prompt if not system_prompt.strip_edges().is_empty() else COMPANION_SYSTEM_PROMPT},
		{"role": "user", "content": prompt},
	]


func _host_context_limit() -> int:
	var memory_info := OS.get_memory_info()
	var physical_bytes := int(memory_info.get("physical", 0))
	if physical_bytes > 0 and physical_bytes < LOW_MEMORY_HOST_BYTES:
		return LOW_MEMORY_CONTEXT_TOKENS
	return STANDARD_CONTEXT_TOKENS


func _normalize_base_url(value: String) -> String:
	var normalized := value.strip_edges()
	while normalized.ends_with("/") and normalized.length() > 0:
		normalized = normalized.substr(0, normalized.length() - 1)
	return normalized
