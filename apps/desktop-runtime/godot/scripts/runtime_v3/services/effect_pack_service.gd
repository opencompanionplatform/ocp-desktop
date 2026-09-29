extends "res://scripts/runtime_v3/services/runtime_service.gd"
class_name RuntimeV3EffectPackService

const ReaderScript = preload("res://scripts/runtime/packages/ocp_package_reader.gd")
const ValidatorScript = preload("res://scripts/runtime/packages/ocp_package_validator.gd")
const InstallerScript = preload("res://scripts/runtime/packages/effect_pack_installer.gd")
const RepositoryScript = preload("res://scripts/runtime/packages/installed_effect_pack_repository.gd")

const STATE_FILE := "user://runtime/state.json"
const CHARACTER_EFFECT_PROFILES_FILE := "user://runtime/character_effect_profiles.json"
const CHARACTER_EFFECT_PROFILE_SCHEMA := 1
const STARTER_ID := "effect.starter-neon"
const STARTER_VERSION := "1.0.0"
const STARTER_FILENAME := "effect.starter-neon-1.0.0.ocp"
const STARTER_ENV := "OCP_EMBEDDED_STARTER_EFFECT_PACK"
const STARTER_DEFAULTS_SCHEMA := 1
const STARTER_CONTENT_SCHEMA := 2
const SLOT_NAMES := ["bodyAura", "groundRune", "levelUpBurst"]
const BOND_ORDER := {
	"stranger": 0,
	"friend": 1,
	"close-friend": 2,
	"partner": 3,
	"best-companion": 4,
}
const RANK_PALETTES := {
	"stranger": {"name": "Calm Cyan", "aura": "#22D3EE", "rune": "#38E1FF", "burst": "#CFFAFE", "intensity": 70, "speedPermille": 1000},
	"friend": {"name": "Friendly Blue", "aura": "#38BDF8", "rune": "#60A5FA", "burst": "#DBEAFE", "intensity": 76, "speedPermille": 1020},
	"close-friend": {"name": "Bond Violet", "aura": "#818CF8", "rune": "#8B5CF6", "burst": "#E9D5FF", "intensity": 84, "speedPermille": 1040},
	"partner": {"name": "Partner Bloom", "aura": "#C084FC", "rune": "#D946EF", "burst": "#F5D0FE", "intensity": 92, "speedPermille": 1080},
	"best-companion": {"name": "Golden Companion", "aura": "#FACC15", "rune": "#F59E0B", "burst": "#FEF3C7", "intensity": 100, "speedPermille": 1120},
}

var _progression_service: Node
var _preview_rank := ""
var character_effect_profiles_file := CHARACTER_EFFECT_PROFILES_FILE


func start() -> void:
	event_bus.subscribe(&"effect_pack.install_requested", Callable(self, "_on_install_requested"))
	event_bus.subscribe(&"effect_pack.equip_requested", Callable(self, "_on_equip_requested"))
	event_bus.subscribe(&"effect_pack.unequip_requested", Callable(self, "_on_unequip_requested"))
	event_bus.subscribe(&"effect_pack.slot_enabled_requested", Callable(self, "_on_slot_enabled_requested"))
	event_bus.subscribe(&"effect_pack.uninstall_requested", Callable(self, "_on_uninstall_requested"))


func stop() -> void:
	event_bus.unsubscribe(&"effect_pack.install_requested", Callable(self, "_on_install_requested"))
	event_bus.unsubscribe(&"effect_pack.equip_requested", Callable(self, "_on_equip_requested"))
	event_bus.unsubscribe(&"effect_pack.unequip_requested", Callable(self, "_on_unequip_requested"))
	event_bus.unsubscribe(&"effect_pack.slot_enabled_requested", Callable(self, "_on_slot_enabled_requested"))
	event_bus.unsubscribe(&"effect_pack.uninstall_requested", Callable(self, "_on_uninstall_requested"))


func bind_progression_service(target: Node) -> void:
	_progression_service = target


