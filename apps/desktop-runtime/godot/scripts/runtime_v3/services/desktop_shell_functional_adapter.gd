extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name DesktopShellFunctionalAdapter

## ADR-0039: a deliberately narrow Runtime-owned adapter for Electron's opaque
## windows. The renderer never sees the token; this service is the only reader
## of commands and it publishes into existing Runtime workflows.

const SentenceChunkerScript = preload("res://scripts/runtime_v3/services/sentence_chunker.gd")
const EffectPlacementResolver = preload("res://scripts/runtime_v3/core/effect_placement_resolver.gd")
const EffectComparisonRenderer = preload("res://scripts/runtime_v3/core/effect_comparison_renderer.gd")

const ENABLED_ENV := "OCP_DESKTOP_SHELL_FUNCTIONAL_ADAPTER"
const SCHEMA_VERSION := 20
const AUTH_HANDOFF_PATTERN := "^[A-Za-z0-9_-]{32,256}$"
const PREVIEW_MEDIA_SCHEMA_VERSION := 1
const POLL_SECONDS := 0.03
const MAX_COMMANDS_PER_POLL := 32
const HEARTBEAT_SECONDS := 1.0
const MAX_COMMAND_BYTES := 16_384
const MAX_PROMPT_LENGTH := 4_000
const MAX_CHAT_MESSAGES := 80
# Electron polls Chat snapshots at 10 FPS while preview media is active. Do not
# serialize the entire Runtime projection once per model token; coalesce stream
# deltas to the consumer cadence so AI transport remains responsive.
const CHAT_STREAM_SNAPSHOT_INTERVAL_MS := 100
const MAX_PREVIEW_OUTPUT_FPS := 12.0
const MAX_PREVIEW_FRAME_WIDTH := 512
const MAX_PREVIEW_FRAME_HEIGHT := 512
const MAX_PREVIEW_PNG_BYTES := 196_608
const MAX_PREVIEW_BASE64_LENGTH := 262_144
const EFFECT_PREVIEW_OUTPUT_SIZE := Vector2i(512, 320)
const EFFECT_PREVIEW_RUNTIME_SURFACE_SIZE := 384
const EFFECT_PREVIEW_OUTPUT_FPS := 24.0
const EFFECT_PREVIEW_MAX_SHEET_DIMENSION := 2048
const PREVIEW_CHARACTER_TARGET_HEIGHT_PX := 220.0
const PREVIEW_CHARACTER_TARGET_WIDTH_PX := 276.0
const PREVIEW_CHARACTER_FEET_Y_PX := 246.0
const EFFECT_PREVIEW_MODES := ["all", "bodyAura", "groundRune", "levelUpBurst", "off"]
const MAX_PREVIEW_SHORTCUT_THUMBNAILS := 7
const MAX_PREVIEW_ANIMATION_FRAMES := 512
const PREVIEW_ANIMATION_CACHE_BYTES := 32 * 1024 * 1024
const PREVIEW_ATLAS_IMAGE_CACHE_BYTES := 16 * 1024 * 1024
const PREVIEW_ATLAS_IMAGE_CACHE_LIMIT := 2
const PREVIEW_SHORTCUT_PAGE_SIZE := 6
const CHAT_CORE_PREVIEW_ANIMATIONS := ["idle", "think", "speak"]
const VOICE_RATE_LIMIT_COOLDOWN_MS := 60000
const MAX_PREVIEW_THUMBNAIL_WIDTH := 112
const MAX_PREVIEW_THUMBNAIL_HEIGHT := 112
const MAX_PREVIEW_THUMBNAIL_PNG_BYTES := 49_152
const MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH := 65_536
const MAX_CHARACTER_THUMBNAIL_WIDTH := 128
const MAX_CHARACTER_THUMBNAIL_HEIGHT := 128
const MAX_CHARACTER_THUMBNAIL_PNG_BYTES := 65_536
const MAX_CHARACTER_THUMBNAIL_BASE64_LENGTH := 87_384
const PREVIEW_SPEEDS := [0.5, 1.0, 1.5, 2.0]
const TEXT_SCALES := {
	"normal": 1.0,
	"standard": 1.15,
	"comfortable": 1.3,
	"large": 1.5,
	"extra": 1.8,
}
const FONT_FAMILIES := {
	"system": "System",
	"inter": "Inter",
	"noto-sans-thai": "Noto Sans Thai",
	"atkinson": "Atkinson Hyperlegible",
}
const CONTROL_FONT_FAMILIES := ["Noto Sans Thai", "Segoe UI", "Tahoma", "Leelawadee UI", "Arial", "Inter"]
const BUBBLE_STYLES := ["Rounded", "Compact", "Soft"]
const UPDATE_CHANNELS := ["stable", "preview"]
const AI_PROVIDER_IDS := ["offline", "ollama", "openai-compatible"]
const AI_TIMEOUT_SECONDS := [15, 30, 45, 60, 120]
const TTS_PROVIDER_IDS := ["auto", "system"]
const CHAT_VOICE_MODES := ["off", "on-demand", "auto-speak", "live-voice"]
const TTS_VOICE_MODES := ["character", "custom"]
const TTS_VOICE_GENDERS := ["female", "male", "neutral"]
const TTS_VOICE_AGES := ["child", "adult"]
const THAI_SPEECH_STYLES := ["feminine", "masculine", "neutral"]
const DEFAULT_TTS_MODEL_ID := "gemini-3.1-flash-tts-preview"
const TTS_MODEL_IDS := [DEFAULT_TTS_MODEL_ID, "gemini-2.5-flash-preview-tts"]
const TTS_VOICE_IDS := [
	"auto", "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
	"Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
	"Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
	"Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat",
]
const RUNTIME_VOICE_TEST_PHRASE := "Hello!"
const RUNTIME_VOICE_TEST_PHRASE_TH := "สวัสดีค่ะ"
const CONTROL_TEST_TIMEOUT_MARGIN_MS := 5000
const UPDATE_CHECK_TIMEOUT_MS := 70_000
const MAX_COMMAND_RESULTS := 64
const UPDATE_MESSAGES := {
	"update-unavailable": "Signed updates are unavailable in this Runtime.",
	"update-idle": "Ready to check the signed update channel.",
	"update-checking": "Runtime is checking and verifying the signed update manifest.",
	"update-current": "OCP is up to date.",
	"update-ready": "A verified update is staged and ready to install.",
	"update-apply-requested": "Runtime accepted the install request and is preparing to restart.",
	"update-stopping": "Waiting for OCP processes to stop safely.",
	"update-validating": "Validating the staged update bundle.",
	"update-swapping": "Switching the per-user installation transactionally.",
	"update-restarting": "Restarting OCP and waiting for the health check.",
	"update-applied": "The update was applied and passed its startup health check.",
	"update-rolled-back": "The update failed and the previous version was restored.",
	"update-config-incomplete": "Signed update configuration is incomplete.",
	"update-preview-config-incomplete": "Preview update configuration is incomplete.",
	"update-stable-trust-pending": "Stable updates stay locked until Production signing trust is ready.",
	"update-updater-missing": "The signed Runtime updater is not installed.",
	"update-check-start-failed": "Runtime could not start the signed update check.",
	"update-check-failed": "The signed update check failed.",
	"update-check-timeout": "The signed update check timed out.",
	"update-not-ready": "No verified staged update is available.",
	"update-apply-not-configured": "Update installation is not configured for this installation.",
	"update-helper-missing": "The update apply helper is not installed.",
	"update-apply-start-failed": "Runtime could not start the update apply helper.",
	"update-rollback-failed": "The update and automatic rollback both failed.",
	"update-failed": "The update was rejected and the installation was not changed.",
}

static var active_instance: DesktopShellFunctionalAdapter

var services: Node
var effect_controller: Node
var session_directory := ""
var command_directory := ""
var network_request_directory := ""
var network_result_directory := ""
var network_download_directory := ""
var token := ""
var poll_elapsed := 0.0
var heartbeat_elapsed := 0.0
var handled_ids: Dictionary = {}
var chat_messages: Array[Dictionary] = []
var chat_status := "offline"
var chat_session_id := ""
var chat_revision := 0
var chat_active_message_id := ""
var ignored_chat_message_ids: Dictionary = {}
var chat_stream_snapshot_pending := false
var chat_stream_last_snapshot_msec := 0
var chat_stream_snapshot_not_before_msec := 0
var preview_state: Dictionary = {}
var preview_frames: SpriteFrames
var preview_active_payload: Dictionary = {}
var preview_package_info: Dictionary = {}
var preview_prepared_entry: Dictionary = {}
var preview_animation_cache: Dictionary = {}
var preview_animation_order: Array[String] = []
var preview_animation_cache_bytes := 0
var preview_animation_loops: Dictionary = {}
var preview_load_thread: Thread
var preview_load_animation := ""
var preview_load_generation := 0
var preview_load_started_at_msec := 0
var preview_requested_animation := ""
var preview_requested_playing := false
var preview_prefetch_queue: Array[String] = []
var preview_load_is_prefetch := false
var preview_generation := 0
var chat_preview_warm_started_at_msec := 0
var chat_preview_warm_ready_logged := false
var preview_thumbnail_base64_cache: Dictionary = {}
var preview_thumbnail_attempted: Dictionary = {}
var preview_elapsed := 0.0
var preview_frame_elapsed := 0.0
var preview_last_frame_index := -1
var preview_media_revision := 0
var preview_thumbnail_offset := 0
var preview_trim_rect_cache: Dictionary = {}
var preview_atlas_image_cache: Dictionary = {}
var preview_atlas_image_order: Array[String] = []
var preview_atlas_image_cache_bytes := 0
# Character Manager camera lock. Runtime visual bounds can change every animation
# frame as alpha extents change; the editor camera must not refit to those bounds
# or the companion visibly zooms in/out while playing.
var preview_camera_reference_rect := Rect2()
var preview_camera_character_id := ""
var effect_preview_mode := ""
var effect_preview_variant := "equipped"
var effect_comparison_renderer: Node
var effect_comparison_sources: Dictionary = {}
var effect_preview_elapsed := 0.0
var effect_preview_frame_elapsed := 0.0
var effect_preview_refresh_pending := false
var effect_preview_sheet_cache: Dictionary = {}
var effect_preview_tuning: Dictionary = {}
var character_thumbnail_cache: Dictionary = {}
var character_snapshot_cache: Array = []
var character_snapshot_dirty := true
var character_snapshot_refresh_scheduled := false
var command_results: Array[Dictionary] = []
var ai_test_state := {"status": "idle", "errorCode": ""}
var voice_test_state := {"status": "idle", "errorCode": ""}
var voice_health_state := {"status": "idle", "reasonCode": "", "lastSuccessAtMs": 0}
var voice_rate_limit_retry_at_ms := 0
var chat_presentation_active := false
# Snapshot projection may synchronously request/activate preview media. Prevent
# any nested _write_snapshot() from re-entering _refresh_chat_presentation();
# the outer snapshot already observes the state mutations made by that refresh.
var snapshot_projection_in_progress := false
var chat_presentation_sequence := 0
var chat_presentation_state := {
	"owner": "native", "state": "idle", "sequence": 0,
	"turnId": "", "messageId": "", "speechId": "", "reasonCode": "ready",
}
var active_voice_message_id := ""
var active_speech_id := ""
# Once audible playback starts for a multi-chunk Read Aloud request, keep the
# Chat presentation in TALK until the last chunk finishes. Without this latch,
# the gap while the next chunk is synthesizing briefly reverts TALK -> THINK.
var voice_playback_latched_messages: Dictionary = {}
var pending_voice_requests: Dictionary = {}
var voice_message_correlations: Dictionary = {}
var pending_ai_test: Dictionary = {}
var pending_ai_discovery: Dictionary = {}
var pending_voice_test: Dictionary = {}
var pending_cloud_install: Dictionary = {}
var pending_update_check: Dictionary = {}
var update_state := {"state": "idle", "messageCode": "update-idle", "targetVersion": ""}
var stopping := false


func start() -> void:
	if OS.get_environment(ENABLED_ENV) != "1":
		return
	stopping = false
	set_process(true)
	active_instance = self
	chat_session_id = _new_chat_session_id()
	preview_state = _idle_preview_state()
	_prepare_session()
	_subscribe(&"chat.response_started", Callable(self, "_on_chat_started"))
	_subscribe(&"chat.assistant_stream_delta", Callable(self, "_on_chat_delta"))
	_subscribe(&"chat.assistant_message_received", Callable(self, "_on_chat_completed"))
	_subscribe(&"chat.response_failed", Callable(self, "_on_chat_failed"))
	_subscribe(&"ai.provider_status_changed", Callable(self, "_on_provider_status"))
	_subscribe(&"ai.connection_test_completed", Callable(self, "_on_ai_test_completed"))
	_subscribe(&"ai.models_discovered", Callable(self, "_on_ai_models_discovered"))
	_subscribe(&"tts.requested", Callable(self, "_on_tts_requested"))
	_subscribe(&"tts.started", Callable(self, "_on_voice_test_started"))
	_subscribe(&"tts.finished", Callable(self, "_on_voice_test_finished"))
	_subscribe(&"tts.failed", Callable(self, "_on_voice_test_failed"))
	_subscribe(&"resource_monitor.updated", Callable(self, "_on_resource_monitor"))
	_subscribe(&"update.status_changed", Callable(self, "_on_update_status_changed"))
	_subscribe(&"update.check_finished", Callable(self, "_on_update_check_finished"))
	_subscribe(&"package.installed", Callable(self, "_on_package_projection_changed"))
	_subscribe(&"character.changed", Callable(self, "_on_package_projection_changed"))
	_subscribe(&"character.uninstalled", Callable(self, "_on_package_projection_changed"))
	_subscribe(&"character.uninstall_result", Callable(self, "_on_character_uninstall_result"))
	_subscribe(&"character.loaded", Callable(self, "_on_package_projection_changed"))
	_subscribe(&"cloud.auth.updated", Callable(self, "_on_account_projection_changed"))
	_subscribe(&"cloud.session.changed", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.device.updated", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.library.updated", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.catalog.updated", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.progression.updated", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.progression.sync_state", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.download.updated", Callable(self, "_on_cloud_projection_changed"))
	_subscribe(&"cloud.download.desktop_transfer_requested", Callable(self, "_on_desktop_transfer_requested"))
	# Initial heartbeat must remain cheap. The verified character library snapshot
	# is populated after Runtime reaches its first process frame, outside the
	# native renderer handoff critical path.
	_write_snapshot()
	_write_preview_media()


func stop() -> void:
	stopping = true
	set_process(false)
	_close_preview()
	_join_preview_load_thread()
	# Leave an explicit terminal marker for an Electron shell that is still
	# open. Electron also has an mtime lease for crash/force-close recovery.
	_write_snapshot("unavailable")
	if active_instance == self:
		active_instance = null
	for topic in [&"chat.response_started", &"chat.assistant_stream_delta", &"chat.assistant_message_received", &"chat.response_failed", &"ai.provider_status_changed", &"ai.connection_test_completed", &"ai.models_discovered", &"tts.requested", &"tts.started", &"tts.finished", &"tts.failed", &"resource_monitor.updated", &"update.status_changed", &"update.check_finished", &"package.installed", &"character.changed", &"character.uninstalled", &"character.uninstall_result", &"character.loaded", &"cloud.auth.updated", &"cloud.session.changed", &"cloud.device.updated", &"cloud.library.updated", &"cloud.catalog.updated", &"cloud.progression.updated", &"cloud.progression.sync_state", &"cloud.download.updated", &"cloud.download.desktop_transfer_requested"]:
		if event_bus != null:
			event_bus.unsubscribe(topic, Callable(self, _callback_name_for_topic(topic)))


static func launch_arguments() -> PackedStringArray:
	if not is_instance_valid(active_instance) or active_instance.session_directory.is_empty() or active_instance.token.is_empty():
		return PackedStringArray()
	var arguments := PackedStringArray([
		"--ocp-bridge-dir=%s" % active_instance.session_directory,
		"--ocp-bridge-token=%s" % active_instance.token,
	])
	arguments.append_array(active_instance._credential_broker_launch_arguments())
	return arguments


func bind_services(value: Node) -> void:
	services = value
	_refresh_update_state_from_service()
	character_snapshot_dirty = true
	# Publish the cheap bootstrap snapshot immediately so Electron can attach,
	# then build the verified character projection after Runtime has yielded its
	# native-ready frame. This keeps Store verification off the renderer handoff.
	_write_snapshot()
	_schedule_character_snapshot_refresh()


func bind_effect_controller(value: Node) -> void:
	effect_controller = value


func _on_package_projection_changed(_payload: Dictionary) -> void:
	character_snapshot_dirty = true
	_schedule_character_snapshot_refresh()


func _on_character_uninstall_result(payload: Dictionary) -> void:
	var request_id := str(payload.get("request_id", ""))
	if request_id.is_empty():
		return
	var ok := bool(payload.get("ok", false))
	print("[CharacterUninstall] result package=%s version=%s request_id=%s ok=%s error=%s" % [str(payload.get("package_id", "")), str(payload.get("version", "")), request_id, str(ok), str(payload.get("error_code", ""))])
	_record_command_result(request_id, "character.uninstall", {
		"status": "succeeded" if ok else "failed",
		"errorCode": "" if ok else str(payload.get("error_code", "uninstall-failed")),
	})
	_write_snapshot()


func _on_account_projection_changed(_payload: Dictionary) -> void:
	_write_snapshot()


func _on_cloud_projection_changed(payload: Dictionary) -> void:
	if not pending_cloud_install.is_empty():
		var package_id := str(payload.get("packageId", ""))
		var version := str(payload.get("version", ""))
		if package_id == str(pending_cloud_install.get("packageId", "")) and version == str(pending_cloud_install.get("version", "")):
			var cloud_status := str(payload.get("status", ""))
			if cloud_status == "installed":
				_record_command_result(str(pending_cloud_install.get("id", "")), "cloud.library.install", {"status": "succeeded", "errorCode": ""})
				pending_cloud_install.clear()
			elif cloud_status not in ["authorizing", "handoff-redeeming", "device-registering", "downloading", ""]:
				_record_command_result(str(pending_cloud_install.get("id", "")), "cloud.library.install", {"status": "failed", "errorCode": cloud_status})
				pending_cloud_install.clear()
	_write_snapshot()


func _schedule_character_snapshot_refresh() -> void:
	if session_directory.is_empty() or character_snapshot_refresh_scheduled:
		return
	character_snapshot_refresh_scheduled = true
	call_deferred("_refresh_character_snapshot_cache_after_startup")


func _refresh_character_snapshot_cache_after_startup() -> void:
	# NativeHostLifecycle writes godot-ready on the first yielded frame. Keep the
	# filesystem-heavy verified library scan behind that handshake and coalesce
	# install/activate/load bursts into one projection refresh.
	await get_tree().create_timer(0.35).timeout
	character_snapshot_refresh_scheduled = false
	if not character_snapshot_dirty or not is_instance_valid(services):
		return
	var started_at := Time.get_ticks_msec()
	character_snapshot_cache = _build_character_snapshot()
	character_snapshot_dirty = false
	print("[DesktopShellTiming] character_snapshot_ms=%d characters=%d" % [
		Time.get_ticks_msec() - started_at,
		character_snapshot_cache.size(),
	])
	_write_snapshot()


func _process(delta: float) -> void:
	if session_directory.is_empty():
		return
	# User commands are latency-critical and must not sit behind preview PNG
	# composition or heartbeat projection. In the previous ordering a busy Chat
	# preview could starve chat.submit / close visibility commands for seconds.
	poll_elapsed += delta
	if poll_elapsed >= POLL_SECONDS:
		poll_elapsed = 0.0
		_consume_commands()
		_consume_network_transfer_results()
	_poll_preview_load()
	_update_preview(delta)
	_update_effect_preview(delta)
	_flush_chat_stream_snapshot_if_due()
	_expire_control_tests()
	_expire_update_check()
	heartbeat_elapsed += delta
	if heartbeat_elapsed >= HEARTBEAT_SECONDS:
		heartbeat_elapsed = 0.0
		_write_snapshot()


func _prepare_session() -> void:
	var random_bytes := Crypto.new().generate_random_bytes(32)
	if random_bytes.size() != 32:
		push_error("DesktopShellFunctionalAdapter: could not create session token")
		return
	token = random_bytes.hex_encode()
	session_directory = ProjectSettings.globalize_path("user://desktop_shell_adapter/%s" % token.substr(0, 16))
	command_directory = session_directory.path_join("commands")
	network_request_directory = session_directory.path_join("network-requests")
	network_result_directory = session_directory.path_join("network-results")
	network_download_directory = session_directory.path_join("network-downloads")
	for directory in [command_directory, network_request_directory, network_result_directory, network_download_directory]:
		DirAccess.make_dir_recursive_absolute(directory)


func _on_desktop_transfer_requested(payload: Dictionary) -> void:
	if session_directory.is_empty() or token.is_empty() or not is_instance_valid(event_bus):
		return
	var request_id := str(payload.get("requestId", "")).strip_edges().to_lower()
	var url := str(payload.get("url", "")).strip_edges()
	if request_id.length() != 32 or not request_id.is_valid_hex_number() or url.length() < 9 or url.length() > 16384 or not url.begins_with("https://"):
		return
	var destination := network_request_directory.path_join("%s.json" % request_id)
	var temporary := "%s.tmp" % destination
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schemaVersion": 1,
		"id": request_id,
		"token": token,
		"url": url,
	}))
	file.flush()
	file.close()
	if DirAccess.rename_absolute(temporary, destination) != OK:
		DirAccess.remove_absolute(temporary)
		return
	event_bus.publish(&"cloud.download.desktop_transfer_started", {"requestId": request_id})


func _consume_network_transfer_results() -> void:
	if network_result_directory.is_empty() or token.is_empty() or not is_instance_valid(event_bus):
		return
	var directory := DirAccess.open(network_result_directory)
	if directory == null:
		return
	var names := directory.get_files()
	names.sort()
	var handled := 0
	for file_name in names:
		if handled >= 4 or not file_name.ends_with(".json"):
			continue
		var request_id := file_name.trim_suffix(".json")
		if request_id.length() != 32 or not request_id.is_valid_hex_number():
			continue
		var result_path := network_result_directory.path_join(file_name)
		var file := FileAccess.open(result_path, FileAccess.READ)
		if file == null:
			continue
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		DirAccess.remove_absolute(result_path)
		handled += 1
		if not (parsed is Dictionary):
			continue
		var result := parsed as Dictionary
		if int(result.get("schemaVersion", 0)) != 1 or str(result.get("id", "")) != request_id or str(result.get("token", "")) != token:
			continue
		var status := str(result.get("status", ""))
		var download_path := str(result.get("path", ""))
		if status == "succeeded":
			var expected_prefix := network_download_directory.rstrip("/\\") + "/"
			var normalized_path := download_path.replace("\\", "/")
			var normalized_prefix := expected_prefix.replace("\\", "/")
			if not normalized_path.begins_with(normalized_prefix) or not normalized_path.ends_with(".ocp") or not FileAccess.file_exists(download_path):
				status = "failed"
				download_path = ""
		event_bus.publish(&"cloud.download.desktop_transfer_completed", {
			"requestId": request_id,
			"status": status,
			"path": download_path,
			"bytes": maxi(0, int(result.get("bytes", 0))),
			"error": str(result.get("error", "")).substr(0, 256),
		})


func _consume_commands() -> void:
	var directory := DirAccess.open(command_directory)
	if directory == null:
		return
	var names := directory.get_files()
	names.sort()
	var handled_count := 0
	for file_name in names:
		if not file_name.ends_with(".json"):
			continue
		var path := command_directory.path_join(file_name)
		var envelope := _read_command(path)
		DirAccess.remove_absolute(path)
		if envelope.is_empty():
			continue
		var command := Dictionary(envelope.get("command", {}))
		# Electron may resend ownership state briefly while waiting for Runtime
		# acknowledgement. Once the requested state is already active, dropping
		# the duplicate avoids repeated preview/snapshot work and queue storms.
		if _is_redundant_system_command(command):
			continue
		_handle_command(command, str(envelope.get("id", "")))
		handled_count += 1
		if handled_count >= MAX_COMMANDS_PER_POLL:
			break


func _is_redundant_system_command(command: Dictionary) -> bool:
	var command_type := str(command.get("type", ""))
	if command_type in ["shell.chat-focus", "shell.chat-visibility"]:
		if typeof(command.get("active")) != TYPE_BOOL:
			return false
		return bool(command.get("active", false)) == chat_presentation_active
	if command_type == "shell.companion-suppression":
		if typeof(command.get("active")) != TYPE_BOOL or not is_instance_valid(context):
			return false
		var runtime_config: Dictionary = context.runtime_config if context.get("runtime_config") is Dictionary else {}
		return bool(command.get("active", false)) == bool(runtime_config.get("shell_companion_suppressed", false))
	return false


func _read_command(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_COMMAND_BYTES:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return {}
	var envelope: Dictionary = parsed
	if not _has_only_keys(envelope, ["id", "token", "command"]):
		return {}
	var id := str(envelope.get("id", ""))
	if id.is_empty() or id.length() > 128 or handled_ids.has(id) or str(envelope.get("token", "")) != token:
		return {}
	var candidate: Variant = envelope.get("command", {})
	if not candidate is Dictionary:
		return {}
	handled_ids[id] = true
	if handled_ids.size() > 256:
		handled_ids.erase(handled_ids.keys()[0])
	return {"id": id, "command": Dictionary(candidate)}


func _handle_command(command: Dictionary, correlation_id: String = "") -> void:
	var command_type := str(command.get("type", ""))
	var result := {"status": "accepted", "errorCode": ""}
	match command_type:
		"settings.update":
			_apply_appearance(command)
		"control.settings.update":
			result = _apply_control_settings(command)
		"control.ai.update":
			result = _apply_ai_settings(command)
		"control.ai.test":
			result = _start_ai_test(command, correlation_id)
		"control.ai.discover":
			result = _start_ai_discovery(command, correlation_id)
		"control.voice.test":
			result = _start_voice_test(command, correlation_id)
		"control.update.check":
			result = _start_update_check(command, correlation_id)
		"control.update.apply":
			result = _start_update_apply(command)
		"control.update.install-on-restart":
			result = _set_update_install_on_restart(command)
		"character.activate":
			_activate_character(command)
		"character.uninstall":
			_record_command_result(correlation_id, command_type, {"status": "accepted", "errorCode": ""})
			_uninstall_character(command, correlation_id)
		"character.effects.update":
			result = _apply_progression_effect_settings(command)
		"character.effects.preview-level-up":
			result = _preview_progression_level_up(command)
		"effect-pack.equip":
			result = _equip_effect_pack(command)
		"effect-pack.unequip":
			result = _unequip_effect_pack(command)
		"effect-pack.slot-enabled":
			result = _set_effect_pack_slot_enabled(command)
		"effect-pack.preview":
			result = _preview_effect_pack(command)
		"effect-pack.preview-tune":
			result = _preview_effect_pack_tune(command)
		"effect-pack.character-profile.save":
			result = _save_effect_character_profile(command)
		"effect-pack.character-profile.reset":
			result = _reset_effect_character_profile(command)
		"effect-pack.preview-rank":
			result = _preview_effect_pack_rank(command)
		"character.preview.open":
			_open_preview(command)
		"character.preview.select":
			_select_preview_animation(command)
		"character.preview.thumbnail-page":
			_set_preview_thumbnail_page(command)
		"character.preview.play":
			_set_preview_playing(command, true)
		"character.preview.pause":
			_set_preview_playing(command, false)
		"character.preview.set-loop":
			_set_preview_loop(command)
		"character.preview.set-speed":
			_set_preview_speed(command)
		"character.preview.close":
			_close_preview_command(command)
		"chat.submit":
			_submit_chat(command)
		"chat.reconnect":
			result = _start_chat_reconnect(command, correlation_id)
		"chat.session.clear":
			result = _clear_chat_session(command)
		"chat.turn.cancel":
			result = _cancel_chat_turn(command)
		"chat.message.edit":
			result = _edit_chat_message(command)
		"chat.message.regenerate":
			result = _regenerate_chat_message(command)
		"chat.feedback.set":
			result = _set_chat_feedback(command)
		"chat.message.read-aloud":
			result = _read_chat_message_aloud(command)
		"chat.session.new":
			result = _new_chat_session(command)
		"account.sign-out":
			result = _sign_out_account(command)
		"cloud.library.refresh":
			result = _refresh_cloud_library(command)
		"cloud.library.install":
			result = _install_cloud_library(command, correlation_id)
		"cloud.sync.now":
			result = _sync_cloud_now(command)
		"account.auth-handoff":
			result = _redeem_account_auth_handoff(command)
		"shell.chat-focus", "shell.chat-visibility":
			_apply_chat_visibility(command)
		"shell.companion-suppression":
			_apply_companion_suppression(command)
		"local.install-package":
			_install_local_package(command)
		"local.install-effect":
			_install_local_effect(command)
		"store.install-handoff":
			_redeem_store_install_handoff(command)
		_:
			push_warning("DesktopShellFunctionalAdapter rejected unknown command")
			result = {"status": "failed", "errorCode": "unsupported-command"}
	# Control Center commands use correlated results. Existing character/chat
	# commands keep their established fire-and-project behaviour.
	if command_type in ["control.settings.update", "control.ai.update", "control.ai.test", "control.ai.discover", "control.voice.test", "control.update.check", "control.update.apply", "control.update.install-on-restart", "character.effects.update", "character.effects.preview-level-up", "effect-pack.equip", "effect-pack.unequip", "effect-pack.slot-enabled", "effect-pack.preview", "effect-pack.preview-tune", "effect-pack.character-profile.save", "effect-pack.character-profile.reset", "effect-pack.preview-rank", "chat.reconnect", "chat.session.clear", "chat.turn.cancel", "chat.message.edit", "chat.message.regenerate", "chat.feedback.set", "chat.message.read-aloud", "chat.session.new", "account.sign-out", "cloud.library.refresh", "cloud.library.install", "cloud.sync.now"]:
		_record_command_result(correlation_id, command_type, result)
	_write_snapshot()


func _apply_progression_effect_settings(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "levelUpEnabled", "auraEnabled"]) or command.size() != 3:
		return {"status": "failed", "errorCode": "invalid-progression-effects"}
	var level_up_value: Variant = command.get("levelUpEnabled", true)
	var aura_value: Variant = command.get("auraEnabled", true)
	if not (level_up_value is bool) or not (aura_value is bool):
		return {"status": "failed", "errorCode": "invalid-progression-effects"}
	var settings_service := _service(&"settings_service")
	if not is_instance_valid(settings_service) or not settings_service.has_method("save_settings"):
		return {"status": "failed", "errorCode": "settings-service-unavailable"}
	if not bool(settings_service.call("save_settings", {
		"progression_level_up_enabled": bool(level_up_value),
		"progression_aura_enabled": bool(aura_value),
	})):
		return {"status": "failed", "errorCode": "settings-save-failed"}
	if is_instance_valid(event_bus):
		event_bus.publish(&"progression.effects.changed", {
			"levelUpEnabled": bool(level_up_value),
			"auraEnabled": bool(aura_value),
		})
	return {"status": "succeeded", "errorCode": ""}


