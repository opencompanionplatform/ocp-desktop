extends SceneTree

const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")


class FakeContext:
	extends Node
	var settings: Dictionary = {
		"theme_preset": "solid", "font_family": "Inter", "text_scale": 1.15,
		"bubble_style": "Rounded", "language": "en", "show_bubbles": true,
		"click_through_enabled": true, "start_with_windows": false,
		"offline_presence_enabled": true, "llm_companion_mode_enabled": false, "update_channel": "stable", "reduce_motion": false,
	}
	var runtime_config: Dictionary = {
		"click_through_enabled": true,
		"resource_monitor": {
			"available": true,
			"cpu_percent": 24.5,
			"memory_percent": 61.0,
			"system_cpu_percent": 24.5,
			"system_memory_percent": 61.0,
			"ocp_memory_mb": 642.5,
			"runtime_memory_mb": 284.0,
			"desktop_shell_memory_mb": 326.0,
			"kernel_memory_mb": 18.0,
			"native_host_memory_mb": 14.5,
			"ai_memory_mb": 4820.0,
			"pressure": "normal",
			"sampled_at_ms": 1234,
		},
	}
	var character: Dictionary = {
		"id": "character.scifi",
		"animations": ["idle", "think", "speak", "wave"],
	}
	var package: Dictionary = {
		"active_id": "character.scifi",
		"active_version": "2.0.0",
	}

	func update_settings(values: Dictionary) -> void:
		settings = values.duplicate(true)

	func update_runtime_config(values: Dictionary) -> void:
		runtime_config.merge(values, true)


class FakeBus:
	extends Node
	var published: Array[Dictionary] = []

	func publish(topic: StringName, payload: Dictionary) -> void:
		published.append({"topic": topic, "payload": payload.duplicate(true)})

	func subscribe(_topic: StringName, _callback: Callable) -> void:
		pass

	func unsubscribe(_topic: StringName, _callback: Callable) -> void:
		pass


class FakeSettings:
	extends Node
	var saved: Dictionary = {}
	var target_context: FakeContext

	func save_settings(values: Dictionary) -> bool:
		saved = values.duplicate(true)
		if is_instance_valid(target_context):
			var merged := target_context.settings.duplicate(true)
			merged.merge(values, true)
			target_context.update_settings(merged)
		return true


class FakeStartup:
	extends Node
	var enabled := false
	var calls := 0

	func set_enabled(value: bool) -> bool:
		enabled = value
		calls += 1
		return true


class FakeTheme:
	extends Node
	var selected := ""

	func select_theme(value: String) -> bool:
		selected = value
		return true


class FakeLocalization:
	extends Node
	var selected := ""

	func select_locale(value: String) -> bool:
		selected = value
		return true


class FakePackageService:
	extends Node
	var installed := [{"packageId": "character.scifi", "version": "2.0.0", "manifest": {"name": "Sci-Fi Woman"}}]

	var last_verified_reuse: Dictionary = {}
	var get_active_calls := 0
	var get_active_candidate_calls := 0
	func list_installed(verified_package_info: Dictionary = {}) -> Array:
		last_verified_reuse = verified_package_info.duplicate(true)
		return installed.duplicate(true)

	func get_active() -> Dictionary:
		get_active_calls += 1
		return installed[0].duplicate(true)

	func get_active_candidate() -> Dictionary:
		get_active_candidate_calls += 1
		return installed[0].duplicate(true)


class FakeCharacterService:
	extends Node
	var metadata_calls := 0
	var animation_requests: Array[String] = []
	var thumbnail_requests: Array[Array] = []

	func get_active_verified_package_info(package_id: String = "", version: String = "") -> Dictionary:
		if package_id != "character.scifi" or version != "2.0.0":
			return {}
		return {
			"packageId": "character.scifi",
			"version": "2.0.0",
			"path": "user://packages/characters/character.scifi/2.0.0",
			"manifest": {"name": "Sci-Fi Woman"},
			"_verification": {"ok": true, "managed": true},
		}

	func load_preview_metadata(_package_info: Dictionary) -> Dictionary:
		metadata_calls += 1
		var animations := ["idle", "think", "speak", "wave", "angry", "appear", "climb_down", "climb_ready", "climb_top", "happy", "sad"]
		var loops := {}
		for animation_name in animations:
			loops[animation_name] = animation_name not in ["wave", "climb_ready", "climb_top"]
		return {"ok": true, "animations": animations, "loops": loops, "default_animation": "idle", "prepared_entry": {"ok": true}}

	func build_preview_animation_payload(_package_info: Dictionary, animation_name: String, _prepared_entry: Dictionary = {}) -> Dictionary:
		animation_requests.append(animation_name)
		OS.delay_msec(5)
		return {
			"ok": true,
			"animation": animation_name,
			"loop": animation_name not in ["wave", "climb_ready", "climb_top"],
			"fps": 8.0,
			"encoded_frames": ["AAAA"],
			"frame_width": 8,
			"frame_height": 8,
			"encoded_bytes": 4,
			"worker_ms": 5,
		}

	func load_animation_thumbnail_png_bytes(_package_info: Dictionary, requested_names: Array) -> Dictionary:
		thumbnail_requests.append(requested_names.duplicate())
		var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color("27c7ff"))
		var png_bytes := image.save_png_to_buffer()
		var thumbnails := {}
		for raw_name in requested_names:
			var name := str(raw_name)
			if not name.is_empty():
				thumbnails[name] = png_bytes
		return {"ok": true, "source": "presentation.animationThumbnails", "thumbnails": thumbnails}


