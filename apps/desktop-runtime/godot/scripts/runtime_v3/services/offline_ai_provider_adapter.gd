extends "res://scripts/runtime_v3/services/ai_provider_adapter.gd"
class_name RuntimeV3OfflineAIProviderAdapter

## Deterministic local fallback. It intentionally behaves like a streaming
## provider so Chat/Bubble lifecycle can be exercised before credentials or a
## network-backed adapter are configured.

func _init() -> void:
	provider_id = "offline"
	display_name = "Offline"
	supports_streaming = true


func request(payload: Dictionary) -> void:
	var prompt := str(payload.get("prompt", "")).strip_edges()
	var message_id := str(payload.get("message_id", ""))
	if prompt.is_empty():
		response_failed.emit({
			"message_id": message_id,
			"error": "Prompt is empty",
			"request": payload,
		})
		return

	var response_text := "AI provider is not configured. Open OCP > AI & Voice to connect a provider."
	stream_started.emit({
		"message_id": message_id,
		"request": payload,
		"provider_id": provider_id,
	})

	var accumulated := ""
	var words := response_text.split(" ", false)
	for index in range(words.size()):
		var delta := str(words[index])
		if index < words.size() - 1:
			delta += " "
		accumulated += delta
		stream_delta.emit({
			"message_id": message_id,
			"delta": delta,
			"text": accumulated,
			"request": payload,
			"provider_id": provider_id,
		})

	response_completed.emit({
		"message_id": message_id,
		"text": accumulated.strip_edges(),
		"request": payload,
		"provider_id": provider_id,
	})


func status() -> Dictionary:
	return {
		"provider_id": provider_id,
		"display_name": display_name,
		"supports_streaming": supports_streaming,
		"configured": false,
		"mode": "offline",
	}
