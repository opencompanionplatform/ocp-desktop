extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3AIController

func start() -> void:
	event_bus.subscribe(&"ai.prompt_requested", Callable(self, "_on_prompt_requested"))
	event_bus.subscribe(&"ai.response_received", Callable(self, "_on_response_received"))


func stop() -> void:
	event_bus.unsubscribe(&"ai.prompt_requested", Callable(self, "_on_prompt_requested"))
	event_bus.unsubscribe(&"ai.response_received", Callable(self, "_on_response_received"))


func _on_prompt_requested(_payload: Dictionary) -> void:
	event_bus.publish(&"ai.thinking_started", {})
	event_bus.publish(&"animation.requested", {"name": "think"})


func _on_response_received(payload: Dictionary) -> void:
	event_bus.publish(&"ai.thinking_finished", {})
	event_bus.publish(&"bubble.requested", {
		"text": str(payload.get("text", "")),
		"duration": 8.0,
	})
	event_bus.publish(&"animation.requested", {"name": "speak"})
