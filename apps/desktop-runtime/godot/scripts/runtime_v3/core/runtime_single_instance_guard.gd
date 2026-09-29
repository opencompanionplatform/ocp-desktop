extends Node
class_name RuntimeV3SingleInstanceGuard
## Process-level single-instance guard.
##
## A TCP listener is retained for the lifetime of the primary Runtime process.
## A second Runtime cannot bind the same localhost port and exits before
## services, controllers, tray or character UI are initialized.

signal duplicate_launch_received

const DEFAULT_PORT: int = 47831
const LOOPBACK: String = "127.0.0.1"

var _server: TCPServer
var _is_primary: bool = false
var _port: int = DEFAULT_PORT


func acquire(port: int = DEFAULT_PORT) -> bool:
	_port = port
	_server = TCPServer.new()

	var result: Error = _server.listen(_port, LOOPBACK)
	if result == OK:
		_is_primary = true
		set_process(true)
		print("[RuntimeV3] Single-instance lock acquired on %s:%d" % [LOOPBACK, _port])
		return true

	_is_primary = false
	set_process(false)
	_notify_primary_instance()
	print("[RuntimeV3] Another Runtime V3 instance is already active; duplicate launch stopped.")
	return false


func release() -> void:
	set_process(false)
	if _server != null:
		_server.stop()
		_server = null
	_is_primary = false


func is_primary() -> bool:
	return _is_primary


func _process(_delta: float) -> void:
	if not _is_primary or _server == null:
		return

	while _server.is_connection_available():
		var peer: StreamPeerTCP = _server.take_connection()
		if peer == null:
			continue

		# Receiving any connection is enough to request foreground restore.
		duplicate_launch_received.emit()
		peer.disconnect_from_host()


func _notify_primary_instance() -> void:
	var peer := StreamPeerTCP.new()
	var result: Error = peer.connect_to_host(LOOPBACK, _port)
	if result != OK:
		return

	# Poll briefly so Windows has time to complete the local connection.
	for _attempt in range(10):
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.put_data("activate".to_utf8_buffer())
			break
		OS.delay_msec(10)

	peer.disconnect_from_host()


func _exit_tree() -> void:
	release()
