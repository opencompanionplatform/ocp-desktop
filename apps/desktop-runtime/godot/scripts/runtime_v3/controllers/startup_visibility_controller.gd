class_name RuntimeV3StartupVisibilityController
extends Node
## Prevents the root overlay window from rendering at (0, 0) before Runtime V3
## has applied transparency, virtual desktop geometry and character layout.
##
## Usage:
##   startup_visibility.begin_startup()
##   await bootstrap.start_runtime()
##   await startup_visibility.reveal_when_ready()

@export var stabilization_frames: int = 2
@export var startup_timeout_seconds: float = 8.0

var _window: Window = null
var _startup_started_at_msec: int = 0
var _revealed: bool = false
var _can_toggle_native_visibility: bool = false


func begin_startup(
	window: Window = null,
	can_toggle_native_visibility: bool = false
) -> void:
	_window = window if window != null else get_window()
	_startup_started_at_msec = Time.get_ticks_msec()
	_revealed = false

	if _window == null:
		push_warning("[StartupVisibility] Root window is unavailable")
		return

	# This controller can be called before it has entered SceneTree, so it must
	# not infer the window role through get_tree(). The caller explicitly opts
	# into native visibility only for subwindows. Main-window callers keep the
	# safe default and rely on the transparent boot background/viewport.
	_can_toggle_native_visibility = can_toggle_native_visibility
	if _can_toggle_native_visibility:
		_window.visible = false

	# Defensive defaults. The real WindowController may apply these again.
	_window.borderless = true
	_window.transparent = true
	_window.always_on_top = true

	print("[StartupVisibility] transparent startup guard armed")


func reveal_when_ready() -> void:
	# character.loaded can fire again when the user installs or activates a
	# different package. Startup visibility is a one-shot gate; once the initial
	# Runtime surface has been revealed, later character lifecycle events must
	# not reuse the original startup timer or emit false timeout warnings.
	if _revealed:
		return

	if _window == null:
		_window = get_window()

	if _window == null:
		push_warning("[StartupVisibility] Cannot reveal missing root window")
		return

	var frames: int = maxi(stabilization_frames, 1)

	for _index in range(frames):
		await get_tree().process_frame

	# Safety valve: never leave the application invisible forever.
	var elapsed_seconds: float = (
		float(Time.get_ticks_msec() - _startup_started_at_msec) / 1000.0
	)

	if elapsed_seconds > startup_timeout_seconds:
		push_warning(
			"[StartupVisibility] Initial reveal took %.2f seconds (budget %.2f seconds)"
			% [elapsed_seconds, startup_timeout_seconds]
		)

	if _can_toggle_native_visibility:
		_window.visible = true
	_window.grab_focus()
	_revealed = true

	print("[StartupVisibility] startup guard released")


func is_revealed() -> bool:
	return _revealed
