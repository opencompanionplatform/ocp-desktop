extends Node
## Dedicated CS-RT conformance entry point.
##
## This scene creates only the real OcpRuntimeBridge and a lightweight
## presentation adapter. It does not load RuntimeApp.tscn or legacy Main.tscn.

const BRIDGE_CLASS_NAME := "OcpRuntimeBridge"
const PresentationAdapter = preload(
	"res://scripts/runtime_v3/tests/runtime_bridge_conformance_adapter.gd"
)

var _bridge: Node = null
var _adapter: Node = null


func _ready() -> void:
	print("[CS-RT Godot] dedicated conformance scene ready")
	print("[CS-RT Godot] display server: %s" % DisplayServer.get_name())
	print(
		"[CS-RT Godot] socket configured: %s"
		% str(not OS.get_environment("OCP_IPC_SOCKET").is_empty())
	)
	print(
		"[CS-RT Godot] token configured: %s"
		% str(not OS.get_environment("OCP_IPC_TOKEN").is_empty())
	)

	if not ClassDB.class_exists(BRIDGE_CLASS_NAME):
		push_error(
			"[CS-RT Godot] GDExtension class not registered: %s"
			% BRIDGE_CLASS_NAME
		)
		get_tree().quit(21)
		return

	var instance: Object = ClassDB.instantiate(BRIDGE_CLASS_NAME)

	if instance == null:
		push_error(
			"[CS-RT Godot] Could not instantiate: %s"
			% BRIDGE_CLASS_NAME
		)
		get_tree().quit(22)
		return

	if not instance is Node:
		push_error(
			"[CS-RT Godot] Bridge class is not a Node: %s"
			% BRIDGE_CLASS_NAME
		)
		instance.free()
		get_tree().quit(23)
		return

	_bridge = instance
	_bridge.name = "OcpRuntimeBridge"
	add_child(_bridge)

	_adapter = PresentationAdapter.new()
	_adapter.name = "RuntimeBridgeConformanceAdapter"
	add_child(_adapter)
	_adapter.bind_bridge(_bridge)

	print("[CS-RT Godot] OcpRuntimeBridge instantiated")
	print("[CS-RT Godot] presentation adapter bound")
	_run_g8_render_host_smoke.call_deferred()


func _run_g8_render_host_smoke() -> void:
	print("[G8 Godot] render-host smoke begin")
	for signal_name in ["render_host_ready", "render_host_resized", "render_host_detached"]:
		if not _bridge.has_signal(signal_name):
			push_error("[G8 Godot] missing bridge signal: %s" % signal_name)
			get_tree().quit(31)
			return

	if not _bridge.has_method("attach_render_surface") \
	or not _bridge.has_method("set_render_client_size") \
	or not _bridge.has_method("detach_render_surface"):
		push_error("[G8 Godot] render-host bridge methods missing")
		get_tree().quit(32)
		return

	var companion_id := "g8-smoke"
	var host_token := "g8-host-token"
	if not _bridge.call("attach_render_surface", companion_id, host_token):
		push_error("[G8 Godot] attach_render_surface rejected valid input")
		get_tree().quit(33)
		return
	print("[G8 Godot] render-host-ready companion=%s physics_committed=false" % companion_id)

	if not _bridge.call("set_render_client_size", 256, 256):
		push_error("[G8 Godot] set_render_client_size rejected valid input")
		get_tree().quit(34)
		return
	print("[G8 Godot] render-host-resized client_size=(256,256) physics_committed=false")

	if not _bridge.call("detach_render_surface", companion_id):
		push_error("[G8 Godot] detach_render_surface rejected valid input")
		get_tree().quit(35)
		return
	print("[G8 Godot] render-host-detached companion=%s physics_committed=false" % companion_id)
	print("[G8 Godot] render-host smoke passed")
	# Do not quit here. The CS-RT harness still needs this real bridge alive for
	# speech, emotion and window-policy steps. run_cs_rt.ps1 terminates Godot
	# after cs_rt_live exits, so a successful render-host smoke must stay resident.
	print("[CS-RT Godot] render-host smoke complete; waiting for CS-RT steps")