func _preview_progression_level_up(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "packageId", "version"]) or command.size() != 3:
		return {"status": "failed", "errorCode": "invalid-request"}
	var package_id := str(command.get("packageId", "")).strip_edges()
	var version := str(command.get("version", "")).strip_edges()
	if package_id.is_empty() or version.is_empty():
		return {"status": "failed", "errorCode": "invalid-request"}
	var active_package_id := str(context.package.get("active_id", "")) if is_instance_valid(context) else ""
	var active_version := str(context.package.get("active_version", "")) if is_instance_valid(context) else ""
	if package_id != active_package_id or version != active_version:
		return {"status": "failed", "errorCode": "character-not-active"}
	if not bool(context.settings.get("progression_level_up_enabled", true)):
		return {"status": "failed", "errorCode": "effects-disabled"}
	var snapshot := _progression_snapshot()
	var level_cap := clampi(int(snapshot.get("levelCap", 200)), 1, 200)
	var current_level := 1
	var bond_rank := "stranger"
	var companion_id := ""
	for companion_value in snapshot.get("companions", []):
		if not companion_value is Dictionary:
			continue
		var companion: Dictionary = companion_value
		if str(companion.get("characterId", "")) != package_id:
			continue
		companion_id = str(companion.get("companionId", ""))
		var relationship_value: Variant = companion.get("relationship", {})
		if relationship_value is Dictionary:
			var relationship: Dictionary = relationship_value
			current_level = clampi(int(relationship.get("level", 1)), 1, level_cap)
			bond_rank = str(relationship.get("bondRank", "stranger"))
		break
	var preview_to := mini(level_cap, current_level + 1)
	var preview_from := maxi(1, preview_to - 1)
	if is_instance_valid(event_bus):
		event_bus.publish(&"progression.level_up", {
			"companionId": companion_id,
			"characterId": package_id,
			"fromLevel": preview_from,
			"toLevel": preview_to,
			"bondRank": bond_rank,
			"source": "desktop-shell-preview",
			"preview": true,
		})
	return {"status": "succeeded", "errorCode": ""}


func _refresh_cloud_library(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-request"}
	var library_service := _service(&"cloud_library_service")
	if not is_instance_valid(library_service) or not library_service.has_method("refresh_library"):
		return {"status": "failed", "errorCode": "cloud-library-unavailable"}
	var result: Variant = library_service.call("refresh_library")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		return {"status": "failed", "errorCode": str((result as Dictionary).get("status", "cloud-library-failed")) if result is Dictionary else "cloud-library-failed"}
	return {"status": "accepted", "errorCode": ""}


func _install_cloud_library(command: Dictionary, correlation_id: String) -> Dictionary:
	if not _has_only_keys(command, ["type", "packageId", "version"]) or command.size() != 3:
		return {"status": "failed", "errorCode": "invalid-request"}
	var package_id := str(command.get("packageId", "")).strip_edges()
	var version := str(command.get("version", "")).strip_edges()
	var download_service := _service(&"cloud_download_service")
	if not is_instance_valid(download_service) or not download_service.has_method("download_and_install"):
		return {"status": "failed", "errorCode": "cloud-download-unavailable"}
	var result: Variant = download_service.call("download_and_install", package_id, version)
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		return {"status": "failed", "errorCode": str((result as Dictionary).get("status", "cloud-install-failed")) if result is Dictionary else "cloud-install-failed"}
	pending_cloud_install = {
		"id": correlation_id,
		"packageId": package_id,
		"version": version,
	}
	return {"status": "accepted", "errorCode": ""}


func _sync_cloud_now(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-request"}
	var progression_service := _service(&"cloud_progression_service")
	if not is_instance_valid(progression_service) or not progression_service.has_method("sync_pending") or not progression_service.has_method("refresh_projection"):
		return {"status": "failed", "errorCode": "cloud-sync-unavailable"}
	var sync_result: Variant = progression_service.call("sync_pending")
	if sync_result is Dictionary and not bool((sync_result as Dictionary).get("ok", false)) and str((sync_result as Dictionary).get("status", "")) != "busy":
		return {"status": "failed", "errorCode": str((sync_result as Dictionary).get("status", "cloud-sync-failed"))}
	var projection_result: Variant = progression_service.call("refresh_projection")
	if projection_result is Dictionary and not bool((projection_result as Dictionary).get("ok", false)) and str((projection_result as Dictionary).get("status", "")) != "busy":
		return {"status": "failed", "errorCode": str((projection_result as Dictionary).get("status", "cloud-sync-failed"))}
	return {"status": "accepted", "errorCode": ""}


func _redeem_account_auth_handoff(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "grant"]) or command.size() != 2 or typeof(command.get("grant")) != TYPE_STRING:
		return {"status": "failed", "errorCode": "invalid-request"}
	var grant := str(command.get("grant", "")).strip_edges()
	var pattern := RegEx.new()
	if pattern.compile(AUTH_HANDOFF_PATTERN) != OK or pattern.search(grant) == null:
		return {"status": "failed", "errorCode": "invalid-handoff"}
	var auth_service := _service(&"cloud_auth_service")
	if not is_instance_valid(auth_service) or not auth_service.has_method("redeem_handoff"):
		return {"status": "failed", "errorCode": "auth-unavailable"}
	var result: Variant = auth_service.call("redeem_handoff", grant)
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		return {"status": "failed", "errorCode": "auth-handoff-rejected"}
	return {"status": "accepted", "errorCode": ""}


func _sign_out_account(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-request"}
	var auth_service := _service(&"cloud_auth_service")
	if not is_instance_valid(auth_service) or not auth_service.has_method("sign_out"):
		return {"status": "failed", "errorCode": "auth-unavailable"}
	auth_service.call("sign_out")
	return {"status": "succeeded", "errorCode": ""}


func _apply_chat_visibility(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "active"]) or command.size() != 2 or typeof(command.get("active")) != TYPE_BOOL:
		return
	chat_presentation_active = bool(command["active"])
	# chat_focus_active remains an internal compatibility key for existing native
	# lifecycle consumers. Its value now means Chat presentation visibility, not
	# transient OS keyboard focus (ADR-0053).
	if is_instance_valid(context):
		if context.has_method("update_runtime_config"):
			context.call("update_runtime_config", {
				"chat_presentation_active": chat_presentation_active,
				"chat_focus_active": chat_presentation_active,
			})
		elif context.get("runtime_config") is Dictionary:
			context.runtime_config["chat_presentation_active"] = chat_presentation_active
			context.runtime_config["chat_focus_active"] = chat_presentation_active
	var lifecycle := _service(&"native_host_lifecycle")
	if is_instance_valid(lifecycle) and lifecycle.has_method("set_chat_focus_active"):
		lifecycle.call("set_chat_focus_active", chat_presentation_active)
	_refresh_chat_presentation()


func _apply_chat_focus(command: Dictionary) -> void:
	# Backward-compatible test and command entry point for schema <= 9 shells.
	_apply_chat_visibility(command)


func _apply_companion_suppression(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "active"]) or command.size() != 2 or typeof(command.get("active")) != TYPE_BOOL:
		return
	var active := bool(command.get("active", false))
	if is_instance_valid(context):
		if context.has_method("update_runtime_config"):
			context.call("update_runtime_config", {"shell_companion_suppressed": active})
		elif context.get("runtime_config") is Dictionary:
			context.runtime_config["shell_companion_suppressed"] = active
	var lifecycle := _service(&"native_host_lifecycle")
	if is_instance_valid(lifecycle) and lifecycle.has_method("set_shell_companion_suppressed"):
		lifecycle.call("set_shell_companion_suppressed", active)


func _safe_model_suggestions(value: Variant) -> Array[String]:
	var safe: Array[String] = []
	if not value is Array:
		return safe
	for item in value:
		var candidate := str(item).strip_edges()
		if candidate.is_empty() or candidate.length() > 160:
			continue
		var invalid := false
		for index in range(candidate.length()):
			if candidate.unicode_at(index) < 32:
				invalid = true
				break
		if invalid or safe.has(candidate):
			continue
		safe.append(candidate)
		if safe.size() >= 16:
			break
	return safe


func _record_command_result(correlation_id: String, command_type: String, result: Dictionary) -> void:
	if correlation_id.is_empty() or correlation_id.length() > 128 or command_type.is_empty() or command_type.length() > 80:
		return
	var status := str(result.get("status", "failed"))
	if status not in ["accepted", "succeeded", "failed"]:
		status = "failed"
	var error_code := str(result.get("errorCode", ""))
	if error_code.length() > 80:
		error_code = "operation-failed"
	var entry := {"id": correlation_id, "type": command_type, "status": status, "errorCode": error_code}
	if command_type == "control.ai.discover" and result.has("models"):
		entry["models"] = _safe_model_suggestions(result.get("models", []))
	for index in range(command_results.size()):
		if str(command_results[index].get("id", "")) == correlation_id and str(command_results[index].get("type", "")) == command_type:
			if status == "accepted" and str(command_results[index].get("status", "")) in ["succeeded", "failed"]:
				return
			command_results[index] = entry
			return
	command_results.append(entry)
	while command_results.size() > MAX_COMMAND_RESULTS:
		command_results.pop_front()


func _install_local_package(command: Dictionary) -> void:
	# Local package paths are selected by Electron main through a native file
	# dialog. Renderer code never supplies or receives the absolute path.
	if not _has_only_keys(command, ["type", "path"]):
		return
	var package_path := str(command.get("path", "")).strip_edges()
	if package_path.is_empty() or package_path.length() > 4096 or not package_path.to_lower().ends_with(".ocp"):
		event_bus.publish(&"package.install_failed", {"error": "Invalid local package path", "source": "desktop-shell-local"})
		return
	if not FileAccess.file_exists(package_path):
		event_bus.publish(&"package.install_failed", {"error": "Local package file was not found", "source": "desktop-shell-local"})
		return
	event_bus.publish(&"package.install_requested", {"path": package_path, "source": "desktop-shell-local"})


func _install_local_effect(command: Dictionary) -> void:
	# Electron main owns the native file picker. Renderer code never supplies
	# the absolute path, and EffectPackService performs the authoritative type
	# and package validation before installing into the effect repository.
	if not _has_only_keys(command, ["type", "path"]):
		return
	var package_path := str(command.get("path", "")).strip_edges()
	if package_path.is_empty() or package_path.length() > 4096 or not package_path.to_lower().ends_with(".ocp"):
		event_bus.publish(&"effect_pack.install_result", {"ok": false, "error": "Invalid local effect package path"})
		return
	if not FileAccess.file_exists(package_path):
		event_bus.publish(&"effect_pack.install_result", {"ok": false, "error": "Local effect package file was not found"})
		return
	# Reinstalling the same package id/version replaces files at the same path.
	# Drop CPU preview sheets/tuning before the synchronous install event so the
	# next composite cannot reuse stale pixels/config from the previous package.
	effect_preview_sheet_cache.clear()
	effect_preview_tuning.clear()
	event_bus.publish(&"effect_pack.install_requested", {"path": package_path, "source": "desktop-shell-local-effect"})
	if not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
		effect_preview_elapsed = 0.0
		effect_preview_frame_elapsed = 0.0
		_refresh_preview_frame(true)
		_write_preview_media()


func _redeem_store_install_handoff(command: Dictionary) -> void:
	# ADR-0041: this command is emitted only by Electron main after strict
	# ocp://install parsing. It is intentionally absent from the renderer
	# RuntimeBridgeCommand allowlist. Do not publish or snapshot the grant.
	if not _has_only_keys(command, ["type", "packageId", "version", "grant"]):
		return
	var package_id := str(command.get("packageId", "")).strip_edges()
	var version := str(command.get("version", "")).strip_edges()
	var grant := str(command.get("grant", "")).strip_edges()
	if package_id.is_empty() or package_id.length() > 160 \
	or version.is_empty() or version.length() > 64 \
	or grant.length() < 43 or grant.length() > 128:
		return
	var download_service := _service(&"cloud_download_service")
	if not is_instance_valid(download_service) or not download_service.has_method("redeem_install_handoff"):
		return
	var result: Variant = download_service.call("redeem_install_handoff", package_id, version, grant)
	var status := str((result as Dictionary).get("status", "invalid-result")) if result is Dictionary else "invalid-result"
	# The grant is intentionally never logged or projected into the renderer.
	print("[StoreInstallHandoff] package=%s version=%s status=%s" % [package_id, version, status])


func _apply_appearance(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "appearance"]):
		return
	var value: Variant = command.get("appearance", {})
	if not value is Dictionary:
		return
	var appearance: Dictionary = value
	if not _has_only_keys(appearance, ["theme", "locale", "fontFamily", "textScale", "reduceMotion"]):
		return
	var theme := str(appearance.get("theme", ""))
	var locale := str(appearance.get("locale", ""))
	var font := str(appearance.get("fontFamily", ""))
	var text_scale := str(appearance.get("textScale", ""))
	var reduce_motion_value: Variant = appearance.get("reduceMotion", false)
	if theme not in ["solid", "glass", "liquid"] or locale not in ["en", "th"] or not FONT_FAMILIES.has(font) or not TEXT_SCALES.has(text_scale) or not (reduce_motion_value is bool):
		return
	var settings_service := _service(&"settings_service")
	if not is_instance_valid(settings_service):
		return
	settings_service.save_settings({
		"theme_preset": theme,
		"language": locale,
		"font_family": FONT_FAMILIES[font],
		"text_scale": TEXT_SCALES[text_scale],
		"reduce_motion": bool(appearance["reduceMotion"]),
	})


func _apply_control_settings(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "settings"]) or command.size() != 2:
		return {"status": "failed", "errorCode": "invalid-settings-command"}
	var value: Variant = command.get("settings", {})
	if not value is Dictionary:
		return {"status": "failed", "errorCode": "invalid-settings"}
	var settings: Dictionary = value
	var allowed_keys := [
		"themePreset", "fontFamily", "textScale", "bubbleStyle", "language", "showBubbles",
		"clickThroughEnabled", "startWithWindows", "offlinePresenceEnabled", "llmCompanionModeEnabled", "updateChannel", "automaticUpdateChecks", "reduceMotion",
	]
	if not _has_only_keys(settings, allowed_keys) or settings.size() != allowed_keys.size():
		return {"status": "failed", "errorCode": "invalid-settings"}
	for key in ["themePreset", "fontFamily", "textScale", "bubbleStyle", "language", "updateChannel"]:
		if typeof(settings.get(key)) != TYPE_STRING:
			return {"status": "failed", "errorCode": "invalid-settings"}
	for key in ["showBubbles", "clickThroughEnabled", "startWithWindows", "offlinePresenceEnabled", "llmCompanionModeEnabled", "automaticUpdateChecks", "reduceMotion"]:
		if typeof(settings.get(key)) != TYPE_BOOL:
			return {"status": "failed", "errorCode": "invalid-settings"}
	var theme := str(settings["themePreset"])
	var font_family := str(settings["fontFamily"])
	var text_scale := str(settings["textScale"])
	var bubble_style := str(settings["bubbleStyle"])
	var language := str(settings["language"])
	var update_channel := str(settings["updateChannel"])
	if theme not in ["solid", "glass", "liquid"] or font_family not in CONTROL_FONT_FAMILIES \
	or not TEXT_SCALES.has(text_scale) or bubble_style not in BUBBLE_STYLES \
	or language not in ["en", "th"] or update_channel not in UPDATE_CHANNELS:
		return {"status": "failed", "errorCode": "invalid-settings"}
	var settings_service := _service(&"settings_service")
	if not is_instance_valid(settings_service) or not settings_service.has_method("save_settings"):
		return {"status": "failed", "errorCode": "settings-service-unavailable"}
	var previous_startup := bool(context.settings.get("start_with_windows", false)) if is_instance_valid(context) else false
	var desired_startup := bool(settings["startWithWindows"])
	var startup_changed := desired_startup != previous_startup
	var startup_service := _service(&"startup_registration_service")
	if startup_changed:
		if not is_instance_valid(startup_service) or not startup_service.has_method("set_enabled") \
		or not bool(startup_service.call("set_enabled", desired_startup)):
			return {"status": "failed", "errorCode": "startup-registration-failed"}
	var persisted := {
		"theme_preset": theme,
		"font_family": font_family,
		"text_scale": TEXT_SCALES[text_scale],
		"bubble_style": bubble_style,
		"language": language,
		"show_bubbles": bool(settings["showBubbles"]),
		"click_through_enabled": bool(settings["clickThroughEnabled"]),
		"start_with_windows": desired_startup,
		"offline_presence_enabled": bool(settings["offlinePresenceEnabled"]),
		"llm_companion_mode_enabled": bool(settings["llmCompanionModeEnabled"]),
		"update_channel": update_channel,
		"automatic_update_checks": bool(settings["automaticUpdateChecks"]),
		"reduce_motion": bool(settings["reduceMotion"]),
	}
	if not bool(settings_service.call("save_settings", persisted)):
		if startup_changed and is_instance_valid(startup_service):
			startup_service.call("set_enabled", previous_startup)
		return {"status": "failed", "errorCode": "settings-save-failed"}
	var update_service := _service(&"update_service")
	if is_instance_valid(update_service) and update_service.has_method("refresh_policy"):
		update_service.call("refresh_policy")
	if is_instance_valid(context) and context.has_method("update_runtime_config"):
		context.update_runtime_config({"click_through_enabled": bool(settings["clickThroughEnabled"])})
	if is_instance_valid(event_bus):
		event_bus.publish(&"click_through.refresh_requested", {})
	var theme_service := _service(&"theme_service")
	if is_instance_valid(theme_service) and theme_service.has_method("select_theme"):
		theme_service.call("select_theme", theme)
	var localization_service := _service(&"localization_service")
	if is_instance_valid(localization_service) and localization_service.has_method("select_locale"):
		localization_service.call("select_locale", language)
	return {"status": "succeeded", "errorCode": ""}


func _apply_ai_settings(command: Dictionary) -> Dictionary:
	var settings := _validated_ai_settings_command(command)
	if settings.is_empty():
		return {"status": "failed", "errorCode": "invalid-ai-settings"}
	if settings["providerId"] == "openai-compatible" and not _credential_present("openai-compatible"):
		return {"status": "failed", "errorCode": "credential-required"}
	var settings_service := _service(&"settings_service")
	if not is_instance_valid(settings_service) or not settings_service.has_method("save_settings"):
		return {"status": "failed", "errorCode": "settings-service-unavailable"}
	if not bool(settings_service.call("save_settings", _ai_settings_for_runtime(settings))):
		return {"status": "failed", "errorCode": "ai-settings-save-failed"}
	var ai_service := _service(&"ai_service")
	if is_instance_valid(ai_service) and ai_service.has_method("reload_provider"):
		ai_service.call("reload_provider")
	return {"status": "succeeded", "errorCode": ""}


func _start_ai_test(command: Dictionary, correlation_id: String) -> Dictionary:
	var settings := _validated_ai_settings_command(command)
	if settings.is_empty():
		return {"status": "failed", "errorCode": "invalid-ai-settings"}
	if not pending_ai_test.is_empty():
		return {"status": "failed", "errorCode": "ai-test-busy"}
	if settings["providerId"] == "offline":
		return {"status": "failed", "errorCode": "provider-test-not-required"}
	if settings["providerId"] == "openai-compatible" and not _credential_present("openai-compatible"):
		return {"status": "failed", "errorCode": "credential-required"}
	var ai_service := _service(&"ai_service")
	if not is_instance_valid(ai_service) or not ai_service.has_method("test_connection"):
		return {"status": "failed", "errorCode": "ai-service-unavailable"}
	pending_ai_test = {
		"id": correlation_id,
		"commandType": "control.ai.test",
		"providerId": settings["providerId"],
		"deadlineMs": Time.get_ticks_msec() + int(settings["timeoutSeconds"]) * 1000 + CONTROL_TEST_TIMEOUT_MARGIN_MS,
	}
	ai_test_state = {"status": "testing", "errorCode": ""}
	ai_service.call("test_connection", _ai_settings_for_runtime(settings))
	return {"status": "accepted", "errorCode": ""}


func _start_ai_discovery(command: Dictionary, correlation_id: String) -> Dictionary:
	var settings := _validated_ai_settings_command(command)
	if settings.is_empty():
		return {"status": "failed", "errorCode": "invalid-ai-settings"}
	if settings["providerId"] != "ollama":
		return {"status": "failed", "errorCode": "model-discovery-not-supported"}
	if not pending_ai_discovery.is_empty():
		return {"status": "failed", "errorCode": "model-discovery-busy"}
	var ai_service := _service(&"ai_service")
	if not is_instance_valid(ai_service) or not ai_service.has_method("discover_models"):
		return {"status": "failed", "errorCode": "ai-service-unavailable"}
	pending_ai_discovery = {
		"id": correlation_id,
		"providerId": "ollama",
		"deadlineMs": Time.get_ticks_msec() + mini(int(settings["timeoutSeconds"]) * 1000 + CONTROL_TEST_TIMEOUT_MARGIN_MS, 35_000),
	}
	ai_service.call("discover_models", _ai_settings_for_runtime(settings))
	return {"status": "accepted", "errorCode": ""}


func _start_voice_test(command: Dictionary, correlation_id: String) -> Dictionary:
	var settings := _validated_ai_settings_command(command)
	if settings.is_empty():
		return {"status": "failed", "errorCode": "invalid-ai-settings"}
	if not pending_voice_test.is_empty():
		return {"status": "failed", "errorCode": "voice-test-busy"}
	if not bool(settings["ttsEnabled"]):
		return {"status": "failed", "errorCode": "tts-disabled"}
	# `auto` is cloud-only: Gemini 3.1 -> Gemini 2.5. Never let a voice test
	# silently fall through to Windows just because this happens to run on Windows.
	if settings["ttsProviderId"] == "auto" and not _credential_present("gemini-cloud"):
		return {"status": "failed", "errorCode": "credential-required"}
	if not is_instance_valid(event_bus):
		return {"status": "failed", "errorCode": "tts-service-unavailable"}
	var message_id := "shell_voice_test_%d" % Time.get_ticks_msec()
	var runtime_language := str(context.settings.get("language", "en")).strip_edges().to_lower() if is_instance_valid(context) else "en"
	var test_phrase := RUNTIME_VOICE_TEST_PHRASE_TH if runtime_language.begins_with("th") else RUNTIME_VOICE_TEST_PHRASE
	pending_voice_test = {"id": correlation_id, "messageId": message_id, "deadlineMs": Time.get_ticks_msec() + 35_000}
	voice_test_state = {"status": "testing", "errorCode": ""}
	event_bus.publish(&"tts.requested", {
		"message_id": message_id,
		"chunk_index": 0,
		"text": test_phrase,
		"voice": _resolved_voice_setting(settings),
		"provider_id": settings["ttsProviderId"],
		"model_id": settings["ttsModel"],
		"final": true,
		"source": "electron-control-center-test",
	})
	return {"status": "accepted", "errorCode": ""}


func _start_update_check(command: Dictionary, correlation_id: String) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-update-command"}
	if not pending_update_check.is_empty():
		return {"status": "failed", "errorCode": "update-check-busy"}
	var update_service := _service(&"update_service")
	if not is_instance_valid(update_service) or not update_service.has_method("request_check"):
		_set_update_state("unavailable", "")
		return {"status": "failed", "errorCode": "update-unavailable"}
	var result_value: Variant = update_service.call("request_check")
	if not result_value is Dictionary:
		return {"status": "failed", "errorCode": "update-check-start-failed"}
	var result: Dictionary = result_value
	if not bool(result.get("ok", false)):
		var error_code := _safe_update_request_error(str(result.get("message", "")), false)
		_set_update_error(error_code)
		return {"status": "failed", "errorCode": error_code}
	pending_update_check = {"id": correlation_id, "deadlineMs": Time.get_ticks_msec() + UPDATE_CHECK_TIMEOUT_MS}
	_set_update_state("checking", "")
	return {"status": "accepted", "errorCode": ""}


func _start_update_apply(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-update-command"}
	var update_service := _service(&"update_service")
	if not is_instance_valid(update_service) or not update_service.has_method("request_apply") \
	or not update_service.has_method("can_apply") or not update_service.has_method("safe_status"):
		return {"status": "failed", "errorCode": "update-unavailable"}
	if not bool(update_service.call("can_apply")):
		return {"status": "failed", "errorCode": "update-not-ready"}
	var result_value: Variant = update_service.call("request_apply")
	if not result_value is Dictionary:
		return {"status": "failed", "errorCode": "update-apply-start-failed"}
	var result: Dictionary = result_value
	if not bool(result.get("ok", false)):
		var error_code := _safe_update_request_error(str(result.get("message", "")), true)
		_set_update_error(error_code)
		return {"status": "failed", "errorCode": error_code}
	_refresh_update_state_from_service()
	if str(update_state.get("state", "")) != "apply-requested":
		_set_update_state("apply_requested", str(update_state.get("targetVersion", "")))
	call_deferred("_request_update_shutdown")
	# Starting the external helper is not reported as a successful installation.
	# The helper owns restart/health/rollback and projects its state after launch.
	return {"status": "accepted", "errorCode": ""}


func _set_update_install_on_restart(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "enabled"]) or command.size() != 2 or typeof(command.get("enabled")) != TYPE_BOOL:
		return {"status": "failed", "errorCode": "invalid-update-command"}
	var update_service := _service(&"update_service")
	if not is_instance_valid(update_service) or not update_service.has_method("request_install_on_restart"):
		return {"status": "failed", "errorCode": "update-unavailable"}
	var result_value: Variant = update_service.call("request_install_on_restart", bool(command.get("enabled", false)))
	if not result_value is Dictionary:
		return {"status": "failed", "errorCode": "update-policy-persist-failed"}
	var result: Dictionary = result_value
	if not bool(result.get("ok", false)):
		var message := str(result.get("message", "")).to_lower()
		return {"status": "failed", "errorCode": "update-not-ready" if message.contains("no verified staged") else "update-policy-persist-failed"}
	_refresh_update_state_from_service()
	return {"status": "succeeded", "errorCode": ""}


func _request_update_shutdown() -> void:
	if is_instance_valid(event_bus):
		event_bus.publish(&"window.exit_requested", {"source": "electron-update-apply"})


func _safe_update_request_error(message: String, applying: bool) -> String:
	var normalized := message.strip_edges().to_lower()
	if applying:
		if normalized.contains("no verified staged"):
			return "update-not-ready"
		if normalized.contains("not configured"):
			return "update-apply-not-configured"
		if normalized.contains("helper") and normalized.contains("not installed"):
			return "update-helper-missing"
		return "update-apply-start-failed"
	if normalized.contains("stable update trust"):
		return "update-stable-trust-pending"
	if normalized.contains("preview update configuration"):
		return "update-preview-config-incomplete"
	if normalized.contains("configuration is incomplete") or normalized.contains("https"):
		return "update-config-incomplete"
	if normalized.contains("updater") and normalized.contains("not installed"):
		return "update-updater-missing"
	return "update-check-start-failed"