func list_installed() -> Array:
	var projected: Array = []
	for item_value in RepositoryScript.new().list_installed():
		if not item_value is Dictionary:
			continue
		var item: Dictionary = item_value
		projected.append({
			"packageId": str(item.get("packageId", "")),
			"version": str(item.get("version", "")),
			"path": str(item.get("path", "")),
			"manifest": (item.get("manifest", {}) as Dictionary).duplicate(true) if item.get("manifest", {}) is Dictionary else {},
			"entry": (item.get("entry", {}) as Dictionary).duplicate(true) if item.get("entry", {}) is Dictionary else {},
		})
	return projected


func is_installed_exact(package_id: String, version: String) -> bool:
	if package_id.strip_edges().is_empty() or version.strip_edges().is_empty():
		return false
	return not RepositoryScript.new().find_exact(package_id.strip_edges(), version.strip_edges()).is_empty()


func ensure_embedded_starter() -> Dictionary:
	var existing := RepositoryScript.new().find_exact(STARTER_ID, STARTER_VERSION)
	var installed_now := existing.is_empty()
	var state := _read_state()
	var content_migration_needed := (not installed_now) \
		and int(state.get("effectStarterContentSchema", 0)) < STARTER_CONTENT_SCHEMA
	if installed_now or content_migration_needed:
		var package_path := _embedded_starter_path()
		if package_path.is_empty():
			return {"ok": false, "error": "Embedded starter effect pack is unavailable"}
		var installed := install(package_path)
		if not bool(installed.get("ok", false)):
			return installed
		state = _read_state()
		state["effectStarterContentSchema"] = STARTER_CONTENT_SCHEMA
		if not _write_state(state):
			return {"ok": false, "error": "Could not persist Starter Effect content migration"}

	var loadout := get_loadout()
	var changed := false
	var pack := RepositoryScript.new().find_exact(STARTER_ID, STARTER_VERSION)
	var entry_value: Variant = pack.get("entry", {})
	if entry_value is Dictionary:
		var slots_value: Variant = (entry_value as Dictionary).get("slots", {})
		if slots_value is Dictionary:
			for slot_name in SLOT_NAMES:
				if loadout.has(slot_name):
					continue
				if (slots_value as Dictionary).has(slot_name):
					loadout[slot_name] = {"packageId": STARTER_ID, "version": STARTER_VERSION}
					changed = true
	if changed:
		_save_loadout(loadout)
	var defaults_changed := _ensure_starter_slot_defaults(loadout)
	var migrated := content_migration_needed or changed or defaults_changed
	if migrated:
		_publish_changed("starter-equipped" if installed_now else "starter-migrated")
	return {
		"ok": true,
		"status": "installed-and-equipped" if installed_now else ("migrated" if migrated else "ready"),
		"packageId": STARTER_ID,
		"version": STARTER_VERSION,
		"loadout": loadout,
	}


func _embedded_starter_path() -> String:
	var explicit_path := OS.get_environment(STARTER_ENV).strip_edges()
	if not explicit_path.is_empty():
		var resolved_explicit := ProjectSettings.globalize_path(explicit_path)
		if FileAccess.file_exists(resolved_explicit):
			return resolved_explicit
	var executable_dir := OS.get_executable_path().get_base_dir()
	var bundled_path := executable_dir.path_join("starter").path_join(STARTER_FILENAME)
	if FileAccess.file_exists(bundled_path):
		return bundled_path
	# Source/dev fallback. Release builds use the executable-relative path above.
	var local_path := ProjectSettings.globalize_path("res://../../../release/starter-local/" + STARTER_FILENAME)
	if FileAccess.file_exists(local_path):
		return local_path
	return ""


