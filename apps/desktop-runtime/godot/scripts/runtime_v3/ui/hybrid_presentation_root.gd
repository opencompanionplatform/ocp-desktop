extends Control
class_name RuntimeV3HybridPresentationRoot
## Isolated visual host for opt-in Hybrid presentation.
##
## This scene is not part of the production overlay. Nodes can be attached and
## returned to their original parents so a failed Hybrid activation has a
## deterministic rollback path.

var original_placements: Dictionary = {}


func attach_nodes(
	character_node: Control,
	bubble_node: Control,
	hover_node: Control
) -> bool:
	if not _slots_ready():
		return false
	if not _attach(character_node, %CharacterSlot):
		return false
	if not _attach(bubble_node, %BubbleSlot):
		detach_all()
		return false
	if not _attach(hover_node, %HoverSlot):
		detach_all()
		return false
	return true


func detach_all() -> void:
	for node_value in original_placements.keys():
		var node: Node = node_value
		var placement: Dictionary = original_placements[node_value]
		var parent: Node = placement.get("parent")
		if not is_instance_valid(node) or not is_instance_valid(parent):
			continue
		node.reparent(parent, true)
		var index := int(placement.get("index", parent.get_child_count() - 1))
		parent.move_child(node, clampi(index, 0, parent.get_child_count() - 1))
	original_placements.clear()


func is_attached() -> bool:
	return not original_placements.is_empty()


func _attach(node: Control, slot: Control) -> bool:
	if not is_instance_valid(node) or not is_instance_valid(slot):
		return false
	if original_placements.has(node):
		return true
	var parent := node.get_parent()
	if parent == null:
		return false
	original_placements[node] = {
		"parent": parent,
		"index": node.get_index(),
	}
	node.reparent(slot, true)
	return true


func _slots_ready() -> bool:
	return (
		is_instance_valid(%CharacterSlot)
		and is_instance_valid(%BubbleSlot)
		and is_instance_valid(%HoverSlot)
	)