func _validated_ai_settings_command(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "settings"]) or command.size() != 2:
		return {}
	var value: Variant = command.get("settings", {})
	if not value is Dictionary:
		return {}
	var settings: Dictionary = value
	var base_keys := ["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "ttsProviderId", "ttsModel", "ttsVoice"]
	var profile_keys := ["ttsVoiceMode", "ttsVoiceGender", "ttsVoiceAge", "thaiSpeechStyle"]
	var chat_voice_keys := ["chatVoiceMode"]
	var keys := base_keys + profile_keys + chat_voice_keys
	var accepted_sizes := [base_keys.size(), base_keys.size() + chat_voice_keys.size(), base_keys.size() + profile_keys.size(), keys.size()]
	if not _has_only_keys(settings, keys) or settings.size() not in accepted_sizes:
		return {}
	for key in ["providerId", "baseUrl", "model", "ttsProviderId", "ttsModel", "ttsVoice"]:
		if typeof(settings.get(key)) != TYPE_STRING:
			return {}
	for key in profile_keys:
		if settings.has(key) and typeof(settings.get(key)) != TYPE_STRING:
			return {}
	if settings.has("chatVoiceMode") and typeof(settings.get("chatVoiceMode")) != TYPE_STRING:
		return {}
	# JSON.parse_string represents every JSON number as TYPE_FLOAT. Electron
	# commands therefore arrive with e.g. `45.0`, although direct in-engine
	# callers use TYPE_INT. Accept only an exactly integral number, then retain
	# the existing fixed timeout allow-list below.
	var timeout_value: Variant = settings.get("timeoutSeconds")
	if (typeof(timeout_value) != TYPE_INT and typeof(timeout_value) != TYPE_FLOAT) \
	or typeof(settings.get("ttsEnabled")) != TYPE_BOOL:
		return {}
	var provider_id := str(settings["providerId"]).strip_edges().to_lower()
	var base_url := str(settings["baseUrl"]).strip_edges()
	var model := str(settings["model"]).strip_edges()
	var timeout_seconds := int(timeout_value)
	if float(timeout_seconds) != float(timeout_value):
		return {}
	var chat_voice_mode := str(settings.get("chatVoiceMode", "on-demand")).strip_edges().to_lower()
	var tts_provider_id := str(settings["ttsProviderId"]).strip_edges().to_lower()
	var tts_model := str(settings["ttsModel"]).strip_edges()
	var tts_voice := str(settings["ttsVoice"]).strip_edges()
	var tts_voice_mode := str(settings.get("ttsVoiceMode", "character")).strip_edges().to_lower()
	var tts_voice_gender := str(settings.get("ttsVoiceGender", "neutral")).strip_edges().to_lower()
	var tts_voice_age := str(settings.get("ttsVoiceAge", "adult")).strip_edges().to_lower()
	var thai_speech_style := str(settings.get("thaiSpeechStyle", "neutral")).strip_edges().to_lower()
	if provider_id not in AI_PROVIDER_IDS or timeout_seconds not in AI_TIMEOUT_SECONDS \
	or chat_voice_mode not in CHAT_VOICE_MODES \
	or tts_provider_id not in TTS_PROVIDER_IDS or tts_model not in TTS_MODEL_IDS or tts_voice not in TTS_VOICE_IDS \
	or tts_voice_mode not in TTS_VOICE_MODES or tts_voice_gender not in TTS_VOICE_GENDERS \
	or tts_voice_age not in TTS_VOICE_AGES or thai_speech_style not in THAI_SPEECH_STYLES:
		return {}
	if not _bounded_control_text(base_url, 2048) or not _bounded_control_text(model, 160):
		return {}
	if provider_id in ["ollama", "openai-compatible"] and (base_url.is_empty() or model.is_empty()):
		return {}
	if provider_id == "ollama" and not (base_url.to_lower().begins_with("http://") or base_url.to_lower().begins_with("https://")):
		return {}
	if provider_id == "openai-compatible" and not base_url.to_lower().begins_with("https://"):
		return {}
	return {
		"providerId": provider_id, "baseUrl": base_url, "model": model, "timeoutSeconds": timeout_seconds,
		"ttsEnabled": bool(settings["ttsEnabled"]), "chatVoiceMode": chat_voice_mode, "ttsProviderId": tts_provider_id, "ttsModel": tts_model, "ttsVoice": tts_voice,
		"ttsVoiceMode": tts_voice_mode, "ttsVoiceGender": tts_voice_gender, "ttsVoiceAge": tts_voice_age, "thaiSpeechStyle": thai_speech_style,
	}


func _ai_settings_for_runtime(settings: Dictionary) -> Dictionary:
	return {
		"ai_provider_id": settings["providerId"], "ai_base_url": settings["baseUrl"],
		"ai_model": settings["model"], "ai_timeout_seconds": settings["timeoutSeconds"],
		"tts_enabled": settings["ttsEnabled"], "chat_voice_mode": settings.get("chatVoiceMode", "on-demand"),
		"tts_provider_id": settings["ttsProviderId"], "tts_model": settings["ttsModel"], "tts_voice": settings["ttsVoice"],
		"tts_voice_mode": settings["ttsVoiceMode"], "tts_voice_gender": settings["ttsVoiceGender"],
		"tts_voice_age": settings["ttsVoiceAge"], "thai_speech_style": settings["thaiSpeechStyle"],
	}


func _resolved_voice_setting(settings: Dictionary) -> String:
	var voice_mode := str(settings.get("ttsVoiceMode", "character")).strip_edges().to_lower()
	# Character mode is authoritative. Legacy builds persisted a concrete Gemini
	# persona in `tts_voice`; allowing that stale value to win makes a female
	# character unexpectedly speak with an unrelated voice after upgrading.
	if voice_mode == "character":
		var profile: Dictionary = context.character.get("voice_profile", {}) if is_instance_valid(context) else {}
		return "profile:%s:%s" % [profile.get("gender", "neutral"), profile.get("age", "adult")]
	var concrete := str(settings.get("ttsVoice", "auto")).strip_edges()
	if not concrete.is_empty() and concrete.to_lower() != "auto":
		return concrete
	return "profile:%s:%s" % [settings.get("ttsVoiceGender", "neutral"), settings.get("ttsVoiceAge", "adult")]


func _bounded_control_text(value: String, maximum: int) -> bool:
	if value.length() > maximum:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code < 32 or code == 127:
			return false
	return true


func _activate_character(command: Dictionary) -> void:
	var identity := _character_identity(command)
	if identity.is_empty() or not is_instance_valid(_service(&"package_service")):
		return
	event_bus.publish(&"character.activate_requested", identity)


func _uninstall_character(command: Dictionary, correlation_id: String = "") -> void:
	var identity := _character_identity(command)
	if identity.is_empty() or not is_instance_valid(_service(&"package_service")):
		_record_command_result(correlation_id, "character.uninstall", {"status": "failed", "errorCode": "package-service-unavailable"})
		return
	# Release preview-owned images/cache and join any in-flight decoder before
	# PackageService attempts the destructive delete. Windows can keep package
	# files locked while the preview worker still owns an image/file handle.
	if str(preview_state.get("packageId", "")) == str(identity.get("package_id", "")) \
	and str(preview_state.get("version", "")) == str(identity.get("version", "")):
		_close_preview()
		_join_preview_load_thread()
	identity["request_id"] = correlation_id
	print("[CharacterUninstall] requested package=%s version=%s request_id=%s" % [str(identity.get("package_id", "")), str(identity.get("version", "")), correlation_id])
	# Destructive package removal is still owned by PackageService/Repository;
	# Desktop Shell only requests the already-supported Runtime workflow after
	# the user confirms in the UI.
	event_bus.publish(&"character.uninstall_requested", identity)


func _open_preview(command: Dictionary) -> void:
	var identity := _character_identity(command)
	if identity.is_empty():
		return
	var package_info := _find_installed_character(identity)
	if package_info.is_empty():
		_set_preview_failed(identity, "package-not-installed")
		return
	_close_preview()
	preview_state = _idle_preview_state()
	preview_state["status"] = "loading"
	preview_state["packageId"] = identity["package_id"]
	preview_state["version"] = identity["version"]
	var character_service := _service(&"character_service")
	if not is_instance_valid(character_service) or not character_service.has_method("load_preview_metadata"):
		_set_preview_failed(identity, "preview-unavailable")
		return
	var result: Dictionary = character_service.call("load_preview_metadata", package_info)
	if not bool(result.get("ok", false)):
		_set_preview_failed(identity, "preview-unavailable")
		return
	var clips: Array = []
	var animation_values: Variant = result.get("animations", [])
	var animations: Array = animation_values if animation_values is Array else []
	for clip_value in animations:
		var clip := str(clip_value)
		if not clip.is_empty() and clip.length() <= 80:
			clips.append(clip)
	clips.sort()
	if clips.is_empty():
		_set_preview_failed(identity, "no-preview-clips")
		return
	preview_package_info = package_info.duplicate(true)
	var prepared_value: Variant = result.get("prepared_entry", {})
	preview_prepared_entry = prepared_value.duplicate(true) if prepared_value is Dictionary else {}
	var loops_value: Variant = result.get("loops", {})
	preview_animation_loops = loops_value.duplicate(true) if loops_value is Dictionary else {}
	preview_state["clips"] = clips
	var default_animation := str(result.get("default_animation", ""))
	preview_state["selectedAnimation"] = default_animation if clips.has(default_animation) else str(clips[0])
	preview_state["loop"] = bool(preview_animation_loops.get(preview_state["selectedAnimation"], false))
	preview_thumbnail_offset = 0
	preview_state["status"] = "ready"
	preview_elapsed = 0.0
	preview_frame_elapsed = 0.0
	preview_last_frame_index = -1
	_write_preview_media()


func _select_preview_animation(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "packageId", "version", "animation"]):
		return
	if not _preview_identity_matches(command):
		return
	var animation := str(command.get("animation", ""))
	if animation.is_empty() or animation.length() > 80 or not preview_state.get("clips", []).has(animation):
		return
	var keep_playing := bool(preview_state.get("isPlaying", false)) or preview_requested_playing
	if not _request_preview_animation(animation, keep_playing):
		_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "preview-unavailable")


func _set_preview_thumbnail_page(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "packageId", "version", "offset"]) or not _preview_identity_matches(command):
		return
	var offset_value: Variant = command.get("offset", null)
	if not (offset_value is int or offset_value is float):
		return
	var offset := int(offset_value)
	var clips_value: Variant = preview_state.get("clips", [])
	var clips: Array = clips_value if clips_value is Array else []
	if offset < 0 or offset >= maxi(1, clips.size()) or offset % PREVIEW_SHORTCUT_PAGE_SIZE != 0:
		return
	preview_thumbnail_offset = offset
	_refresh_preview_shortcut_thumbnails()
	_queue_preview_page_prefetch(offset)
	_write_preview_media()


func _queue_preview_page_prefetch(offset: int) -> void:
	var clips_value: Variant = preview_state.get("clips", [])
	var clips: Array = clips_value if clips_value is Array else []
	if clips.is_empty():
		return
	var page_end := mini(clips.size(), offset + PREVIEW_SHORTCUT_PAGE_SIZE)
	# Insert in reverse at the front so the visible left-to-right page order is
	# preserved ahead of speculative Chat/background work. Explicit selections
	# still win through preview_requested_animation in _start_preview_load_if_idle.
	for index in range(page_end - 1, offset - 1, -1):
		var candidate := str(clips[index])
		if candidate.is_empty() \
		or preview_animation_cache.has(candidate) \
		or candidate == preview_load_animation \
		or candidate == preview_requested_animation \
		or preview_prefetch_queue.has(candidate):
			continue
		preview_prefetch_queue.push_front(candidate)
	_start_preview_load_if_idle()


func _set_preview_playing(command: Dictionary, playing: bool) -> void:
	if not _has_only_keys(command, ["type", "packageId", "version"]) or not _preview_identity_matches(command):
		return
	# A Character Manager tile click intentionally sends select -> play. During
	# an uncached atomic swap selectedAnimation still names the old visible clip
	# until the worker finishes. Play must therefore target the pending selection,
	# otherwise it immediately re-requests the old clip and wins the race.
	var active_selected := str(preview_state.get("selectedAnimation", ""))
	var pending_selected := preview_requested_animation if playing else ""
	var selected := pending_selected if not pending_selected.is_empty() else active_selected
	if playing and not _request_preview_animation(selected, true):
		_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "preview-unavailable")
		return
	# With atomic swap the old clip remains visible/Ready while the requested clip
	# is built off-thread. Do not mark the old clip as playing or clear the pending
	# autoplay request; the worker completion must activate the requested clip and
	# start that clip instead.
	if playing and not pending_selected.is_empty() and pending_selected != active_selected:
		return
	if playing and str(preview_state.get("status", "")) == "loading":
		return
	preview_requested_playing = false
	preview_state["isPlaying"] = playing
	preview_state["status"] = "playing" if playing else "paused"
	preview_frame_elapsed = 0.0
	_refresh_preview_frame(true)
	_write_preview_media()


func _set_preview_loop(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "packageId", "version", "enabled"]) or not _preview_identity_matches(command):
		return
	var enabled: Variant = command.get("enabled", null)
	if not enabled is bool:
		return
	var animation := StringName(str(preview_state.get("selectedAnimation", "")))
	if animation.is_empty():
		return
	preview_animation_loops[str(animation)] = enabled
	preview_state["loop"] = enabled


func _set_preview_speed(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "packageId", "version", "speed"]) or not _preview_identity_matches(command):
		return
	var speed: Variant = command.get("speed", null)
	if not (speed is float or speed is int) or float(speed) not in PREVIEW_SPEEDS:
		return
	preview_state["speed"] = float(speed)


func _close_preview_command(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "packageId", "version"]) or not _preview_identity_matches(command):
		return
	_close_preview()


func _find_installed_character(identity: Dictionary) -> Dictionary:
	var package_id := str(identity.get("package_id", ""))
	var version := str(identity.get("version", ""))
	var character_service := _service(&"character_service")
	if is_instance_valid(character_service) and character_service.has_method("get_active_verified_package_info"):
		var verified_active: Variant = character_service.call("get_active_verified_package_info", package_id, version)
		if verified_active is Dictionary and not (verified_active as Dictionary).is_empty():
			return (verified_active as Dictionary).duplicate(true)
	var package_service := _service(&"package_service")
	if not is_instance_valid(package_service):
		return {}
	for candidate_value in package_service.list_installed():
		if candidate_value is Dictionary:
			var candidate: Dictionary = candidate_value
			if str(candidate.get("packageId", "")) == str(identity.get("package_id", "")) and str(candidate.get("version", "")) == str(identity.get("version", "")):
				return candidate.duplicate(true)
	return {}


func _submit_chat(command: Dictionary) -> void:
	if not _has_only_keys(command, ["type", "prompt"]):
		return
	var prompt := str(command.get("prompt", "")).strip_edges()
	if prompt.is_empty() or prompt.length() > MAX_PROMPT_LENGTH or chat_status == "thinking":
		return
	print("[ChatTiming] command-consumed at_ms=%d prompt_chars=%d" % [Time.get_ticks_msec(), prompt.length()])
	_start_chat_turn(prompt)


func _start_chat_turn(prompt: String) -> void:
	var message_id := "shell_%d_%d" % [Time.get_ticks_msec(), chat_revision + 1]
	chat_revision += 1
	chat_active_message_id = message_id
	chat_status = "thinking"
	chat_messages.append({"id": message_id, "role": "user", "text": prompt, "status": "complete", "feedback": "none"})
	_trim_chat_messages()
	event_bus.publish(&"ai.prompt_requested", {"message_id": message_id, "prompt": prompt, "source": "electron-shell"})


func _start_chat_reconnect(command: Dictionary, correlation_id: String) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-chat-command"}
	if chat_status == "thinking" or not pending_ai_test.is_empty():
		return {"status": "failed", "errorCode": "chat-busy"}
	var ai_service := _service(&"ai_service")
	if not is_instance_valid(ai_service) or not ai_service.has_method("reload_provider") or not ai_service.has_method("test_connection"):
		return {"status": "failed", "errorCode": "ai-service-unavailable"}
	ai_service.call("reload_provider")
	var provider_id := _provider_id()
	var provider_status: Dictionary = ai_service.call("provider_status") if ai_service.has_method("provider_status") else {}
	if provider_id == "offline" or not bool(provider_status.get("configured", false)):
		chat_status = "offline"
		return {"status": "failed", "errorCode": "provider-not-configured"}
	pending_ai_test = {
		"id": correlation_id,
		"commandType": "chat.reconnect",
		"providerId": provider_id,
		"deadlineMs": Time.get_ticks_msec() + int(context.settings.get("ai_timeout_seconds", 45)) * 1000 + CONTROL_TEST_TIMEOUT_MARGIN_MS,
	}
	chat_status = "offline"
	ai_service.call("test_connection")
	return {"status": "accepted", "errorCode": ""}


func _clear_chat_session(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type"]) or command.size() != 1:
		return {"status": "failed", "errorCode": "invalid-chat-command"}
	if chat_status == "thinking":
		return {"status": "failed", "errorCode": "chat-busy"}
	chat_messages.clear()
	chat_revision += 1
	chat_status = _chat_status_from_provider()
	return {"status": "succeeded", "errorCode": ""}


func _validate_chat_revision(command: Dictionary, keys: Array[String]) -> Dictionary:
	if not _has_only_keys(command, keys) or command.size() != keys.size():
		return {"status": "failed", "errorCode": "invalid-command"}
	var expected: Variant = command.get("expectedRevision")
	if typeof(expected) != TYPE_INT and typeof(expected) != TYPE_FLOAT:
		return {"status": "failed", "errorCode": "invalid-command"}
	var expected_revision := int(expected)
	if expected_revision < 0 or float(expected) != float(expected_revision):
		return {"status": "failed", "errorCode": "invalid-command"}
	if expected_revision != chat_revision:
		return {"status": "failed", "errorCode": "revision-conflict"}
	return {"status": "succeeded", "errorCode": ""}


func _cancel_chat_turn(command: Dictionary) -> Dictionary:
	var validation := _validate_chat_revision(command, ["type", "expectedRevision"])
	if str(validation.get("status", "")) != "succeeded":
		return validation
	if chat_active_message_id.is_empty() or chat_status != "thinking":
		return {"status": "failed", "errorCode": "no-active-turn"}
	var cancelled_id := chat_active_message_id
	_ignore_chat_message(cancelled_id)
	var ai_service := _service(&"ai_service")
	if is_instance_valid(ai_service) and ai_service.has_method("cancel"):
		ai_service.call("cancel", cancelled_id)
	for index in range(chat_messages.size() - 1, -1, -1):
		if str(chat_messages[index].get("id", "")) == "%s:assistant" % cancelled_id:
			chat_messages[index]["status"] = "complete"
			break
	chat_active_message_id = ""
	chat_revision += 1
	chat_status = _chat_status_from_provider()
	return {"status": "succeeded", "errorCode": ""}


func _edit_chat_message(command: Dictionary) -> Dictionary:
	var validation := _validate_chat_revision(command, ["type", "messageId", "prompt", "expectedRevision"])
	if str(validation.get("status", "")) != "succeeded":
		return validation
	if chat_status == "thinking":
		return {"status": "failed", "errorCode": "turn-active"}
	var prompt := str(command.get("prompt", "")).strip_edges()
	if prompt.is_empty() or prompt.length() > MAX_PROMPT_LENGTH:
		return {"status": "failed", "errorCode": "invalid-command"}
	var index := _chat_message_index(str(command.get("messageId", "")))
	if index < 0:
		return {"status": "failed", "errorCode": "message-not-found"}
	if str(chat_messages[index].get("role", "")) != "user":
		return {"status": "failed", "errorCode": "invalid-message-role"}
	_truncate_chat_messages(index)
	_start_chat_turn(prompt)
	return {"status": "accepted", "errorCode": ""}


func _regenerate_chat_message(command: Dictionary) -> Dictionary:
	var validation := _validate_chat_revision(command, ["type", "messageId", "expectedRevision"])
	if str(validation.get("status", "")) != "succeeded":
		return validation
	if chat_status == "thinking":
		return {"status": "failed", "errorCode": "turn-active"}
	var index := _chat_message_index(str(command.get("messageId", "")))
	if index < 0:
		return {"status": "failed", "errorCode": "message-not-found"}
	while index >= 0 and str(chat_messages[index].get("role", "")) != "user":
		index -= 1
	if index < 0:
		return {"status": "failed", "errorCode": "invalid-message-role"}
	var prompt := str(chat_messages[index].get("text", "")).strip_edges()
	if prompt.is_empty():
		return {"status": "failed", "errorCode": "invalid-command"}
	_truncate_chat_messages(index)
	_start_chat_turn(prompt)
	return {"status": "accepted", "errorCode": ""}


func _set_chat_feedback(command: Dictionary) -> Dictionary:
	var validation := _validate_chat_revision(command, ["type", "messageId", "feedback", "expectedRevision"])
	if str(validation.get("status", "")) != "succeeded":
		return validation
	var feedback := str(command.get("feedback", ""))
	if feedback not in ["none", "positive", "negative"]:
		return {"status": "failed", "errorCode": "invalid-command"}
	var index := _chat_message_index(str(command.get("messageId", "")))
	if index < 0:
		return {"status": "failed", "errorCode": "message-not-found"}
	if str(chat_messages[index].get("role", "")) != "assistant":
		return {"status": "failed", "errorCode": "invalid-message-role"}
	chat_messages[index]["feedback"] = feedback
	chat_revision += 1
	return {"status": "succeeded", "errorCode": ""}


func _read_chat_message_aloud(command: Dictionary) -> Dictionary:
	var validation := _validate_chat_revision(command, ["type", "messageId", "expectedRevision"])
	if str(validation.get("status", "")) != "succeeded":
		return validation
	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	if voice_rate_limit_retry_at_ms > now_ms:
		return {
			"status": "failed",
			"errorCode": "provider-rate-limited",
			"retryAtMs": voice_rate_limit_retry_at_ms,
		}
	if voice_rate_limit_retry_at_ms > 0:
		voice_rate_limit_retry_at_ms = 0
	# Acquire the Runtime-side voice transport lock before publishing any TTS
	# chunks. This closes the short window between the user's click and the
	# tts.requested lifecycle event where a second Read aloud command could enter.
	var voice_status := str(voice_health_state.get("status", ""))
	if voice_status in ["synthesizing", "playing"] or not pending_voice_requests.is_empty():
		return {"status": "failed", "errorCode": "voice-request-in-flight"}
	var index := _chat_message_index(str(command.get("messageId", "")))
	if index < 0:
		return {"status": "failed", "errorCode": "message-not-found"}
	var message := chat_messages[index]
	if str(message.get("role", "")) != "assistant" or str(message.get("status", "")) != "complete":
		return {"status": "failed", "errorCode": "invalid-message-role"}
	var text := str(message.get("text", "")).strip_edges()
	if text.is_empty():
		return {"status": "failed", "errorCode": "invalid-command"}
	# Project synthesizing immediately, before the EventBus can hand the first
	# chunk to TTSService. Electron can disable Read aloud on the very next
	# snapshot, and the Runtime-side guard above already rejects a double click.
	active_voice_message_id = str(message.get("id", ""))
	active_speech_id = ""
	voice_health_state = {
		"status": "synthesizing",
		"reasonCode": "",
		"lastSuccessAtMs": int(voice_health_state.get("lastSuccessAtMs", 0)),
		"retryAtMs": 0,
	}
	_write_snapshot()
	# Quality-first cloud TTS now plays complete WAV clips. Split a long reply at
	# stable sentence/phrase boundaries so the first short WAV can start quickly
	# while TTSService synthesizes the next clip in parallel with playback.
	var bounded_text := text.left(600).strip_edges()
	var chunker := SentenceChunkerScript.new()
	var chunks: Array[String] = chunker.take_ready(bounded_text, true)
	if chunks.is_empty():
		chunks = [bounded_text]
	var transport_message_id := "read_aloud_%s_%d" % [str(message.get("id", "")), Time.get_ticks_msec()]
	for chunk_index in range(chunks.size()):
		var speech_text := str(chunks[chunk_index]).strip_edges()
		if speech_text.is_empty():
			continue
		event_bus.publish(&"tts.requested", {
			"message_id": transport_message_id,
			"presentation_message_id": str(message.get("id", "")),
			"chunk_index": chunk_index,
			"text": speech_text,
			"final": chunk_index == chunks.size() - 1,
			"source": "electron-read-aloud",
		})
	return {"status": "accepted", "errorCode": ""}


func _new_chat_session(command: Dictionary) -> Dictionary:
	var validation := _validate_chat_revision(command, ["type", "expectedRevision"])
	if str(validation.get("status", "")) != "succeeded":
		return validation
	if not chat_active_message_id.is_empty():
		_ignore_chat_message(chat_active_message_id)
		var ai_service := _service(&"ai_service")
		if is_instance_valid(ai_service) and ai_service.has_method("cancel"):
			ai_service.call("cancel", chat_active_message_id)
	chat_active_message_id = ""
	chat_messages.clear()
	ignored_chat_message_ids.clear()
	chat_session_id = _new_chat_session_id()
	chat_revision += 1
	chat_status = _chat_status_from_provider()
	return {"status": "succeeded", "errorCode": ""}


func _chat_message_index(message_id: String) -> int:
	for index in range(chat_messages.size()):
		if str(chat_messages[index].get("id", "")) == message_id:
			return index
	return -1


func _truncate_chat_messages(from_index: int) -> void:
	while chat_messages.size() > from_index:
		chat_messages.pop_back()


func _new_chat_session_id() -> String:
	return "session_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]


func _ignore_chat_message(message_id: String) -> void:
	if message_id.is_empty():
		return
	ignored_chat_message_ids[message_id] = true
	while ignored_chat_message_ids.size() > MAX_CHAT_MESSAGES:
		ignored_chat_message_ids.erase(ignored_chat_message_ids.keys()[0])


func _character_identity(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "packageId", "version"]):
		return {}
	var package_id := str(command.get("packageId", ""))
	var version := str(command.get("version", ""))
	if package_id.is_empty() or package_id.length() > 128 or version.is_empty() or version.length() > 64:
		return {}
	return {"package_id": package_id, "version": version}


func _queue_chat_stream_snapshot(delay_ms: int = 0) -> void:
	var now_ms := Time.get_ticks_msec()
	chat_stream_snapshot_pending = true
	var earliest_ms := now_ms + maxi(0, delay_ms)
	if chat_stream_last_snapshot_msec > 0:
		earliest_ms = maxi(earliest_ms, chat_stream_last_snapshot_msec + CHAT_STREAM_SNAPSHOT_INTERVAL_MS)
	# Once a flush is scheduled, later tokens must not keep pushing the deadline
	# forward. Preserve the first due time so a continuously streaming model still
	# publishes a bounded chunk every 100 ms.
	if chat_stream_snapshot_not_before_msec <= 0:
		chat_stream_snapshot_not_before_msec = earliest_ms


func _flush_chat_stream_snapshot_if_due(force: bool = false) -> void:
	if not chat_stream_snapshot_pending:
		return
	var now_ms := Time.get_ticks_msec()
	if not force and now_ms < chat_stream_snapshot_not_before_msec:
		return
	chat_stream_snapshot_pending = false
	chat_stream_snapshot_not_before_msec = 0
	_write_snapshot()