func _ensure_starter_slot_defaults(loadout: Dictionary) -> bool:
	var state := _read_state()
	var enabled_value: Variant = state.get("effectSlotEnabled", {})
	var enabled: Dictionary = enabled_value.duplicate(true) if enabled_value is Dictionary else {}
	var changed := false
	var defaults := {"bodyAura": true, "groundRune": false, "levelUpBurst": true}
	for slot_name in SLOT_NAMES:
		if enabled.has(slot_name):
			continue
		var identity_value: Variant = loadout.get(slot_name, {})
		if not identity_value is Dictionary:
			continue
		var identity := identity_value as Dictionary
		if str(identity.get("packageId", "")) != STARTER_ID or str(identity.get("version", "")) != STARTER_VERSION:
			continue
		enabled[slot_name] = bool(defaults.get(slot_name, true))
		changed = true
	if int(state.get("effectStarterDefaultsSchema", 0)) < STARTER_DEFAULTS_SCHEMA:
		state["effectStarterDefaultsSchema"] = STARTER_DEFAULTS_SCHEMA
		changed = true
	if not changed:
		return false
	state["effectSlotEnabled"] = enabled
	return _write_state(state)


func install(path: String) -> Dictionary:
	var reader = ReaderScript.new()
	var read_result = reader.read(path)
	if not read_result.ok:
		return {"ok": false, "error": str(read_result.error_message)}
	if str(read_result.manifest.get("type", "")) != "effect-pack":
		read_result.close()
		return {"ok": false, "error": "Selected package is not an effect-pack"}
	var validation = ValidatorScript.new().validate(read_result)
	if not validation.ok:
		read_result.close()
		return {"ok": false, "error": str(validation.error_message)}
	var result = InstallerScript.new().install(read_result)
	read_result.close()
	if not result.ok:
		return {"ok": false, "error": str(result.error_message)}
	var payload := {
		"ok": true,
		"packageId": result.package_id,
		"version": result.version,
		"path": result.installed_path,
	}
	if is_instance_valid(event_bus):
		event_bus.publish(&"effect_pack.installed", payload)
	return payload


func uninstall(package_id: String, version: String) -> bool:
	var loadout := get_loadout()
	var changed := false
	for slot_name in SLOT_NAMES:
		var identity_value: Variant = loadout.get(slot_name, {})
		if identity_value is Dictionary:
			var identity := identity_value as Dictionary
			if str(identity.get("packageId", "")) == package_id and str(identity.get("version", "")) == version:
				loadout.erase(slot_name)
				changed = true
	if changed:
		_save_loadout(loadout)
	var removed := RepositoryScript.new().uninstall(package_id, version)
	if removed:
		_publish_changed("uninstalled")
	return removed


func equip(package_id: String, version: String, slot_name: String = "") -> bool:
	var item := RepositoryScript.new().find_exact(package_id, version)
	if item.is_empty():
		return false
	var entry_value: Variant = item.get("entry", {})
	if not entry_value is Dictionary:
		return false
	var slots_value: Variant = (entry_value as Dictionary).get("slots", {})
	if not slots_value is Dictionary:
		return false
	var slots := slots_value as Dictionary
	var targets := SLOT_NAMES if slot_name.is_empty() else [slot_name]
	var loadout := get_loadout()
	var changed := false
	for target in targets:
		if target not in SLOT_NAMES or not slots.has(target):
			continue
		loadout[target] = {"packageId": package_id, "version": version}
		changed = true
	if not changed:
		return false
	if not _save_loadout(loadout):
		return false
	_publish_changed("equipped")
	return true


func unequip(slot_name: String) -> bool:
	if slot_name not in SLOT_NAMES:
		return false
	var loadout := get_loadout()
	if not loadout.has(slot_name):
		return true
	loadout.erase(slot_name)
	if not _save_loadout(loadout):
		return false
	_publish_changed("unequipped")
	return true


func get_loadout() -> Dictionary:
	var state := _read_state()
	var value: Variant = state.get("effectLoadout", {})
	var source: Dictionary = value if value is Dictionary else {}
	var result := {}
	for slot_name in SLOT_NAMES:
		var identity_value: Variant = source.get(slot_name, {})
		if not identity_value is Dictionary:
			continue
		var identity := identity_value as Dictionary
		var package_id := str(identity.get("packageId", ""))
		var version := str(identity.get("version", ""))
		if RepositoryScript.new().find_exact(package_id, version).is_empty():
			continue
		result[slot_name] = {"packageId": package_id, "version": version}
	return result


