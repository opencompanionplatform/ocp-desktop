extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3NativePresentationCoordinator
## G11 contract-only coordinator for the future native companion host.
##
## This service deliberately does not create or move HWNDs yet. It owns the
## opt-in decision and lifecycle contract so the production Runtime can keep
## the existing overlay path as a safe fallback while native integration is
## brought in behind explicit gates.

const MODE_OVERLAY := &"overlay"
const MODE_NATIVE := &"native-companion"

enum HostState { DISABLED, REQUESTED, READY, ATTACHED, DETACHED, FALLBACK }

var state: HostState = HostState.DISABLED
var companion_id: String = ""
var host_token: String = ""
var host_size: Vector2i = Vector2i.ZERO


func state_name() -> String:
	match state:
		HostState.DISABLED:
			return "disabled"
		HostState.REQUESTED:
			return "requested"
		HostState.READY:
			return "ready"
		HostState.ATTACHED:
			return "attached"
		HostState.DETACHED:
			return "detached"
		HostState.FALLBACK:
			return "fallback"
	return "unknown"


func start() -> void:
	event_bus.subscribe(&"native_presentation.requested", Callable(self, "_on_requested"))
	event_bus.subscribe(&"native_presentation.ready", Callable(self, "_on_ready"))
	event_bus.subscribe(&"native_presentation.attached", Callable(self, "_on_attached"))
	event_bus.subscribe(&"native_presentation.resized", Callable(self, "_on_resized"))
	event_bus.subscribe(&"native_presentation.detached", Callable(self, "_on_detached"))
	event_bus.subscribe(&"native_presentation.failed", Callable(self, "_on_failed"))
	_set_overlay_fallback()


func stop() -> void:
	event_bus.unsubscribe(&"native_presentation.requested", Callable(self, "_on_requested"))
	event_bus.unsubscribe(&"native_presentation.ready", Callable(self, "_on_ready"))
	event_bus.unsubscribe(&"native_presentation.attached", Callable(self, "_on_attached"))
	event_bus.unsubscribe(&"native_presentation.resized", Callable(self, "_on_resized"))
	event_bus.unsubscribe(&"native_presentation.detached", Callable(self, "_on_detached"))
	event_bus.unsubscribe(&"native_presentation.failed", Callable(self, "_on_failed"))
	_set_overlay_fallback()


func native_enabled() -> bool:
	return bool(context.runtime_config.get("native_presentation_enabled", false))


func request(companion: String, token: String) -> bool:
	if not native_enabled() or companion.strip_edges().is_empty() or token.strip_edges().is_empty():
		_set_fallback("disabled-or-invalid-request")
		return false
	companion_id = companion
	host_token = token
	state = HostState.REQUESTED
	_update_context("requested")
	return true


func accept_ready(companion: String, token: String) -> bool:
	if state != HostState.REQUESTED or companion != companion_id or token != host_token:
		_set_fallback("ready-contract-rejected")
		return false
	state = HostState.READY
	_update_context("ready")
	return true


func accept_attached(companion: String) -> bool:
	if state != HostState.READY or companion != companion_id:
		_set_fallback("attach-contract-rejected")
		return false
	state = HostState.ATTACHED
	_update_context("attached")
	return true


func accept_resized(width: int, height: int) -> bool:
	if state not in [HostState.READY, HostState.ATTACHED] or width <= 0 or height <= 0:
		_set_fallback("resize-contract-rejected")
		return false
	host_size = Vector2i(width, height)
	_update_context(state_name(), "resize")
	return true


func accept_detached(companion: String) -> bool:
	if state not in [HostState.ATTACHED, HostState.READY] or companion != companion_id:
		_set_fallback("detach-contract-rejected")
		return false
	state = HostState.DETACHED
	_update_context("detached")
	return true


func _on_requested(payload: Dictionary) -> void:
	request(str(payload.get("companionId", "")), str(payload.get("hostToken", "")))


func _on_ready(payload: Dictionary) -> void:
	accept_ready(str(payload.get("companionId", "")), str(payload.get("hostToken", "")))


func _on_attached(payload: Dictionary) -> void:
	accept_attached(str(payload.get("companionId", "")))


func _on_resized(payload: Dictionary) -> void:
	accept_resized(int(payload.get("width", 0)), int(payload.get("height", 0)))


func _on_detached(payload: Dictionary) -> void:
	accept_detached(str(payload.get("companionId", "")))


func _on_failed(payload: Dictionary) -> void:
	_set_fallback(str(payload.get("reason", "native-host-failed")))


func _set_overlay_fallback() -> void:
	state = HostState.DISABLED
	companion_id = ""
	host_token = ""
	host_size = Vector2i.ZERO
	_update_context("overlay")


func _set_fallback(reason: String) -> void:
	state = HostState.FALLBACK
	_update_context("fallback", reason)


func _update_context(mode: String, reason: String = "") -> void:
	if context == null:
		return
	context.update_runtime_config({
		"native_presentation_state": mode,
		"native_presentation_reason": reason,
		"native_presentation_client_size": host_size,
		"presentation_owner": "native-host" if state in [HostState.REQUESTED, HostState.READY, HostState.ATTACHED] else "overlay",
	})