func _on_chat_started(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	if message_id.is_empty() or ignored_chat_message_ids.has(message_id):
		return
	if chat_active_message_id.is_empty():
		chat_active_message_id = message_id
	if message_id != chat_active_message_id:
		return
	chat_status = "thinking"
	# Do not serialize the full Desktop Shell projection inside the synchronous
	# ai.prompt_requested call stack. Starting Ollama takes priority; Electron can
	# observe the new user/THINK state on the next 10 FPS Chat snapshot tick.
	_queue_chat_stream_snapshot(CHAT_STREAM_SNAPSHOT_INTERVAL_MS)


func _on_chat_delta(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	var text := str(payload.get("text", ""))
	if message_id.is_empty() or text.is_empty() or message_id != chat_active_message_id or ignored_chat_message_ids.has(message_id):
		return
	_upsert_assistant_message(message_id, text, "streaming")
	# Coalesce raw token deltas to Electron's 10 FPS snapshot cadence. Previously
	# every token performed JSON projection + flush + atomic rename on the Godot
	# main thread, which starved HTTPClient.poll() and made a fast local model look
	# like it was typing one character at a time.
	_queue_chat_stream_snapshot()


func _on_chat_completed(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	var text := str(payload.get("text", ""))
	if message_id.is_empty() or message_id != chat_active_message_id or ignored_chat_message_ids.has(message_id):
		return
	if not message_id.is_empty() and not text.is_empty():
		_upsert_assistant_message(message_id, text, "complete")
	chat_active_message_id = ""
	chat_status = _chat_status_from_provider()
	chat_stream_snapshot_pending = false
	chat_stream_snapshot_not_before_msec = 0
	_write_snapshot()


func _on_chat_failed(payload: Dictionary) -> void:
	var message_id := str(payload.get("message_id", ""))
	var text := str(payload.get("error", "AI response failed"))
	if message_id.is_empty() or message_id != chat_active_message_id or ignored_chat_message_ids.has(message_id):
		return
	if not message_id.is_empty():
		_upsert_assistant_message(message_id, text, "failed")
	chat_active_message_id = ""
	chat_status = "failed"
	chat_stream_snapshot_pending = false
	chat_stream_snapshot_not_before_msec = 0
	_write_snapshot()


func _on_provider_status(payload: Dictionary) -> void:
	chat_status = _chat_status_from_provider(payload)
	_write_snapshot()


func _chat_status_from_provider(status_override: Dictionary = {}) -> String:
	var provider_id := _provider_id()
	if provider_id == "offline":
		return "offline"
	var status := status_override
	if status.is_empty():
		var ai_service := _service(&"ai_service")
		if is_instance_valid(ai_service) and ai_service.has_method("provider_status"):
			var value: Variant = ai_service.call("provider_status")
			if value is Dictionary:
				status = value
	return "ready" if bool(status.get("configured", false)) and bool(status.get("reachable", false)) else "offline"


func _on_ai_test_completed(payload: Dictionary) -> void:
	if pending_ai_test.is_empty():
		return
	var provider_id := str(payload.get("provider_id", "")).strip_edges().to_lower()
	if provider_id != str(pending_ai_test.get("providerId", "")):
		return
	var succeeded := bool(payload.get("ok", false))
	var error_code := "" if succeeded else _safe_ai_test_error(payload)
	ai_test_state = {"status": "succeeded" if succeeded else "failed", "errorCode": error_code}
	var command_type := str(pending_ai_test.get("commandType", "control.ai.test"))
	_record_command_result(str(pending_ai_test.get("id", "")), command_type, {
		"status": "succeeded" if succeeded else "failed", "errorCode": error_code,
	})
	if command_type == "chat.reconnect":
		chat_status = "ready" if succeeded else "failed"
	pending_ai_test.clear()
	_write_snapshot()


func _on_ai_models_discovered(payload: Dictionary) -> void:
	if pending_ai_discovery.is_empty():
		return
	var provider_id := str(payload.get("provider_id", "")).strip_edges().to_lower()
	if provider_id != str(pending_ai_discovery.get("providerId", "")):
		return
	var succeeded := bool(payload.get("ok", false))
	var models := _safe_model_suggestions(payload.get("models", []))
	var error_code := "" if succeeded else "model-discovery-failed"
	_record_command_result(str(pending_ai_discovery.get("id", "")), "control.ai.discover", {
		"status": "succeeded" if succeeded else "failed",
		"errorCode": error_code,
		"models": models,
	})
	pending_ai_discovery.clear()
	_write_snapshot()


func _on_voice_test_started(payload: Dictionary) -> void:
	voice_rate_limit_retry_at_ms = 0
	active_voice_message_id = _presentation_voice_message_id(payload)
	active_speech_id = str(payload.get("speech_id", active_speech_id))
	if not active_voice_message_id.is_empty():
		voice_playback_latched_messages[active_voice_message_id] = true
	voice_health_state = {"status": "playing", "reasonCode": "", "lastSuccessAtMs": int(voice_health_state.get("lastSuccessAtMs", 0))}
	if not pending_voice_test.is_empty() and str(payload.get("message_id", "")) == str(pending_voice_test.get("messageId", "")):
		_write_snapshot()
	elif pending_voice_test.is_empty():
		_write_snapshot()


func _on_tts_requested(payload: Dictionary) -> void:
	var request_key := _voice_request_key(payload)
	if not request_key.is_empty():
		pending_voice_requests[request_key] = true
	var transport_message_id := str(payload.get("message_id", ""))
	var presentation_message_id := str(payload.get("presentation_message_id", ""))
	if not transport_message_id.is_empty() and not presentation_message_id.is_empty():
		voice_message_correlations[transport_message_id] = presentation_message_id
	active_voice_message_id = _presentation_voice_message_id(payload)
	active_speech_id = str(payload.get("speech_id", active_speech_id))
	voice_health_state = {"status": "synthesizing", "reasonCode": "", "lastSuccessAtMs": int(voice_health_state.get("lastSuccessAtMs", 0))}
	_write_snapshot()


func _on_voice_test_finished(payload: Dictionary) -> void:
	var transport_message_id := str(payload.get("message_id", ""))
	var presentation_message_id := _presentation_voice_message_id(payload)
	_remove_pending_voice_request(payload)
	active_voice_message_id = presentation_message_id
	active_speech_id = str(payload.get("speech_id", active_speech_id))
	var same_transport_pending := _has_pending_voice_transport(transport_message_id)
	var hold_talk := same_transport_pending and bool(voice_playback_latched_messages.get(presentation_message_id, false))
	voice_health_state = {
		"status": "playing" if hold_talk else ("synthesizing" if not pending_voice_requests.is_empty() else "healthy"),
		"reasonCode": "", "lastSuccessAtMs": int(Time.get_unix_time_from_system() * 1000.0),
	}
	# Sentence chunks from one Read Aloud share a transport message id. Keep the
	# correlation and TALK latch until its final chunk finishes; erasing either
	# after chunk 0 caused TALK -> THINK -> TALK flicker and lost message identity.
	if not same_transport_pending:
		if not transport_message_id.is_empty():
			voice_message_correlations.erase(transport_message_id)
		if not presentation_message_id.is_empty():
			voice_playback_latched_messages.erase(presentation_message_id)
	if pending_voice_test.is_empty() or str(payload.get("message_id", "")) != str(pending_voice_test.get("messageId", "")):
		_write_snapshot()
		return
	voice_test_state = {"status": "succeeded", "errorCode": ""}
	_record_command_result(str(pending_voice_test.get("id", "")), "control.voice.test", {"status": "succeeded", "errorCode": ""})
	pending_voice_test.clear()
	_write_snapshot()


func _on_voice_test_failed(payload: Dictionary) -> void:
	var transport_message_id := str(payload.get("message_id", ""))
	var presentation_message_id := _presentation_voice_message_id(payload)
	_remove_pending_voice_request(payload)
	active_voice_message_id = presentation_message_id
	active_speech_id = str(payload.get("speech_id", active_speech_id))
	var playback_outcome := str(payload.get("outcome", "")).to_lower()
	var safe_reason := str(payload.get("reason_code", "")).strip_edges().to_lower()
	if safe_reason not in ["provider-credential-required", "local-voice-not-installed", "dns-unreachable", "provider-auth-failed", "provider-quota-exceeded", "provider-rate-limited", "tts-unavailable", "playback-failed", "interrupted"]:
		safe_reason = "tts-unavailable" if playback_outcome.contains("unavailable") else ("interrupted" if playback_outcome.contains("interrupt") or playback_outcome.contains("cancel") else "playback-failed")
	if safe_reason == "provider-rate-limited":
		voice_rate_limit_retry_at_ms = maxi(
			voice_rate_limit_retry_at_ms,
			int(Time.get_unix_time_from_system() * 1000.0) + VOICE_RATE_LIMIT_COOLDOWN_MS
		)
	var same_transport_pending := _has_pending_voice_transport(transport_message_id)
	var hold_talk := same_transport_pending and bool(voice_playback_latched_messages.get(presentation_message_id, false))
	voice_health_state = {
		"status": "playing" if hold_talk else ("synthesizing" if not pending_voice_requests.is_empty() else ("degraded" if safe_reason == "interrupted" else "failed")),
		"reasonCode": "" if not pending_voice_requests.is_empty() else safe_reason,
		"lastSuccessAtMs": int(voice_health_state.get("lastSuccessAtMs", 0)),
	}
	if not same_transport_pending:
		if not transport_message_id.is_empty():
			voice_message_correlations.erase(transport_message_id)
		if not presentation_message_id.is_empty():
			voice_playback_latched_messages.erase(presentation_message_id)
	if pending_voice_test.is_empty() or str(payload.get("message_id", "")) != str(pending_voice_test.get("messageId", "")):
		_write_snapshot()
		return
	var error_code := safe_reason if safe_reason in ["provider-credential-required", "local-voice-not-installed", "dns-unreachable", "provider-auth-failed", "provider-quota-exceeded", "provider-rate-limited", "tts-unavailable"] else "voice-test-failed"
	voice_test_state = {"status": "failed", "errorCode": error_code}
	_record_command_result(str(pending_voice_test.get("id", "")), "control.voice.test", {"status": "failed", "errorCode": error_code})
	pending_voice_test.clear()
	_write_snapshot()


func _voice_request_key(payload: Dictionary) -> String:
	var message_id := str(payload.get("message_id", ""))
	var speech_id := str(payload.get("speech_id", ""))
	var source := str(payload.get("source", ""))
	var chunk_index := str(payload.get("chunk_index", ""))
	if message_id.is_empty() and speech_id.is_empty():
		return ""
	return "%s|%s|%s|%s" % [message_id, speech_id, source, chunk_index]


func _presentation_voice_message_id(payload: Dictionary) -> String:
	var transport_message_id := str(payload.get("message_id", ""))
	var explicit_id := str(payload.get("presentation_message_id", ""))
	if not explicit_id.is_empty():
		return explicit_id
	return str(voice_message_correlations.get(transport_message_id, transport_message_id))


func _has_pending_voice_transport(message_id: String) -> bool:
	if message_id.is_empty():
		return false
	for candidate in pending_voice_requests.keys():
		if str(candidate).begins_with(message_id + "|"):
			return true
	return false


func _remove_pending_voice_request(payload: Dictionary) -> void:
	var exact_key := _voice_request_key(payload)
	if not exact_key.is_empty() and pending_voice_requests.erase(exact_key):
		return
	# Some TTS backends allocate speech_id after synthesis begins. Fall back to
	# the message correlation without allowing an unrelated late event to clear
	# the entire pending queue.
	var message_id := str(payload.get("message_id", ""))
	if message_id.is_empty():
		return
	for candidate in pending_voice_requests.keys():
		if str(candidate).begins_with(message_id + "|"):
			pending_voice_requests.erase(candidate)
			return


func _safe_ai_test_error(payload: Dictionary) -> String:
	var message := str(payload.get("message", "")).to_lower()
	if message.contains("required") or message.contains("configure"):
		return "provider-not-configured"
	if message.contains("unavailable") or message.contains("bridge"):
		return "ai-service-unavailable"
	if message.contains("timed out") or message.contains("timeout"):
		return "ai-test-timeout"
	if message.contains("failed to load clip") or message.contains("llama-server process has terminated") or message.contains("failed to load model"):
		return "ollama-model-load-failed"
	return "connection-test-failed"


func _expire_control_tests() -> void:
	var now := Time.get_ticks_msec()
	if not pending_ai_test.is_empty() and now >= int(pending_ai_test.get("deadlineMs", now + 1)):
		ai_test_state = {"status": "failed", "errorCode": "ai-test-timeout"}
		var command_type := str(pending_ai_test.get("commandType", "control.ai.test"))
		_record_command_result(str(pending_ai_test.get("id", "")), command_type, {"status": "failed", "errorCode": "ai-test-timeout"})
		if command_type == "chat.reconnect":
			chat_status = "failed"
		pending_ai_test.clear()
		_write_snapshot()
	if not pending_ai_discovery.is_empty() and now >= int(pending_ai_discovery.get("deadlineMs", now + 1)):
		_record_command_result(str(pending_ai_discovery.get("id", "")), "control.ai.discover", {"status": "failed", "errorCode": "model-discovery-timeout", "models": []})
		pending_ai_discovery.clear()
		_write_snapshot()
	if not pending_voice_test.is_empty() and now >= int(pending_voice_test.get("deadlineMs", now + 1)):
		voice_test_state = {"status": "failed", "errorCode": "voice-test-timeout"}
		_record_command_result(str(pending_voice_test.get("id", "")), "control.voice.test", {"status": "failed", "errorCode": "voice-test-timeout"})
		pending_voice_test.clear()
		_write_snapshot()


func _expire_update_check() -> void:
	if pending_update_check.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now < int(pending_update_check.get("deadlineMs", now + 1)):
		return
	_set_update_error("update-check-timeout")
	_record_command_result(str(pending_update_check.get("id", "")), "control.update.check", {"status": "failed", "errorCode": "update-check-timeout"})
	pending_update_check.clear()
	_write_snapshot()


func _on_update_status_changed(payload: Dictionary) -> void:
	_set_update_state(str(payload.get("state", "")), str(payload.get("version", "")))
	_write_snapshot()


func _on_update_check_finished(payload: Dictionary) -> void:
	var raw_state := str(payload.get("state", ""))
	_set_update_state(raw_state, str(payload.get("version", "")))
	if not pending_update_check.is_empty():
		var succeeded := raw_state in ["staged", "no_update"]
		var error_code := "" if succeeded else "update-check-failed"
		_record_command_result(str(pending_update_check.get("id", "")), "control.update.check", {
			"status": "succeeded" if succeeded else "failed",
			"errorCode": error_code,
		})
		pending_update_check.clear()
	_write_snapshot()


func _refresh_update_state_from_service() -> void:
	var update_service := _service(&"update_service")
	if not is_instance_valid(update_service) or not update_service.has_method("safe_status"):
		_set_update_state("unavailable", "")
		return
	var value: Variant = update_service.call("safe_status")
	if not value is Dictionary:
		_set_update_state("unavailable", "")
		return
	var status: Dictionary = value
	var raw_state := str(status.get("state", "idle"))
	var availability := str(status.get("checkAvailabilityCode", "config-incomplete"))
	if raw_state == "idle" and availability != "ready":
		match availability:
			"updater-missing": _set_update_error("update-updater-missing")
			"preview-config-incomplete": _set_update_error("update-preview-config-incomplete")
			"stable-trust-pending": _set_update_error("update-stable-trust-pending")
			_: _set_update_error("update-config-incomplete")
		return
	_set_update_state(raw_state, str(status.get("targetVersion", "")))


func _set_update_error(error_code: String) -> void:
	var safe_code := error_code if UPDATE_MESSAGES.has(error_code) else "update-failed"
	var state := "unavailable" if safe_code in ["update-unavailable", "update-config-incomplete", "update-preview-config-incomplete", "update-stable-trust-pending", "update-updater-missing"] else "failed"
	update_state = {"state": state, "messageCode": safe_code, "targetVersion": ""}


func _set_update_state(raw_state: String, version: String) -> void:
	var normalized := raw_state.strip_edges().to_lower()
	var state := "failed"
	var code := "update-failed"
	match normalized:
		"unavailable": state = "unavailable"; code = "update-unavailable"
		"idle": state = "idle"; code = "update-idle"
		"checking": state = "checking"; code = "update-checking"
		"no_update": state = "up-to-date"; code = "update-current"
		"staged": state = "ready"; code = "update-ready"
		"apply_requested": state = "apply-requested"; code = "update-apply-requested"
		"stopping": state = "stopping"; code = "update-stopping"
		"validating": state = "validating"; code = "update-validating"
		"swapping": state = "swapping"; code = "update-swapping"
		"restarting": state = "restarting"; code = "update-restarting"
		"applied": state = "applied"; code = "update-applied"
		"rolled_back": state = "rolled-back"; code = "update-rolled-back"
		"rollback_failed": state = "failed"; code = "update-rollback-failed"
		"error": state = "failed"; code = "update-check-failed"
		"failed": state = "failed"; code = "update-failed"
	var target_version := _safe_update_version(version, "")
	if state not in ["ready", "apply-requested", "stopping", "validating", "swapping", "restarting"]:
		target_version = ""
	update_state = {"state": state, "messageCode": code, "targetVersion": target_version}


func _safe_update_version(value: String, fallback: String) -> String:
	var candidate := value.strip_edges()
	if candidate.is_empty() or candidate.length() > 64:
		return fallback
	var first := candidate.unicode_at(0)
	if first < 48 or first > 57:
		return fallback
	for index in range(candidate.length()):
		var code := candidate.unicode_at(index)
		var allowed := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [43, 45, 46]
		if not allowed:
			return fallback
	return candidate


func _on_resource_monitor(_payload: Dictionary) -> void:
	_write_snapshot()


func _upsert_assistant_message(message_id: String, text: String, status: String) -> void:
	for index in range(chat_messages.size() - 1, -1, -1):
		if str(chat_messages[index].get("id", "")) == "%s:assistant" % message_id:
			var feedback := str(chat_messages[index].get("feedback", "none"))
			chat_messages[index] = {"id": "%s:assistant" % message_id, "role": "assistant", "text": text, "status": status, "feedback": feedback}
			return
	chat_messages.append({"id": "%s:assistant" % message_id, "role": "assistant", "text": text, "status": status, "feedback": "none"})
	_trim_chat_messages()


func _trim_chat_messages() -> void:
	while chat_messages.size() > MAX_CHAT_MESSAGES:
		chat_messages.pop_front()


func _idle_preview_state() -> Dictionary:
	return {
		"status": "idle",
		"errorCode": "",
		"packageId": "",
		"version": "",
		"clips": [],
		"selectedAnimation": "",
		"isPlaying": false,
		"loop": false,
		"speed": 1.0,
		"clipThumbnailPngBase64": {},
		"framePngBase64": "",
		"frameWidth": 0,
		"frameHeight": 0,
	}


func _set_preview_failed(identity: Dictionary, error_code: String) -> void:
	_close_preview()
	preview_state["status"] = "failed"
	preview_state["errorCode"] = error_code
	preview_state["packageId"] = str(identity.get("package_id", ""))
	preview_state["version"] = str(identity.get("version", ""))


func _close_preview() -> void:
	_reset_effect_comparison()
	preview_generation += 1
	preview_requested_animation = ""
	preview_requested_playing = false
	preview_prefetch_queue.clear()
	preview_load_is_prefetch = false
	preview_frames = null
	preview_active_payload.clear()
	preview_package_info.clear()
	preview_prepared_entry.clear()
	preview_animation_cache.clear()
	preview_animation_order.clear()
	preview_animation_cache_bytes = 0
	preview_animation_loops.clear()
	preview_thumbnail_base64_cache.clear()
	preview_thumbnail_attempted.clear()
	preview_elapsed = 0.0
	preview_frame_elapsed = 0.0
	preview_last_frame_index = -1
	preview_thumbnail_offset = 0
	preview_trim_rect_cache.clear()
	preview_atlas_image_cache.clear()
	preview_atlas_image_order.clear()
	preview_atlas_image_cache_bytes = 0
	preview_camera_reference_rect = Rect2()
	preview_camera_character_id = ""
	effect_preview_mode = ""
	effect_preview_elapsed = 0.0
	effect_preview_frame_elapsed = 0.0
	effect_preview_sheet_cache.clear()
	effect_preview_tuning.clear()
	var effect_pack_service := _service(&"effect_pack_service")
	if is_instance_valid(effect_pack_service) and effect_pack_service.has_method("set_preview_rank"):
		effect_pack_service.call("set_preview_rank", "")
	preview_state = _idle_preview_state()
	_write_preview_media()


func _preview_identity_matches(command: Dictionary) -> bool:
	var package_id := str(command.get("packageId", ""))
	var version := str(command.get("version", ""))
	return not package_id.is_empty() and package_id.length() <= 128 \
		and not version.is_empty() and version.length() <= 64 \
		and str(preview_state.get("packageId", "")) == package_id \
		and str(preview_state.get("version", "")) == version \
		and not preview_package_info.is_empty()


func _request_preview_animation(animation: String, play_when_ready: bool = false) -> bool:
	if animation.is_empty() or animation.length() > 80 or preview_package_info.is_empty():
		return false
	var cached_value: Variant = preview_animation_cache.get(animation, null)
	if cached_value is Dictionary and _is_valid_preview_payload(cached_value, animation):
		_activate_preview_payload(animation, cached_value, play_when_ready, "memory-cache", 0)
		return true
	var character_service := _service(&"character_service")
	if not is_instance_valid(character_service) or not character_service.has_method("build_preview_animation_payload"):
		return false
	var has_active_frame := not preview_active_payload.is_empty() and not str(preview_state.get("framePngBase64", "")).is_empty()
	# Promote an in-flight background prefetch when Chat asks for the same clip.
	# Keep the current frame visible until the replacement's frame 0 is ready.
	if preview_load_thread != null and preview_load_animation == animation and preview_load_generation == preview_generation:
		preview_load_is_prefetch = false
		preview_requested_animation = animation
		preview_requested_playing = preview_requested_playing or play_when_ready
		if not has_active_frame:
			preview_state["selectedAnimation"] = animation
			preview_state["loop"] = bool(preview_animation_loops.get(animation, false))
			preview_state["isPlaying"] = false
			preview_state["status"] = "loading"
			preview_state["errorCode"] = ""
			preview_state["framePngBase64"] = ""
			preview_state["frameWidth"] = 0
			preview_state["frameHeight"] = 0
			preview_active_payload.clear()
			preview_elapsed = 0.0
			preview_frame_elapsed = 0.0
			preview_last_frame_index = -1
			_write_preview_media()
		else:
			preview_state["errorCode"] = ""
		_write_snapshot()
		return true
	preview_generation += 1
	preview_requested_animation = animation
	preview_requested_playing = play_when_ready
	if not has_active_frame:
		preview_state["selectedAnimation"] = animation
		preview_state["loop"] = bool(preview_animation_loops.get(animation, false))
		preview_state["isPlaying"] = false
		preview_state["status"] = "loading"
		preview_state["errorCode"] = ""
		preview_state["framePngBase64"] = ""
		preview_state["frameWidth"] = 0
		preview_state["frameHeight"] = 0
		preview_active_payload.clear()
		preview_elapsed = 0.0
		preview_frame_elapsed = 0.0
		preview_last_frame_index = -1
	else:
		# Atomic swap: the old animation continues to render while the worker
		# prepares the requested clip. Activation replaces it only after frame 0
		# is available, so Electron never sees a blank/placeholder transition.
		preview_state["errorCode"] = ""
	_start_preview_load_if_idle()
	if not has_active_frame:
		_write_preview_media()
	_write_snapshot()
	return true


func _start_preview_load_if_idle() -> void:
	if stopping or preview_load_thread != null or preview_package_info.is_empty():
		return
	var character_service := _service(&"character_service")
	if not is_instance_valid(character_service) or not character_service.has_method("build_preview_animation_payload"):
		return
	var animation := ""
	var is_prefetch := false
	if not preview_requested_animation.is_empty():
		animation = preview_requested_animation
	else:
		while not preview_prefetch_queue.is_empty():
			var candidate := str(preview_prefetch_queue.pop_front())
			if candidate.is_empty() or preview_animation_cache.has(candidate):
				continue
			if not preview_state.get("clips", []).has(candidate):
				continue
			animation = candidate
			is_prefetch = true
			break
	if animation.is_empty():
		return
	preview_load_animation = animation
	preview_load_is_prefetch = is_prefetch
	preview_load_generation = preview_generation
	preview_load_started_at_msec = Time.get_ticks_msec()
	# Native trust verification already ran when this preview session opened.
	# Reuse that immutable entry/hash snapshot for every clip; each worker still
	# hashes the sprite bytes against the signed asset hash before decoding.
	var prepared: Dictionary = preview_prepared_entry.duplicate(true)
	if prepared.is_empty() and character_service.has_method("prepare_preview_entry"):
		prepared = character_service.call("prepare_preview_entry", preview_package_info)
		if bool(prepared.get("ok", false)):
			preview_prepared_entry = prepared.duplicate(true)
	if not bool(prepared.get("ok", false)):
		preview_load_animation = ""
		preview_load_is_prefetch = false
		_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "package-verification-failed")
		return
	preview_load_thread = Thread.new()
	var callable := Callable(character_service, "build_preview_animation_payload").bind(
		preview_package_info.duplicate(true), preview_load_animation, prepared
	)
	var start_error := preview_load_thread.start(callable, Thread.PRIORITY_LOW)
	if start_error != OK:
		var failed_prefetch := preview_load_is_prefetch
		preview_load_thread = null
		preview_load_animation = ""
		preview_load_is_prefetch = false
		if not failed_prefetch and preview_load_generation == preview_generation:
			_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "preview-unavailable")
		elif failed_prefetch:
			call_deferred("_start_preview_load_if_idle")


func _poll_preview_load() -> void:
	if preview_load_thread == null:
		_start_preview_load_if_idle()
		return
	if preview_load_thread.is_alive():
		return
	var completed_thread := preview_load_thread
	var completed_animation := preview_load_animation
	var completed_generation := preview_load_generation
	var completed_prefetch := preview_load_is_prefetch
	var elapsed_ms := Time.get_ticks_msec() - preview_load_started_at_msec
	preview_load_thread = null
	preview_load_animation = ""
	preview_load_is_prefetch = false
	var result: Variant = completed_thread.wait_to_finish()
	if completed_generation == preview_generation:
		var valid_payload := result is Dictionary and bool(result.get("ok", false)) and _is_valid_preview_payload(result, completed_animation)
		if valid_payload:
			_cache_preview_payload(completed_animation, result)
			if completed_prefetch:
				print("[DesktopShellPreview] animation-preloaded name=%s total_ms=%d cache_bytes=%d" % [completed_animation, elapsed_ms, preview_animation_cache_bytes])
				if chat_preview_warm_started_at_msec > 0 and not chat_preview_warm_ready_logged and _chat_core_preview_cache_ready():
					chat_preview_warm_ready_logged = true
					print("[DesktopShellTiming] preview_core_ready_ms=%d cache_bytes=%d" % [Time.get_ticks_msec() - chat_preview_warm_started_at_msec, preview_animation_cache_bytes])
			elif completed_animation == preview_requested_animation:
				var payload_source := "persistent-cache" if bool(result.get("cache_hit", false)) else "background-package"
				_activate_preview_payload(completed_animation, result, preview_requested_playing, payload_source, elapsed_ms)
		elif not completed_prefetch and completed_animation == preview_requested_animation:
			_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "preview-unavailable")
	_start_preview_load_if_idle()


func _join_preview_load_thread() -> void:
	if preview_load_thread == null:
		return
	preview_load_thread.wait_to_finish()
	preview_load_thread = null
	preview_load_animation = ""
	preview_load_is_prefetch = false


func _is_valid_preview_payload(payload: Dictionary, animation: String) -> bool:
	if str(payload.get("animation", "")) != animation:
		return false
	var encoded_value: Variant = payload.get("encoded_frames", [])
	if not encoded_value is Array:
		return false
	var encoded_frames: Array = encoded_value
	if encoded_frames.is_empty() or encoded_frames.size() > MAX_PREVIEW_ANIMATION_FRAMES:
		return false
	var total_bytes := 0
	for encoded_value_item in encoded_frames:
		var encoded := str(encoded_value_item)
		if encoded.is_empty() or encoded.length() > MAX_PREVIEW_BASE64_LENGTH:
			return false
		total_bytes += encoded.length()
		if total_bytes > PREVIEW_ANIMATION_CACHE_BYTES:
			return false
	var width := int(payload.get("frame_width", 0))
	var height := int(payload.get("frame_height", 0))
	var fps := float(payload.get("fps", 0.0))
	return width > 0 and width <= MAX_PREVIEW_FRAME_WIDTH \
		and height > 0 and height <= MAX_PREVIEW_FRAME_HEIGHT \
		and fps >= 0.1 and fps <= 60.0


func _preview_payload_bytes(payload: Dictionary) -> int:
	var total := 0
	var encoded_value: Variant = payload.get("encoded_frames", [])
	if encoded_value is Array:
		for value in encoded_value:
			total += str(value).length()
	return total


func _cache_preview_payload(animation: String, payload: Dictionary) -> void:
	if preview_animation_cache.has(animation):
		preview_animation_cache_bytes -= _preview_payload_bytes(preview_animation_cache[animation])
	preview_animation_cache[animation] = payload.duplicate(true)
	preview_animation_cache_bytes += _preview_payload_bytes(payload)
	_touch_preview_animation(animation)
	_trim_preview_animation_cache(animation)


func warm_chat_preview() -> bool:
	if stopping:
		return false
	if chat_preview_warm_started_at_msec <= 0:
		chat_preview_warm_started_at_msec = Time.get_ticks_msec()
		chat_preview_warm_ready_logged = false
	var package_service := _service(&"package_service")
	if not is_instance_valid(package_service):
		return false
	var active_value: Variant = package_service.call("get_active_candidate") if package_service.has_method("get_active_candidate") else package_service.get_active()
	if not active_value is Dictionary:
		return false
	var active: Dictionary = active_value
	var package_id := str(active.get("packageId", ""))
	var version := str(active.get("version", ""))
	if package_id.is_empty() or version.is_empty():
		return false
	if str(preview_state.get("packageId", "")) != package_id or str(preview_state.get("version", "")) != version or preview_package_info.is_empty():
		_open_preview({"type": "character.preview.open", "packageId": package_id, "version": version})
	if not _preview_identity_matches({"packageId": package_id, "version": version}):
		return false
	_queue_chat_core_preview_prefetch(true)
	print("[DesktopShellPreview] warm-requested package=%s version=%s" % [package_id, version])
	return true