func resolve_slot(slot_name: String, include_disabled: bool = false, character_id_override: String = "") -> Dictionary:
	# Canonical Runtime resolution must never consume Character Manager preview
	# state. A temporary color/rank experiment in the shell is editor-only.
	return _resolve_slot_internal(slot_name, include_disabled, character_id_override, "")


func resolve_slot_for_preview(slot_name: String, include_disabled: bool = false, character_id_override: String = "") -> Dictionary:
	# Preview resolution may opt into the temporary bond-rank palette while the
	# live desktop companion remains on canonical Cloud progression.
	return _resolve_slot_internal(slot_name, include_disabled, character_id_override, _preview_rank)


func _resolve_slot_internal(slot_name: String, include_disabled: bool, character_id_override: String, preview_rank_override: String) -> Dictionary:
	if slot_name not in SLOT_NAMES:
		return {}
	if not include_disabled and not is_slot_enabled(slot_name):
		return {}
	var identity_value: Variant = get_loadout().get(slot_name, {})
	if not identity_value is Dictionary:
		return {}
	var identity := identity_value as Dictionary
	var item := RepositoryScript.new().find_exact(str(identity.get("packageId", "")), str(identity.get("version", "")))
	return _resolve_preview_item(item, slot_name, character_id_override, preview_rank_override, true)


func resolve_comparison_slot(slot_name: String, variant: String, character_id: String) -> Dictionary:
	if slot_name not in SLOT_NAMES or variant not in ["video-original", "video-blend", "starter-mist"]:
		return {}
	var package_id := "effect.starter-neon" if variant == "starter-mist" else "effect.video-neon"
	for item in list_installed():
		if str(item.get("packageId", "")) == package_id:
			var resolved := _resolve_preview_item(item, slot_name, character_id, _preview_rank, false)
			if variant != "starter-mist" and not resolved.is_empty():
				resolved.config["speedPermille"] = 1000
			return resolved
	return {}


func _resolve_preview_item(item: Dictionary, slot_name: String, character_id_override: String, preview_rank_override: String, apply_profile: bool) -> Dictionary:
	if item.is_empty():
		return {}
	var entry := item.get("entry", {}) as Dictionary
	var slots := entry.get("slots", {}) as Dictionary
	var slot_value: Variant = slots.get(slot_name, {})
	if not slot_value is Dictionary:
		return {}
	var slot := (slot_value as Dictionary).duplicate(true)
	_apply_video_neon_v1_placement_compatibility(slot_name, item, slot)
	var character_id := character_id_override.strip_edges()
	if character_id.is_empty() and is_instance_valid(context):
		character_id = str(context.character.get("id", "")).strip_edges()
	# Resolution order is intentionally deterministic:
	# .ocp base/progression -> OCP rank palette -> per-character override.
	_apply_progression_variant(slot_name, entry, slot, character_id, preview_rank_override)
	_apply_standard_rank_palette(slot_name, slot, character_id, preview_rank_override)
	if apply_profile:
		_apply_character_profile(character_id, slot_name, slot)
	return {
		"packageId": str(item.get("packageId", "")),
		"version": str(item.get("version", "")),
		"name": str(entry.get("name", item.get("packageId", ""))),
		"slot": slot_name,
		"path": str(item.get("path", "")),
		"config": slot,
	}


func _apply_video_neon_v1_placement_compatibility(slot_name: String, item: Dictionary, slot: Dictionary) -> void:
	# The bundled Creator sample effect.video-neon@1.0.0 was authored before
	# the final feet/ground placement contract. Upgrade only its untouched legacy
	# placement values at resolve time so already-installed copies behave like
	# newly-built Studio packages without mutating third-party packs.
	if str(item.get("packageId", "")) != "effect.video-neon" or str(item.get("version", "")) != "1.0.0":
		return
	match slot_name:
		"bodyAura":
			if is_equal_approx(float(slot.get("scale", 1.15)), 1.15):
				slot["scale"] = 1.12
			if not slot.has("anchor"):
				slot["anchor"] = "character-center"
			if not slot.has("offsetY"):
				slot["offsetY"] = -6
		"groundRune":
			if is_equal_approx(float(slot.get("scale", 1.45)), 1.45):
				slot["scale"] = 1.40
			if int(slot.get("offsetY", -8)) == -8:
				slot["offsetY"] = 0
			if str(slot.get("anchor", "character-feet")) == "character-feet":
				slot["anchor"] = "character-feet"
		"levelUpBurst":
			if is_equal_approx(float(slot.get("scale", 1.30)), 1.30):
				slot["scale"] = 1.10
			if int(slot.get("offsetY", -24)) == -24:
				slot["offsetY"] = 0
			if str(slot.get("anchor", "character-center")) == "character-center":
				slot["anchor"] = "character-feet-bottom"