class FakeCloudSession:
	extends Node
	func snapshot() -> Dictionary:
		return {"signed_in": true, "user_id": "user-1", "device_id": "device-1"}


class FakeCloudAuth:
	extends Node
	var signed_in_email := ""
	var signed_out := false
	func sign_in_with_password(email: String, _password: String) -> Dictionary:
		signed_in_email = email
		return {"ok": true, "status": "loading"}
	func sign_out() -> void:
		signed_out = true


class FakeCloudLibrary:
	extends Node
	var catalog_refreshes := 0
	var library_refreshes := 0
	func cached_catalog() -> Array:
		return [{"characterId": "character.sabai", "name": "Sabai", "publisher": {"publisherId": "publisher.ocp", "displayName": "OCP"}, "latestVersion": "1.2.0", "thumbnailUrl": "https://cdn.example/sabai.webp", "availability": "free"}]
	func cached_library() -> Array:
		return [{"productId": "character.sabai", "productType": "character", "entitled": true, "source": "free-install", "grantedAt": "2026-08-27T00:00:00Z", "revokedAt": null}]
	func refresh_catalog() -> Dictionary:
		catalog_refreshes += 1
		return {"ok": true}
	func refresh_library() -> Dictionary:
		library_refreshes += 1
		return {"ok": true}
	func library_snapshot() -> Dictionary:
		return {"status": "synced", "items": [{
			"productId": "character.sabai", "productType": "character", "entitled": true,
			"source": "free-install", "grantedAt": "2026-08-27T00:00:00Z", "revokedAt": "",
			"name": "Sabai", "latestVersion": "1.2.0", "thumbnailUrl": "https://cdn.example/sabai.webp", "availability": "free",
		}]}


class FakeCloudDownload:
	extends Node
	var requested := ""
	var handoff_requested := ""
	func download_and_install(package_id: String, version: String) -> Dictionary:
		requested = "%s@%s" % [package_id, version]
		return {"ok": true, "status": "authorizing"}
	func redeem_install_handoff(package_id: String, version: String, grant: String) -> Dictionary:
		if grant.length() >= 43:
			handoff_requested = "%s@%s" % [package_id, version]
		return {"ok": true, "status": "handoff-redeeming"}
	func public_snapshot() -> Dictionary:
		return {"status": "idle", "packageId": "", "version": ""}


class FakeCloudProgression:
	extends Node
	var sync_calls := 0
	var refresh_calls := 0
	func sync_pending() -> Dictionary:
		sync_calls += 1
		return {"ok": true, "status": "idle", "count": 0}
	func refresh_projection() -> Dictionary:
		refresh_calls += 1
		return {"ok": true, "status": "loading"}
	func canonical_projection() -> Dictionary:
		return {"revision": 4, "companions": []}
	func sync_snapshot() -> Dictionary:
		return {"status": "synced", "progressionRevision": 4}


class FakeServices:
	extends Node
	var settings_service := FakeSettings.new()
	var package_service := FakePackageService.new()
	var character_service := FakeCharacterService.new()
	var cloud_session_service := FakeCloudSession.new()
	var cloud_auth_service := FakeCloudAuth.new()
	var cloud_library_service := FakeCloudLibrary.new()
	var cloud_download_service := FakeCloudDownload.new()
	var cloud_progression_service := FakeCloudProgression.new()
	var startup_registration_service := FakeStartup.new()
	var theme_service := FakeTheme.new()
	var localization_service := FakeLocalization.new()


