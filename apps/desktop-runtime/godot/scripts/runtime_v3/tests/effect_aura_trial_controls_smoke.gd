extends "res://scripts/runtime_v3/tests/effect_aura_trial_preview.gd"

func setup() -> void:
	await super.setup()
	var burst_button := root.get_node_or_null("BurstButton") as Button
	var motion_button := root.get_node_or_null("MotionButton") as Button
	var close_button := root.get_node_or_null("CloseButton") as Button
	if burst_button == null or motion_button == null or close_button == null:
		push_error("[FX-CONTROLS] buttons missing")
		quit(1)
		return
	burst_button.pressed.emit()
	var burst_ok: bool = controllers[0].level_up_burst != null and controllers[1].level_up_burst != null
	motion_button.pressed.emit()
	var paused_ok: bool = not motion and not controllers[0].relationship_aura.is_playing()
	var key := InputEventKey.new()
	key.keycode = KEY_M # Logical-only events must work too.
	key.pressed = true
	root.window_input.emit(key)
	var resumed_ok: bool = motion and controllers[0].relationship_aura.is_playing()
	key.echo = true
	root.window_input.emit(key)
	var repeat_ok := motion
	key.echo = false
	key.keycode = KEY_NONE
	key.physical_keycode = KEY_B
	root.window_input.emit(key)
	var key_burst_ok: bool = controllers[1].level_up_burst != null
	var close_ok := close_button.pressed.is_connected(quit)
	print("[FX-CONTROLS] buttons_burst=%s pause=%s logical_resume=%s repeat_ignored=%s physical_burst=%s close_connected=%s" % [burst_ok, paused_ok, resumed_ok, repeat_ok, key_burst_ok, close_ok])
	if not (burst_ok and paused_ok and resumed_ok and repeat_ok and key_burst_ok and close_ok):
		quit(1)
		return
	key.physical_keycode = KEY_ESCAPE
	root.window_input.emit(key) # Must exit successfully; runner enforces a timeout.