func _queue_chat_core_preview_prefetch(force: bool = false) -> void:
	if (not chat_presentation_active and not force) or preview_package_info.is_empty():
		return
	var clips: Array = preview_state.get("clips", [])
	var groups := [
		["idle"],
		["think", "thinking"],
		["speak", "talk", "happy"],
	]
	for group in groups:
		var selected := ""
		for candidate in group:
			if clips.has(candidate):
				selected = candidate
				break
		if selected.is_empty() \
		or preview_animation_cache.has(selected) \
		or selected == preview_load_animation \
		or selected == preview_requested_animation \
		or preview_prefetch_queue.has(selected):
			continue
		preview_prefetch_queue.append(selected)
	_start_preview_load_if_idle()


func _chat_core_preview_cache_ready() -> bool:
	var clips: Array = preview_state.get("clips", [])
	for group in [["idle"], ["think", "thinking"], ["speak", "talk", "happy"]]:
		var required := ""
		for candidate in group:
			if clips.has(candidate):
				required = candidate
				break
		if not required.is_empty() and not preview_animation_cache.has(required):
			return false
	return not clips.is_empty()


func _activate_preview_payload(animation: String, payload: Dictionary, playing: bool, source: String, load_ms: int) -> void:
	# Keep active playback and cache ownership separate. Clearing the active
	# animation on a new selection must not mutate the cached Dictionary.
	preview_active_payload = payload.duplicate(true)
	preview_requested_animation = ""
	preview_requested_playing = false
	preview_state["selectedAnimation"] = animation
	if not preview_animation_loops.has(animation):
		preview_animation_loops[animation] = bool(payload.get("loop", false))
	preview_state["loop"] = bool(preview_animation_loops.get(animation, false))
	preview_state["isPlaying"] = playing
	preview_state["status"] = "playing" if playing else "ready"
	preview_elapsed = 0.0
	preview_frame_elapsed = 0.0
	preview_last_frame_index = -1
	_touch_preview_animation(animation)
	_refresh_preview_frame(true)
	_write_preview_media()
	_write_snapshot()
	_queue_chat_core_preview_prefetch()
	print("[DesktopShellPreview] animation-ready name=%s source=%s total_ms=%d worker_ms=%d cache_bytes=%d" % [
		animation, source, load_ms, int(payload.get("worker_ms", 0)), preview_animation_cache_bytes
	])


func _touch_preview_animation(animation: String) -> void:
	preview_animation_order.erase(animation)
	preview_animation_order.append(animation)


func _trim_preview_animation_cache(active_animation: String) -> void:
	var attempts := preview_animation_order.size() + 1
	while preview_animation_cache_bytes > PREVIEW_ANIMATION_CACHE_BYTES and attempts > 0:
		attempts -= 1
		var candidate: String = preview_animation_order.pop_front()
		if candidate == active_animation or (chat_presentation_active and candidate in CHAT_CORE_PREVIEW_ANIMATIONS):
			preview_animation_order.append(candidate)
			continue
		preview_animation_cache_bytes -= _preview_payload_bytes(preview_animation_cache.get(candidate, {}))
		preview_animation_cache.erase(candidate)
		preview_trim_rect_cache.erase(candidate)
		var cached_atlas_value: Variant = preview_atlas_image_cache.get(candidate, null)
		if cached_atlas_value is Image:
			preview_atlas_image_cache_bytes = maxi(0, preview_atlas_image_cache_bytes - (cached_atlas_value as Image).get_data_size())
		preview_atlas_image_cache.erase(candidate)
		preview_atlas_image_order.erase(candidate)


func _update_preview(delta: float) -> void:
	if preview_active_payload.is_empty() or not bool(preview_state.get("isPlaying", false)):
		return
	preview_elapsed += delta
	preview_frame_elapsed += delta
	var authored_fps := float(preview_active_payload.get("fps", 8.0))
	var playback_speed := maxf(0.5, float(preview_state.get("speed", 1.0)))
	var target_fps := clampf(authored_fps * playback_speed, 1.0, MAX_PREVIEW_OUTPUT_FPS)
	var frame_interval := 1.0 / target_fps
	if preview_frame_elapsed < frame_interval:
		return
	preview_frame_elapsed = fmod(preview_frame_elapsed, frame_interval)
	var previous_index := preview_last_frame_index
	var was_playing := bool(preview_state.get("isPlaying", false))
	_refresh_preview_frame(false)
	if preview_last_frame_index != previous_index:
		_write_preview_media()
	if was_playing and not bool(preview_state.get("isPlaying", false)):
		_write_snapshot()


func _update_effect_preview(delta: float) -> void:
	if preview_active_payload.is_empty():
		return
	if effect_preview_refresh_pending:
		effect_preview_refresh_pending = false
		effect_preview_frame_elapsed = 0.0
		_refresh_preview_frame(true)
		_write_preview_media()
		return
	if effect_preview_mode.is_empty():
		return
	if effect_preview_variant == "equipped" or not (is_instance_valid(context) and bool(context.settings.get("reduce_motion", false))):
		effect_preview_elapsed += delta
	effect_preview_frame_elapsed += delta
	var frame_interval := 1.0 / EFFECT_PREVIEW_OUTPUT_FPS
	if effect_preview_frame_elapsed < frame_interval:
		return
	effect_preview_frame_elapsed = fmod(effect_preview_frame_elapsed, frame_interval)
	_refresh_preview_frame(false)
	_write_preview_media()


func _refresh_preview_shortcut_thumbnails() -> void:
	preview_state["clipThumbnailPngBase64"] = {}
	if preview_package_info.is_empty():
		return
	var clips_value: Variant = preview_state.get("clips", [])
	var clips: Array = clips_value if clips_value is Array else []
	var wanted: Array[String] = []
	var start_index := clampi(preview_thumbnail_offset, 0, maxi(0, clips.size() - 1))
	var end_index := mini(start_index + 6, clips.size())
	for index in range(start_index, end_index):
		var clip := str(clips[index])
		if not clip.is_empty():
			wanted.append(clip)
	var selected := str(preview_state.get("selectedAnimation", ""))
	if not selected.is_empty() and clips.has(selected) and not wanted.has(selected) and wanted.size() < MAX_PREVIEW_SHORTCUT_THUMBNAILS:
		wanted.append(selected)

	var missing: Array[String] = []
	for clip in wanted:
		if not preview_thumbnail_attempted.has(clip):
			missing.append(clip)
	if not missing.is_empty():
		var character_service := _service(&"character_service")
		if is_instance_valid(character_service) and character_service.has_method("load_animation_thumbnail_png_bytes"):
			var result: Variant = character_service.call("load_animation_thumbnail_png_bytes", preview_package_info, missing)
			if result is Dictionary and bool(result.get("ok", false)):
				var raw_thumbnails_value: Variant = result.get("thumbnails", {})
				var raw_thumbnails: Dictionary = raw_thumbnails_value if raw_thumbnails_value is Dictionary else {}
				var source := str(result.get("source", ""))
				var legacy_no_thumbnails := source == "legacy-no-animation-thumbnails"
				for clip in missing:
					var bytes_value: Variant = raw_thumbnails.get(clip, PackedByteArray())
					if not bytes_value is PackedByteArray:
						if legacy_no_thumbnails:
							preview_thumbnail_attempted[clip] = true
						continue
					var png_bytes: PackedByteArray = bytes_value
					if png_bytes.is_empty() or png_bytes.size() > MAX_PREVIEW_THUMBNAIL_PNG_BYTES:
						if legacy_no_thumbnails:
							preview_thumbnail_attempted[clip] = true
						continue
					var encoded := Marshalls.raw_to_base64(png_bytes)
					if encoded.is_empty() or encoded.length() > MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH:
						continue
					preview_thumbnail_base64_cache[clip] = encoded
					preview_thumbnail_attempted[clip] = true
	var encoded_thumbnails: Dictionary = {}
	for clip in wanted:
		var encoded := str(preview_thumbnail_base64_cache.get(clip, ""))
		if not encoded.is_empty():
			encoded_thumbnails[clip] = encoded
	preview_state["clipThumbnailPngBase64"] = encoded_thumbnails


func _refresh_preview_frame(force: bool) -> void:
	if preview_active_payload.is_empty():
		return
	var render_started_at_msec := Time.get_ticks_msec() if force else 0
	var animation := str(preview_state.get("selectedAnimation", ""))
	if animation.is_empty() or str(preview_active_payload.get("animation", "")) != animation:
		return
	var encoded_value: Variant = preview_active_payload.get("encoded_frames", [])
	var encoded_frames: Array = encoded_value if encoded_value is Array else []
	var frame_count := encoded_frames.size()
	if frame_count <= 0:
		_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "no-preview-frames")
		return
	var frame_index := _preview_frame_index(frame_count)
	if not force and frame_index == preview_last_frame_index and effect_preview_mode.is_empty():
		return
	var encoded := str(encoded_frames[frame_index])
	if encoded.is_empty() or encoded.length() > MAX_PREVIEW_BASE64_LENGTH:
		_set_preview_failed({"package_id": preview_state.get("packageId", ""), "version": preview_state.get("version", "")}, "frame-unavailable")
		return
	var output_width := int(preview_active_payload.get("frame_width", 0))
	var output_height := int(preview_active_payload.get("frame_height", 0))

	# Character Manager always uses the same character-first compositor.
	# Switching Animation <-> Effects must never change the camera/character fit;
	# effect_preview_mode only controls which Runtime layers are added.
	var composite := _compose_preview_frame(encoded, frame_index)
	if not composite.is_empty():
		encoded = str(composite.get("encoded", encoded))
		output_width = int(composite.get("width", output_width))
		output_height = int(composite.get("height", output_height))
		if force:
			var runtime_rect: Rect2 = composite.get("runtimeCharacterRect", Rect2())
			var reference_rect: Rect2 = composite.get("displayReferenceRect", runtime_rect)
			var display_origin: Vector2 = composite.get("displayOrigin", Vector2.ZERO)
			var display_scale := float(composite.get("displayScale", 1.0))
			print("[PreviewGeometry] character=%s animation=%s mode=%s runtime_rect=%s reference_rect=%s display_scale=%.4f origin=%s output=%dx%d" % [
				str(preview_state.get("packageId", "")),
				animation,
				effect_preview_mode if not effect_preview_mode.is_empty() else "off",
				str(runtime_rect),
				str(reference_rect),
				display_scale,
				str(display_origin),
				output_width,
				output_height,
			])

	preview_last_frame_index = frame_index
	preview_state["framePngBase64"] = encoded
	preview_state["frameWidth"] = output_width
	preview_state["frameHeight"] = output_height
	if str(preview_state.get("status", "")) == "loading":
		preview_state["status"] = "ready"
	if force:
		print("[DesktopShellPreview] first-frame-ready name=%s frame=%d effect=%s main_apply_ms=%d" % [animation, frame_index, effect_preview_mode if not effect_preview_mode.is_empty() else "off", Time.get_ticks_msec() - render_started_at_msec])


func _effect_preview_presentation_scale(character_id: String) -> float:
	var settings_service := _service(&"settings_service")
	if is_instance_valid(settings_service) and settings_service.has_method("load_character_presentation_scale"):
		return clampf(float(settings_service.call("load_character_presentation_scale", character_id)), 0.25, 1.25)
	if context != null and str(context.character.get("id", "")) == character_id:
		return clampf(float(context.character.get("presentation_scale", 1.0)), 0.25, 1.25)
	return 1.0


func _compose_effect_preview_frame(character_encoded: String, frame_index: int = 0) -> Dictionary:
	# Backward-compatible test/helper entry point. The actual pipeline is shared
	# by normal animation preview and FX preview so the character camera never
	# changes when the user switches tabs.
	return _compose_preview_frame(character_encoded, frame_index)


func _compose_preview_frame(character_encoded: String, frame_index: int = 0) -> Dictionary:
	var character_bytes := Marshalls.base64_to_raw(character_encoded)
	if character_bytes.is_empty():
		return {}
	var character_image := Image.new()
	if character_image.load_png_from_buffer(character_bytes) != OK or character_image.is_empty():
		return {}
	character_image.convert(Image.FORMAT_RGBA8)

	var geometry := _resolve_preview_character_geometry(character_image, frame_index)
	if geometry.is_empty():
		return {}

	var character_rect: Rect2 = geometry.get("character_rect", Rect2())
	var reference_rect: Rect2 = geometry.get("display_reference_rect", character_rect)
	var display_transform := _resolve_preview_display_transform(reference_rect)
	if display_transform.is_empty():
		return {}

	# Compose directly in Character Manager output space. The previous path first
	# blended into a 384x384 runtime surface and clipped wide/low effects before
	# the display camera could show them. Runtime coordinates remain the source
	# of truth, but editor overflow (notably Ground Rune below the feet line) is
	# preserved so tuning controls can show the complete effect.
	var output := Image.create(
		EFFECT_PREVIEW_OUTPUT_SIZE.x,
		EFFECT_PREVIEW_OUTPUT_SIZE.y,
		false,
		Image.FORMAT_RGBA8
	)
	output.fill(Color.TRANSPARENT)

	var runtime_surface: Vector2 = geometry.get("runtime_surface_size", Vector2(EFFECT_PREVIEW_RUNTIME_SURFACE_SIZE, EFFECT_PREVIEW_RUNTIME_SURFACE_SIZE))
	var presentation_scale := float(geometry.get("presentation_scale", 1.0))
	var layers: Array[Dictionary] = []
	if not effect_preview_mode.is_empty():
		for slot_name in ["bodyAura", "groundRune", "levelUpBurst"]:
			if effect_preview_mode != "all" and effect_preview_mode != slot_name:
				continue
			var layer := _effect_preview_layer(
				slot_name,
				character_rect,
				runtime_surface,
				presentation_scale
			)
			if not layer.is_empty():
				layers.append(layer)

	layers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("z", 0)) < int(b.get("z", 0)))
	for layer in layers:
		if int(layer.get("z", 0)) >= 0:
			continue
		_blend_runtime_image_to_preview(
			output,
			layer.get("image") as Image,
			layer.get("position", Vector2i.ZERO) as Vector2i,
			display_transform
		)

	var rendered_character := character_image.duplicate()
	var source_crop_size: Vector2 = geometry.get("source_crop_size", Vector2(character_image.get_size()))
	var runtime_scale := float(geometry.get("runtime_scale", 1.0))
	rendered_character.resize(
		maxi(1, int(round(source_crop_size.x * runtime_scale))),
		maxi(1, int(round(source_crop_size.y * runtime_scale))),
		Image.INTERPOLATE_LANCZOS
	)
	_blend_runtime_image_to_preview(
		output,
		rendered_character,
		geometry.get("character_position", Vector2i.ZERO) as Vector2i,
		display_transform
	)

	for layer in layers:
		if int(layer.get("z", 0)) < 0:
			continue
		_blend_runtime_image_to_preview(
			output,
			layer.get("image") as Image,
			layer.get("position", Vector2i.ZERO) as Vector2i,
			display_transform
		)

	var encoded := _encode_preview_canvas(output)
	if encoded.is_empty():
		return {}
	encoded["runtimeCharacterRect"] = character_rect
	encoded["displayReferenceRect"] = reference_rect
	encoded["displayScale"] = float(display_transform.get("scale", 1.0))
	encoded["displayOrigin"] = display_transform.get("origin", Vector2.ZERO)
	encoded["geometrySource"] = str(geometry.get("geometry_source", "preview-fallback"))
	return encoded


func _blend_runtime_image_to_preview(
	target: Image,
	source: Image,
	runtime_destination: Vector2i,
	display_transform: Dictionary
) -> void:
	if target == null or target.is_empty() or source == null or source.is_empty():
		return
	var display_scale := maxf(0.001, float(display_transform.get("scale", 1.0)))
	var display_origin: Vector2 = display_transform.get("origin", Vector2.ZERO)
	var projected := source.duplicate()
	projected.resize(
		maxi(1, int(round(float(source.get_width()) * display_scale))),
		maxi(1, int(round(float(source.get_height()) * display_scale))),
		Image.INTERPOLATE_LANCZOS
	)
	var projected_destination := display_origin + Vector2(runtime_destination) * display_scale
	_blend_preview_image(
		target,
		projected,
		Vector2i(
			int(round(projected_destination.x)),
			int(round(projected_destination.y))
		)
	)


func _preview_reference_payload() -> Dictionary:
	var idle_value: Variant = preview_animation_cache.get("idle", {})
	if idle_value is Dictionary and not (idle_value as Dictionary).is_empty():
		return idle_value as Dictionary
	return preview_active_payload


func _preview_rect_from_payload(payload: Dictionary, key: String, fallback: Rect2) -> Rect2:
	var value: Variant = payload.get(key, {})
	if not value is Dictionary:
		return fallback
	var rect := value as Dictionary
	var width := maxf(1.0, float(rect.get("width", fallback.size.x)))
	var height := maxf(1.0, float(rect.get("height", fallback.size.y)))
	return Rect2(
		Vector2(
			float(rect.get("x", fallback.position.x)),
			float(rect.get("y", fallback.position.y))
		),
		Vector2(width, height)
	)


func _stable_preview_camera_reference_rect(character_id: String, candidate: Rect2) -> Rect2:
	if candidate.size.x <= 0.0 or candidate.size.y <= 0.0:
		return candidate
	var normalized_id := character_id.strip_edges()
	if preview_camera_reference_rect.size.x <= 0.0 \
	or preview_camera_reference_rect.size.y <= 0.0 \
	or preview_camera_character_id != normalized_id:
		preview_camera_reference_rect = candidate
		preview_camera_character_id = normalized_id
	return preview_camera_reference_rect


func _resolve_preview_character_geometry(character_image: Image, frame_index: int) -> Dictionary:
	if character_image == null or character_image.is_empty() or preview_active_payload.is_empty():
		return {}
	var runtime_size := float(EFFECT_PREVIEW_RUNTIME_SURFACE_SIZE)
	var current_payload := preview_active_payload
	var reference_payload := _preview_reference_payload()

	var source_frame_width := maxf(1.0, float(current_payload.get("source_frame_width", character_image.get_width())))
	var source_frame_height := maxf(1.0, float(current_payload.get("source_frame_height", character_image.get_height())))
	var source_crop_x := float(current_payload.get("source_crop_x", 0.0))
	var source_crop_y := float(current_payload.get("source_crop_y", 0.0))
	var source_crop_width := maxf(1.0, float(current_payload.get("source_crop_width", character_image.get_width())))
	var source_crop_height := maxf(1.0, float(current_payload.get("source_crop_height", character_image.get_height())))
	var current_union := _preview_rect_from_payload(
		current_payload,
		"runtime_union_alpha",
		Rect2(Vector2.ZERO, Vector2(source_frame_width, source_frame_height))
	)
	var current_rect := current_union
	var runtime_rects_value: Variant = current_payload.get("runtime_alpha_rects", [])
	if runtime_rects_value is Array and frame_index >= 0 and frame_index < (runtime_rects_value as Array).size():
		var frame_rect_value: Variant = (runtime_rects_value as Array)[frame_index]
		if frame_rect_value is Dictionary:
			var frame_rect_dict := frame_rect_value as Dictionary
			current_rect = Rect2(
				Vector2(
					float(frame_rect_dict.get("x", current_union.position.x)),
					float(frame_rect_dict.get("y", current_union.position.y))
				),
				Vector2(
					maxf(1.0, float(frame_rect_dict.get("width", current_union.size.x))),
					maxf(1.0, float(frame_rect_dict.get("height", current_union.size.y)))
				)
			)

	# Runtime uses idle as the canonical visual-size reference. Use the already
	# warmed idle payload when available so animation changes do not zoom the
	# Character Manager camera.
	var reference_frame_width := maxf(1.0, float(reference_payload.get("source_frame_width", source_frame_width)))
	var reference_frame_height := maxf(1.0, float(reference_payload.get("source_frame_height", source_frame_height)))
	var reference_union := _preview_rect_from_payload(
		reference_payload,
		"runtime_union_alpha",
		current_union
	)
	var profile_ratio := clampf(
		float(reference_payload.get("idle_profile_scale", current_payload.get("idle_profile_scale", 1.0))),
		0.25,
		2.0
	)
	var character_id := str(preview_state.get("packageId", "")).strip_edges()
	var presentation_scale := _effect_preview_presentation_scale(character_id)

	# Active-character preview borrows Runtime's native surface + render scale,
	# but it must NOT lock the editor camera to Runtime's current visual rect.
	# During a character switch Runtime may briefly be on appear/disappear or a
	# narrow transition frame; locking to that transient rect is what made Sabai
	# blow up until Character Manager was closed/reopened. Rebuild both the current
	# and idle-reference geometry from Preview's own payload using Runtime's scale
	# and native anchoring contract instead.
	if is_instance_valid(effect_controller) and effect_controller.has_method("preview_runtime_character_geometry"):
		var live_value: Variant = effect_controller.call("preview_runtime_character_geometry", character_id)
		if live_value is Dictionary and not (live_value as Dictionary).is_empty():
			var live_geometry := live_value as Dictionary
			var live_surface: Vector2 = live_geometry.get("surfaceSize", Vector2(runtime_size, runtime_size))
			var live_sprite_scale_vector: Vector2 = live_geometry.get("spriteScale", Vector2.ONE)
			presentation_scale = float(live_geometry.get("presentationScale", presentation_scale))
			var live_render_scale := maxf(0.001, absf(live_sprite_scale_vector.y))

			var source_frame_center_live := Vector2(source_frame_width, source_frame_height) * 0.5
			var current_union_center_live := current_union.get_center()
			var preview_sprite_position_live := Vector2(
				live_surface.x * 0.5 - (current_union_center_live.x - source_frame_center_live.x) * live_render_scale,
				live_surface.y - (current_union.end.y - source_frame_center_live.y) * live_render_scale
			)
			var preview_character_rect_live := Rect2(
				preview_sprite_position_live + (current_rect.position - source_frame_center_live) * live_render_scale,
				current_rect.size * live_render_scale
			)
			var character_position_live := Vector2i(
				int(round(preview_sprite_position_live.x + (source_crop_x - source_frame_center_live.x) * live_render_scale)),
				int(round(preview_sprite_position_live.y + (source_crop_y - source_frame_center_live.y) * live_render_scale))
			)

			var reference_frame_center_live := Vector2(reference_frame_width, reference_frame_height) * 0.5
			var reference_union_center_live := reference_union.get_center()
			var reference_sprite_position_live := Vector2(
				live_surface.x * 0.5 - (reference_union_center_live.x - reference_frame_center_live.x) * live_render_scale,
				live_surface.y - (reference_union.end.y - reference_frame_center_live.y) * live_render_scale
			)
			var reference_character_rect_live := Rect2(
				reference_sprite_position_live + (reference_union.position - reference_frame_center_live) * live_render_scale,
				reference_union.size * live_render_scale
			)
			var stable_reference_rect := _stable_preview_camera_reference_rect(character_id, reference_character_rect_live)
			return {
				"runtime_scale": live_render_scale,
				"presentation_scale": presentation_scale,
				"character_rect": preview_character_rect_live,
				"display_reference_rect": stable_reference_rect,
				"character_position": character_position_live,
				"source_crop_size": Vector2(source_crop_width, source_crop_height),
				"runtime_surface_size": live_surface,
				"geometry_source": "runtime-scale-native-anchor-camera-locked",
			}

	var safe_size := maxf(128.0, runtime_size - 64.0)
	var fitted_base := minf(
		safe_size / maxf(1.0, reference_union.size.x),
		safe_size / maxf(1.0, reference_union.size.y)
	)
	var runtime_scale := clampf(fitted_base * profile_ratio * presentation_scale, 0.0625, 3.0)

	# Fallback for inactive Library characters: emulate Runtime anchoring from
	# package metadata because no live sprite exists for that character.
	var source_frame_center := Vector2(source_frame_width, source_frame_height) * 0.5
	var current_union_center := current_union.get_center()
	var sprite_position := Vector2(
		runtime_size * 0.5 - (current_union_center.x - source_frame_center.x) * runtime_scale,
		runtime_size - (current_union.end.y - source_frame_center.y) * runtime_scale
	)
	var character_rect := Rect2(
		sprite_position + (current_rect.position - source_frame_center) * runtime_scale,
		current_rect.size * runtime_scale
	)
	var character_position := Vector2i(
		int(round(sprite_position.x + (source_crop_x - source_frame_center.x) * runtime_scale)),
		int(round(sprite_position.y + (source_crop_y - source_frame_center.y) * runtime_scale))
	)
	var reference_frame_center := Vector2(reference_frame_width, reference_frame_height) * 0.5
	var reference_union_center := reference_union.get_center()
	var reference_sprite_position := Vector2(
		runtime_size * 0.5 - (reference_union_center.x - reference_frame_center.x) * runtime_scale,
		runtime_size - (reference_union.end.y - reference_frame_center.y) * runtime_scale
	)
	var display_reference_rect := Rect2(
		reference_sprite_position + (reference_union.position - reference_frame_center) * runtime_scale,
		reference_union.size * runtime_scale
	)
	return {
		"runtime_scale": runtime_scale,
		"presentation_scale": presentation_scale,
		"character_rect": character_rect,
		"display_reference_rect": display_reference_rect,
		"character_position": character_position,
		"source_crop_size": Vector2(source_crop_width, source_crop_height),
		"runtime_surface_size": Vector2(runtime_size, runtime_size),
		"geometry_source": "preview-fallback",
	}


func _resolve_preview_display_transform(reference_rect: Rect2) -> Dictionary:
	if reference_rect.size.x <= 0.0 or reference_rect.size.y <= 0.0:
		return {}
	var output_size := Vector2(EFFECT_PREVIEW_OUTPUT_SIZE)

	# Character Manager camera is intentionally pixel-stable. Enlarging the
	# preview card must add breathing room, not zoom the companion. The runtime
	# character/effect geometry is still canonical; only this display camera is
	# fixed to an authored preview size.
	var display_scale := minf(
		PREVIEW_CHARACTER_TARGET_HEIGHT_PX / maxf(1.0, reference_rect.size.y),
		PREVIEW_CHARACTER_TARGET_WIDTH_PX / maxf(1.0, reference_rect.size.x)
	)
	display_scale = clampf(display_scale, 0.05, 8.0)
	var feet_y := PREVIEW_CHARACTER_FEET_Y_PX
	var display_origin := Vector2(
		output_size.x * 0.5 - reference_rect.get_center().x * display_scale,
		feet_y - reference_rect.end.y * display_scale
	)
	return {
		"scale": display_scale,
		"origin": display_origin,
		"feetY": feet_y,
		"outputSize": EFFECT_PREVIEW_OUTPUT_SIZE,
	}


func _project_runtime_canvas_to_preview(runtime_canvas: Image, reference_rect: Rect2) -> Dictionary:
	if runtime_canvas == null or runtime_canvas.is_empty():
		return {}
	var transform := _resolve_preview_display_transform(reference_rect)
	if transform.is_empty():
		return {}
	var display_scale := float(transform.get("scale", 1.0))
	var display_origin: Vector2 = transform.get("origin", Vector2.ZERO)
	var scaled_runtime := runtime_canvas.duplicate()
	scaled_runtime.resize(
		maxi(1, int(round(float(runtime_canvas.get_width()) * display_scale))),
		maxi(1, int(round(float(runtime_canvas.get_height()) * display_scale))),
		Image.INTERPOLATE_LANCZOS
	)
	var output := Image.create(
		EFFECT_PREVIEW_OUTPUT_SIZE.x,
		EFFECT_PREVIEW_OUTPUT_SIZE.y,
		false,
		Image.FORMAT_RGBA8
	)
	output.fill(Color.TRANSPARENT)
	_blend_preview_image(
		output,
		scaled_runtime,
		Vector2i(int(round(display_origin.x)), int(round(display_origin.y)))
	)
	return {
		"image": output,
		"display_scale": display_scale,
		"display_origin": display_origin,
	}


func _encode_preview_canvas(canvas: Image) -> Dictionary:
	if canvas == null or canvas.is_empty():
		return {}
	var png_bytes := canvas.save_png_to_buffer()
	if png_bytes.size() > MAX_PREVIEW_PNG_BYTES:
		_downscale_preview_for_transport(canvas, Vector2i(448, 280))
		png_bytes = canvas.save_png_to_buffer()
	if png_bytes.is_empty() or png_bytes.size() > MAX_PREVIEW_PNG_BYTES:
		_downscale_preview_for_transport(canvas, Vector2i(384, 240))
		png_bytes = canvas.save_png_to_buffer()
	if png_bytes.is_empty() or png_bytes.size() > MAX_PREVIEW_PNG_BYTES:
		_downscale_preview_for_transport(canvas, Vector2i(320, 200))
		png_bytes = canvas.save_png_to_buffer()
	if png_bytes.is_empty() or png_bytes.size() > MAX_PREVIEW_PNG_BYTES:
		return {}
	var encoded := Marshalls.raw_to_base64(png_bytes)
	if encoded.is_empty() or encoded.length() > MAX_PREVIEW_BASE64_LENGTH:
		return {}
	return {
		"encoded": encoded,
		"width": canvas.get_width(),
		"height": canvas.get_height(),
	}


