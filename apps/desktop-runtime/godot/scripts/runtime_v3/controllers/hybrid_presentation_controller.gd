extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3HybridPresentationController
## Opt-in coordinator for the isolated Hybrid PresentationRoot.
##
## Gate 3 intentionally keeps the existing native window. Monitor-scoped
## native window activation is a later gate after this reversible reparenting
## path is proven stable.

const HybridPresentationRootScene = preload(
	"res://scenes/runtime_v3/HybridPresentationRoot.tscn"
)

var ui_parent: Node
var character_layer: Control
var bubble_layer: Control
var hover_menu: Control
var presentation_root: Control


func bind(
	target_parent: Node,
	target_character_layer: Control,
	target_bubble_layer: Control,
	target_hover_menu: Control
) -> void:
	ui_parent = target_parent
	character_layer = target_character_layer
	bubble_layer = target_bubble_layer
	hover_menu = target_hover_menu


func activate_isolated() -> bool:
	if is_instance_valid(presentation_root):
		return true
	if (
		not is_instance_valid(ui_parent)
		or not is_instance_valid(character_layer)
		or not is_instance_valid(bubble_layer)
		or not is_instance_valid(hover_menu)
	):
		return false

	presentation_root = HybridPresentationRootScene.instantiate()
	ui_parent.add_child(presentation_root)
	var attached: bool = presentation_root.attach_nodes(
		character_layer,
		bubble_layer,
		hover_menu
	)
	if not attached:
		presentation_root.queue_free()
		presentation_root = null
		return false

	context.update_runtime_config({
		"hybrid_monitor_active": true,
		"hybrid_monitor_gate": "isolated-presentation-root",
	})
	return true


func deactivate() -> void:
	if is_instance_valid(presentation_root):
		presentation_root.detach_all()
		presentation_root.queue_free()
	presentation_root = null
	if context != null:
		context.update_runtime_config({
			"hybrid_monitor_active": false,
			"hybrid_monitor_gate": "disabled",
		})


func stop() -> void:
	deactivate()
