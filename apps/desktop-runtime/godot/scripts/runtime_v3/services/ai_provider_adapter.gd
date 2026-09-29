extends Node
class_name RuntimeV3AIProviderAdapter

## Provider-neutral boundary used by AIService. Concrete adapters own transport
## details and emit a stable streaming lifecycle back to the runtime.

signal stream_started(payload: Dictionary)
signal stream_delta(payload: Dictionary)
signal response_completed(payload: Dictionary)
signal response_failed(payload: Dictionary)

var context: Node
var provider_id := "unknown"
var display_name := "Unknown provider"
var supports_streaming := false


func configure(runtime_context: Node) -> void:
	context = runtime_context


func request(_payload: Dictionary) -> void:
	response_failed.emit({"error": "Provider adapter does not implement request()"})


func cancel(_message_id: String) -> void:
	pass


func status() -> Dictionary:
	return {
		"provider_id": provider_id,
		"display_name": display_name,
		"supports_streaming": supports_streaming,
		"configured": false,
	}