func _downscale_preview_for_transport(image: Image, target_size: Vector2i) -> void:
	if image == null or image.is_empty() or target_size.x <= 0 or target_size.y <= 0:
		return
	var ratio := minf(
		float(target_size.x) / float(image.get_width()),
		float(target_size.y) / float(image.get_height())
	)
	if ratio >= 1.0:
		return
	image.resize(
		maxi(1, int(round(float(image.get_width()) * ratio))),
		maxi(1, int(round(float(image.get_height()) * ratio))),
		Image.INTERPOLATE_LANCZOS
	)


func _runtime_effect_preview_placement(
	slot_name: String,
	config: Dictionary,
	content_rect: Rect2,
	frame_size: Vector2,
	preview_character_rect: Rect2,
	preview_surface_size: Vector2,
	preview_presentation_scale: float
) -> Dictionary:
	var preview_character_id := str(preview_state.get("packageId", "")).strip_edges()
	if is_instance_valid(effect_controller) and effect_controller.has_method("resolve_preview_effect_placement"):
		var runtime_value: Variant = effect_controller.call(
			"resolve_preview_effect_placement",
			slot_name,
			config,
			content_rect,
			frame_size,
			preview_character_id
		)
		if runtime_value is Dictionary:
			var runtime_geometry := runtime_value as Dictionary
			if not runtime_geometry.is_empty():
				var runtime_character_rect: Rect2 = runtime_geometry.get("characterRect", Rect2())
				var runtime_position: Vector2 = runtime_geometry.get("position", runtime_character_rect.get_center())
				var runtime_scale: Vector2 = runtime_geometry.get("scale", Vector2.ONE)
				var runtime_surface: Vector2 = runtime_geometry.get("surfaceSize", preview_surface_size)
				if runtime_character_rect.size.x > 0.0 and runtime_character_rect.size.y > 0.0:
					var relation_x := preview_character_rect.size.x / runtime_character_rect.size.x
					var relation_y := preview_character_rect.size.y / runtime_character_rect.size.y
					var mapped_position := preview_character_rect.position + Vector2(
						(runtime_position.x - runtime_character_rect.position.x) * relation_x,
						(runtime_position.y - runtime_character_rect.position.y) * relation_y
					)
					var scale_mode := str(config.get("scaleMode", "character-height"))
					var relation_scale := relation_y
					if scale_mode == "character-width":
						relation_scale = relation_x
					elif scale_mode == "native-surface":
						var surface_x := preview_surface_size.x / maxf(1.0, runtime_surface.x)
						var surface_y := preview_surface_size.y / maxf(1.0, runtime_surface.y)
						relation_scale = minf(surface_x, surface_y)
					return {
						"position": mapped_position,
						"scale": runtime_scale * relation_scale,
						"z": int(runtime_geometry.get("z", EffectPlacementResolver.default_z(slot_name))),
						"source": "runtime",
						"runtimeCharacterRect": runtime_character_rect,
					}
	return EffectPlacementResolver.resolve(
		slot_name,
		config,
		preview_character_rect,
		content_rect,
		frame_size,
		preview_surface_size,
		preview_presentation_scale
	)


func _effect_preview_asset(resolved: Dictionary, config: Dictionary) -> Dictionary:
	# Production path: ask EffectController to prepare the exact same cropped /
	# frame-capped atlas geometry used by Runtime. Placement parity is not enough
	# if Preview still renders the authored 512px frame while Runtime renders the
	# normalized 384px copy.
	if is_instance_valid(effect_controller) and effect_controller.has_method("prepare_effect_preview_asset"):
		var runtime_config := config.duplicate(true)
		runtime_config["_packagePath"] = str(resolved.get("path", ""))
		var runtime_value: Variant = effect_controller.call("prepare_effect_preview_asset", runtime_config)
		if runtime_value is Dictionary and not (runtime_value as Dictionary).is_empty():
			return runtime_value as Dictionary

	# Test / inactive-character fallback. This path preserves the previous
	# preview behavior when no live Runtime controller can authoritatively
	# prepare the selected character's Effect Pack.
	var sheet_entry := _effect_preview_sheet(resolved)
	if sheet_entry.is_empty():
		return {}
	var sheet: Image = sheet_entry.get("image") as Image
	if sheet == null or sheet.is_empty():
		return {}
	var sheet_ratio := float(sheet_entry.get("ratio", 1.0))
	var authored_frame_width := maxi(1, int(config.get("frameWidth", 1)))
	var authored_frame_height := maxi(1, int(config.get("frameHeight", 1)))
	var frame_width := maxi(1, int(round(float(authored_frame_width) * sheet_ratio)))
	var frame_height := maxi(1, int(round(float(authored_frame_height) * sheet_ratio)))
	var columns := maxi(1, sheet.get_width() / frame_width)
	var rows := maxi(1, sheet.get_height() / frame_height)
	var frame_count := clampi(int(config.get("frameCount", 1)), 1, columns * rows)
	var content_rect := Rect2(Vector2.ZERO, Vector2(frame_width, frame_height))
	var bounds_value: Variant = config.get("contentBounds", {})
	if config.has("contentBounds") and bounds_value is Dictionary:
		var bounds := bounds_value as Dictionary
		var bounds_width := float(bounds.get("width", authored_frame_width))
		var bounds_height := float(bounds.get("height", authored_frame_height))
		if bounds_width > 0.0 and bounds_height > 0.0:
			content_rect = Rect2(
				Vector2(float(bounds.get("x", 0.0)) * sheet_ratio, float(bounds.get("y", 0.0)) * sheet_ratio),
				Vector2(bounds_width * sheet_ratio, bounds_height * sheet_ratio)
			)
	else:
		var inferred_bounds := EffectPlacementResolver.infer_content_bounds(
			sheet,
			frame_width,
			frame_height,
			columns,
			frame_count
		)
		if inferred_bounds.size != Vector2i.ZERO:
			content_rect = Rect2(Vector2(inferred_bounds.position), Vector2(inferred_bounds.size))
	return {
		"image": sheet,
		"frameWidth": frame_width,
		"frameHeight": frame_height,
		"columns": columns,
		"rows": rows,
		"frameCount": frame_count,
		"startFrame": clampi(int(config.get("startFrame", 0)), 0, frame_count - 1),
		"endFrame": clampi(int(config.get("endFrame", frame_count - 1)), 0, frame_count - 1),
		"contentRect": content_rect,
		"source": "preview-fallback",
	}


func _procedural_effect_preview_layer(
	slot_name: String,
	config: Dictionary,
	character_rect: Rect2,
	surface_size: Vector2
) -> Dictionary:
	if str(config.get("renderer", "")) != "procedural-rings-v1":
		return {}
	var color := Color.from_string(str(config.get("tint", "#22D3EE")), Color("#22D3EE"))
	var intensity := clampf(float(config.get("intensity", 80.0)) / 100.0, 0.05, 1.0)
	var speed := maxf(0.1, float(config.get("speedPermille", 1000.0)) / 1000.0)
	var scale_value := clampf(float(config.get("scale", 1.0)), 0.25, 4.0)
	var offset := Vector2(float(config.get("offsetX", 0.0)), float(config.get("offsetY", 0.0)))
	var root_position := character_rect.get_center()
	var canvas_size := Vector2i(256, 256)
	var canvas_anchor := Vector2(128.0, 128.0)
	var z_index := EffectPlacementResolver.default_z(slot_name)
	var svg := ""
	var base_hex := color.to_html(false)
	var light_hex := color.lightened(0.24).to_html(false)

	match slot_name:
		"bodyAura":
			canvas_anchor = Vector2(124.0, 132.0)
			# Starter Aura is intentionally body-only. Ground ellipses belong to the
			# independent Ground Rune slot and must never be baked into this preview.
			canvas_size = Vector2i(248, 264)
			root_position = Vector2(
				clampf(character_rect.get_center().x, 124.0, maxf(124.0, surface_size.x - 124.0)),
				clampf(character_rect.get_center().y, 128.0, maxf(128.0, surface_size.y - 128.0))
			)
			var pulse := 1.0 + sin(effect_preview_elapsed * 2.4 * speed) * 0.035
			scale_value *= pulse
			svg = """<svg xmlns="http://www.w3.org/2000/svg" width="248" height="264" viewBox="0 0 248 264">
<ellipse cx="124" cy="132" rx="112" ry="126" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="3.6"/>
<ellipse cx="124" cy="132" rx="94" ry="108" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="2.2"/>
</svg>""" % [base_hex, 0.62 * intensity, light_hex, 0.48 * intensity]
		"groundRune":
			canvas_size = Vector2i(260, 64)
			canvas_anchor = Vector2(130.0, 32.0)
			root_position = Vector2(
				clampf(character_rect.get_center().x, 124.0, maxf(124.0, surface_size.x - 124.0)),
				clampf(character_rect.end.y - 8.0, 24.0, maxf(24.0, surface_size.y - 24.0))
			)
			var rune_pulse := 1.0 + sin(effect_preview_elapsed * 1.8 * speed) * 0.025
			scale_value *= rune_pulse
			# Keep the CPU preview raster static and animate only the inexpensive
			# pulse. Runtime still rotates the live procedural node; rebuilding an
			# SVG every preview frame caused avoidable Character Manager jank.
			var parts := PackedStringArray([
				"""<svg xmlns="http://www.w3.org/2000/svg" width="260" height="64" viewBox="0 0 260 64"><g transform="translate(130 32)">""",
				"""<ellipse cx="0" cy="0" rx="122" ry="23" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="4"/>""" % [base_hex, 0.90 * intensity],
				"""<ellipse cx="0" cy="0" rx="101" ry="18" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="2"/>""" % [light_hex, 0.72 * intensity],
				"""<ellipse cx="0" cy="0" rx="72" ry="12" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="1.6"/>""" % [color.lightened(0.38).to_html(false), 0.58 * intensity],
			])
			for index in range(12):
				var angle := TAU * float(index) / 12.0
				var inner := Vector2(cos(angle) * 76.0, sin(angle) * 12.5)
				var outer := Vector2(cos(angle) * 116.0, sin(angle) * 21.0)
				var glyph := Vector2(cos(angle) * 95.0, sin(angle) * 16.0)
				parts.append("""<line x1="%f" y1="%f" x2="%f" y2="%f" stroke="#%s" stroke-opacity="%.4f" stroke-width="1.2"/>""" % [inner.x, inner.y, outer.x, outer.y, light_hex, 0.48 * intensity])
				parts.append("""<polygon points="%f,%f %f,%f %f,%f %f,%f" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="1.2"/>""" % [
					glyph.x, glyph.y - 2.5,
					glyph.x + 3.5, glyph.y,
					glyph.x, glyph.y + 2.5,
					glyph.x - 3.5, glyph.y,
					color.lightened(0.36).to_html(false), 0.78 * intensity
				])
			parts.append("</g></svg>")
			svg = "".join(parts)
		"levelUpBurst":
			# Match Runtime's ground-origin Level-Up contract: base ring at the feet,
			# rays fan upward. Keeping the whole procedural canvas above the anchor
			# prevents the clipped/half-visible burst seen with the old above-head
			# radial sprite.
			canvas_size = Vector2i(192, 168)
			canvas_anchor = Vector2(96.0, 150.0)
			root_position = Vector2(
				character_rect.get_center().x,
				character_rect.end.y - 8.0
			)
			var duration_ms := maxf(250.0, float(config.get("durationMs", 1400.0)))
			var phase := fmod(effect_preview_elapsed * 1000.0, duration_ms) / duration_ms
			var burst_scale := 0.62 + minf(1.0, phase * 3.0) * 0.46
			scale_value *= burst_scale
			var burst_parts := PackedStringArray([
				"""<svg xmlns="http://www.w3.org/2000/svg" width="192" height="168" viewBox="0 0 192 168"><g transform="translate(96 150)">"""
			])
			for index in range(11):
				var ratio := float(index) / 10.0
				var angle := lerpf(deg_to_rad(-160.0), deg_to_rad(-20.0), ratio)
				var inner := Vector2(cos(angle), sin(angle)) * 18.0
				var outer := Vector2(cos(angle), sin(angle)) * 80.0
				burst_parts.append("""<line x1="%f" y1="%f" x2="%f" y2="%f" stroke="#%s" stroke-opacity="%.4f" stroke-width="2.4"/>""" % [inner.x, inner.y, outer.x, outer.y, base_hex, 0.90 * intensity])
			burst_parts.append("""<ellipse cx="0" cy="0" rx="70" ry="14" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="3"/>""" % [color.lightened(0.22).to_html(false), 0.82 * intensity])
			burst_parts.append("""<ellipse cx="0" cy="0" rx="48" ry="9" fill="none" stroke="#%s" stroke-opacity="%.4f" stroke-width="1.8"/></g></svg>""" % [color.lightened(0.34).to_html(false), 0.62 * intensity])
			svg = "".join(burst_parts)
			z_index = int(config.get("zIndex", -20)) if effect_preview_variant == "starter-mist" else 4
		_:
			return {}

	var cache_key := "procedural|%s|%s|%d" % [slot_name, base_hex, int(round(intensity * 1000.0))]
	var base_image: Image = null
	var cached_value: Variant = effect_preview_sheet_cache.get(cache_key, {})
	if cached_value is Dictionary:
		var cached_image_value: Variant = (cached_value as Dictionary).get("image", null)
		if cached_image_value is Image and not (cached_image_value as Image).is_empty():
			base_image = cached_image_value as Image
	if base_image == null:
		base_image = Image.new()
		if base_image.load_svg_from_buffer(svg.to_utf8_buffer()) != OK or base_image.is_empty():
			return {}
		base_image.convert(Image.FORMAT_RGBA8)
		effect_preview_sheet_cache[cache_key] = {"image": base_image}
	var image := base_image.duplicate()
	if effect_preview_variant == "starter-mist" and slot_name == "bodyAura":
		var mist: Image = _comparison_renderer().mist(color, intensity, effect_preview_elapsed)
		if mist != null:
			image.fill(Color.TRANSPARENT)
			image.blend_rect(mist, Rect2i(Vector2i.ZERO, mist.get_size()), Vector2i(0, 4))
			image.blend_rect(base_image, Rect2i(Vector2i.ZERO, base_image.get_size()), Vector2i.ZERO)
	var target_width := maxi(1, int(round(float(canvas_size.x) * scale_value)))
	var target_height := maxi(1, int(round(float(canvas_size.y) * scale_value)))
	if image.get_width() != target_width or image.get_height() != target_height:
		image.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
	root_position += offset
	var anchor_scale := Vector2(
		float(target_width) / maxf(1.0, float(canvas_size.x)),
		float(target_height) / maxf(1.0, float(canvas_size.y))
	)
	var destination := root_position - canvas_anchor * anchor_scale
	return {
		"image": image,
		"position": Vector2i(int(round(destination.x)), int(round(destination.y))),
		"center": root_position,
		"z": z_index,
		"placementSource": "procedural-preview",
		"assetSource": "procedural-rings-v1",
	}


func _effect_preview_layer(slot_name: String, character_rect: Rect2, surface_size: Vector2, presentation_scale: float) -> Dictionary:
	var preview_character_id := str(preview_state.get("packageId", "")).strip_edges()
	var tuning_value: Variant = effect_preview_tuning.get(slot_name, {})
	var has_preview_tuning := tuning_value is Dictionary and not (tuning_value as Dictionary).is_empty()

	# Exact active-Runtime path. When the user has not changed Preview tuning,
	# capture the frame, position and scale from the actual EffectController node
	# instead of rebuilding the effect from package metadata. This guarantees the
	# baseline Character Manager preview is the same scene Runtime is rendering.
	if effect_preview_variant == "equipped" and not has_preview_tuning and is_instance_valid(effect_controller) and effect_controller.has_method("capture_live_effect_preview_layer"):
		var live_value: Variant = effect_controller.call("capture_live_effect_preview_layer", slot_name, preview_character_id)
		if live_value is Dictionary and not (live_value as Dictionary).is_empty():
			var live := live_value as Dictionary
			var live_image: Image = live.get("image") as Image
			if live_image != null and not live_image.is_empty():
				var frame := live_image.duplicate()
				var live_scale: Vector2 = live.get("scale", Vector2.ONE)
				var target_width := maxi(1, int(round(float(frame.get_width()) * live_scale.x)))
				var target_height := maxi(1, int(round(float(frame.get_height()) * live_scale.y)))
				frame.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
				var live_config_value: Variant = live.get("config", {})
				var live_config: Dictionary = live_config_value if live_config_value is Dictionary else {}
				if not live_config.is_empty():
					frame = _tint_effect_preview_image(
						frame,
						Color.from_string(str(live_config.get("tint", "#FFFFFF")), Color.WHITE),
						clampf(float(live_config.get("intensity", 100.0)) / 100.0, 0.0, 1.0),
						bool(live_config.get("_colorize", false))
					)
				var effect_position: Vector2 = live.get("position", character_rect.get_center())
				var destination := Vector2i(
					int(round(effect_position.x - float(target_width) * 0.5)),
					int(round(effect_position.y - float(target_height) * 0.5))
				)
				return {
					"image": frame,
					"position": destination,
					"center": effect_position,
					"z": int(live.get("z", EffectPlacementResolver.default_z(slot_name))),
					"placementSource": "runtime-live-node",
					"assetSource": "runtime-live-frame",
				}

	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service):
		return {}
	var resolver := "resolve_slot_for_preview" if service.has_method("resolve_slot_for_preview") else "resolve_slot"
	if not service.has_method(resolver):
		return {}
	# "Play All" mirrors the live enabled loadout. A single-slot preview is an
	# editor inspection mode and may render an equipped slot even when disabled,
	# so users can preview Starter FX before turning it on.
	var include_disabled := effect_preview_mode == slot_name
	var resolved_value: Variant = service.call(resolver, slot_name, include_disabled, preview_character_id) if effect_preview_variant == "equipped" else effect_comparison_sources.get(slot_name, {})
	if not resolved_value is Dictionary:
		return {}
	var resolved := resolved_value as Dictionary
	if resolved.is_empty():
		return {}
	var config_value: Variant = resolved.get("config", {})
	if not config_value is Dictionary:
		return {}
	var config := (config_value as Dictionary).duplicate(true)
	if effect_preview_variant == "equipped" and tuning_value is Dictionary:
		var tuning := tuning_value as Dictionary
		for key in ["fps", "startFrame", "endFrame", "scale", "offsetX", "offsetY", "anchor", "scaleMode"]:
			if tuning.has(key):
				config[key] = tuning[key]
	var renderer := str(config.get("renderer", ""))
	if renderer == "procedural-rings-v1":
		if effect_preview_variant == "starter-mist" and slot_name == "levelUpBurst" and effect_preview_elapsed * 1000.0 >= float(config.get("durationMs", 1400)):
			return {}
		return _procedural_effect_preview_layer(slot_name, config, character_rect, surface_size)
	if renderer != "sprite-sheet-2d":
		return {}

	var asset := _effect_preview_asset(resolved, config)
	if asset.is_empty():
		return {}
	var sheet: Image = asset.get("image") as Image
	if sheet == null or sheet.is_empty():
		return {}
	var frame_width := maxi(1, int(asset.get("frameWidth", 1)))
	var frame_height := maxi(1, int(asset.get("frameHeight", 1)))
	var columns := maxi(1, int(asset.get("columns", 1)))
	var rows := maxi(1, int(asset.get("rows", 1)))
	var frame_count := clampi(int(asset.get("frameCount", 1)), 1, columns * rows)
	var start_frame := clampi(int(asset.get("startFrame", config.get("startFrame", 0))), 0, frame_count - 1)
	var end_frame := clampi(int(asset.get("endFrame", config.get("endFrame", frame_count - 1))), start_frame, frame_count - 1)
	var tuned_frame_count := maxi(1, end_frame - start_frame + 1)
	var fps := clampf(float(config.get("fps", 12.0)) * maxf(0.1, float(config.get("speedPermille", 1000)) / 1000.0), 0.1, 60.0)
	var raw_index := maxi(0, int(floor(effect_preview_elapsed * fps)))
	var looped := bool(config.get("looped", slot_name != "levelUpBurst"))
	if effect_preview_variant != "equipped" and not looped and raw_index >= tuned_frame_count:
		return {}
	var frame_index := start_frame + (posmod(raw_index, tuned_frame_count) if looped else mini(raw_index, tuned_frame_count - 1))
	var row := frame_index / columns
	var frame_rect := Rect2i((frame_index % columns) * frame_width, row * frame_height, frame_width, frame_height)
	frame_rect = frame_rect.intersection(Rect2i(Vector2i.ZERO, sheet.get_size()))
	if frame_rect.size.x <= 0 or frame_rect.size.y <= 0:
		return {}
	var frame := sheet.get_region(frame_rect)
	if effect_preview_variant == "video-blend":
		var following := start_frame + (posmod(raw_index + 1, tuned_frame_count) if looped else mini(raw_index + 1, tuned_frame_count - 1))
		var next_rect := Rect2i((following % columns) * frame_width, (following / columns) * frame_height, frame_width, frame_height)
		frame = _comparison_renderer().blend(sheet, slot_name, frame_rect, next_rect, fposmod(effect_preview_elapsed * fps, 1.0))
	if frame == null or frame.is_empty():
		return {}
	var content_rect: Rect2 = asset.get("contentRect", Rect2(Vector2.ZERO, Vector2(frame_width, frame_height)))

	var placement := _runtime_effect_preview_placement(
		slot_name,
		config,
		content_rect,
		Vector2(frame_width, frame_height),
		character_rect,
		surface_size,
		presentation_scale
	)
	var scale_vector: Vector2 = placement.get("scale", Vector2.ONE)
	var target_width := maxi(1, int(round(float(frame_width) * scale_vector.x)))
	var target_height := maxi(1, int(round(float(frame_height) * scale_vector.y)))
	frame.resize(target_width, target_height, Image.INTERPOLATE_LANCZOS)
	frame = _tint_effect_preview_image(
		frame,
		Color.from_string(str(config.get("tint", "#FFFFFF")), Color.WHITE),
		clampf(float(config.get("intensity", 100.0)) / 100.0, 0.0, 1.0),
		bool(config.get("_colorize", false))
	)
	var effect_position: Vector2 = placement.get("position", character_rect.get_center())
	var destination := Vector2i(
		int(round(effect_position.x - float(target_width) * 0.5)),
		int(round(effect_position.y - float(target_height) * 0.5))
	)
	return {
		"image": frame,
		"position": destination,
		"center": effect_position,
		"z": int(placement.get("z", EffectPlacementResolver.default_z(slot_name))),
		"placementSource": str(placement.get("source", "preview")),
		"assetSource": str(asset.get("source", "preview-fallback")),
	}


func _effect_preview_sheet(resolved: Dictionary) -> Dictionary:
	var package_path := str(resolved.get("path", "")).strip_edges()
	var config_value: Variant = resolved.get("config", {})
	if package_path.is_empty() or not config_value is Dictionary:
		return {}
	var config := config_value as Dictionary
	var asset_path := str(config.get("asset", "")).strip_edges()
	if asset_path.is_empty():
		return {}
	var image_path := package_path.path_join(asset_path)
	var cache_key := "%s|%s" % [package_path, asset_path]
	var cached_value: Variant = effect_preview_sheet_cache.get(cache_key, {})
	if cached_value is Dictionary and not (cached_value as Dictionary).is_empty():
		return cached_value as Dictionary
	if not FileAccess.file_exists(image_path):
		return {}
	var image := Image.load_from_file(image_path)
	if image == null or image.is_empty():
		return {}
	image.convert(Image.FORMAT_RGBA8)
	var ratio := 1.0
	var max_dimension := maxi(image.get_width(), image.get_height())
	if max_dimension > EFFECT_PREVIEW_MAX_SHEET_DIMENSION:
		ratio = float(EFFECT_PREVIEW_MAX_SHEET_DIMENSION) / float(max_dimension)
		image.resize(
			maxi(1, int(round(float(image.get_width()) * ratio))),
			maxi(1, int(round(float(image.get_height()) * ratio))),
			Image.INTERPOLATE_LANCZOS
		)
	var entry := {"image": image, "ratio": ratio, "inferredBoundsCache": {}}
	effect_preview_sheet_cache[cache_key] = entry
	return entry


func _tint_effect_preview_image(image: Image, tint: Color, intensity: float, colorize: bool = false) -> Image:
	var result := image.duplicate()
	result.convert(Image.FORMAT_RGBA8)
	var data: PackedByteArray = result.get_data()
	for index in range(0, data.size(), 4):
		if data[index + 3] == 0:
			continue
		if colorize:
			var luminance := maxf(float(data[index]), maxf(float(data[index + 1]), float(data[index + 2]))) / 255.0
			data[index] = clampi(int(round(255.0 * tint.r * luminance)), 0, 255)
			data[index + 1] = clampi(int(round(255.0 * tint.g * luminance)), 0, 255)
			data[index + 2] = clampi(int(round(255.0 * tint.b * luminance)), 0, 255)
		else:
			data[index] = clampi(int(round(float(data[index]) * tint.r)), 0, 255)
			data[index + 1] = clampi(int(round(float(data[index + 1]) * tint.g)), 0, 255)
			data[index + 2] = clampi(int(round(float(data[index + 2]) * tint.b)), 0, 255)
		data[index + 3] = clampi(int(round(float(data[index + 3]) * intensity)), 0, 255)
	result.set_data(result.get_width(), result.get_height(), false, Image.FORMAT_RGBA8, data)
	return result


func _blend_preview_image(target: Image, source: Image, destination: Vector2i) -> void:
	if source == null or source.is_empty():
		return
	var target_bounds := Rect2i(Vector2i.ZERO, target.get_size())
	var placed := Rect2i(destination, source.get_size())
	var clipped := placed.intersection(target_bounds)
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	var source_offset := clipped.position - placed.position
	target.blend_rect(source, Rect2i(source_offset, clipped.size), clipped.position)


func _preview_frame_index(frame_count: int) -> int:
	var animation_speed := maxf(0.01, float(preview_active_payload.get("fps", 8.0)))
	var elapsed_index := int(floor(preview_elapsed * animation_speed * float(preview_state.get("speed", 1.0))))
	if bool(preview_state.get("loop", false)):
		return posmod(elapsed_index, frame_count)
	if elapsed_index >= frame_count - 1:
		preview_state["isPlaying"] = false
		preview_state["status"] = "paused"
	return mini(elapsed_index, frame_count - 1)


func _image_for_preview_texture(texture: Texture2D, animation_key: String = "") -> Image:
	if texture is AtlasTexture:
		var atlas_texture := texture as AtlasTexture
		if atlas_texture.atlas == null:
			return null
		var atlas_image: Image = null
		if not animation_key.is_empty():
			var cached: Variant = preview_atlas_image_cache.get(animation_key, null)
			if cached is Image:
				atlas_image = cached as Image
		if atlas_image == null or atlas_image.is_empty():
			atlas_image = atlas_texture.atlas.get_image()
			if atlas_image == null or atlas_image.is_empty():
				return null
			if not animation_key.is_empty():
				var atlas_bytes := atlas_image.get_data_size()
				# A large source atlas may be needed transiently to extract one frame,
				# but never keep it resident if it would blow the Character Manager's
				# bounded CPU-image cache.
				if atlas_bytes <= PREVIEW_ATLAS_IMAGE_CACHE_BYTES:
					preview_atlas_image_cache[animation_key] = atlas_image
					preview_atlas_image_cache_bytes += atlas_bytes
					preview_atlas_image_order.erase(animation_key)
					preview_atlas_image_order.append(animation_key)
					while preview_atlas_image_order.size() > PREVIEW_ATLAS_IMAGE_CACHE_LIMIT \
					or preview_atlas_image_cache_bytes > PREVIEW_ATLAS_IMAGE_CACHE_BYTES:
						var evicted_key: String = preview_atlas_image_order.pop_front()
						var evicted_value: Variant = preview_atlas_image_cache.get(evicted_key, null)
						if evicted_value is Image:
							preview_atlas_image_cache_bytes = maxi(0, preview_atlas_image_cache_bytes - (evicted_value as Image).get_data_size())
						preview_atlas_image_cache.erase(evicted_key)
		elif not animation_key.is_empty():
			preview_atlas_image_order.erase(animation_key)
			preview_atlas_image_order.append(animation_key)
		return atlas_image.get_region(Rect2i(atlas_texture.region.position, atlas_texture.region.size))
	return texture.get_image()


