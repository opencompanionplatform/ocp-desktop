class_name RuntimeV3HoverLifecycleController
extends Node
## Wires lifecycle actions owned by the Hover Menu.
##
## RuntimeApp creates several controllers during its own _ready(). Child nodes
## enter _ready() first, so WindowController may not exist when this node first
## starts. Resolution is therefore deferred and repeated on demand.

@export var hide_button_path: NodePath = NodePath(
	"../../RuntimeUI/HoverMenu/Buttons/HoverHideToTrayButton"
)
@export var hover_menu_path: NodePath = NodePath(
	"../../RuntimeUI/HoverMenu"
)

@export var resolve_retry_frames: int = 4

var _hide_button: Button = null
var _hover_menu: Control = null
var _window_controller: Object = null
var _resolution_started: bool = false


func _ready() -> void:
	_hide_button = get_node_or_null(hide_button_path) as Button
	_hover_menu = get_node_or_null(hover_menu_path) as Control

	if _hide_button == null:
		push_error(
			"[HoverLifecycle] HoverHideToTrayButton not found: %s"
			% hide_button_path
		)
		return

	if not _hide_button.pressed.is_connected(
		_on_hide_to_tray_pressed
	):
		_hide_button.pressed.connect(
			_on_hide_to_tray_pressed
		)

	# Parent RuntimeApp has not necessarily completed _ready() yet.
	call_deferred("_resolve_after_bootstrap")

	print("[HoverLifecycle] Hide to Tray button connected")


func _resolve_after_bootstrap() -> void:
	if _resolution_started:
		return

	_resolution_started = true

	var retries: int = maxi(resolve_retry_frames, 1)

	for _index in range(retries):
		_window_controller = _resolve_window_controller()

		if _is_valid_window_controller(_window_controller):
			print("[HoverLifecycle] WindowController resolved")
			return

		await get_tree().process_frame

	# This is not fatal. The button retries resolution when pressed.
	push_warning(
		"[HoverLifecycle] WindowController not ready yet; "
		+ "will resolve again on demand"
	)


func _on_hide_to_tray_pressed() -> void:
	if _hover_menu != null:
		_hover_menu.visible = false

	if not _is_valid_window_controller(_window_controller):
		_window_controller = _resolve_window_controller()

	if not _is_valid_window_controller(_window_controller):
		push_error(
			"[HoverLifecycle] WindowController unavailable "
			+ "when Hide to Tray was pressed"
		)
		return

	if _window_controller.has_method("hide_to_tray"):
		_window_controller.call_deferred("hide_to_tray")
		print("[HoverLifecycle] Hide to Tray requested")
		return

	if _window_controller.has_method("request_hide_to_tray"):
		_window_controller.call_deferred(
			"request_hide_to_tray"
		)
		print("[HoverLifecycle] Hide to Tray requested")
		return

	push_error(
		"[HoverLifecycle] Resolved WindowController has no "
		+ "supported hide method"
	)


func _resolve_window_controller() -> Object:
	var scene: Node = get_tree().current_scene

	if scene == null:
		return null

	# RuntimeApp V3 already exposes a controller lookup helper in some
	# revisions. Use it before walking the tree.
	if scene.has_method("_controller"):
		for controller_name in [
			"WindowController",
			"RuntimeV3WindowController",
			"window",
		]:
			var resolved: Variant = scene.call(
				"_controller",
				controller_name
			)

			if _is_valid_window_controller(resolved):
				return resolved

	# Some revisions keep controllers as properties instead of nodes.
	for property_name in [
		"window_controller",
		"_window_controller",
	]:
		var property_value: Variant = scene.get(property_name)

		if _is_valid_window_controller(property_value):
			return property_value

	# Search known node names.
	for candidate_name in [
		"WindowController",
		"RuntimeWindowController",
	]:
		var candidate: Node = scene.find_child(
			candidate_name,
			true,
			false
		)

		if _is_valid_window_controller(candidate):
			return candidate

	# Final fallback: recursively search any object implementing the method.
	return _find_controller_by_method(scene)


func _find_controller_by_method(root: Node) -> Object:
	if root == null:
		return null

	if root != self and (
		root.has_method("hide_to_tray")
		or root.has_method("request_hide_to_tray")
	):
		return root

	for child_value in root.get_children():
		var child: Node = child_value as Node

		if child == null:
			continue

		var nested: Object = _find_controller_by_method(child)

		if _is_valid_window_controller(nested):
			return nested

	return null


func _is_valid_window_controller(value: Variant) -> bool:
	if value == null:
		return false

	if not is_instance_valid(value):
		return false

	return (
		value.has_method("hide_to_tray")
		or value.has_method("request_hide_to_tray")
	)
