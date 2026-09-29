extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3ProactiveLocalLLMCompanionController

## ADR-0045: an opt-in, privacy-bounded prompt scheduler. This controller does
## not belong to the deterministic behavior engine and never invokes a provider
## directly; it only publishes into the existing Chat session boundary.

const IDLE_COOLDOWN_MS := 30 * 60 * 1000
const SOURCE := "proactive-local-llm-companion"
const MESSAGE_PREFIX := "proactive_companion_"

var _last_activity_ms := 0
var _last_proactive_ms := 0
var _request_in_flight := false
var _sequence := 0


func start() -> void:
	_last_activity_ms = Time.get_ticks_msec()
	event_bus.subscribe(&"ai.prompt_requested", Callable(self, "_on_prompt_requested"))
	event_bus.subscribe(&"chat.response_started", Callable(self, "_on_response_started"))
	event_bus.subscribe(&"chat.assistant_message_received", Callable(self, "_on_response_finished"))
	event_bus.subscribe(&"chat.response_failed", Callable(self, "_on_response_failed"))
	event_bus.subscribe(&"tts.started", Callable(self, "_on_tts_started"))
	set_process(true)


func stop() -> void:
	event_bus.unsubscribe(&"ai.prompt_requested", Callable(self, "_on_prompt_requested"))
	event_bus.unsubscribe(&"chat.response_started", Callable(self, "_on_response_started"))
	event_bus.unsubscribe(&"chat.assistant_message_received", Callable(self, "_on_response_finished"))
	event_bus.unsubscribe(&"chat.response_failed", Callable(self, "_on_response_failed"))
	event_bus.unsubscribe(&"tts.started", Callable(self, "_on_tts_started"))
	set_process(false)


func _process(_delta: float) -> void:
	try_request(Time.get_ticks_msec())


## Exposed for the focused contract smoke. `now_ms` is runtime-local monotonic
## time, not an operating-system user activity probe.
func try_request(now_ms: int) -> bool:
	if not _eligible() or _request_in_flight:
		return false
	if now_ms - _last_activity_ms < IDLE_COOLDOWN_MS:
		return false
	if now_ms - _last_proactive_ms < IDLE_COOLDOWN_MS:
		return false
	_sequence += 1
	var message_id := "%s%d_%d" % [MESSAGE_PREFIX, now_ms, _sequence]
	_request_in_flight = true
	_last_proactive_ms = now_ms
	event_bus.publish(&"ai.prompt_requested", {
		"message_id": message_id,
		"source": SOURCE,
		"proactive": true,
		"prompt": _prompt_for_current_locale(),
	})
	return true


func _on_prompt_requested(payload: Dictionary) -> void:
	if str(payload.get("source", "")) == SOURCE:
		_request_in_flight = true
		return
	_mark_activity()


func _on_response_started(payload: Dictionary) -> void:
	if _is_proactive_message(str(payload.get("message_id", ""))):
		_request_in_flight = true
	else:
		_mark_activity()


func _on_response_finished(payload: Dictionary) -> void:
	if _is_proactive_message(str(payload.get("message_id", ""))):
		_request_in_flight = false
		_last_activity_ms = Time.get_ticks_msec()
	else:
		_mark_activity()


func _on_response_failed(payload: Dictionary) -> void:
	if _is_proactive_message(str(payload.get("message_id", ""))):
		_request_in_flight = false
		_last_activity_ms = Time.get_ticks_msec()
	else:
		_mark_activity()


func _on_tts_started(_payload: Dictionary) -> void:
	_mark_activity()


func _mark_activity() -> void:
	_last_activity_ms = Time.get_ticks_msec()


func _eligible() -> bool:
	if not is_instance_valid(context) or not bool(context.settings.get("llm_companion_mode_enabled", false)):
		return false
	if str(context.settings.get("ai_provider_id", "offline")).strip_edges().to_lower() != "ollama":
		return false
	if not is_instance_valid(services) or not is_instance_valid(services.ai_service) \
	or not services.ai_service.has_method("provider_status"):
		return false
	var status_value: Variant = services.ai_service.call("provider_status")
	return status_value is Dictionary and bool((status_value as Dictionary).get("configured", false))


func _prompt_for_current_locale() -> String:
	var locale := str(context.settings.get("language", "en")).to_lower()
	if locale.begins_with("th"):
		return "คุณคือเพื่อนร่วมทาง OCP ในเครื่อง ชวนคุยอย่างเป็นมิตรสั้น ๆ หนึ่งประโยค ไม่อ้างว่ารู้ข้อมูลนอกบทสนทนา ไม่ขอข้อมูลส่วนตัว และอย่าใช้คำสั่งหรือเครื่องมือใด ๆ"
	return "You are the local OCP companion. Offer one short, friendly conversation opener. Do not claim awareness outside this chat, ask for personal data, or use commands or tools."


func _is_proactive_message(message_id: String) -> bool:
	return message_id.begins_with(MESSAGE_PREFIX)