func rank_palettes() -> Dictionary:
	return RANK_PALETTES.duplicate(true)


func character_profile(character_id: String) -> Dictionary:
	var normalized_id := character_id.strip_edges()
	if normalized_id.is_empty():
		return {}
	var document := _read_character_profiles()
	var characters_value: Variant = document.get("characters", {})
	if not characters_value is Dictionary:
		return {}
	var profile_value: Variant = (characters_value as Dictionary).get(normalized_id, {})
	return (profile_value as Dictionary).duplicate(true) if profile_value is Dictionary else {}


func save_character_profile(character_id: String, slot_name: String, overrides: Dictionary) -> Dictionary:
	var normalized_id := character_id.strip_edges()
	if not _valid_character_id(normalized_id) or slot_name not in SLOT_NAMES:
		return {"ok": false, "error": "invalid-character-effect-profile"}
	var normalized := _normalize_character_effect_overrides(overrides)
	if normalized.is_empty() and not overrides.is_empty():
		return {"ok": false, "error": "invalid-character-effect-overrides"}
	var document := _read_character_profiles()
	var characters_value: Variant = document.get("characters", {})
	var characters: Dictionary = characters_value.duplicate(true) if characters_value is Dictionary else {}
	var profile_value: Variant = characters.get(normalized_id, {})
	var profile: Dictionary = profile_value.duplicate(true) if profile_value is Dictionary else {}
	var slots_value: Variant = profile.get("slots", {})
	var slots: Dictionary = slots_value.duplicate(true) if slots_value is Dictionary else {}
	slots[slot_name] = normalized
	profile["slots"] = slots
	profile["updatedAtMs"] = int(Time.get_unix_time_from_system() * 1000.0)
	characters[normalized_id] = profile
	document["schemaVersion"] = CHARACTER_EFFECT_PROFILE_SCHEMA
	document["characters"] = characters
	if not _write_character_profiles(document):
		return {"ok": false, "error": "character-effect-profile-write-failed"}
	_publish_changed("character-profile-saved")
	return {"ok": true, "characterId": normalized_id, "slot": slot_name, "overrides": normalized}


func reset_character_profile(character_id: String, slot_name: String = "") -> Dictionary:
	var normalized_id := character_id.strip_edges()
	if not _valid_character_id(normalized_id):
		return {"ok": false, "error": "invalid-character-effect-profile"}
	if not slot_name.is_empty() and slot_name not in SLOT_NAMES:
		return {"ok": false, "error": "invalid-effect-pack-slot"}
	var document := _read_character_profiles()
	var characters_value: Variant = document.get("characters", {})
	var characters: Dictionary = characters_value.duplicate(true) if characters_value is Dictionary else {}
	if not characters.has(normalized_id):
		return {"ok": true, "characterId": normalized_id, "slot": slot_name}
	if slot_name.is_empty():
		characters.erase(normalized_id)
	else:
		var profile_value: Variant = characters.get(normalized_id, {})
		var profile: Dictionary = profile_value.duplicate(true) if profile_value is Dictionary else {}
		var slots_value: Variant = profile.get("slots", {})
		var slots: Dictionary = slots_value.duplicate(true) if slots_value is Dictionary else {}
		slots.erase(slot_name)
		if slots.is_empty():
			characters.erase(normalized_id)
		else:
			profile["slots"] = slots
			profile["updatedAtMs"] = int(Time.get_unix_time_from_system() * 1000.0)
			characters[normalized_id] = profile
	document["schemaVersion"] = CHARACTER_EFFECT_PROFILE_SCHEMA
	document["characters"] = characters
	if not _write_character_profiles(document):
		return {"ok": false, "error": "character-effect-profile-write-failed"}
	_publish_changed("character-profile-reset")
	return {"ok": true, "characterId": normalized_id, "slot": slot_name}


