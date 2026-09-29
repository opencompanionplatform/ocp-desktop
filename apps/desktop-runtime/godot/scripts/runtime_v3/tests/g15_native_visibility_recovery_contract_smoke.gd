extends SceneTree

const NativeLifecycleScript = preload(
	"res://scripts/runtime_v3/services/native_host_lifecycle.gd"
)
const PickerControllerScript = preload(
	"res://scripts/runtime_v3/controllers/character_picker_controller.gd"
)


class FakeContext:
	extends Node
	var runtime_config := {"native_presentation_enabled": true}
	var settings := {"show_bubbles": true}


class FakeEventBus:
	extends Node
	var command_path := ""
	var ordering_ok := true
	var publish_count := 0

	func publish(_event_name: StringName, payload: Dictionary) -> void:
		if not payload.has("suppressed") or command_path.is_empty():
			return
		publish_count += 1
		if not FileAccess.file_exists(command_path):
			ordering_ok = false
			return
		var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(command_path))
		if not value is Dictionary:
			ordering_ok = false
			return
		var command := value as Dictionary
		var expected_visible := not bool(payload.get("suppressed", false))
		var actual_visible := bool(command.get("visibility_desired", command.get("visible", false)))
		if actual_visible != expected_visible:
			ordering_ok = false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)

	var lifecycle := NativeLifecycleScript.new()
	var context := FakeContext.new()
	holder.add_child(context)
	holder.add_child(lifecycle)
	lifecycle.configure(context, null)
	var hidden_generation := lifecycle._next_native_visibility_generation(false)
	var restored_generation := lifecycle._next_native_visibility_generation(true)
	var monotonic_generation := hidden_generation > 0 \
		and restored_generation > hidden_generation \
		and lifecycle.native_visibility_desired
	var focus_command_path := ProjectSettings.globalize_path("user://g16_24_chat_focus_command.json")
	var focus_move_path := ProjectSettings.globalize_path("user://g16_24_chat_focus_move.json")
	var focus_bubble_path := ProjectSettings.globalize_path("user://g16_24_chat_focus_bubble.json")
	lifecycle.ui_command_path = focus_command_path
	lifecycle.command_path = focus_move_path
	lifecycle.bubble_path = focus_bubble_path
	lifecycle.host_token = "test-token"
	var event_bus := FakeEventBus.new()
	event_bus.command_path = focus_command_path
	holder.add_child(event_bus)
	lifecycle.event_bus = event_bus
	lifecycle._prehide_native_for_shell_launch("test")
	var prehide_payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(focus_command_path))
	var prehide_payload: Dictionary = prehide_payload_value if prehide_payload_value is Dictionary else {}
	var shell_launch_prehide: bool = prehide_payload.get("status", "") == "visibility-request" \
		and not bool(prehide_payload.get("visibility_desired", true))
	lifecycle.pending_bubble_payload = {"text": "stale"}
	lifecycle.set_chat_focus_active(true)
	var hidden_payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(focus_command_path))
	var hidden_payload: Dictionary = hidden_payload_value if hidden_payload_value is Dictionary else {}
	lifecycle._on_bubble_requested({"text": "must-not-render"})
	var chat_focus_hidden: bool = lifecycle.chat_focus_active \
		and lifecycle.pending_bubble_payload.is_empty() \
		and hidden_payload.get("status", "") == "visibility-request" \
		and not bool(hidden_payload.get("visibility_desired", true)) \
		and not FileAccess.file_exists(focus_bubble_path)
	lifecycle._write_command({
		"status": "move-request",
		"token": "test-token",
		"sequence": 777,
		"desktop_feet": [640.0, 952.0],
	})
	var move_payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(focus_move_path))
	var move_payload: Dictionary = move_payload_value if move_payload_value is Dictionary else {}
	var move_visibility_piggyback: bool = move_payload.get("status", "") == "move-request" \
		and not bool(move_payload.get("visibility_desired", true)) \
		and int(move_payload.get("visibility_generation", 0)) == lifecycle.native_visibility_generation
	lifecycle.set_chat_focus_active(false)
	var restored_payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(focus_command_path))
	var restored_payload: Dictionary = restored_payload_value if restored_payload_value is Dictionary else {}
	var chat_focus_restored: bool = not lifecycle.chat_focus_active \
		and bool(restored_payload.get("visibility_desired", false))
	lifecycle.pending_bubble_payload = {"text": "stale-manager-bubble"}
	lifecycle.set_shell_companion_suppressed(true)
	var manager_hidden_payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(focus_command_path))
	var manager_hidden_payload: Dictionary = manager_hidden_payload_value if manager_hidden_payload_value is Dictionary else {}
	var manager_suppressed: bool = lifecycle.shell_companion_suppressed \
		and lifecycle.pending_bubble_payload.is_empty() \
		and manager_hidden_payload.get("status", "") == "visibility-request" \
		and not bool(manager_hidden_payload.get("visibility_desired", true))
	lifecycle.set_shell_companion_suppressed(false)
	var manager_restored_payload_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(focus_command_path))
	var manager_restored_payload: Dictionary = manager_restored_payload_value if manager_restored_payload_value is Dictionary else {}
	var manager_native_restored: bool = not lifecycle.shell_companion_suppressed \
		and bool(manager_restored_payload.get("visibility_desired", false))
	DirAccess.remove_absolute(focus_command_path)
	DirAccess.remove_absolute(focus_move_path)
	DirAccess.remove_absolute(focus_bubble_path)

	var manager := Window.new()
	var picker_panel := PanelContainer.new()
	var companion := Control.new()
	manager.add_child(picker_panel)
	holder.add_child(companion)
	get_root().add_child(manager)
	manager.show()
	picker_panel.visible = true
	var picker := PickerControllerScript.new()
	picker.panel = picker_panel
	picker.manager_window = manager
	picker.companion_host = companion
	picker._sync_companion_preview_visibility()
	var hidden_while_manager_visible := not companion.visible
	manager.mode = Window.MODE_MINIMIZED
	picker._sync_companion_preview_visibility()
	var restored_while_manager_minimized := companion.visible
	manager.mode = Window.MODE_WINDOWED
	picker._sync_companion_preview_visibility()
	var hidden_after_manager_restore := not companion.visible
	picker_panel.visible = false
	picker._sync_companion_preview_visibility()
	var restored_after_manager_close := companion.visible

	var native_source := FileAccess.get_file_as_string(ProjectSettings.globalize_path(
		"res://../../../spike/native-companion-window/src/main.rs"
	))
	var native_recovery_contract := native_source.contains("WM_SHOWWINDOW") \
		and native_source.contains("LAST_VISIBILITY_GENERATION") \
		and native_source.contains("RUNTIME_VISIBILITY_DESIRED") \
		and native_source.contains("visibility_generation < previous_generation") \
		and native_source.contains("if is_move_request {") \
		and native_source.contains("apply_runtime_visibility_generation(hwnd, &payload);") \
		and native_source.contains("phase=canonical-demo-reveal visible_after_placement=true")
	var visibility_before_cleanup := event_bus.ordering_ok and event_bus.publish_count >= 2
	var ok := monotonic_generation \
		and shell_launch_prehide \
		and chat_focus_hidden \
		and move_visibility_piggyback \
		and chat_focus_restored \
		and visibility_before_cleanup \
		and manager_suppressed \
		and manager_native_restored \
		and hidden_while_manager_visible \
		and restored_while_manager_minimized \
		and hidden_after_manager_restore \
		and restored_after_manager_close \
		and native_recovery_contract
	print("[G16.24] generation=%s prehide=%s chat_focus=%s move_visibility=%s visibility_first=%s shell_safe_zone=%s manager_minimize=%s native_recovery=%s" % [
		str(monotonic_generation).to_lower(),
		str(shell_launch_prehide).to_lower(),
		str(chat_focus_hidden and chat_focus_restored).to_lower(),
		str(move_visibility_piggyback).to_lower(),
		str(visibility_before_cleanup).to_lower(),
		str(manager_suppressed and manager_native_restored).to_lower(),
		str(restored_while_manager_minimized).to_lower(),
		str(native_recovery_contract).to_lower(),
	])
	picker.free()
	lifecycle.free()
	manager.queue_free()
	holder.queue_free()
	await process_frame
	quit(0 if ok else 1)