func _preview_trim_rect_for_animation(animation: StringName) -> Rect2i:
	var cache_key := str(animation)
	var cached: Variant = preview_trim_rect_cache.get(cache_key, null)
	if cached is Rect2i:
		return cached
	if preview_frames == null or animation.is_empty() or not preview_frames.has_animation(animation):
		return Rect2i()
	var frame_count := preview_frames.get_frame_count(animation)
	if frame_count <= 0:
		return Rect2i()
	var found := false
	var x0 := 0
	var y0 := 0
	var x1 := 0
	var y1 := 0
	for frame_index in range(frame_count):
		var texture := preview_frames.get_frame_texture(animation, frame_index)
		if texture == null:
			continue
		var image := _image_for_preview_texture(texture, str(animation))
		if image == null or image.is_empty():
			continue
		var used := image.get_used_rect()
		if used.size.x <= 0 or used.size.y <= 0:
			continue
		if not found:
			x0 = used.position.x
			y0 = used.position.y
			x1 = used.end.x
			y1 = used.end.y
			found = true
		else:
			x0 = mini(x0, used.position.x)
			y0 = mini(y0, used.position.y)
			x1 = maxi(x1, used.end.x)
			y1 = maxi(y1, used.end.y)
	var result := Rect2i(x0, y0, x1 - x0, y1 - y0) if found else Rect2i()
	preview_trim_rect_cache[cache_key] = result
	return result


func _trim_preview_transparency(image: Image, stable_used_rect: Rect2i = Rect2i()) -> Image:
	# Use one union alpha-bounds rectangle for the whole animation. Cropping each
	# frame independently changes the projected PNG dimensions and creates fake
	# bobbing/zooming in Desktop Shell even when the authored root is stationary.
	var used_rect := stable_used_rect if stable_used_rect.size.x > 0 and stable_used_rect.size.y > 0 else image.get_used_rect()
	if used_rect.size.x <= 0 or used_rect.size.y <= 0:
		return image
	used_rect = used_rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if used_rect.size.x <= 0 or used_rect.size.y <= 0:
		return image
	var padding := 4
	var x0 := maxi(0, used_rect.position.x - padding)
	var y0 := maxi(0, used_rect.position.y - padding)
	var x1 := mini(image.get_width(), used_rect.end.x + padding)
	var y1 := mini(image.get_height(), used_rect.end.y + padding)
	return image.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))


func _scale_preview_image(image: Image) -> void:
	if image.get_width() <= MAX_PREVIEW_FRAME_WIDTH and image.get_height() <= MAX_PREVIEW_FRAME_HEIGHT:
		return
	var factor := minf(
		float(MAX_PREVIEW_FRAME_WIDTH) / float(image.get_width()),
		float(MAX_PREVIEW_FRAME_HEIGHT) / float(image.get_height())
	)
	image.resize(maxi(1, int(round(image.get_width() * factor))), maxi(1, int(round(image.get_height() * factor))), Image.INTERPOLATE_LANCZOS)


func _preview_state_without_media() -> Dictionary:
	var projection := preview_state.duplicate(true)
	projection["clipThumbnailPngBase64"] = {}
	projection["framePngBase64"] = ""
	projection["frameWidth"] = 0
	projection["frameHeight"] = 0
	return projection


func _write_preview_media() -> void:
	if session_directory.is_empty():
		return
	preview_media_revision += 1
	var destination := session_directory.path_join("preview-media.json")
	var temporary := session_directory.path_join("preview-media.json.tmp")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return

	# Keep peak allocations bounded while the preview is animating. Building one
	# large Dictionary and JSON.stringify()-ing it every frame duplicated all
	# thumbnail/frame base64 strings at up to MAX_PREVIEW_OUTPUT_FPS. On Windows
	# ARM64 this could exhaust Godot's allocator and crash with alloc_static(null).
	# Stream the same schema field-by-field so only one media string is copied at
	# a time while preserving the atomic preview-media.json contract.
	file.store_string("{\"schemaVersion\":")
	file.store_string(str(PREVIEW_MEDIA_SCHEMA_VERSION))
	file.store_string(",\"revision\":")
	file.store_string(str(preview_media_revision))
	file.store_string(",\"packageId\":")
	file.store_string(JSON.stringify(str(preview_state.get("packageId", ""))))
	file.store_string(",\"version\":")
	file.store_string(JSON.stringify(str(preview_state.get("version", ""))))
	file.store_string(",\"selectedAnimation\":")
	file.store_string(JSON.stringify(str(preview_state.get("selectedAnimation", ""))))
	file.store_string(",\"clipThumbnailPngBase64\":{")

	var thumbnails_value: Variant = preview_state.get("clipThumbnailPngBase64", {})
	var thumbnails: Dictionary = thumbnails_value if thumbnails_value is Dictionary else {}
	var thumbnail_index := 0
	for animation_value in thumbnails.keys():
		if thumbnail_index > 0:
			file.store_string(",")
		file.store_string(JSON.stringify(str(animation_value)))
		file.store_string(":")
		file.store_string(JSON.stringify(str(thumbnails.get(animation_value, ""))))
		thumbnail_index += 1

	file.store_string("},\"framePngBase64\":")
	file.store_string(JSON.stringify(str(preview_state.get("framePngBase64", ""))))
	file.store_string(",\"frameWidth\":")
	file.store_string(str(int(preview_state.get("frameWidth", 0))))
	file.store_string(",\"frameHeight\":")
	file.store_string(str(int(preview_state.get("frameHeight", 0))))
	file.store_string("}")
	file.flush()
	file.close()

	var rename_error := DirAccess.rename_absolute(temporary, destination)
	if rename_error != OK:
		DirAccess.remove_absolute(destination)
		rename_error = DirAccess.rename_absolute(temporary, destination)
	if rename_error != OK:
		push_warning("DesktopShellFunctionalAdapter: atomic preview media replace failed (%s)" % rename_error)


func _write_snapshot(status: String = "connected") -> void:
	if session_directory.is_empty() or snapshot_projection_in_progress:
		return
	var snapshot_started_at_msec := Time.get_ticks_msec()
	chat_stream_snapshot_pending = false
	chat_stream_snapshot_not_before_msec = 0
	snapshot_projection_in_progress = true
	var refresh_started_at_msec := Time.get_ticks_msec()
	_refresh_chat_presentation()
	var refresh_elapsed_msec := Time.get_ticks_msec() - refresh_started_at_msec
	snapshot_projection_in_progress = false
	var projection_started_at_msec := Time.get_ticks_msec()
	var state := {
		"schemaVersion": SCHEMA_VERSION,
		"status": status if status in ["connected", "unavailable"] else "connected",
		"appearance": _appearance_snapshot(),
		"characters": _character_snapshot(),
		"progression": _progression_snapshot(),
		"effectPacks": _effect_pack_snapshot(),
		"account": _account_snapshot(),
		"cloud": _cloud_snapshot(),
		"chat": {
			"providerId": _provider_id(),
			"status": chat_status,
			"messages": chat_messages.duplicate(true),
			"presentationState": _chat_presentation_state(),
			"sessionId": chat_session_id,
			"revision": chat_revision,
			"activeMessageId": chat_active_message_id,
			"presentation": chat_presentation_state.duplicate(true),
		},
		"preview": _preview_state_without_media(),
		"controlCenter": {
			"settings": _control_settings_snapshot(),
			"resources": _resource_snapshot(),
			"ai": _ai_control_snapshot(),
			"updates": _update_control_snapshot(),
		},
		"commandResults": command_results.duplicate(true),
		"voice": _voice_health_snapshot(),
	}
	var projection_elapsed_msec := Time.get_ticks_msec() - projection_started_at_msec
	var io_started_at_msec := Time.get_ticks_msec()
	var destination := session_directory.path_join("state.json")
	var temporary := session_directory.path_join("state.json.tmp")
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(state))
		file.flush()
		file.close()
		var rename_error := DirAccess.rename_absolute(temporary, destination)
		if rename_error != OK:
			# Some Windows filesystems do not replace an existing destination with
			# rename. Electron keeps its last authenticated snapshot during this
			# bounded fallback gap, so readers never observe a false disconnect.
			DirAccess.remove_absolute(destination)
			rename_error = DirAccess.rename_absolute(temporary, destination)
		if rename_error != OK:
			push_warning("DesktopShellFunctionalAdapter: atomic snapshot replace failed (%s)" % rename_error)
	var io_elapsed_msec := Time.get_ticks_msec() - io_started_at_msec
	chat_stream_last_snapshot_msec = Time.get_ticks_msec()
	var snapshot_elapsed_msec := chat_stream_last_snapshot_msec - snapshot_started_at_msec
	if snapshot_elapsed_msec >= 50:
		print("[DesktopShellTiming] snapshot_slow_ms=%d refresh_ms=%d projection_ms=%d io_ms=%d chat_status=%s messages=%d" % [
			snapshot_elapsed_msec,
			refresh_elapsed_msec,
			projection_elapsed_msec,
			io_elapsed_msec,
			chat_status,
			chat_messages.size(),
		])


func _chat_presentation_state() -> String:
	# _write_snapshot() refreshes presentation exactly once before assembling the
	# payload. Keep this accessor side-effect free so a Chat submit cannot trigger
	# the preview loader twice in the same snapshot projection.
	return str(chat_presentation_state.get("state", "idle"))


func _refresh_chat_presentation() -> void:
	var voice_status := str(_voice_health_snapshot().get("status", "idle"))
	var next_state := "idle"
	var reason_code := "ready"
	var message_id := ""
	var speech_id := ""
	if voice_status == "playing":
		next_state = "talk"
		reason_code = "voice-playing"
		message_id = active_voice_message_id
		speech_id = active_speech_id
	elif chat_status == "thinking":
		next_state = "think"
		reason_code = "turn-active"
		message_id = chat_active_message_id
	elif voice_status == "synthesizing" or not pending_voice_requests.is_empty():
		next_state = "think"
		reason_code = "voice-synthesizing"
		message_id = active_voice_message_id
		speech_id = active_speech_id
	elif voice_status in ["degraded", "failed"]:
		reason_code = "voice-failed"
	var next_owner := "chat" if chat_presentation_active else "native"
	var changed := next_owner != str(chat_presentation_state.get("owner", "native")) \
		or next_state != str(chat_presentation_state.get("state", "idle")) \
		or chat_active_message_id != str(chat_presentation_state.get("turnId", "")) \
		or message_id != str(chat_presentation_state.get("messageId", "")) \
		or speech_id != str(chat_presentation_state.get("speechId", "")) \
		or reason_code != str(chat_presentation_state.get("reasonCode", "ready"))
	if changed:
		chat_presentation_sequence += 1
		chat_presentation_state = {
			"owner": next_owner,
			"state": next_state,
			"sequence": chat_presentation_sequence,
			"turnId": chat_active_message_id,
			"messageId": message_id,
			"speechId": speech_id,
			"reasonCode": reason_code,
		}
	if next_owner == "chat":
		_sync_chat_preview(next_state)


func _sync_chat_preview(state: String) -> void:
	# Chat only needs the already-active package identity here. Calling
	# PackageService.get_active() re-runs full installed-package verification on
	# every snapshot; on the current managed Sabai package that costs ~2.5-2.8 s
	# and blocks both Chat close and Ollama polling. Prefer Runtime's committed
	# identity, then the CharacterService's verified active projection. A cheap
	# persisted candidate is only a final fallback; _open_preview() still performs
	# the normal trusted package lookup before reading any preview asset.
	var package_id := ""
	var version := ""
	if is_instance_valid(context):
		package_id = str(context.package.get("active_id", "")).strip_edges()
		version = str(context.package.get("active_version", "")).strip_edges()
	if package_id.is_empty() or version.is_empty():
		var character_service := _service(&"character_service")
		if is_instance_valid(character_service) and character_service.has_method("get_active_verified_package_info"):
			var verified_value: Variant = character_service.call("get_active_verified_package_info")
			if verified_value is Dictionary:
				var verified := verified_value as Dictionary
				package_id = str(verified.get("packageId", "")).strip_edges()
				version = str(verified.get("version", "")).strip_edges()
	if package_id.is_empty() or version.is_empty():
		var package_service := _service(&"package_service")
		if is_instance_valid(package_service) and package_service.has_method("get_active_candidate"):
			var candidate_value: Variant = package_service.call("get_active_candidate")
			if candidate_value is Dictionary:
				var candidate := candidate_value as Dictionary
				package_id = str(candidate.get("packageId", "")).strip_edges()
				version = str(candidate.get("version", "")).strip_edges()
	if package_id.is_empty() or version.is_empty():
		return
	if str(preview_state.get("packageId", "")) != package_id or str(preview_state.get("version", "")) != version or preview_package_info.is_empty():
		_open_preview({"type": "character.preview.open", "packageId": package_id, "version": version})
	if not _preview_identity_matches({"packageId": package_id, "version": version}):
		return
	var candidates := ["idle"]
	if state == "think":
		candidates = ["think", "thinking", "idle"]
	elif state == "talk":
		candidates = ["speak", "talk", "happy", "idle"]
	var selected := ""
	var clips: Array = preview_state.get("clips", [])
	for candidate in candidates:
		if clips.has(candidate):
			selected = candidate
			break
	if selected.is_empty() and not clips.is_empty():
		selected = str(clips[0])
	if selected.is_empty():
		return
	var selection_changed := selected != str(preview_state.get("selectedAnimation", ""))
	preview_animation_loops[selected] = true
	# Atomic swap deliberately keeps the old selectedAnimation/frame visible while
	# the replacement is loading. During that window snapshot projection can run
	# many times; treat the requested/in-flight clip as already synchronized instead
	# of requesting it again and recursively writing another snapshot.
	var selected_request_pending := selected == preview_requested_animation
	var selected_load_inflight := preview_load_thread != null \
		and preview_load_animation == selected \
		and preview_load_generation == preview_generation
	if selected_request_pending or selected_load_inflight:
		preview_requested_animation = selected
		preview_requested_playing = true
		if selected_load_inflight:
			preview_load_is_prefetch = false
		_start_preview_load_if_idle()
		return
	# Chat presentation refresh runs while state.json is being projected. Once the
	# requested clip is already active, do not route it through the preview loader
	# again: the memory-cache path activates synchronously and writes another
	# snapshot, which would re-enter this function and recurse indefinitely.
	var selected_payload_active := not preview_active_payload.is_empty() \
		and str(preview_active_payload.get("animation", "")) == selected
	if not selection_changed and selected_payload_active:
		var playback_changed := not bool(preview_state.get("loop", false)) \
			or not bool(preview_state.get("isPlaying", false)) \
			or str(preview_state.get("status", "")) != "playing"
		preview_state["loop"] = true
		preview_state["isPlaying"] = true
		preview_state["status"] = "playing"
		if playback_changed:
			_write_preview_media()
		return
	if not _request_preview_animation(selected, true):
		return


func _appearance_snapshot() -> Dictionary:
	var settings: Dictionary = context.settings if is_instance_valid(context) else {}
	var font_name := str(settings.get("font_family", "Noto Sans Thai"))
	var font_key := "inter" if font_name == "Inter" else ("noto-sans-thai" if font_name == "Noto Sans Thai" else ("atkinson" if font_name == "Atkinson Hyperlegible" else "system"))
	var scale_key := "standard"
	var requested_scale := float(settings.get("text_scale", 1.15))
	for key in TEXT_SCALES:
		if is_equal_approx(float(TEXT_SCALES[key]), requested_scale):
			scale_key = key
	return {"theme": str(settings.get("theme_preset", "solid")), "locale": str(settings.get("language", "en")), "fontFamily": font_key, "textScale": scale_key, "reduceMotion": bool(settings.get("reduce_motion", false))}


func _control_settings_snapshot() -> Dictionary:
	var settings: Dictionary = context.settings if is_instance_valid(context) else {}
	var runtime_config: Dictionary = context.runtime_config if is_instance_valid(context) else {}
	var font_family := str(settings.get("font_family", "Noto Sans Thai"))
	if font_family not in CONTROL_FONT_FAMILIES:
		font_family = "Noto Sans Thai"
	var scale_key := "standard"
	var requested_scale := float(settings.get("text_scale", 1.15))
	for key in TEXT_SCALES:
		if is_equal_approx(float(TEXT_SCALES[key]), requested_scale):
			scale_key = key
	var bubble_style := str(settings.get("bubble_style", "Rounded"))
	if bubble_style not in BUBBLE_STYLES:
		bubble_style = "Rounded"
	var update_channel := str(settings.get("update_channel", "stable")).to_lower()
	if update_channel in ["beta", "nightly"]:
		update_channel = "preview"
	if update_channel not in UPDATE_CHANNELS:
		update_channel = "stable"
	return {
		"themePreset": str(settings.get("theme_preset", "solid")),
		"fontFamily": font_family,
		"textScale": scale_key,
		"bubbleStyle": bubble_style,
		"language": "th" if str(settings.get("language", "en")).to_lower().begins_with("th") else "en",
		"showBubbles": bool(settings.get("show_bubbles", true)),
		"clickThroughEnabled": bool(settings.get("click_through_enabled", runtime_config.get("click_through_enabled", true))),
		"startWithWindows": bool(settings.get("start_with_windows", false)),
		"offlinePresenceEnabled": bool(settings.get("offline_presence_enabled", true)),
		"llmCompanionModeEnabled": bool(settings.get("llm_companion_mode_enabled", false)),
		"updateChannel": update_channel,
		"automaticUpdateChecks": bool(settings.get("automatic_update_checks", true)),
		"reduceMotion": bool(settings.get("reduce_motion", false)),
	}


func _resource_snapshot() -> Dictionary:
	var runtime_config: Dictionary = context.runtime_config if is_instance_valid(context) else {}
	var value: Variant = runtime_config.get("resource_monitor", {})
	var source: Dictionary = value if value is Dictionary else {}
	var available := bool(source.get("available", false))
	var pressure := str(source.get("pressure", "unavailable"))
	if not available:
		return {
			"available": false,
			"cpuPercent": 0.0,
			"memoryPercent": 0.0,
			"ocpMemoryMb": 0.0,
			"runtimeMemoryMb": 0.0,
			"desktopShellMemoryMb": 0.0,
			"kernelMemoryMb": 0.0,
			"nativeHostMemoryMb": 0.0,
			"aiMemoryMb": 0.0,
			"pressure": "unavailable",
			"sampledAtMs": 0,
		}
	if pressure not in ["normal", "high"]:
		pressure = "normal"
	return {
		"available": true,
		# These percentages intentionally describe the whole machine. OCP-owned
		# memory is reported separately below in MiB to avoid misleading users.
		"cpuPercent": clampf(float(source.get("system_cpu_percent", source.get("cpu_percent", 0.0))), 0.0, 100.0),
		"memoryPercent": clampf(float(source.get("system_memory_percent", source.get("memory_percent", 0.0))), 0.0, 100.0),
		"ocpMemoryMb": maxf(0.0, float(source.get("ocp_memory_mb", 0.0))),
		"runtimeMemoryMb": maxf(0.0, float(source.get("runtime_memory_mb", 0.0))),
		"desktopShellMemoryMb": maxf(0.0, float(source.get("desktop_shell_memory_mb", 0.0))),
		"kernelMemoryMb": maxf(0.0, float(source.get("kernel_memory_mb", 0.0))),
		"nativeHostMemoryMb": maxf(0.0, float(source.get("native_host_memory_mb", 0.0))),
		"aiMemoryMb": maxf(0.0, float(source.get("ai_memory_mb", 0.0))),
		"pressure": pressure,
		"sampledAtMs": maxi(0, int(source.get("sampled_at_ms", 0))),
	}


func _ai_control_snapshot() -> Dictionary:
	var settings: Dictionary = context.settings if is_instance_valid(context) else {}
	var provider_id := str(settings.get("ai_provider_id", "offline")).strip_edges().to_lower()
	if provider_id not in AI_PROVIDER_IDS:
		provider_id = "offline"
	var timeout_seconds := int(settings.get("ai_timeout_seconds", 45))
	if timeout_seconds not in AI_TIMEOUT_SECONDS:
		timeout_seconds = 45
	var chat_voice_mode := str(settings.get("chat_voice_mode", "on-demand")).strip_edges().to_lower()
	if chat_voice_mode not in CHAT_VOICE_MODES:
		chat_voice_mode = "on-demand"
	var tts_provider_id := str(settings.get("tts_provider_id", "auto")).strip_edges().to_lower()
	if tts_provider_id not in TTS_PROVIDER_IDS:
		tts_provider_id = "auto"
	var tts_model := str(settings.get("tts_model", DEFAULT_TTS_MODEL_ID)).strip_edges()
	if tts_model not in TTS_MODEL_IDS:
		tts_model = DEFAULT_TTS_MODEL_ID
	var tts_voice := str(settings.get("tts_voice", "auto")).strip_edges()
	if tts_voice not in TTS_VOICE_IDS:
		tts_voice = "auto"
	var tts_voice_mode := str(settings.get("tts_voice_mode", "character")).strip_edges().to_lower()
	if tts_voice_mode not in TTS_VOICE_MODES:
		tts_voice_mode = "character"
	var tts_voice_gender := str(settings.get("tts_voice_gender", "neutral")).strip_edges().to_lower()
	if tts_voice_gender not in TTS_VOICE_GENDERS:
		tts_voice_gender = "neutral"
	var tts_voice_age := str(settings.get("tts_voice_age", "adult")).strip_edges().to_lower()
	if tts_voice_age not in TTS_VOICE_AGES:
		tts_voice_age = "adult"
	var thai_speech_style := str(settings.get("thai_speech_style", "neutral")).strip_edges().to_lower()
	if thai_speech_style not in THAI_SPEECH_STYLES:
		thai_speech_style = "neutral"
	# In character mode project the effective validated Character/3 values, not
	# dormant custom overrides. This lets Electron explain which identity is
	# active without widening the authenticated snapshot contract.
	if tts_voice_mode == "character" and is_instance_valid(context) and context.has_method("snapshot"):
		# Provider-specific personas are inactive in Character mode. Project Auto
		# so the Control Center cannot imply that a stale legacy persona is active.
		tts_voice = "auto"
		var context_snapshot_value: Variant = context.call("snapshot")
		var context_snapshot: Dictionary = context_snapshot_value if context_snapshot_value is Dictionary else {}
		var character_value: Variant = context_snapshot.get("character", {})
		var character: Dictionary = character_value if character_value is Dictionary else {}
		var profile_value: Variant = character.get("voice_profile", {})
		var profile: Dictionary = profile_value if profile_value is Dictionary else {}
		var profile_gender := str(profile.get("gender", "neutral")).strip_edges().to_lower()
		var profile_age := str(profile.get("age", "adult")).strip_edges().to_lower()
		var profile_thai_style := str(profile.get("thaiSpeechStyle", "neutral")).strip_edges().to_lower()
		if profile_gender in TTS_VOICE_GENDERS:
			tts_voice_gender = profile_gender
		if profile_age in TTS_VOICE_AGES:
			tts_voice_age = profile_age
		if profile_thai_style in THAI_SPEECH_STYLES:
			thai_speech_style = profile_thai_style
	var base_url := str(settings.get("ai_base_url", "")).strip_edges()
	if not _bounded_control_text(base_url, 2048):
		base_url = ""
	var model := str(settings.get("ai_model", "")).strip_edges()
	if not _bounded_control_text(model, 160):
		model = ""
	var provider_status: Dictionary = {}
	var ai_service := _service(&"ai_service")
	if is_instance_valid(ai_service) and ai_service.has_method("provider_status"):
		var status_value: Variant = ai_service.call("provider_status")
		if status_value is Dictionary:
			provider_status = status_value
	return {
		"settings": {
			"providerId": provider_id,
			"baseUrl": base_url,
			"model": model,
			"timeoutSeconds": timeout_seconds,
			"ttsEnabled": bool(settings.get("tts_enabled", false)),
			"chatVoiceMode": chat_voice_mode,
			"ttsProviderId": tts_provider_id,
			"ttsModel": tts_model,
			"ttsVoice": tts_voice,
			"ttsVoiceMode": tts_voice_mode,
			"ttsVoiceGender": tts_voice_gender,
			"ttsVoiceAge": tts_voice_age,
			"thaiSpeechStyle": thai_speech_style,
		},
		"provider": {
			"providerId": provider_id,
			"available": is_instance_valid(ai_service),
			"configured": bool(provider_status.get("configured", provider_id == "offline")),
			"reachable": bool(provider_status.get("reachable", provider_id == "offline")),
			"test": ai_test_state.duplicate(true),
		},
		"credentials": {
			"brokerAvailable": _credential_broker_available(),
			"openAiCompatiblePresent": _credential_present("openai-compatible"),
			"geminiPresent": _credential_present("gemini-cloud"),
		},
		"voiceTest": voice_test_state.duplicate(true),
	}


func _voice_health_snapshot() -> Dictionary:
	var settings: Dictionary = context.settings if is_instance_valid(context) else {}
	var snapshot := voice_health_state.duplicate(true)
	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	if voice_rate_limit_retry_at_ms > 0 and voice_rate_limit_retry_at_ms <= now_ms:
		voice_rate_limit_retry_at_ms = 0
		if str(snapshot.get("reasonCode", "")) == "provider-rate-limited":
			voice_health_state["status"] = "idle"
			voice_health_state["reasonCode"] = ""
			snapshot["status"] = "idle"
			snapshot["reasonCode"] = ""
	snapshot["retryAtMs"] = voice_rate_limit_retry_at_ms
	if not bool(settings.get("tts_enabled", false)):
		snapshot["status"] = "disabled"
		snapshot["reasonCode"] = ""
		snapshot["retryAtMs"] = 0
	return snapshot


func _update_control_snapshot() -> Dictionary:
	var settings: Dictionary = context.settings if is_instance_valid(context) else {}
	var channel := str(settings.get("update_channel", "stable")).strip_edges().to_lower()
	if channel in ["beta", "nightly"]:
		channel = "preview"
	if channel not in UPDATE_CHANNELS:
		channel = "stable"
	var service_status: Dictionary = {}
	var update_service := _service(&"update_service")
	if is_instance_valid(update_service) and update_service.has_method("safe_status"):
		var value: Variant = update_service.call("safe_status")
		if value is Dictionary:
			service_status = value
	var current_version := _safe_update_version(str(service_status.get("currentVersion", "")), "0.1.0")
	var state := str(update_state.get("state", "unavailable"))
	var message_code := str(update_state.get("messageCode", "update-unavailable"))
	if not UPDATE_MESSAGES.has(message_code):
		message_code = "update-failed"
		state = "failed"
	var target_version := _safe_update_version(str(update_state.get("targetVersion", "")), "")
	var applying := state in ["apply-requested", "stopping", "validating", "swapping", "restarting"]
	var can_check := bool(service_status.get("canCheck", false)) and pending_update_check.is_empty() and not applying and state != "checking"
	var can_apply := bool(service_status.get("canApply", false)) and pending_update_check.is_empty() and state == "ready" and not target_version.is_empty()
	return {
		"currentVersion": current_version,
		"channel": channel,
		"state": state,
		"messageCode": message_code,
		"message": str(UPDATE_MESSAGES[message_code]),
		"targetVersion": target_version,
		"canCheck": can_check,
		"canApply": can_apply,
		"automaticChecksEnabled": bool(service_status.get("automaticChecksEnabled", false)),
		"nextAutomaticCheckSeconds": maxi(0, int(service_status.get("nextAutomaticCheckSeconds", 0))),
		"stableTrustReady": bool(service_status.get("stableTrustReady", false)),
		"installOnRestart": bool(service_status.get("installOnRestart", false)) and can_apply,
	}


func _credential_present(provider_id: String) -> bool:
	var credential_service := _service(&"credential_service")
	return is_instance_valid(credential_service) and credential_service.has_method("present") \
		and bool(credential_service.call("present", provider_id))


func _native_bridge() -> Node:
	var bridge_adapter := _service(&"bridge_adapter")
	if not is_instance_valid(bridge_adapter):
		return null
	var value: Variant = bridge_adapter.get("bridge")
	return value as Node if value is Node else null


func _credential_broker_available() -> bool:
	var bridge := _native_bridge()
	return OS.get_name() == "Windows" and is_instance_valid(bridge) and bridge.has_method("start_credential_broker")


func _credential_broker_launch_arguments() -> PackedStringArray:
	if not _credential_broker_available():
		return PackedStringArray()
	var random_bytes := Crypto.new().generate_random_bytes(32)
	if random_bytes.size() != 32:
		return PackedStringArray()
	var value: Variant = _native_bridge().call("start_credential_broker", random_bytes.hex_encode())
	return value if value is PackedStringArray else PackedStringArray()


func _account_snapshot() -> Dictionary:
	var fallback := {"signedIn": false, "userId": "", "email": "", "deviceId": ""}
	var session_service := _service(&"cloud_session_service")
	if not is_instance_valid(session_service) or not session_service.has_method("snapshot"):
		return fallback
	var raw: Variant = session_service.call("snapshot")
	if not raw is Dictionary:
		return fallback
	var source: Dictionary = raw
	var signed_in := bool(source.get("signed_in", false))
	var user_id := str(source.get("user_id", "")).strip_edges()
	var email := str(source.get("email", "")).strip_edges().to_lower()
	var device_id := str(source.get("device_id", "")).strip_edges()
	if user_id.length() > 160 or email.length() > 320 or device_id.length() > 160:
		return fallback
	return {
		"signedIn": signed_in and not user_id.is_empty(),
		"userId": user_id if signed_in else "",
		"email": email if signed_in else "",
		"deviceId": device_id if signed_in else "",
	}


