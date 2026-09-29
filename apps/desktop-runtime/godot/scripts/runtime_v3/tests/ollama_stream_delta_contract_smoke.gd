extends SceneTree

const ProviderScript = preload("res://scripts/runtime_v3/services/ollama_ai_provider_adapter.gd")

var deltas: Array[Dictionary] = []
var completions: Array[Dictionary] = []
var connection_results: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var provider := ProviderScript.new()
	get_root().add_child(provider)
	provider.stream_delta.connect(func(payload: Dictionary) -> void:
		deltas.append(payload.duplicate(true)))
	provider.response_completed.connect(func(payload: Dictionary) -> void:
		completions.append(payload.duplicate(true)))
	provider.connection_tested.connect(func(payload: Dictionary) -> void:
		connection_results.append(payload.duplicate(true)))

	provider._active_message_id = "ollama-delta-contract"
	provider._active_payload = {"message_id": "ollama-delta-contract"}
	var synthetic_now_ms := 100_000
	provider._stream_started_ms = 40_000
	provider._stream_last_activity_ms = synthetic_now_ms - 100
	provider.request_timeout_seconds = 45.0
	var active_long_stream_not_stalled := not provider._stream_stalled(synthetic_now_ms)
	provider._stream_last_activity_ms = synthetic_now_ms - 46_000
	var inactive_stream_stalled := provider._stream_stalled(synthetic_now_ms)
	provider._stream_started_ms = Time.get_ticks_msec()
	provider._stream_last_activity_ms = provider._stream_started_ms
	provider._process_ndjson_line('{"message":{"content":"สวัสดี"},"done":false}')
	provider._process_ndjson_line('{"message":{"content":"ครับ"},"done":false}')
	provider._process_ndjson_line('{"message":{"content":" 😊"},"done":false}')
	provider._process_ndjson_line('{"message":{"content":""},"done":true}')
	provider.model = "deepseek-r1:1.5b"
	provider._on_test_completed(
		HTTPRequest.RESULT_SUCCESS,
		200,
		PackedStringArray(),
		JSON.stringify({"message": {"content": "", "thinking": "working"}, "done": true}).to_utf8_buffer()
	)
	var reasoning_probe_ok := connection_results.size() == 1 and bool(connection_results[0].get("ok", false))
	var activated_provider := ProviderScript.new()
	get_root().add_child(activated_provider)
	activated_provider.model = "deepseek-r1:1.5b"
	activated_provider.adopt_connection_test_result(connection_results[0])
	var transferred_reachability_ok := bool(activated_provider.status().get("reachable", false))
	activated_provider.queue_free()
	var reasoning_budget_ok := provider._chat_output_token_limit() == ProviderScript.REASONING_CHAT_MAX_OUTPUT_TOKENS
	provider.model = "qwen2.5-coder:1.5b"
	var normal_budget_ok := provider._chat_output_token_limit() == ProviderScript.CHAT_MAX_OUTPUT_TOKENS
	var chat_messages: Array[Dictionary] = provider._chat_messages("แนะนำตัวสั้นๆ")

	var ok: bool = deltas.size() == 3 \
		and str(deltas[0].get("delta", "")) == "สวัสดี" \
		and str(deltas[1].get("delta", "")) == "ครับ" \
		and str(deltas[2].get("delta", "")) == " 😊" \
		and not deltas[0].has("text") \
		and not deltas[1].has("text") \
		and not deltas[2].has("text") \
		and completions.size() == 1 \
		and str(completions[0].get("text", "not-empty")) == "" \
		and chat_messages.size() == 2 \
		and chat_messages[0].get("role", "") == "system" \
		and str(chat_messages[0].get("content", "")).contains("same language") \
		and chat_messages[1].get("content", "") == "แนะนำตัวสั้นๆ" \
		and active_long_stream_not_stalled \
		and inactive_stream_stalled \
		and reasoning_probe_ok \
		and transferred_reachability_ok \
		and reasoning_budget_ok \
		and normal_budget_ok \
		and ProviderScript.CHAT_MAX_OUTPUT_TOKENS == 128 \
		and ProviderScript.REASONING_CHAT_MAX_OUTPUT_TOKENS == 384 \
		and ProviderScript.OLLAMA_KEEP_ALIVE == "15m"

	print("[OLLAMA-STREAM-DELTA] packets=", deltas.size(), " delta_only=", ok)
	provider.queue_free()
	quit(0 if ok else 1)
