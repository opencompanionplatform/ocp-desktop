extends RefCounted
class_name RuntimeV3LocalBehaviorCatalog

# Standard Character/3 compatibility vocabulary and the subsystem that owns
# each animation. Character/3 itself is open-ended: optional semantic clips and
# package-declared custom actions may extend this Standard set without changing
# Runtime code.
const CHARACTER3_ANIMATIONS := [
	"idle",
	"appear",
	"disappear",
	"angry",
	"happy",
	"sad",
	"surprised",
	"speak",
	"think",
	"wake",
	"sleep",
	"sit",
	"jump",
	"fall",
	"land",
	"climb_up",
	"climb_down",
	"hang",
	"walk_left",
	"walk_right",
	"wave",
	"climb_ready",
]

# Safe autonomous presentation clips. These never move the canonical Physics
# body and are only scheduled while the companion is stationary on the desktop
# floor. `sit`/`sleep`/`wake` are handled separately as a surface-idle lifecycle.
const OPTIONAL_BEHAVIOR_OWNER := {
	"climb_top": "physics-transition-optional",
	"climb_up_left": "physics-directional-optional",
	"climb_up_right": "physics-directional-optional",
	"climb_down_left": "physics-directional-optional",
	"climb_down_right": "physics-directional-optional",
	"climb_ready_left": "physics-directional-derived",
	"climb_ready_right": "physics-directional-derived",
	"hang_left": "physics-directional-optional",
	"hang_right": "physics-directional-optional",
	"drag_hold": "interaction-optional",
	"drag_release": "interaction-optional",
}

const AMBIENT_ROTATION := ["think", "happy", "wave", "idle"]

const EMOTION_TO_ANIMATION := {
	"neutral": "idle",
	"happy": "happy",
	"sad": "sad",
	"angry": "angry",
	"surprised": "surprised",
}

const BEHAVIOR_OWNER := {
	"idle": "ambient",
	"think": "ambient",
	"happy": "ambient+reaction",
	"wave": "ambient+user",
	"sit": "surface-idle-lifecycle",
	"sleep": "surface-idle-lifecycle",
	"wake": "surface-idle-lifecycle",
	"angry": "reaction",
	"sad": "reaction",
	"surprised": "reaction+physics-fallback",
	"speak": "chat-tts",
	"appear": "character-lifecycle",
	"disappear": "character-lifecycle",
	"walk_left": "physics",
	"walk_right": "physics",
	"jump": "physics",
	"fall": "physics",
	"land": "physics-transition",
	"climb_ready": "physics",
	"climb_up": "physics",
	"climb_down": "physics",
	"hang": "physics",
}


static func animation_for_emotion(emotion: String) -> StringName:
	return StringName(EMOTION_TO_ANIMATION.get(emotion.strip_edges().to_lower(), "idle"))


static func mapped_animation_names() -> PackedStringArray:
	var names := PackedStringArray()
	for animation_name in BEHAVIOR_OWNER.keys():
		names.append(str(animation_name))
	names.sort()
	return names


static func owner_for(animation_name: String) -> String:
	if BEHAVIOR_OWNER.has(animation_name):
		return str(BEHAVIOR_OWNER[animation_name])
	return str(OPTIONAL_BEHAVIOR_OWNER.get(animation_name, "unmapped"))
