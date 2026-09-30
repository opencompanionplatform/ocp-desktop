extends RefCounted
class_name RuntimeV3Events

const SYSTEM_STARTING: StringName = &"system.starting"
const SYSTEM_READY: StringName = &"system.ready"
const SYSTEM_SHUTTING_DOWN: StringName = &"system.shutting_down"

const CHARACTER_LOAD_ACTIVE_REQUESTED: StringName = &"character.load_active_requested"
const CHARACTER_LOADING: StringName = &"character.loading"
const CHARACTER_LOADED: StringName = &"character.loaded"
const CHARACTER_LOAD_FAILED: StringName = &"character.load_failed"
const CHARACTER_CHANGED: StringName = &"character.changed"
const CHARACTER_POSITION_CHANGED: StringName = &"character.position_changed"
const CHARACTER_DRAG_STARTED: StringName = &"character.drag_started"
const CHARACTER_DRAG_FINISHED: StringName = &"character.drag_finished"
const CHARACTER_POSITION_RESTORE_REQUESTED: StringName = &"character.position_restore_requested"
const CHARACTER_POSITION_SAVE_REQUESTED: StringName = &"character.position_save_requested"
const CHARACTER_ACTIVATE_REQUESTED: StringName = &"character.activate_requested"
const CHARACTER_UNINSTALL_REQUESTED: StringName = &"character.uninstall_requested"
const CHARACTER_UNINSTALL_RESULT: StringName = &"character.uninstall_result"
const CHARACTER_UNINSTALLED: StringName = &"character.uninstalled"

const PACKAGE_INSTALL_REQUESTED: StringName = &"package.install_requested"
const PACKAGE_INSTALLED: StringName = &"package.installed"
const PACKAGE_INSTALL_FAILED: StringName = &"package.install_failed"

const ANIMATION_REQUESTED: StringName = &"animation.requested"
const ANIMATION_STARTED: StringName = &"animation.started"
const ANIMATION_FINISHED: StringName = &"animation.finished"
const ANIMATION_MISSING: StringName = &"animation.missing"

const BUBBLE_REQUESTED: StringName = &"bubble.requested"
const BUBBLE_SHOWN: StringName = &"bubble.shown"
const BUBBLE_HIDDEN: StringName = &"bubble.hidden"

const SOUND_PLAY_REQUESTED: StringName = &"sound.play_requested"
const SOUND_STARTED: StringName = &"sound.started"
const SOUND_MISSING: StringName = &"sound.missing"

const HOVER_SHOW_REQUESTED: StringName = &"hover.show_requested"
const HOVER_HIDE_REQUESTED: StringName = &"hover.hide_requested"

const WINDOW_HIDE_TO_TRAY_REQUESTED: StringName = &"window.hide_to_tray_requested"
const WINDOW_RESTORE_REQUESTED: StringName = &"window.restore_requested"
const WINDOW_HIDDEN_TO_TRAY: StringName = &"window.hidden_to_tray"
const WINDOW_RESTORED: StringName = &"window.restored"
const WINDOW_EXIT_REQUESTED: StringName = &"window.exit_requested"
const MONITOR_TOPOLOGY_CHANGED: StringName = &"monitor.topology_changed"

const QUICK_PANEL_OPEN_REQUESTED: StringName = &"quick_panel.open_requested"
const QUICK_PANEL_CLOSE_REQUESTED: StringName = &"quick_panel.close_requested"
const CHARACTER_PICKER_OPEN_REQUESTED: StringName = &"character_picker.open_requested"
const CHARACTER_PICKER_CLOSE_REQUESTED: StringName = &"character_picker.close_requested"
const CHAT_WINDOW_OPEN_REQUESTED: StringName = &"chat_window.open_requested"
const CHAT_WINDOW_CLOSE_REQUESTED: StringName = &"chat_window.close_requested"

const CLICK_THROUGH_REFRESH_REQUESTED: StringName = &"click_through.refresh_requested"

const NOTIFICATION_REQUESTED: StringName = &"notification.requested"
const NOTIFICATION_SHOWN: StringName = &"notification.shown"

const AI_PROMPT_REQUESTED: StringName = &"ai.prompt_requested"
const AI_STREAM_STARTED: StringName = &"ai.stream_started"
const AI_STREAM_DELTA: StringName = &"ai.stream_delta"
const AI_RESPONSE_RECEIVED: StringName = &"ai.response_received"
const AI_RESPONSE_FAILED: StringName = &"ai.response_failed"
const AI_PROVIDER_STATUS_CHANGED: StringName = &"ai.provider_status_changed"
const AI_THINKING_STARTED: StringName = &"ai.thinking_started"
const AI_THINKING_FINISHED: StringName = &"ai.thinking_finished"

const CHAT_RESPONSE_STARTED: StringName = &"chat.response_started"
const CHAT_ASSISTANT_STREAM_STARTED: StringName = &"chat.assistant_stream_started"
const CHAT_ASSISTANT_STREAM_DELTA: StringName = &"chat.assistant_stream_delta"
const CHAT_ASSISTANT_MESSAGE_RECEIVED: StringName = &"chat.assistant_message_received"
const CHAT_RESPONSE_FAILED: StringName = &"chat.response_failed"

const TTS_REQUESTED: StringName = &"tts.requested"
const TTS_CANCEL_REQUESTED: StringName = &"tts.cancel_requested"
const TTS_STARTED: StringName = &"tts.started"
const TTS_FINISHED: StringName = &"tts.finished"
const TTS_FAILED: StringName = &"tts.failed"
const TTS_INTERRUPTED: StringName = &"tts.interrupted"
const TTS_LATENCY_MEASURED: StringName = &"tts.latency_measured"

const MEMORY_READ_REQUESTED: StringName = &"memory.read_requested"
const MEMORY_WRITE_REQUESTED: StringName = &"memory.write_requested"

const DEBUG_TOGGLE_REQUESTED: StringName = &"debug.toggle_requested"
const PERFORMANCE_TOGGLE_REQUESTED: StringName = &"performance.toggle_requested"
