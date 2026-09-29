extends Node
class_name RuntimeV3EventBus

signal event_published(topic: StringName, payload: Dictionary)

var _subscriptions: Dictionary = {}


func subscribe(topic: StringName, callback: Callable) -> void:
	if not callback.is_valid():
		push_warning("RuntimeV3EventBus: invalid callback for %s" % topic)
		return

	var listeners: Array = _subscriptions.get(topic, [])
	if not listeners.has(callback):
		listeners.append(callback)
		_subscriptions[topic] = listeners


func unsubscribe(topic: StringName, callback: Callable) -> void:
	var listeners: Array = _subscriptions.get(topic, [])
	var index: int = listeners.find(callback)
	if index >= 0:
		listeners.remove_at(index)

	if listeners.is_empty():
		_subscriptions.erase(topic)
	else:
		_subscriptions[topic] = listeners


func publish(topic: StringName, payload: Dictionary = {}) -> void:
	event_published.emit(topic, payload)

	var listeners: Array = _subscriptions.get(topic, []).duplicate()
	for listener_value in listeners:
		var listener: Callable = listener_value
		if listener.is_valid():
			listener.call(payload)


func clear() -> void:
	_subscriptions.clear()