func _valid_character_id(value: String) -> bool:
	if value.is_empty() or value.length() > 128:
		return false
	for index in range(value.length()):
		var code := value.unicode_at(index)
		var alpha_numeric := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		if not alpha_numeric and code not in [45, 46, 95]:
			return false
	return true


func _normalize_character_effect_overrides(overrides: Dictionary) -> Dictionary:
	var result := {}
	if overrides.has("fps"):
		var fps := int(overrides.get("fps", 0))
		if fps < 1 or fps > 30:
			return {}
		result["fps"] = fps
	if overrides.has("startFrame"):
		var start_frame := int(overrides.get("startFrame", -1))
		if start_frame < 0 or start_frame > 119:
			return {}
		result["startFrame"] = start_frame
	if overrides.has("endFrame"):
		var end_frame := int(overrides.get("endFrame", -1))
		if end_frame < 0 or end_frame > 119:
			return {}
		result["endFrame"] = end_frame
	if result.has("startFrame") and result.has("endFrame") and int(result["endFrame"]) < int(result["startFrame"]):
		return {}
	if overrides.has("scale"):
		var scale := float(overrides.get("scale", 0.0))
		if scale < 0.25 or scale > 4.0:
			return {}
		result["scale"] = scale
	for key in ["offsetX", "offsetY"]:
		if overrides.has(key):
			var offset := float(overrides.get(key, 9999.0))
			if absf(offset) > 512.0:
				return {}
			result[key] = offset
	if overrides.has("anchor"):
		var anchor := str(overrides.get("anchor", ""))
		if anchor not in ["character-center", "character-feet", "character-feet-bottom", "character-above-head"]:
			return {}
		result["anchor"] = anchor
	if overrides.has("scaleMode"):
		var scale_mode := str(overrides.get("scaleMode", ""))
		if scale_mode not in ["character-width", "character-height", "native-surface"]:
			return {}
		result["scaleMode"] = scale_mode
	if overrides.has("intensity"):
		var intensity := int(overrides.get("intensity", -1))
		if intensity < 0 or intensity > 100:
			return {}
		result["intensity"] = intensity
	if overrides.has("tint"):
		var tint := str(overrides.get("tint", "")).strip_edges()
		if not Color.html_is_valid(tint):
			return {}
		result["tint"] = tint
		result["_colorize"] = true
	return result


func _apply_standard_rank_palette(slot_name: String, slot: Dictionary, character_id_override: String = "", preview_rank_override: String = "") -> void:
	var state := _current_progression(character_id_override)
	var rank := preview_rank_override if not preview_rank_override.is_empty() else str(state.get("bondRank", "stranger"))
	if not RANK_PALETTES.has(rank):
		rank = "stranger"
	var palette := RANK_PALETTES[rank] as Dictionary
	var color_key := "aura" if slot_name == "bodyAura" else ("rune" if slot_name == "groundRune" else "burst")
	slot["tint"] = str(palette.get(color_key, "#FFFFFF"))
	slot["intensity"] = int(palette.get("intensity", slot.get("intensity", 100)))
	slot["speedPermille"] = int(palette.get("speedPermille", slot.get("speedPermille", 1000)))
	slot["_colorize"] = true
	slot["_rank"] = rank
	slot["_rankPreset"] = str(palette.get("name", rank))


func _apply_character_profile(character_id: String, slot_name: String, slot: Dictionary) -> void:
	if character_id.is_empty():
		return
	var profile := character_profile(character_id)
	var slots_value: Variant = profile.get("slots", {})
	if not slots_value is Dictionary:
		return
	var override_value: Variant = (slots_value as Dictionary).get(slot_name, {})
	if not override_value is Dictionary:
		return
	slot.merge(override_value as Dictionary, true)
	slot["_characterProfile"] = character_id