func _cloud_snapshot() -> Dictionary:
	var account := _account_snapshot()
	var signed_in := bool(account.get("signedIn", false))
	var library_status := "signed-out" if not signed_in else "idle"
	var library_items: Array = []
	var library_service := _service(&"cloud_library_service")
	if is_instance_valid(library_service) and library_service.has_method("library_snapshot"):
		var raw_library: Variant = library_service.call("library_snapshot")
		if raw_library is Dictionary:
			var library: Dictionary = raw_library
			var candidate_status := str(library.get("status", library_status))
			if candidate_status in ["signed-out", "idle", "loading", "synced", "error", "not-configured"]:
				library_status = candidate_status
			var raw_items: Variant = library.get("items", [])
			if raw_items is Array:
				for raw_item in raw_items:
					if not raw_item is Dictionary or library_items.size() >= 128:
						continue
					var item: Dictionary = raw_item
					var source := str(item.get("source", ""))
					var availability := str(item.get("availability", "unknown"))
					if source not in ["free-install", "grant", "purchase"] or availability not in ["free", "entitlement-required", "unknown"]:
						continue
					var product_id := str(item.get("productId", "")).strip_edges()
					if product_id.is_empty() or product_id.length() > 160:
						continue
					library_items.append({
						"productId": product_id,
						"productType": str(item.get("productType", "" )).substr(0, 80),
						"entitled": bool(item.get("entitled", false)),
						"source": source,
						"grantedAt": str(item.get("grantedAt", "")).substr(0, 80),
						"revokedAt": str(item.get("revokedAt", "")).substr(0, 80),
						"name": str(item.get("name", "")).substr(0, 160),
						"latestVersion": str(item.get("latestVersion", "")).substr(0, 64),
						"thumbnailUrl": str(item.get("thumbnailUrl", "")).substr(0, 2048),
						"availability": availability,
					})
	if not signed_in:
		library_status = "signed-out"
		library_items.clear()

	var sync_status := "signed-out" if not signed_in else "idle"
	var progression_revision := 0
	var progression_service := _service(&"cloud_progression_service")
	if is_instance_valid(progression_service) and progression_service.has_method("sync_snapshot"):
		var raw_sync: Variant = progression_service.call("sync_snapshot")
		if raw_sync is Dictionary:
			var sync: Dictionary = raw_sync
			var candidate_sync_status := str(sync.get("status", sync_status))
			if candidate_sync_status in ["signed-out", "idle", "syncing", "synced", "error"]:
				sync_status = candidate_sync_status
			progression_revision = maxi(0, int(sync.get("progressionRevision", 0)))
	var device_registered := signed_in and not str(account.get("deviceId", "")).is_empty()
	if not signed_in:
		sync_status = "signed-out"
	elif not device_registered:
		sync_status = "device-registration-required"

	var download := {
		"status": "idle",
		"packageId": "",
		"version": "",
		"trust": {"mode": "none", "sequence": 0, "trustedPublishers": 0, "revocationStale": false},
	}
	var download_service := _service(&"cloud_download_service")
	if is_instance_valid(download_service) and download_service.has_method("public_snapshot"):
		var raw_download: Variant = download_service.call("public_snapshot")
		if raw_download is Dictionary:
			var source_download: Dictionary = raw_download
			var download_status := str(source_download.get("status", "idle"))
			if download_status in ["idle", "authorizing", "downloading", "installed", "error"]:
				var projected_trust := {"mode": "none", "sequence": 0, "trustedPublishers": 0, "revocationStale": false}
				var raw_trust: Variant = source_download.get("trust", {})
				if raw_trust is Dictionary:
					var source_trust: Dictionary = raw_trust
					var trust_mode := str(source_trust.get("mode", "none"))
					if trust_mode in ["none", "local-beta", "marketplace-release"]:
						projected_trust = {
							"mode": trust_mode,
							"sequence": maxi(0, int(source_trust.get("sequence", 0))),
							"trustedPublishers": clampi(int(source_trust.get("trustedPublishers", 0)), 0, 256),
							"revocationStale": bool(source_trust.get("revocationStale", false)),
						}
				download = {
					"status": download_status,
					"packageId": str(source_download.get("packageId", "")).substr(0, 160),
					"version": str(source_download.get("version", "")).substr(0, 64),
					"trust": projected_trust,
				}
	return {
		"library": {"status": library_status, "items": library_items},
		"sync": {"status": sync_status, "deviceRegistered": device_registered, "progressionRevision": progression_revision},
		"download": download,
	}


func _effect_pack_snapshot() -> Dictionary:
	var fallback := {
		"installed": [],
		"loadout": {},
		"enabled": {
			"bodyAura": true,
			"groundRune": true,
			"levelUpBurst": true,
		},
		"resolved": {},
		"previewRank": "",
	}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("snapshot"):
		return fallback
	var value: Variant = service.call("snapshot")
	if not value is Dictionary:
		return fallback
	var projected_source := (value as Dictionary).duplicate(true)
	var preview_character_id := str(preview_state.get("packageId", "")).strip_edges()
	if not preview_character_id.is_empty():
		var preview_resolved := {}
		var preview_resolver := "resolve_slot_for_preview" if service.has_method("resolve_slot_for_preview") else "resolve_slot"
		for slot_name in ["bodyAura", "groundRune", "levelUpBurst"]:
			# Character Manager must be able to inspect an equipped Starter FX slot
			# even while that slot is disabled on the live desktop companion.
			var resolved_value: Variant = service.call(preview_resolver, slot_name, true, preview_character_id)
			if resolved_value is Dictionary and not (resolved_value as Dictionary).is_empty():
				preview_resolved[slot_name] = (resolved_value as Dictionary).duplicate(true)
		projected_source["resolved"] = preview_resolved
	return _project_effect_pack_snapshot(projected_source)


static func _project_effect_pack_snapshot(value: Dictionary) -> Dictionary:
	# Desktop Shell consumes a strict schema-20 projection. Runtime-internal
	# package locations such as `user://...` must never leak across this bridge;
	# besides being unnecessary to Electron, extra keys make the strict snapshot
	# validator reject the entire Runtime as unavailable.
	var resolved_projected := {}
	var resolved_value: Variant = value.get("resolved", {})
	if resolved_value is Dictionary:
		for slot_name in ["bodyAura", "groundRune", "levelUpBurst"]:
			var item_value: Variant = (resolved_value as Dictionary).get(slot_name, {})
			if not item_value is Dictionary or (item_value as Dictionary).is_empty():
				continue
			var item := item_value as Dictionary
			var config_value: Variant = item.get("config", {})
			resolved_projected[slot_name] = {
				"packageId": str(item.get("packageId", "")),
				"version": str(item.get("version", "")),
				"name": str(item.get("name", "")),
				"slot": str(item.get("slot", slot_name)),
				"config": (config_value as Dictionary).duplicate(true) if config_value is Dictionary else {},
			}
	var installed_value: Variant = value.get("installed", [])
	var loadout_value: Variant = value.get("loadout", {})
	var enabled_value: Variant = value.get("enabled", {})
	return {
		"installed": (installed_value as Array).duplicate(true) if installed_value is Array else [],
		"loadout": (loadout_value as Dictionary).duplicate(true) if loadout_value is Dictionary else {},
		"enabled": (enabled_value as Dictionary).duplicate(true) if enabled_value is Dictionary else {
			"bodyAura": true,
			"groundRune": true,
			"levelUpBurst": true,
		},
		"resolved": resolved_projected,
		"previewRank": str(value.get("previewRank", "")),
	}


func _valid_effect_slot(value: String) -> bool:
	return value in ["bodyAura", "groundRune", "levelUpBurst"]


func _equip_effect_pack(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "packageId", "version", "slot"]) or command.size() != 4:
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var package_id := str(command.get("packageId", "")).strip_edges()
	var version := str(command.get("version", "")).strip_edges()
	var slot := str(command.get("slot", "")).strip_edges()
	if package_id.is_empty() or version.is_empty() or (not slot.is_empty() and not _valid_effect_slot(slot)):
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("equip"):
		return {"status": "failed", "errorCode": "effect-pack-service-unavailable"}
	var ok := bool(service.call("equip", package_id, version, slot))
	if ok:
		effect_preview_sheet_cache.clear()
		if slot.is_empty():
			effect_preview_tuning.clear()
		else:
			effect_preview_tuning.erase(slot)
		if not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
			effect_preview_elapsed = 0.0
			effect_preview_frame_elapsed = 0.0
			_refresh_preview_frame(true)
			_write_preview_media()
	return {
		"status": "succeeded" if ok else "failed",
		"errorCode": "" if ok else "effect-pack-equip-failed",
	}


func _unequip_effect_pack(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "slot"]) or command.size() != 2:
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var slot := str(command.get("slot", ""))
	if not _valid_effect_slot(slot):
		return {"status": "failed", "errorCode": "invalid-effect-pack-slot"}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("unequip"):
		return {"status": "failed", "errorCode": "effect-pack-service-unavailable"}
	var ok := bool(service.call("unequip", slot))
	if ok:
		effect_preview_sheet_cache.clear()
		effect_preview_tuning.erase(slot)
		if not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
			effect_preview_elapsed = 0.0
			effect_preview_frame_elapsed = 0.0
			_refresh_preview_frame(true)
			_write_preview_media()
	return {"status": "succeeded" if ok else "failed", "errorCode": "" if ok else "effect-pack-unequip-failed"}


func _set_effect_pack_slot_enabled(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "slot", "enabled"]) or command.size() != 3:
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var slot := str(command.get("slot", ""))
	var enabled_value: Variant = command.get("enabled")
	if not _valid_effect_slot(slot) or not (enabled_value is bool):
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("set_slot_enabled"):
		return {"status": "failed", "errorCode": "effect-pack-service-unavailable"}
	var enabled := bool(enabled_value)
	var ok := bool(service.call("set_slot_enabled", slot, enabled))
	if ok and not enabled and effect_preview_mode == slot and effect_preview_variant == "equipped":
		# Turning off the slot owns the current single-slot preview as well. Stop it
		# before composing so a Runtime redraw cannot briefly resurrect the disabled
		# effect while Electron's separate "preview off" command is still in flight.
		effect_preview_mode = ""
	if ok and not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
		# Redraw immediately from authoritative slot state instead of waiting for
		# the next snapshot poll.
		effect_preview_elapsed = 0.0
		effect_preview_frame_elapsed = 0.0
		_refresh_preview_frame(true)
		_write_preview_media()
	elif ok and not preview_active_payload.is_empty():
		_refresh_preview_frame(true)
		_write_preview_media()
	return {"status": "succeeded" if ok else "failed", "errorCode": "" if ok else "effect-pack-setting-failed"}


func _preview_effect_pack_tune(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "slot", "tuning"]) or command.size() != 3:
		return {"status": "failed", "errorCode": "invalid-effect-pack-preview-tuning"}
	var slot := str(command.get("slot", ""))
	if not _valid_effect_slot(slot):
		return {"status": "failed", "errorCode": "invalid-effect-pack-slot"}
	var tuning_value: Variant = command.get("tuning", {})
	if not tuning_value is Dictionary:
		return {"status": "failed", "errorCode": "invalid-effect-pack-preview-tuning"}
	var tuning := tuning_value as Dictionary
	if not _has_only_keys(tuning, ["fps", "startFrame", "endFrame", "scale", "offsetX", "offsetY", "anchor", "scaleMode"]) or tuning.size() != 8:
		return {"status": "failed", "errorCode": "invalid-effect-pack-preview-tuning"}
	var fps := int(tuning.get("fps", 0))
	var start_frame := int(tuning.get("startFrame", -1))
	var end_frame := int(tuning.get("endFrame", -1))
	var scale := float(tuning.get("scale", 0.0))
	var offset_x := float(tuning.get("offsetX", 9999.0))
	var offset_y := float(tuning.get("offsetY", 9999.0))
	var anchor := str(tuning.get("anchor", ""))
	var scale_mode := str(tuning.get("scaleMode", ""))
	if fps < 1 or fps > 30 \
	or start_frame < 0 or start_frame > 119 \
	or end_frame < start_frame or end_frame > 119 \
	or scale < 0.25 or scale > 4.0 \
	or absf(offset_x) > 512.0 or absf(offset_y) > 512.0 \
	or anchor not in ["character-center", "character-feet", "character-feet-bottom", "character-above-head"] \
	or scale_mode not in ["character-width", "character-height", "native-surface"]:
		return {"status": "failed", "errorCode": "invalid-effect-pack-preview-tuning"}
	effect_preview_tuning[slot] = tuning.duplicate(true)
	if not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
		effect_preview_elapsed = 0.0
		effect_preview_refresh_pending = true
	return {"status": "succeeded", "errorCode": ""}


func _save_effect_character_profile(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "characterId", "slot", "tuning"]) or command.size() != 4:
		return {"status": "failed", "errorCode": "invalid-character-effect-profile"}
	var character_id := str(command.get("characterId", "")).strip_edges()
	var slot := str(command.get("slot", ""))
	var tuning_value: Variant = command.get("tuning", {})
	if character_id.is_empty() or character_id.length() > 128 or not _valid_effect_slot(slot) or not tuning_value is Dictionary:
		return {"status": "failed", "errorCode": "invalid-character-effect-profile"}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("save_character_profile"):
		return {"status": "failed", "errorCode": "effect-pack-service-unavailable"}
	var saved_value: Variant = service.call("save_character_profile", character_id, slot, tuning_value as Dictionary)
	if not saved_value is Dictionary or not bool((saved_value as Dictionary).get("ok", false)):
		return {"status": "failed", "errorCode": str((saved_value as Dictionary).get("error", "character-effect-profile-save-failed")) if saved_value is Dictionary else "character-effect-profile-save-failed"}
	effect_preview_tuning.erase(slot)
	effect_preview_sheet_cache.clear()
	if not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
		effect_preview_elapsed = 0.0
		effect_preview_frame_elapsed = 0.0
		_refresh_preview_frame(true)
		_write_preview_media()
	return {"status": "succeeded", "errorCode": ""}


func _reset_effect_character_profile(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "characterId", "slot"]) or command.size() != 3:
		return {"status": "failed", "errorCode": "invalid-character-effect-profile"}
	var character_id := str(command.get("characterId", "")).strip_edges()
	var slot := str(command.get("slot", ""))
	if character_id.is_empty() or character_id.length() > 128 or not _valid_effect_slot(slot):
		return {"status": "failed", "errorCode": "invalid-character-effect-profile"}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("reset_character_profile"):
		return {"status": "failed", "errorCode": "effect-pack-service-unavailable"}
	var reset_value: Variant = service.call("reset_character_profile", character_id, slot)
	if not reset_value is Dictionary or not bool((reset_value as Dictionary).get("ok", false)):
		return {"status": "failed", "errorCode": str((reset_value as Dictionary).get("error", "character-effect-profile-reset-failed")) if reset_value is Dictionary else "character-effect-profile-reset-failed"}
	effect_preview_tuning.erase(slot)
	effect_preview_sheet_cache.clear()
	if not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
		effect_preview_elapsed = 0.0
		effect_preview_frame_elapsed = 0.0
		_refresh_preview_frame(true)
		_write_preview_media()
	return {"status": "succeeded", "errorCode": ""}


func _preview_effect_pack_rank(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "rank"]) or command.size() != 2:
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var rank := str(command.get("rank", "")).strip_edges()
	if rank not in ["", "stranger", "friend", "close-friend", "partner", "best-companion"]:
		return {"status": "failed", "errorCode": "invalid-effect-pack-rank"}
	var service := _service(&"effect_pack_service")
	if not is_instance_valid(service) or not service.has_method("set_preview_rank"):
		return {"status": "failed", "errorCode": "effect-pack-service-unavailable"}
	var ok := bool(service.call("set_preview_rank", rank))
	if ok and not effect_preview_mode.is_empty() and not preview_active_payload.is_empty():
		effect_preview_elapsed = 0.0
		_refresh_preview_frame(true)
		_write_preview_media()
	return {"status": "succeeded" if ok else "failed", "errorCode": "" if ok else "effect-pack-preview-rank-failed"}


func _preview_effect_pack(command: Dictionary) -> Dictionary:
	if not _has_only_keys(command, ["type", "mode", "variant"]) or command.size() not in [1, 2, 3]:
		return {"status": "failed", "errorCode": "invalid-effect-pack-request"}
	var variant: Variant = command.get("variant", "equipped")
	if not variant is String or variant not in ["equipped", "video-original", "video-blend", "starter-mist"]:
		return {"status": "failed", "errorCode": "invalid-effect-pack-preview-variant"}
	var mode := str(command.get("mode", "all")).strip_edges()
	if mode not in EFFECT_PREVIEW_MODES:
		return {"status": "failed", "errorCode": "invalid-effect-pack-preview-mode"}
	if mode == "off":
		_reset_effect_comparison()
		effect_preview_mode = ""
		effect_preview_elapsed = 0.0
		effect_preview_frame_elapsed = 0.0
		effect_preview_refresh_pending = false
		effect_preview_sheet_cache.clear()
		if not preview_active_payload.is_empty():
			_refresh_preview_frame(true)
			_write_preview_media()
		return {"status": "succeeded", "errorCode": ""}
	if preview_active_payload.is_empty():
		return {"status": "failed", "errorCode": "character-preview-unavailable"}
	var comparison_sources := {}
	if variant != "equipped":
		var source := _service(&"effect_pack_service")
		if not is_instance_valid(source) or not source.has_method("resolve_comparison_slot"):
			return {"status": "failed", "errorCode": "effect-comparison-source-unavailable"}
		for slot in ["bodyAura", "groundRune", "levelUpBurst"]:
			comparison_sources[slot] = source.call("resolve_comparison_slot", slot, variant, str(preview_state.get("packageId", "")))
		if (comparison_sources.get("bodyAura" if mode == "all" else mode, {}) as Dictionary).is_empty():
			return {"status": "failed", "errorCode": "effect-comparison-source-unavailable"}
	_reset_effect_comparison()
	effect_preview_variant = variant
	effect_comparison_sources = comparison_sources
	effect_preview_mode = mode
	effect_preview_elapsed = 0.0
	effect_preview_frame_elapsed = 0.0
	_refresh_preview_frame(true)
	_write_preview_media()
	# Preserve the existing native-preview behavior for callers outside Character
	# Manager. The controller ignores this event while shell presentation is
	# suppressed, while the composite preview above remains visible in the shell.
	if mode == "all" and variant == "equipped" and is_instance_valid(event_bus):
		event_bus.publish(&"effect_pack.preview_requested", {})
	return {"status": "succeeded", "errorCode": ""}


func _comparison_renderer() -> Node:
	if not is_instance_valid(effect_comparison_renderer):
		effect_comparison_renderer = EffectComparisonRenderer.new()
		add_child(effect_comparison_renderer)
	return effect_comparison_renderer


func _reset_effect_comparison() -> void:
	effect_preview_variant = "equipped"
	effect_comparison_sources.clear()
	if is_instance_valid(effect_comparison_renderer):
		effect_comparison_renderer.free()
	effect_comparison_renderer = null


func _progression_snapshot() -> Dictionary:
	var fallback := {"revision": 0, "levelCap": 200, "companions": [], "effects": _progression_effects_snapshot()}
	var progression_service := _service(&"cloud_progression_service")
	if not is_instance_valid(progression_service) or not progression_service.has_method("canonical_projection"):
		return fallback
	var raw: Variant = progression_service.call("canonical_projection")
	if not raw is Dictionary:
		return fallback
	var source: Dictionary = raw
	var level_cap := clampi(int(source.get("levelCap", 200)), 1, 200)
	var companions_value: Variant = source.get("companions", [])
	if not companions_value is Array:
		return fallback
	var companions: Array = []
	for companion_value in companions_value:
		if not companion_value is Dictionary:
			continue
		var companion: Dictionary = companion_value
		var companion_id := str(companion.get("companionId", "")).strip_edges()
		var character_id := str(companion.get("characterId", "")).strip_edges()
		if companion_id.is_empty() or character_id.is_empty() or companion_id.length() > 128 or character_id.length() > 128:
			continue
		var relationship_value: Variant = companion.get("relationship", {})
		if not relationship_value is Dictionary:
			continue
		var relationship: Dictionary = relationship_value
		var skills: Array = []
		var skills_value: Variant = companion.get("skills", [])
		if skills_value is Array:
			for skill_value in skills_value:
				if not skill_value is Dictionary or skills.size() >= 64:
					continue
				var skill: Dictionary = skill_value
				var skill_id := str(skill.get("skillId", "")).strip_edges()
				if skill_id.is_empty() or skill_id.length() > 80:
					continue
				skills.append({
					"skillId": skill_id,
					"level": maxi(0, int(skill.get("level", 0))),
					"xp": maxi(0, int(skill.get("xp", 0))),
				})
		var next_level_value: Variant = relationship.get("nextLevelXp", null)
		companions.append({
			"companionId": companion_id,
			"characterId": character_id,
			"relationship": {
				"level": clampi(int(relationship.get("level", 1)), 1, level_cap),
				"xp": maxi(0, int(relationship.get("xp", 0))),
				"bondRank": str(relationship.get("bondRank", "stranger")).substr(0, 32),
				"currentLevelXp": maxi(0, int(relationship.get("currentLevelXp", 0))),
				"nextLevelXp": null if next_level_value == null else maxi(0, int(next_level_value)),
				"progressPermille": clampi(int(relationship.get("progressPermille", 0)), 0, 1000),
			},
			"skills": skills,
		})
	return {
		"revision": maxi(0, int(source.get("revision", 0))),
		"levelCap": level_cap,
		"companions": companions,
		"effects": _progression_effects_snapshot(),
	}


func _progression_effects_snapshot() -> Dictionary:
	var settings: Dictionary = context.settings if is_instance_valid(context) else {}
	return {
		"levelUpEnabled": bool(settings.get("progression_level_up_enabled", true)),
		"auraEnabled": bool(settings.get("progression_aura_enabled", false)),
	}


func _character_snapshot() -> Array:
	# Heartbeats are once per second; never rescan/reverify Store packages from
	# this projection path. The cache is refreshed only after package/character
	# lifecycle changes and the initial Runtime handoff has had a process frame.
	return character_snapshot_cache.duplicate(true)


func _build_character_snapshot() -> Array:
	var projected: Array = []
	var package_service := _service(&"package_service")
	if not is_instance_valid(package_service):
		return projected
	var active_id := str(context.package.get("active_id", "")) if is_instance_valid(context) else ""
	var active_version := str(context.package.get("active_version", "")) if is_instance_valid(context) else ""
	if (active_id.is_empty() or active_version.is_empty()) and package_service.has_method("get_active_candidate"):
		var candidate: Dictionary = package_service.call("get_active_candidate")
		active_id = str(candidate.get("packageId", ""))
		active_version = str(candidate.get("version", ""))
	var verified_active: Dictionary = {}
	var character_service := _service(&"character_service")
	if is_instance_valid(character_service) and character_service.has_method("get_active_verified_package_info"):
		var verified_value: Variant = character_service.call("get_active_verified_package_info", active_id, active_version)
		if verified_value is Dictionary:
			verified_active = (verified_value as Dictionary).duplicate(true)
	if not verified_active.is_empty():
		print("[DesktopShellTiming] character_snapshot_reuse_active package=%s version=%s" % [active_id, active_version])
	for package_info_value in package_service.list_installed(verified_active):
		if not package_info_value is Dictionary:
			continue
		var package_info: Dictionary = package_info_value
		var manifest: Dictionary = package_info.get("manifest", {}) if package_info.get("manifest", {}) is Dictionary else {}
		var package_id := str(package_info.get("packageId", ""))
		var version := str(package_info.get("version", ""))
		if package_id.is_empty() or version.is_empty():
			continue
		var thumbnail := _character_thumbnail_projection(package_info, package_id, version)
		projected.append({
			"packageId": package_id,
			"version": version,
			"name": str(manifest.get("name", package_id)),
			"active": package_id == active_id and version == active_version,
			"animations": _active_animations(package_id, version),
			"thumbnailPngBase64": str(thumbnail.get("base64", "")),
			"thumbnailWidth": int(thumbnail.get("width", 0)),
			"thumbnailHeight": int(thumbnail.get("height", 0)),
		})
	return projected


func _character_thumbnail_projection(package_info: Dictionary, package_id: String, version: String) -> Dictionary:
	var cache_key := "%s@%s" % [package_id, version]
	if character_thumbnail_cache.has(cache_key):
		var cached: Variant = character_thumbnail_cache[cache_key]
		return cached if cached is Dictionary else {}
	var projection := {"base64": "", "width": 0, "height": 0}
	var character_service := _service(&"character_service")
	if not is_instance_valid(character_service) or not character_service.has_method("build_preview_thumbnail"):
		character_thumbnail_cache[cache_key] = projection
		return projection
	var result: Variant = character_service.call("build_preview_thumbnail", package_info)
	if not result is Dictionary or not bool(result.get("ok", false)):
		character_thumbnail_cache[cache_key] = projection
		return projection
	var texture: Texture2D = result.get("texture") as Texture2D
	if texture == null:
		character_thumbnail_cache[cache_key] = projection
		return projection
	var image := texture.get_image()
	if image == null or image.is_empty():
		character_thumbnail_cache[cache_key] = projection
		return projection
	_scale_character_thumbnail_image(image)
	var png_bytes := image.save_png_to_buffer()
	if png_bytes.is_empty() or png_bytes.size() > MAX_CHARACTER_THUMBNAIL_PNG_BYTES:
		character_thumbnail_cache[cache_key] = projection
		return projection
	var encoded := Marshalls.raw_to_base64(png_bytes)
	if encoded.length() > MAX_CHARACTER_THUMBNAIL_BASE64_LENGTH:
		character_thumbnail_cache[cache_key] = projection
		return projection
	projection = {"base64": encoded, "width": image.get_width(), "height": image.get_height()}
	character_thumbnail_cache[cache_key] = projection
	return projection


func _scale_character_thumbnail_image(image: Image) -> void:
	if image.get_width() <= MAX_CHARACTER_THUMBNAIL_WIDTH and image.get_height() <= MAX_CHARACTER_THUMBNAIL_HEIGHT:
		return
	var factor := minf(
		float(MAX_CHARACTER_THUMBNAIL_WIDTH) / float(image.get_width()),
		float(MAX_CHARACTER_THUMBNAIL_HEIGHT) / float(image.get_height())
	)
	image.resize(maxi(1, int(round(image.get_width() * factor))), maxi(1, int(round(image.get_height() * factor))), Image.INTERPOLATE_LANCZOS)


func _active_animations(package_id: String, version: String) -> Array:
	if is_instance_valid(context) and package_id == str(context.character.get("id", "")):
		var animations: Variant = context.character.get("animations", [])
		return animations if animations is Array else []
	return []


func _provider_id() -> String:
	var ai_service := _service(&"ai_service")
	if is_instance_valid(ai_service):
		return str(ai_service.get("provider_id"))
	return "offline"


func _service(property: StringName) -> Node:
	if not is_instance_valid(services):
		return null
	var value: Variant = services.get(property)
	return value as Node if value is Node else null


func _has_only_keys(value: Dictionary, allowed: Array) -> bool:
	for key in value.keys():
		if key not in allowed:
			return false
	return true


func _subscribe(topic: StringName, callback: Callable) -> void:
	if event_bus != null:
		event_bus.subscribe(topic, callback)


func _callback_name_for_topic(topic: StringName) -> StringName:
	match topic:
		&"chat.response_started": return &"_on_chat_started"
		&"chat.assistant_stream_delta": return &"_on_chat_delta"
		&"chat.assistant_message_received": return &"_on_chat_completed"
		&"chat.response_failed": return &"_on_chat_failed"
		&"ai.provider_status_changed": return &"_on_provider_status"
		&"ai.connection_test_completed": return &"_on_ai_test_completed"
		&"ai.models_discovered": return &"_on_ai_models_discovered"
		&"tts.requested": return &"_on_tts_requested"
		&"tts.started": return &"_on_voice_test_started"
		&"tts.finished": return &"_on_voice_test_finished"
		&"tts.failed": return &"_on_voice_test_failed"
		&"resource_monitor.updated": return &"_on_resource_monitor"
		&"update.status_changed": return &"_on_update_status_changed"
		&"update.check_finished": return &"_on_update_check_finished"
		&"package.installed", &"character.changed", &"character.uninstalled", &"character.loaded": return &"_on_package_projection_changed"
		&"character.uninstall_result": return &"_on_character_uninstall_result"
		&"cloud.auth.updated": return &"_on_account_projection_changed"
		&"cloud.session.changed", &"cloud.device.updated", &"cloud.library.updated", &"cloud.catalog.updated", &"cloud.progression.updated", &"cloud.progression.sync_state", &"cloud.download.updated": return &"_on_cloud_projection_changed"
		&"cloud.download.desktop_transfer_requested": return &"_on_desktop_transfer_requested"
		_: return &"_on_provider_status"
