extends Node
## Minimal presentation boundary used only by CS-RT conformance.
##
## The Rust bridge deliberately defers speech-completed and emotion-presented
## until GDScript reports what was actually presented. Production Runtime V3
## controllers perform that job during normal execution. This adapter supplies
## deterministic headless acknowledgements without loading production UI.

var _bridge: Node = null
var _speech_argument_names: PackedStringArray = PackedStringArray()
var _emotion_argument_names: PackedStringArray = PackedStringArray()


func bind_bridge(bridge: Node) -> void:
	_bridge = bridge

	if _bridge == null:
		push_error("[CS-RT Adapter] bridge is null")
		return

	_bind_signal("speech_requested", true)
	_bind_signal("emotion_changed", false)


func _bind_signal(signal_name: String, is_speech: bool) -> void:
	if not _bridge.has_signal(signal_name):
		push_error(
			"[CS-RT Adapter] bridge signal missing: %s"
			% signal_name
		)
		return

	var metadata: Dictionary = _find_signal_metadata(signal_name)
	var argument_names := PackedStringArray()

	for argument_value in metadata.get("args", []):
		if argument_value is Dictionary:
			argument_names.append(
				str(argument_value.get("name", ""))
			)

	if is_speech:
		_speech_argument_names = argument_names
	else:
		_emotion_argument_names = argument_names

	var argument_count: int = argument_names.size()
	var callback_name: String = _callback_name(
		signal_name,
		argument_count
	)

	if callback_name.is_empty() or not has_method(callback_name):
		push_error(
			"[CS-RT Adapter] unsupported signal signature: %s (%d args)"
			% [signal_name, argument_count]
		)
		return

	var error: Error = _bridge.connect(
		signal_name,
		Callable(self, callback_name)
	)

	if error != OK:
		push_error(
			"[CS-RT Adapter] cannot connect %s: error %d"
			% [signal_name, error]
		)
		return

	print(
		"[CS-RT Adapter] connected %s args=%s"
		% [signal_name, argument_names]
	)


func _find_signal_metadata(signal_name: String) -> Dictionary:
	for signal_value in _bridge.get_signal_list():
		if signal_value is Dictionary \
		and str(signal_value.get("name", "")) == signal_name:
			return signal_value

	return {}


func _callback_name(signal_name: String, count: int) -> String:
	var prefix: String = (
		"_speech_" if signal_name == "speech_requested"
		else "_emotion_"
	)

	if count < 1 or count > 6:
		return ""

	return "%s%d" % [prefix, count]


# Speech callbacks: support bridge signature evolution without hard-coding only
# one argument count.
func _speech_1(a) -> void:
	_handle_speech([a])


func _speech_2(a, b) -> void:
	_handle_speech([a, b])


func _speech_3(a, b, c) -> void:
	_handle_speech([a, b, c])


func _speech_4(a, b, c, d) -> void:
	_handle_speech([a, b, c, d])


func _speech_5(a, b, c, d, e) -> void:
	_handle_speech([a, b, c, d, e])


func _speech_6(a, b, c, d, e, f) -> void:
	_handle_speech([a, b, c, d, e, f])


# Emotion callbacks.
func _emotion_1(a) -> void:
	_handle_emotion([a])


func _emotion_2(a, b) -> void:
	_handle_emotion([a, b])


func _emotion_3(a, b, c) -> void:
	_handle_emotion([a, b, c])


func _emotion_4(a, b, c, d) -> void:
	_handle_emotion([a, b, c, d])


func _emotion_5(a, b, c, d, e) -> void:
	_handle_emotion([a, b, c, d, e])


func _emotion_6(a, b, c, d, e, f) -> void:
	_handle_emotion([a, b, c, d, e, f])


func _handle_speech(values: Array) -> void:
	var payload: Dictionary = _map_arguments(
		_speech_argument_names,
		values
	)

	var companion_id: String = _first_string(
		payload,
		[
			"companion_id",
			"companionid",
			"companion",
		],
		0,
		values
	)

	var speech_id: String = _first_string(
		payload,
		[
			"speech_id",
			"speechid",
		],
		1,
		values
	)

	if companion_id.is_empty() or speech_id.is_empty():
		push_error(
			"[CS-RT Adapter] speech ids unresolved: names=%s values=%s"
			% [_speech_argument_names, values]
		)
		return

	# Let speech-started leave the Rust bridge first, then report the honest
	# headless result. No audio device exists in conformance.
	await get_tree().process_frame

	if not _bridge.has_method("report_speech_finished"):
		push_error(
			"[CS-RT Adapter] report_speech_finished method missing"
		)
		return

	_bridge.call(
		"report_speech_finished",
		speech_id,
		companion_id,
		"tts-unavailable"
	)

	print(
		"[CS-RT Adapter] speech completed: %s"
		% speech_id
	)


func _handle_emotion(values: Array) -> void:
	var payload: Dictionary = _map_arguments(
		_emotion_argument_names,
		values
	)

	var companion_id: String = _first_string(
		payload,
		[
			"companion_id",
			"companionid",
			"companion",
		],
		0,
		values
	)

	var emotion: String = _first_string(
		payload,
		[
			"emotion",
			"to",
			"target_emotion",
		],
		1,
		values
	)

	var emotion_instance: String = _first_string(
		payload,
		[
			"emotion_instance",
			"emotioninstance",
			"instance",
			"instance_token",
			"token",
		],
		2,
		values
	)

	if companion_id.is_empty() \
	or emotion.is_empty() \
	or emotion_instance.is_empty():
		push_error(
			"[CS-RT Adapter] emotion fields unresolved: names=%s values=%s"
			% [_emotion_argument_names, values]
		)
		return

	await get_tree().process_frame

	if not _bridge.has_method("report_emotion_presented"):
		push_error(
			"[CS-RT Adapter] report_emotion_presented method missing"
		)
		return

	# Headless conformance has no visual expression asset. "default" + fallback
	# true accurately describes what the test adapter presented.
	_bridge.call(
		"report_emotion_presented",
		emotion_instance,
		companion_id,
		emotion,
		"default",
		true
	)

	print(
		"[CS-RT Adapter] emotion presented: %s"
		% emotion
	)


func _map_arguments(
	names: PackedStringArray,
	values: Array
) -> Dictionary:
	var result: Dictionary = {}
	var count: int = mini(names.size(), values.size())

	for index in range(count):
		result[_normalize_name(names[index])] = values[index]

	return result


func _first_string(
	payload: Dictionary,
	aliases: Array,
	fallback_index: int,
	values: Array
) -> String:
	for alias_value in aliases:
		var alias: String = _normalize_name(str(alias_value))

		if payload.has(alias):
			var value: String = str(payload[alias])

			if not value.is_empty():
				return value

	if fallback_index >= 0 and fallback_index < values.size():
		return str(values[fallback_index])

	return ""


func _normalize_name(value: String) -> String:
	return value.strip_edges().to_lower().replace("-", "_")
