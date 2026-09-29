class_name RuntimeV3LifecycleMenuPolicy
extends RefCounted
## Single source of truth for lifecycle command ownership.
##
## Hover Menu:
##   Quick Panel, Animations, Change Character, Hide to Tray, Exit
##
## Quick Panel:
##   Runtime controls only. No Hide to Tray and no Exit.
##
## Tray:
##   Restore, Quick Panel, Exit
##
## Exit remains in both Hover Menu and Tray so the user can always close the
## runtime even if hover input stops working.

const ACTION_QUICK_PANEL := "quick_panel"
const ACTION_ANIMATIONS := "animations"
const ACTION_CHANGE_CHARACTER := "change_character"
const ACTION_HIDE_TO_TRAY := "hide_to_tray"
const ACTION_RESTORE := "restore"
const ACTION_EXIT := "exit"


static func hover_actions() -> Array[String]:
	return [
		ACTION_QUICK_PANEL,
		ACTION_ANIMATIONS,
		ACTION_CHANGE_CHARACTER,
		ACTION_HIDE_TO_TRAY,
		ACTION_EXIT,
	]


static func quick_panel_actions() -> Array[String]:
	return [
		ACTION_ANIMATIONS,
		ACTION_CHANGE_CHARACTER,
	]


static func tray_actions() -> Array[String]:
	return [
		ACTION_RESTORE,
		ACTION_QUICK_PANEL,
		ACTION_EXIT,
	]


static func should_show_in_hover(action: String) -> bool:
	return action in hover_actions()


static func should_show_in_quick_panel(action: String) -> bool:
	return action in quick_panel_actions()


static func should_show_in_tray(action: String) -> bool:
	return action in tray_actions()
