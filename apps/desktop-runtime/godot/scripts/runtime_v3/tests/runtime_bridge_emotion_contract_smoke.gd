extends SceneTree

const BridgeAdapterScript = preload("res://scripts/runtime_v3/services/runtime_bridge_adapter.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")


class FakeBridge:
	extends Node
	signal emotion_changed(companion_id: String, emotion: String, emotion_instance: String)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var bus := EventBusScript.new()
	var bridge := FakeBridge.new()
	var adapter := BridgeAdapterScript.new()
	holder.add_child(bus)
	holder.add_child(bridge)
	holder.add_child(adapter)
	adapter.configure(null, bus)
	adapter.bind_bridge(bridge)

	var received: Array = []
	bus.event_published.connect(func(topic: StringName, payload: Dictionary):
		if topic == &"emotion.changed":
			received.append(payload.duplicate(true))
	)
	bridge.emotion_changed.emit("default", "angry", "emotion-smoke-1")
	await process_frame
	var ok := received.size() == 1 \
		and str(received[0].get("companionId", "")) == "default" \
		and str(received[0].get("emotion", "")) == "angry" \
		and str(received[0].get("emotionInstance", "")) == "emotion-smoke-1" \
		and str(received[0].get("source", "")) == "kernel" \
		and adapter.connected_signals.has("emotion_changed")
	print("[BridgeEmotion] connected=", adapter.connected_signals.has("emotion_changed"), " payload=", received, " ok=", ok)
	holder.free()
	await process_frame
	quit(0 if ok else 1)
