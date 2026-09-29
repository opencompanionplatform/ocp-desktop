extends Node
class_name RuntimeV3StateMachine

signal state_changed(previous: StringName, current: StringName, context: Dictionary)
signal transition_rejected(current: StringName, requested: StringName)

const BOOTING: StringName = &"booting"
const READY: StringName = &"ready"
const DRAGGING: StringName = &"dragging"
const WALKING: StringName = &"walking"
const QUICK_PANEL: StringName = &"quick_panel"
const CHARACTER_PICKER: StringName = &"character_picker"
const HIDDEN_TO_TRAY: StringName = &"hidden_to_tray"
const SHUTTING_DOWN: StringName = &"shutting_down"

var current_state: StringName = BOOTING
var previous_state: StringName = BOOTING

var _allowed: Dictionary = {
	BOOTING: [READY, SHUTTING_DOWN],
	READY: [DRAGGING, WALKING, QUICK_PANEL, CHARACTER_PICKER, HIDDEN_TO_TRAY, SHUTTING_DOWN],
	DRAGGING: [READY, HIDDEN_TO_TRAY, SHUTTING_DOWN],
	WALKING: [READY, DRAGGING, HIDDEN_TO_TRAY, SHUTTING_DOWN],
	QUICK_PANEL: [READY, CHARACTER_PICKER, HIDDEN_TO_TRAY, SHUTTING_DOWN],
	CHARACTER_PICKER: [READY, QUICK_PANEL, HIDDEN_TO_TRAY, SHUTTING_DOWN],
	HIDDEN_TO_TRAY: [READY, SHUTTING_DOWN],
	SHUTTING_DOWN: [],
}


func can_transition(next_state: StringName) -> bool:
	return (_allowed.get(current_state, []) as Array).has(next_state)


func transition(next_state: StringName, transition_context: Dictionary = {}, force: bool = false) -> bool:
	if next_state == current_state:
		return true

	if not force and not can_transition(next_state):
		transition_rejected.emit(current_state, next_state)
		return false

	previous_state = current_state
	current_state = next_state
	state_changed.emit(previous_state, current_state, transition_context)
	return true
