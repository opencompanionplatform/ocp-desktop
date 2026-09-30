extends SceneTree

const AIServiceScript = preload("res://scripts/runtime_v3/services/ai_service.gd")
const AutonomousScript = preload("res://scripts/runtime_v3/controllers/autonomous_floor_walk_controller.gd")
const OfflinePresenceScript = preload("res://scripts/runtime_v3/controllers/offline_presence_controller.gd")
const EventBusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const LocalBehaviorCatalogScript = preload("res://scripts/runtime_v3/core/local_behavior_catalog.gd")


class FakeContext:
	extends Node
	var settings: Dictionary = {
		"language": "en",
		"offline_presence_enabled": true,
		"tts_voice_mode": "character",
	}
	var character: Dictionary = {
		"animations": PackedStringArray(LocalBehaviorCatalogScript.CHARACTER3_ANIMATIONS),
		"voice_profile": {"thaiSpeechStyle": "neutral"},
	}
	var window: Dictionary = {"hidden_to_tray": false}
	var runtime_config: Dictionary = {
		"chat_presentation_active": false,
		"chat_focus_active": false,
	}


class FakeServices:
	extends Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := EventBusScript.new()
	var services := FakeServices.new()
	var state_machine := Node.new()
	var ai := AIServiceScript.new()
	var autonomous := AutonomousScript.new()
	var presence := OfflinePresenceScript.new()
	for node in [context, bus, services, state_machine, ai, autonomous, presence]:
		holder.add_child(node)
	ai.configure(context, bus)
	autonomous.configure(context, bus, services, state_machine)
	presence.configure(context, bus, services, state_machine)

	var playful := {
		"identity": {"descriptions": {"en": "Nene is warm, playful, energetic, curious, and casually cheerful."}},
		"traits": {
			"warmth": 0.90,
			"humor": 0.85,
			"formality": 0.20,
			"initiative": 0.85,
			"energy": 0.90,
			"talkativeness": 0.75,
			"movement": 0.88,
		},
		"speakingStyle": {"maxSentences": 4},
		"behavior": {"restSeconds": 16.0, "walkSeconds": 12.5, "hangSettleSeconds": 0.88},
	}
	var composed := {
		"identity": {"descriptions": {"en": "Mori is calm, formal, reserved, thoughtful, and deliberately concise."}},
		"traits": {
			"warmth": 0.55,
			"humor": 0.20,
			"formality": 0.85,
			"initiative": 0.25,
			"energy": 0.20,
			"talkativeness": 0.25,
			"movement": 0.30,
		},
		"speakingStyle": {"maxSentences": 2},
		"behavior": {"restSeconds": 24.0, "walkSeconds": 9.5, "hangSettleSeconds": 1.15},
	}

	context.character["soul_profile"] = playful
	var playful_prompt := ai._companion_system_prompt()
	var playful_motion := autonomous._behavior_profile(0)
	var playful_interval := presence._schedule_interval_seconds()
	var playful_ambient := Array(presence._soul_ambient_rotation())

	context.character["soul_profile"] = composed
	var composed_prompt := ai._companion_system_prompt()
	var composed_motion := autonomous._behavior_profile(0)
	var composed_interval := presence._schedule_interval_seconds()
	var composed_ambient := Array(presence._soul_ambient_rotation())

	var voice_distinct := playful_prompt != composed_prompt \
		and playful_prompt.contains("1 to 4 short sentences") \
		and composed_prompt.contains("1 to 2 short sentences") \
		and playful_prompt.contains("playful, energetic") \
		and composed_prompt.contains("formal, reserved")
	var motion_distinct := float(playful_motion.get("walk_seconds", 0.0)) > float(composed_motion.get("walk_seconds", 0.0)) \
		and float(playful_motion.get("rest_seconds", 99.0)) < float(composed_motion.get("rest_seconds", 0.0)) \
		and float(playful_motion.get("hang_settle_seconds", 99.0)) < float(composed_motion.get("hang_settle_seconds", 0.0))
	var ambient_distinct := playful_interval < composed_interval \
		and playful_ambient.slice(0, 2) == ["happy", "wave"] \
		and composed_ambient.slice(0, 2) == ["think", "idle"]
	var bounded := playful_interval >= 12.0 and playful_interval <= 30.0 \
		and composed_interval >= 12.0 and composed_interval <= 30.0
	var ok := voice_distinct and motion_distinct and ambient_distinct and bounded
	print("[SOUL-DIFFERENTIATION] voice=", voice_distinct, " motion=", motion_distinct, " ambient=", ambient_distinct, " intervals=", [playful_interval, composed_interval], " rotations=", [playful_ambient, composed_ambient], " ok=", ok)

	holder.free()
	quit(0 if ok else 1)