func _wait_for_preview(adapter: Node, frame_limit: int = 120) -> bool:
	for _index in range(frame_limit):
		adapter._poll_preview_load()
		if adapter.preview_load_thread == null and str(adapter.preview_state.get("status", "")) != "loading":
			return true
		await process_frame
	return false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := FakeBus.new()
	var services := FakeServices.new()
	var adapter := AdapterScript.new()
	for node in [context, bus, services, adapter]:
		holder.add_child(node)
	services.add_child(services.settings_service)
	services.add_child(services.package_service)
	services.add_child(services.character_service)
	services.add_child(services.cloud_session_service)
	services.add_child(services.cloud_auth_service)
	services.add_child(services.cloud_library_service)
	services.add_child(services.cloud_download_service)
	services.add_child(services.cloud_progression_service)
	services.add_child(services.startup_registration_service)
	services.add_child(services.theme_service)
	services.add_child(services.localization_service)
	services.settings_service.target_context = context
	adapter.configure(context, bus)
	adapter.bind_services(services)

	adapter._handle_command({
		"type": "settings.update",
		"appearance": {
			"theme": "glass",
			"locale": "th",
			"fontFamily": "system",
			"textScale": "large",
			"reduceMotion": true,
		},
	})
	var settings_ok: bool = services.settings_service.saved.get("theme_preset", "") == "glass" \
		and services.settings_service.saved.get("language", "") == "th" \
		and is_equal_approx(float(services.settings_service.saved.get("text_scale", 0.0)), 1.5)
	adapter._handle_command({
		"type": "control.settings.update",
		"settings": {
			"themePreset": "liquid",
			"fontFamily": "Leelawadee UI",
			"textScale": "comfortable",
			"bubbleStyle": "Soft",
			"language": "th",
			"showBubbles": false,
			"clickThroughEnabled": false,
			"startWithWindows": true,
			"offlinePresenceEnabled": false,
			"llmCompanionModeEnabled": true,
			"updateChannel": "beta",
			"reduceMotion": true,
		},
	}, "settings-request-1")
	var full_settings_ok: bool = services.settings_service.saved.get("theme_preset", "") == "liquid" \
		and services.settings_service.saved.get("font_family", "") == "Leelawadee UI" \
		and is_equal_approx(float(services.settings_service.saved.get("text_scale", 0.0)), 1.3) \
		and services.settings_service.saved.get("bubble_style", "") == "Soft" \
		and services.settings_service.saved.get("language", "") == "th" \
		and not bool(services.settings_service.saved.get("show_bubbles", true)) \
		and not bool(services.settings_service.saved.get("click_through_enabled", true)) \
		and bool(services.settings_service.saved.get("start_with_windows", false)) \
		and not bool(services.settings_service.saved.get("offline_presence_enabled", true)) \
		and bool(services.settings_service.saved.get("llm_companion_mode_enabled", false)) \
		and services.settings_service.saved.get("update_channel", "") == "beta" \
		and bool(services.settings_service.saved.get("reduce_motion", false)) \
		and services.startup_registration_service.enabled \
		and services.theme_service.selected == "liquid" \
		and services.localization_service.selected == "th"
	var control_snapshot := adapter._control_settings_snapshot()
	var resource_snapshot := adapter._resource_snapshot()
	var projection_ok: bool = control_snapshot.get("fontFamily", "") == "Leelawadee UI" \
		and control_snapshot.get("textScale", "") == "comfortable" \
		and control_snapshot.get("updateChannel", "") == "beta" \
		and is_equal_approx(float(resource_snapshot.get("cpuPercent", 0.0)), 24.5) \
		and is_equal_approx(float(resource_snapshot.get("memoryPercent", 0.0)), 61.0) \
		and is_equal_approx(float(resource_snapshot.get("ocpMemoryMb", 0.0)), 642.5) \
		and is_equal_approx(float(resource_snapshot.get("runtimeMemoryMb", 0.0)), 284.0) \
		and is_equal_approx(float(resource_snapshot.get("desktopShellMemoryMb", 0.0)), 326.0) \
		and is_equal_approx(float(resource_snapshot.get("aiMemoryMb", 0.0)), 4820.0) \
		and resource_snapshot.get("pressure", "") == "normal"
	var projected_characters: Array = adapter._build_character_snapshot()
	var active_reuse_ok: bool = projected_characters.size() == 1 \
		and str(services.package_service.last_verified_reuse.get("packageId", "")) == "character.scifi" \
		and str(services.package_service.last_verified_reuse.get("version", "")) == "2.0.0" \
		and bool((services.package_service.last_verified_reuse.get("_verification", {}) as Dictionary).get("managed", false))
	var cloud_projection: Dictionary = adapter._cloud_snapshot()
	var cloud_library: Dictionary = cloud_projection.get("library", {}) if cloud_projection.get("library", {}) is Dictionary else {}
	var cloud_sync: Dictionary = cloud_projection.get("sync", {}) if cloud_projection.get("sync", {}) is Dictionary else {}
	var cloud_download: Dictionary = cloud_projection.get("download", {}) if cloud_projection.get("download", {}) is Dictionary else {}
	var cloud_items: Array = cloud_library.get("items", []) if cloud_library.get("items", []) is Array else []
	var cloud_projection_ok: bool = cloud_projection.size() == 3 \
		and str(cloud_library.get("status", "")) == "synced" \
		and cloud_items.size() == 1 \
		and str((cloud_items[0] as Dictionary).get("productId", "")) == "character.sabai" \
		and str((cloud_items[0] as Dictionary).get("latestVersion", "")) == "1.2.0" \
		and str(cloud_sync.get("status", "")) == "synced" \
		and bool(cloud_sync.get("deviceRegistered", false)) \
		and int(cloud_sync.get("progressionRevision", -1)) == 4 \
		and str(cloud_download.get("status", "")) == "idle" \
		and not cloud_projection.has("accessToken") \
		and not cloud_projection.has("refreshToken")
	var result_ok: bool = adapter.command_results.size() == 1 \
		and adapter.command_results[0].get("id", "") == "settings-request-1" \
		and adapter.command_results[0].get("status", "") == "succeeded" \
		and adapter.command_results[0].get("errorCode", "invalid") == ""
	var saved_before_invalid := services.settings_service.saved.duplicate(true)
	adapter._handle_command({
		"type": "control.settings.update",
		"settings": {"themePreset": "solid", "credential": "must-not-cross"},
	}, "settings-request-2")
	var invalid_control_rejected: bool = services.settings_service.saved == saved_before_invalid \
		and adapter.command_results.size() == 2 \
		and adapter.command_results[1].get("status", "") == "failed" \
		and adapter.command_results[1].get("errorCode", "") == "invalid-settings"

	adapter._handle_command({"type": "character.activate", "packageId": "character.scifi", "version": "2.0.0"})
	adapter.preview_state = {"status": "ready", "packageId": "character.scifi", "version": "2.0.0"}
	adapter.preview_animation_cache["idle"] = {"bytes": 64}
	adapter._handle_command({"type": "character.uninstall", "packageId": "character.scifi", "version": "2.0.0"}, "uninstall-request-1")
	var uninstall_preview_released: bool = str(adapter.preview_state.get("status", "")) == "idle" \
		and adapter.preview_animation_cache.is_empty()
	var uninstall_pending_result: bool = adapter.command_results.any(func(entry: Dictionary) -> bool:
		return entry.get("id", "") == "uninstall-request-1" \
			and entry.get("type", "") == "character.uninstall" \
			and entry.get("status", "") == "accepted"
	)
	adapter._handle_command({"type": "chat.submit", "prompt": "hello"})
	var activation_ok := bus.published.any(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"character.activate_requested" \
			and entry.get("payload", {}).get("package_id", "") == "character.scifi"
	)
	var uninstall_ok := bus.published.any(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"character.uninstall_requested" \
			and entry.get("payload", {}).get("package_id", "") == "character.scifi" \
			and entry.get("payload", {}).get("version", "") == "2.0.0" \
			and entry.get("payload", {}).get("request_id", "") == "uninstall-request-1"
	)
	adapter._on_character_uninstall_result({"request_id": "uninstall-request-1", "ok": true})
	var uninstall_result_ok: bool = adapter.command_results.any(func(entry: Dictionary) -> bool:
		return entry.get("id", "") == "uninstall-request-1" \
			and entry.get("type", "") == "character.uninstall" \
			and entry.get("status", "") == "succeeded" \
			and entry.get("errorCode", "") == ""
	)
	var chat_ok := bus.published.any(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"ai.prompt_requested" \
			and entry.get("payload", {}).get("prompt", "") == "hello"
	)
	# ADR-0052/G16.25B: transcript actions are Runtime-owned, revision checked,
	# and late events from superseded branches are ignored.
	var original_id := adapter.chat_active_message_id
	adapter._on_chat_delta({"message_id": original_id, "text": "first answer."})
	var first_stream_snapshot_due := adapter.chat_stream_snapshot_not_before_msec
	adapter._on_chat_delta({"message_id": original_id, "text": "first answer. second answer."})
	var stream_snapshot_throttle_ok: bool = adapter.chat_stream_snapshot_pending \
		and first_stream_snapshot_due > 0 \
		and adapter.chat_stream_snapshot_not_before_msec == first_stream_snapshot_due \
		and AdapterScript.CHAT_STREAM_SNAPSHOT_INTERVAL_MS == 100
	adapter._on_chat_completed({"message_id": original_id, "text": "first answer. second answer."})
	adapter._handle_command({"type": "chat.feedback.set", "messageId": "%s:assistant" % original_id, "feedback": "positive", "expectedRevision": 1}, "feedback-1")
	adapter._handle_command({"type": "chat.message.read-aloud", "messageId": "%s:assistant" % original_id, "expectedRevision": 2}, "read-1")
	var read_aloud_requests := bus.published.filter(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"tts.requested" and entry.get("payload", {}).get("source", "") == "electron-read-aloud"
	)
	var read_aloud_chunked: bool = read_aloud_requests.size() == 2 \
		and int(read_aloud_requests[0].get("payload", {}).get("chunk_index", -1)) == 0 \
		and not bool(read_aloud_requests[0].get("payload", {}).get("final", true)) \
		and str(read_aloud_requests[0].get("payload", {}).get("text", "")) == "first answer." \
		and int(read_aloud_requests[1].get("payload", {}).get("chunk_index", -1)) == 1 \
		and bool(read_aloud_requests[1].get("payload", {}).get("final", false)) \
		and str(read_aloud_requests[1].get("payload", {}).get("text", "")) == "second answer." \
		and str(read_aloud_requests[0].get("payload", {}).get("message_id", "")) == str(read_aloud_requests[1].get("payload", {}).get("message_id", ""))
	var tts_count_before_inflight_retry := read_aloud_requests.size()
	adapter._handle_command({"type": "chat.message.read-aloud", "messageId": "%s:assistant" % original_id, "expectedRevision": 2}, "read-inflight")
	var tts_count_after_inflight_retry := bus.published.filter(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"tts.requested" and entry.get("payload", {}).get("source", "") == "electron-read-aloud"
	).size()
	var inflight_guard_ok: bool = tts_count_after_inflight_retry == tts_count_before_inflight_retry \
		and str(adapter.voice_health_state.get("status", "")) == "synthesizing"
	var feedback_and_read_ok: bool = adapter.chat_revision == 2 \
		and str(adapter.chat_messages[1].get("feedback", "")) == "positive" \
		and read_aloud_chunked and inflight_guard_ok
	# A provider rate limit is a bounded Runtime state, not a reason to keep
	# emitting TTS requests. The adapter blocks repeated Read aloud commands and
	# projects the authoritative retry deadline for Electron's countdown UI.
	context.settings["tts_enabled"] = true
	adapter.voice_health_state = {"status": "failed", "reasonCode": "provider-rate-limited", "lastSuccessAtMs": 0}
	adapter.voice_rate_limit_retry_at_ms = int(Time.get_unix_time_from_system() * 1000.0) + 60000
	var tts_count_before_cooldown_retry := read_aloud_requests.size()
	adapter._handle_command({"type": "chat.message.read-aloud", "messageId": "%s:assistant" % original_id, "expectedRevision": 2}, "read-rate-limited")
	var tts_count_after_cooldown_retry := bus.published.filter(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"tts.requested" and entry.get("payload", {}).get("source", "") == "electron-read-aloud"
	).size()
	var cooldown_snapshot := adapter._voice_health_snapshot()
	var rate_limit_guard_ok: bool = tts_count_after_cooldown_retry == tts_count_before_cooldown_retry \
		and str(cooldown_snapshot.get("reasonCode", "")) == "provider-rate-limited" \
		and int(cooldown_snapshot.get("retryAtMs", 0)) > int(Time.get_unix_time_from_system() * 1000.0)
	print("[VOICE-COOLDOWN-CONTRACT] before=", tts_count_before_cooldown_retry, " after=", tts_count_after_cooldown_retry, " snapshot=", cooldown_snapshot, " ok=", rate_limit_guard_ok)
	adapter.voice_rate_limit_retry_at_ms = 0
	adapter.voice_health_state = {"status": "idle", "reasonCode": "", "lastSuccessAtMs": 0}
	adapter._handle_command({"type": "chat.message.edit", "messageId": original_id, "prompt": "edited prompt", "expectedRevision": 2}, "edit-1")
	var edited_id := adapter.chat_active_message_id
	adapter._on_chat_delta({"message_id": original_id, "text": "late old branch"})
	var stale_edit_event_ignored: bool = adapter.chat_messages.size() == 1 and str(adapter.chat_messages[0].get("text", "")) == "edited prompt"
	adapter._on_chat_delta({"message_id": edited_id, "text": "edited answer"})
	adapter._on_chat_completed({"message_id": edited_id, "text": "edited answer"})
	adapter._handle_command({"type": "chat.message.regenerate", "messageId": "%s:assistant" % edited_id, "expectedRevision": 3}, "regen-1")
	var regenerated_id := adapter.chat_active_message_id
	var regenerate_ok: bool = adapter.chat_revision == 4 and regenerated_id != edited_id \
		and adapter.chat_messages.size() == 1 and str(adapter.chat_messages[0].get("text", "")) == "edited prompt"
	adapter._handle_command({"type": "chat.turn.cancel", "expectedRevision": 4}, "cancel-1")
	adapter._on_chat_completed({"message_id": regenerated_id, "text": "late cancelled branch"})
	var cancel_late_event_ok: bool = adapter.chat_revision == 5 and adapter.chat_active_message_id.is_empty() \
		and adapter.chat_messages.size() == 1
	var previous_session := adapter.chat_session_id
	adapter._handle_command({"type": "chat.session.new", "expectedRevision": 5}, "new-session-1")
	adapter._handle_command({"type": "chat.feedback.set", "messageId": "missing", "feedback": "positive", "expectedRevision": 5}, "stale-feedback-1")
	var new_session_and_revision_ok: bool = adapter.chat_revision == 6 and adapter.chat_messages.is_empty() \
		and adapter.chat_session_id != previous_session \
		and adapter.command_results.any(func(entry: Dictionary) -> bool:
			return entry.get("id", "") == "stale-feedback-1" and entry.get("errorCode", "") == "revision-conflict"
	)
	# Renderer-supplied credentials and unapproved raw cloud mutations remain
	# outside the functional-adapter allowlist. S6 adds only bounded library and
	# sync commands that delegate to existing Runtime-owned services.
	adapter._handle_command({"type": "cloud.auth.password", "email": "user@example.com", "password": "password123"})
	adapter._handle_command({"type": "cloud.download.install", "packageId": "character.sabai", "version": "1.2.0"})
	var cloud_commands_rejected: bool = services.cloud_auth_service.signed_in_email.is_empty() \
		and services.cloud_download_service.requested.is_empty()
	adapter._handle_command({"type": "cloud.library.refresh"}, "library-refresh-1")
	adapter._handle_command({"type": "cloud.library.install", "packageId": "character.sabai", "version": "1.2.0"}, "library-install-1")
	adapter._handle_command({"type": "cloud.sync.now"}, "cloud-sync-1")
	var library_refresh_result_ok: bool = adapter.command_results.any(func(entry: Dictionary) -> bool:
		return entry.get("id", "") == "library-refresh-1" and entry.get("status", "") == "accepted"
	)
	var library_install_result_ok: bool = adapter.command_results.any(func(entry: Dictionary) -> bool:
		return entry.get("id", "") == "library-install-1" and entry.get("status", "") == "accepted"
	)
	var cloud_sync_result_ok: bool = adapter.command_results.any(func(entry: Dictionary) -> bool:
		return entry.get("id", "") == "cloud-sync-1" and entry.get("status", "") == "accepted"
	)
	var cloud_s6_commands_ok: bool = services.cloud_library_service.library_refreshes == 1 \
		and services.cloud_download_service.requested == "character.sabai@1.2.0" \
		and services.cloud_progression_service.sync_calls == 1 \
		and services.cloud_progression_service.refresh_calls == 1 \
		and library_refresh_result_ok and library_install_result_ok and cloud_sync_result_ok
	adapter._on_cloud_projection_changed({"status": "download-timeout", "packageId": "character.sabai", "version": "1.2.0"})
	var async_install_failure_propagated: bool = adapter.command_results.any(func(entry: Dictionary) -> bool:
		return entry.get("id", "") == "library-install-1" \
			and entry.get("status", "") == "failed" \
			and entry.get("errorCode", "") == "download-timeout"
	)
	adapter._handle_command({
		"type": "store.install-handoff",
		"packageId": "character.sabai",
		"version": "1.2.0",
		"grant": "A".repeat(43),
	})
	var system_handoff_ok: bool = services.cloud_download_service.handoff_requested == "character.sabai@1.2.0"
	adapter._handle_command({
		"type": "store.install-handoff",
		"packageId": "character.sabai",
		"version": "1.2.0",
		"grant": "short",
	})
	var malformed_handoff_rejected: bool = services.cloud_download_service.handoff_requested == "character.sabai@1.2.0"
	var activation_count_before_preview := bus.published.filter(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"character.activate_requested"
	).size()
	adapter._handle_command({"type": "character.preview.open", "packageId": "character.scifi", "version": "2.0.0"})
	var preview_open_lazy: bool = services.character_service.metadata_calls == 1 \
		and services.character_service.animation_requests.is_empty() \
		and adapter.preview_frames == null \
		and adapter.preview_animation_cache.is_empty() \
		and str(adapter.preview_state.get("status", "")) == "ready" \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "idle" \
		and str(adapter.preview_state.get("framePngBase64", "")).is_empty() \
		and (adapter.preview_state.get("clipThumbnailPngBase64", {}) as Dictionary).is_empty() \
		and services.character_service.thumbnail_requests.is_empty()
	adapter._handle_command({"type": "character.preview.thumbnail-page", "packageId": "character.scifi", "version": "2.0.0", "offset": 0})
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "wave"})
	var preview_uncached_non_blocking: bool = str(adapter.preview_state.get("status", "")) == "loading" \
		and str(adapter.preview_state.get("framePngBase64", "")).is_empty()
	var preview_wave_settled: bool = await _wait_for_preview(adapter)
	var wave_frame_before_atomic := str(adapter.preview_state.get("framePngBase64", ""))
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "angry"})
	# Character Manager sends select -> play immediately. While the uncached
	# atomic swap is preparing, selectedAnimation still reports the old visible
	# clip; play must follow the pending requested clip rather than re-request it.
	adapter._handle_command({"type": "character.preview.play", "packageId": "character.scifi", "version": "2.0.0"})
	var preview_atomic_hold: bool = preview_wave_settled \
		and not wave_frame_before_atomic.is_empty() \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "wave" \
		and str(adapter.preview_state.get("framePngBase64", "")) == wave_frame_before_atomic \
		and str(adapter.preview_state.get("status", "")) != "loading" \
		and adapter.preview_requested_animation == "angry" \
		and adapter.preview_requested_playing
	var preview_angry_settled: bool = await _wait_for_preview(adapter)
	var preview_select_play_targets_pending: bool = preview_angry_settled \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "angry" \
		and bool(adapter.preview_state.get("isPlaying", false))
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "wave"})
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "appear"})
	var preview_appear_settled: bool = await _wait_for_preview(adapter)
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "happy"})
	var preview_happy_settled: bool = await _wait_for_preview(adapter)
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "sad"})
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "speak"})
	var preview_reselection_settled: bool = await _wait_for_preview(adapter)
	var preview_stale_result_discarded: bool = preview_reselection_settled \
		and adapter.preview_animation_cache.has("speak") \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "speak"
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "climb_top"})
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "wave"})
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "climb_top"})
	var preview_reattached_settled: bool = await _wait_for_preview(adapter)
	var preview_inflight_reattached: bool = preview_reattached_settled \
		and adapter.preview_animation_cache.has("climb_top") \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "climb_top"
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "wave"})
	var preview_page_prefetch_ok: bool = ["angry", "appear", "climb_down", "climb_ready", "climb_top", "happy"].all(
		func(name: String) -> bool: return adapter.preview_animation_cache.has(name)
	)
	var preview_cache_bounded: bool = adapter.preview_animation_cache_bytes <= AdapterScript.PREVIEW_ANIMATION_CACHE_BYTES \
		and AdapterScript.PREVIEW_ANIMATION_CACHE_BYTES == 32 * 1024 * 1024 \
		and adapter.preview_atlas_image_cache.size() <= AdapterScript.PREVIEW_ATLAS_IMAGE_CACHE_LIMIT \
		and adapter.preview_atlas_image_cache_bytes <= AdapterScript.PREVIEW_ATLAS_IMAGE_CACHE_BYTES \
		and adapter.preview_animation_cache.has("wave") \
		and services.character_service.animation_requests.count("wave") == 1 \
		and preview_page_prefetch_ok
	var preview_background_ok: bool = preview_uncached_non_blocking and preview_wave_settled and preview_atomic_hold \
		and preview_angry_settled and preview_select_play_targets_pending and preview_appear_settled and preview_happy_settled \
		and preview_stale_result_discarded and preview_inflight_reattached and preview_page_prefetch_ok
	adapter._handle_command({"type": "character.preview.set-loop", "packageId": "character.scifi", "version": "2.0.0", "enabled": true})
	adapter._handle_command({"type": "character.preview.set-speed", "packageId": "character.scifi", "version": "2.0.0", "speed": 1.5})
	adapter._handle_command({"type": "character.preview.play", "packageId": "character.scifi", "version": "2.0.0"})
	var preview_thumbnails_value: Variant = adapter.preview_state.get("clipThumbnailPngBase64", {})
	var preview_thumbnails: Dictionary = preview_thumbnails_value if preview_thumbnails_value is Dictionary else {}
	var preview_ok: bool = str(adapter.preview_state.get("status", "")) == "playing" \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "wave" \
		and bool(adapter.preview_state.get("loop", false)) \
		and is_equal_approx(float(adapter.preview_state.get("speed", 0.0)), 1.5) \
		and not str(adapter.preview_state.get("framePngBase64", "")).is_empty() \
		and preview_thumbnails.has("idle") \
		and not str(preview_thumbnails.get("idle", "")).is_empty()
	var activation_count_after_preview := bus.published.filter(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"character.activate_requested"
	).size()
	var preview_isolated: bool = activation_count_before_preview == activation_count_after_preview
	var frame_bounded: bool = str(adapter.preview_state.get("framePngBase64", "")).length() <= AdapterScript.MAX_PREVIEW_BASE64_LENGTH \
		and int(adapter.preview_state.get("frameWidth", 0)) <= AdapterScript.MAX_PREVIEW_FRAME_WIDTH \
		and int(adapter.preview_state.get("frameHeight", 0)) <= AdapterScript.MAX_PREVIEW_FRAME_HEIGHT \
		and preview_thumbnails.size() <= AdapterScript.MAX_PREVIEW_SHORTCUT_THUMBNAILS \
		and preview_thumbnails.values().all(func(encoded: Variant) -> bool: return str(encoded).length() <= AdapterScript.MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH)
	adapter._handle_command({"type": "character.preview.thumbnail-page", "packageId": "character.scifi", "version": "2.0.0", "offset": 6})
	var page_thumbnails_value: Variant = adapter.preview_state.get("clipThumbnailPngBase64", {})
	var page_thumbnails: Dictionary = page_thumbnails_value if page_thumbnails_value is Dictionary else {}
	var thumbnail_page_ok: bool = adapter.preview_thumbnail_offset == 6 \
		and page_thumbnails.has("idle") \
		and page_thumbnails.has("sad") \
		and page_thumbnails.has("wave")
	adapter._handle_command({"type": "character.preview.thumbnail-page", "packageId": "character.scifi", "version": "2.0.0", "offset": 5})
	var invalid_thumbnail_page_rejected: bool = adapter.preview_thumbnail_offset == 6
	adapter._handle_command({"type": "character.preview.set-speed", "packageId": "character.scifi", "version": "2.0.0", "speed": 3.0})
	var invalid_speed_rejected: bool = is_equal_approx(float(adapter.preview_state.get("speed", 0.0)), 1.5)
	# Warm-up is allowed while Chat is still hidden. It must prepare the bounded
	# core cache without claiming Chat presentation ownership.
	var warm_preview_requested: bool = adapter.warm_chat_preview()
	for _index in range(120):
		adapter._poll_preview_load()
		if adapter._chat_core_preview_cache_ready():
			break
		await process_frame
	var warm_preview_ready: bool = warm_preview_requested \
		and not adapter.chat_presentation_active \
		and adapter.preview_animation_cache.has("idle") \
		and adapter.preview_animation_cache.has("think") \
		and adapter.preview_animation_cache.has("speak")
	# ADR-0053 regression: opening Chat must project the active character into the
	# left companion panel without recursively re-activating the same cached clip.
	# Use a deliberately invalid but non-empty bridge path so _write_snapshot()
	# executes its projection path without leaving test artifacts on disk. This
	# reproduces the production-only recursion that a blank session_directory hid.
	adapter.session_directory = "::ocp-invalid-contract-path::"
	var get_active_calls_before_chat := services.package_service.get_active_calls
	var get_active_candidate_calls_before_chat := services.package_service.get_active_candidate_calls
	adapter._handle_command({"type": "shell.chat-visibility", "active": true})
	adapter.session_directory = ""
	var chat_preview_settled: bool = await _wait_for_preview(adapter)
	adapter._write_snapshot()
	var chat_preview_reentrant_safe: bool = chat_preview_settled \
		and str(adapter.preview_state.get("selectedAnimation", "")) == "idle" \
		and str(adapter.preview_state.get("status", "")) == "playing" \
		and bool(adapter.preview_state.get("isPlaying", false)) \
		and adapter.preview_animation_cache.has("idle") \
		and adapter.preview_animation_cache.has("think") \
		and adapter.preview_animation_cache.has("speak") \
		and services.character_service.animation_requests.count("idle") == 1 \
		and services.character_service.animation_requests.count("think") == 1 \
		and services.character_service.animation_requests.count("speak") == 1
	var chat_preview_avoids_reverify: bool = services.package_service.get_active_calls == get_active_calls_before_chat 		and services.package_service.get_active_candidate_calls == get_active_candidate_calls_before_chat
	adapter._handle_command({"type": "shell.chat-visibility", "active": false})
	var system_command_coalesce_ok: bool = adapter._is_redundant_system_command({"type": "shell.chat-visibility", "active": false}) 		and not adapter._is_redundant_system_command({"type": "shell.chat-visibility", "active": true}) 		and AdapterScript.MAX_COMMANDS_PER_POLL == 32
	adapter._handle_command({"type": "shell.companion-suppression", "active": true})
	var companion_suppression_on := bool(context.runtime_config.get("shell_companion_suppressed", false))
	adapter._handle_command({"type": "shell.companion-suppression", "active": false})
	var companion_suppression_ok := companion_suppression_on and not bool(context.runtime_config.get("shell_companion_suppressed", true))
	adapter._handle_command({"type": "character.preview.select", "packageId": "character.scifi", "version": "2.0.0", "animation": "climb_ready"})
	var close_started_at_msec := Time.get_ticks_msec()
	adapter._handle_command({"type": "character.preview.close", "packageId": "character.scifi", "version": "2.0.0"})
	var close_returned_immediately: bool = Time.get_ticks_msec() - close_started_at_msec < 20 \
		and str(adapter.preview_state.get("status", "")) == "idle"
	var close_worker_settled: bool = await _wait_for_preview(adapter)
	var close_cleanup_ok: bool = str(adapter.preview_state.get("status", "")) == "idle" and adapter.preview_frames == null \
		and adapter.preview_animation_cache.is_empty() and adapter.preview_animation_order.is_empty() \
		and adapter.preview_active_payload.is_empty() and adapter.preview_animation_cache_bytes == 0 \
		and adapter.preview_load_thread == null and adapter.preview_requested_animation.is_empty() \
		and adapter.preview_thumbnail_base64_cache.is_empty() \
		and adapter.preview_atlas_image_cache.is_empty() and adapter.preview_atlas_image_order.is_empty() \
		and adapter.preview_atlas_image_cache_bytes == 0 \
		and str(adapter.preview_state.get("framePngBase64", "")).is_empty() \
		and (adapter.preview_state.get("clipThumbnailPngBase64", {}) as Dictionary).is_empty() \
		and close_returned_immediately and close_worker_settled
	adapter._handle_command({"type": "package.install", "path": "C:/unsafe.ocp"})
	var rejected_ok := not bus.published.any(func(entry: Dictionary) -> bool:
		return entry.get("topic", &"") == &"package.install_requested"
	)
	var local_effect_path := ProjectSettings.globalize_path("user://desktop-shell-local-effect-smoke.ocp")
	var local_effect_file := FileAccess.open(local_effect_path, FileAccess.WRITE)
	if local_effect_file != null:
		local_effect_file.store_string("effect-smoke")
		local_effect_file.close()
	var effect_event_start := bus.published.size()
	adapter._handle_command({"type": "local.install-effect", "path": local_effect_path})
	var local_effect_install_ok := false
	for event_index in range(effect_event_start, bus.published.size()):
		var effect_event: Dictionary = bus.published[event_index]
		if effect_event.get("topic", &"") == &"effect_pack.install_requested" \
		and str((effect_event.get("payload", {}) as Dictionary).get("path", "")) == local_effect_path:
			local_effect_install_ok = true
			break
	DirAccess.remove_absolute(local_effect_path)
	# Shutdown must be terminal for preview work. A deferred warm-up may resume on
	# the same frame that Runtime begins shutdown; it must not start a Thread
	# after stop() has already joined the previous worker.
	adapter.stop()
	var shutdown_preview_guard_ok: bool = adapter.stopping \
		and not adapter.is_processing() \
		and not adapter.warm_chat_preview()
	adapter._start_preview_load_if_idle()
	shutdown_preview_guard_ok = shutdown_preview_guard_ok and adapter.preview_load_thread == null
	var ok: bool = settings_ok and full_settings_ok and projection_ok and active_reuse_ok and cloud_projection_ok and result_ok and invalid_control_rejected \
		and activation_ok and uninstall_ok and uninstall_preview_released and uninstall_pending_result and uninstall_result_ok and chat_ok and stream_snapshot_throttle_ok and feedback_and_read_ok and rate_limit_guard_ok and stale_edit_event_ignored \
		and regenerate_ok and cancel_late_event_ok and new_session_and_revision_ok and cloud_commands_rejected and cloud_s6_commands_ok and async_install_failure_propagated \
		and system_handoff_ok and malformed_handoff_rejected and preview_open_lazy and preview_background_ok and preview_cache_bounded and preview_ok and preview_isolated \
		and frame_bounded and thumbnail_page_ok and invalid_thumbnail_page_rejected \
		and invalid_speed_rejected and warm_preview_ready and chat_preview_reentrant_safe and chat_preview_avoids_reverify and system_command_coalesce_ok and companion_suppression_ok and close_cleanup_ok and rejected_ok and local_effect_install_ok and shutdown_preview_guard_ok
	print("[G16.25B] shell adapter legacy_settings=", settings_ok, " full_settings=", full_settings_ok, " projection=", projection_ok, " active_reuse=", active_reuse_ok, " result=", result_ok, " invalid_rejected=", invalid_control_rejected, " activation=", activation_ok, " uninstall=", uninstall_ok, " uninstall_preview_released=", uninstall_preview_released, " uninstall_pending=", uninstall_pending_result, " uninstall_result=", uninstall_result_ok, " chat=", chat_ok, " stream_throttle=", stream_snapshot_throttle_ok, " feedback_read=", feedback_and_read_ok, " rate_limit_guard=", rate_limit_guard_ok, " stale_edit_ignored=", stale_edit_event_ignored, " regenerate=", regenerate_ok, " cancel_late=", cancel_late_event_ok, " new_session_revision=", new_session_and_revision_ok, " cloud_rejected=", cloud_commands_rejected, " cloud_s6=", cloud_s6_commands_ok, " system_handoff=", system_handoff_ok, " preview_open_lazy=", preview_open_lazy, " preview_background=", preview_background_ok, " preview_atomic_hold=", preview_atomic_hold, " preview_select_play_pending=", preview_select_play_targets_pending, " preview_angry_settled=", preview_angry_settled, " preview_stale_discarded=", preview_stale_result_discarded, " preview_inflight_reattached=", preview_inflight_reattached, " preview_cache_bounded=", preview_cache_bounded, " preview=", preview_ok, " isolated=", preview_isolated, " frame_bounded=", frame_bounded, " thumbnail_page=", thumbnail_page_ok, " invalid_thumbnail_page_rejected=", invalid_thumbnail_page_rejected, " warm_preview_ready=", warm_preview_ready, " chat_preview_reentrant_safe=", chat_preview_reentrant_safe, " chat_preview_avoids_reverify=", chat_preview_avoids_reverify, " command_coalesce=", system_command_coalesce_ok, " companion_suppression=", companion_suppression_ok, " cleanup=", close_cleanup_ok, " rejection=", rejected_ok, " local_effect_install=", local_effect_install_ok, " shutdown_preview_guard=", shutdown_preview_guard_ok, " ok=", ok)
	holder.free()
	await process_frame
	quit(0 if ok else 1)
