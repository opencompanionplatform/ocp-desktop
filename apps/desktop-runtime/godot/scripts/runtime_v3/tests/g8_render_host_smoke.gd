extends Node

const BRIDGE_CLASS_NAME := "OcpRuntimeBridge"

var _bridge: Node


func _ready() -> void:
	print("[G8 Godot] render-host smoke begin")
	if not ClassDB.class_exists(BRIDGE_CLASS_NAME):
		push_error("[G8 Godot] GDExtension class missing")
		get_tree().quit(31)
		return

	_bridge = ClassDB.instantiate(BRIDGE_CLASS_NAME)
	if _bridge == null or not _bridge is Node:
		push_error("[G8 Godot] bridge instantiate failed")
		get_tree().quit(32)
		return
	add_child(_bridge)

	await get_tree().process_frame
	var companion_id := "g8-smoke"
	var token := "g8-host-token"
	if not _bridge.call("attach_render_surface", companion_id, token):
		push_error("[G8 Godot] attach rejected")
		get_tree().quit(33)
		return
	print("[G8 Godot] render-host-ready companion=%s physics_committed=false" % companion_id)

	if not _bridge.call("set_render_client_size", 256, 256):
		push_error("[G8 Godot] resize rejected")
		get_tree().quit(34)
		return
	print("[G8 Godot] render-host-resized client_size=(256,256) physics_committed=false")

	if not _bridge.call("detach_render_surface", companion_id):
		push_error("[G8 Godot] detach rejected")
		get_tree().quit(35)
		return
	print("[G8 Godot] render-host-detached companion=%s physics_committed=false" % companion_id)
	print("[G8 Godot] render-host smoke passed")
	get_tree().quit(0)