func _read_character_profiles() -> Dictionary:
	if not FileAccess.file_exists(character_effect_profiles_file):
		return {"schemaVersion": CHARACTER_EFFECT_PROFILE_SCHEMA, "characters": {}}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(character_effect_profiles_file))
	if not parsed is Dictionary:
		return {"schemaVersion": CHARACTER_EFFECT_PROFILE_SCHEMA, "characters": {}}
	var document := parsed as Dictionary
	if int(document.get("schemaVersion", 0)) != CHARACTER_EFFECT_PROFILE_SCHEMA:
		return {"schemaVersion": CHARACTER_EFFECT_PROFILE_SCHEMA, "characters": {}}
	if not document.get("characters", {}) is Dictionary:
		document["characters"] = {}
	return document


func _write_character_profiles(document: Dictionary) -> bool:
	var runtime_dir := ProjectSettings.globalize_path("user://runtime")
	if DirAccess.make_dir_recursive_absolute(runtime_dir) != OK and not DirAccess.dir_exists_absolute(runtime_dir):
		return false
	var target := ProjectSettings.globalize_path(character_effect_profiles_file)
	var temporary := target + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(document, "	"))
	file.close()
	if FileAccess.file_exists(target):
		DirAccess.remove_absolute(target)
	return DirAccess.rename_absolute(temporary, target) == OK


func is_slot_enabled(slot_name: String) -> bool:
	if slot_name not in SLOT_NAMES:
		return false
	var state := _read_state()
	var enabled_value: Variant = state.get("effectSlotEnabled", {})
	if enabled_value is Dictionary and (enabled_value as Dictionary).has(slot_name):
		return bool((enabled_value as Dictionary).get(slot_name, true))
	return true


func set_preview_rank(rank: String) -> bool:
	if not rank.is_empty() and not BOND_ORDER.has(rank):
		return false
	# Preview rank is ephemeral editor state. Do not publish effect_pack.changed:
	# that event is consumed by EffectController and would recolor the real
	# desktop companion while the user is only experimenting in Character Manager.
	_preview_rank = rank
	return true


func preview_rank() -> String:
	return _preview_rank


func set_slot_enabled(slot_name: String, enabled: bool) -> bool:
	if slot_name not in SLOT_NAMES:
		return false
	var state := _read_state()
	var enabled_value: Variant = state.get("effectSlotEnabled", {})
	var enabled_map: Dictionary = enabled_value.duplicate(true) if enabled_value is Dictionary else {}
	enabled_map[slot_name] = enabled
	state["effectSlotEnabled"] = enabled_map
	if not _write_state(state):
		return false
	_publish_changed("slot-enabled")
	return true


func snapshot() -> Dictionary:
	var installed := []
	for item_value in list_installed():
		var item := item_value as Dictionary
		var entry := item.get("entry", {}) as Dictionary
		installed.append({
			"packageId": item.get("packageId", ""),
			"version": item.get("version", ""),
			"name": entry.get("name", item.get("packageId", "")),
			"slots": (entry.get("slots", {}) as Dictionary).keys(),
			"progression": entry.get("progression", null),
		})
	var resolved := {}
	for slot_name in SLOT_NAMES:
		var slot := resolve_slot(slot_name)
		if not slot.is_empty():
			resolved[slot_name] = slot
	var enabled := {}
	for slot_name in SLOT_NAMES:
		enabled[slot_name] = is_slot_enabled(slot_name)
	return {
		"installed": installed,
		"loadout": get_loadout(),
		"enabled": enabled,
		"resolved": resolved,
		"previewRank": _preview_rank,
	}


