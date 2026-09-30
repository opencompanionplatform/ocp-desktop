extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")


class FakeVoiceInputService:
	extends Node
	var capture_active := false

	func bind(bus: Node) -> void:
		bus.subscribe(&"voice.input_start_requested", Callable(self, "_on_start"))
		bus.subscribe(&"voice.input_stop_requested", Callable(self, "_on_stop"))

	func _on_start(_payload: Dictionary) -> void:
		capture_active = true

	func _on_stop(_payload: Dictionary) -> void:
		capture_active = false


class FakeServices:
	extends Node
	var voice_input_service: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := ContextScript.new()
	var bus := EventBusScript.new()
	var adapter := AdapterScript.new()
	var voice := FakeVoiceInputService.new()
	var services := FakeServices.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(adapter)
	holder.add_child(voice)
	holder.add_child(services)
	voice.bind(bus)
	services.voice_input_service = voice
	adapter.configure(context, bus)
	adapter.services = services

	var start_result: Dictionary = adapter._set_voice_input({"type": "voice.input.start"})
	var start_ok: bool = str(start_result.get("status", "")) == "succeeded" and voice.capture_active
	var stop_result: Dictionary = adapter._set_voice_input({"type": "voice.input.stop"})
	var stop_ok: bool = str(stop_result.get("status", "")) == "succeeded" and not voice.capture_active
	var invalid_result: Dictionary = adapter._set_voice_input({"type": "voice.input.start", "extra": true})
	var invalid_ok: bool = str(invalid_result.get("status", "")) == "failed"
	var ok := start_ok and stop_ok and invalid_ok
	print("[SHELL-VOICE-INPUT] start=", start_ok, " stop=", stop_ok, " invalid=", invalid_ok, " ok=", ok)
	holder.free()
	quit(0 if ok else 1)