func _apply_progression_variant(slot_name: String, entry: Dictionary, slot: Dictionary, character_id_override: String = "", preview_rank_override: String = "") -> void:
	var progression_value: Variant = entry.get("progression", null)
	if not progression_value is Dictionary:
		return
	var state := _current_progression(character_id_override)
	var level := int(state.get("level", 1))
	var rank := preview_rank_override if not preview_rank_override.is_empty() else str(state.get("bondRank", "stranger"))
	var rank_order := int(BOND_ORDER.get(rank, 0))
	var variants_value: Variant = (progression_value as Dictionary).get("variants", [])
	if not variants_value is Array:
		return
	for variant_value in variants_value:
		if not variant_value is Dictionary:
			continue
		var variant := variant_value as Dictionary
		var required_level := int(variant.get("minLevel", 1))
		var required_rank := str(variant.get("minBondRank", "stranger"))
		if level < required_level or rank_order < int(BOND_ORDER.get(required_rank, 0)):
			continue
		var overrides_value: Variant = variant.get("slotOverrides", {})
		if overrides_value is Dictionary:
			var override_value: Variant = (overrides_value as Dictionary).get(slot_name, {})
			if override_value is Dictionary:
				slot.merge(override_value as Dictionary, true)
		slot["_variantId"] = str(variant.get("id", ""))


func _current_progression(character_id_override: String = "") -> Dictionary:
	if not is_instance_valid(_progression_service) or not _progression_service.has_method("canonical_projection"):
		return {"level": 1, "bondRank": "stranger"}
	var projection_value: Variant = _progression_service.call("canonical_projection")
	if not projection_value is Dictionary:
		return {"level": 1, "bondRank": "stranger"}
	var character_id := character_id_override.strip_edges()
	if character_id.is_empty() and is_instance_valid(context):
		character_id = str(context.character.get("id", ""))
	for companion_value in (projection_value as Dictionary).get("companions", []):
		if not companion_value is Dictionary:
			continue
		var companion := companion_value as Dictionary
		if str(companion.get("characterId", "")) != character_id:
			continue
		var relationship_value: Variant = companion.get("relationship", {})
		if relationship_value is Dictionary:
			return {
				"level": int((relationship_value as Dictionary).get("level", 1)),
				"bondRank": str((relationship_value as Dictionary).get("bondRank", "stranger")),
			}
	return {"level": 1, "bondRank": "stranger"}


func _read_state() -> Dictionary:
	if not FileAccess.file_exists(STATE_FILE):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE_FILE))
	return value if value is Dictionary else {}


func _save_loadout(loadout: Dictionary) -> bool:
	var state := _read_state()
	state["effectLoadout"] = loadout.duplicate(true)
	return _write_state(state)


func _write_state(state: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute("user://runtime")
	var file := FileAccess.open(STATE_FILE, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(state, "\t"))
	file.close()
	return true


func _publish_changed(reason: String) -> void:
	if is_instance_valid(event_bus):
		event_bus.publish(&"effect_pack.changed", {
			"reason": reason,
			"snapshot": snapshot(),
		})


func _on_install_requested(payload: Dictionary) -> void:
	var result := install(str(payload.get("path", "")))
	var source := str(payload.get("source", ""))
	if bool(result.get("ok", false)) and source == "desktop-shell-local-effect":
		var package_id := str(result.get("packageId", ""))
		var version := str(result.get("version", ""))
		var auto_equipped := equip(package_id, version, "")
		result["autoEquipped"] = auto_equipped
		if not auto_equipped:
			result["warning"] = "Effect Pack installed but could not be equipped"
	if is_instance_valid(event_bus):
		event_bus.publish(&"effect_pack.install_result", result)


func _on_equip_requested(payload: Dictionary) -> void:
	var ok := equip(str(payload.get("packageId", "")), str(payload.get("version", "")), str(payload.get("slot", "")))
	if not ok and is_instance_valid(event_bus):
		event_bus.publish(&"notification.requested", {"text": "Unable to equip effect pack"})


func _on_unequip_requested(payload: Dictionary) -> void:
	unequip(str(payload.get("slot", "")))


func _on_slot_enabled_requested(payload: Dictionary) -> void:
	set_slot_enabled(str(payload.get("slot", "")), bool(payload.get("enabled", true)))


func _on_uninstall_requested(payload: Dictionary) -> void:
	uninstall(str(payload.get("packageId", "")), str(payload.get("version", "")))
