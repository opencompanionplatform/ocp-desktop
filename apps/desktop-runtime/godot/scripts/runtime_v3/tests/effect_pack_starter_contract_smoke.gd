extends SceneTree

const ReaderScript = preload("res://scripts/runtime/packages/ocp_package_reader.gd")
const ValidatorScript = preload("res://scripts/runtime/packages/ocp_package_validator.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := ProjectSettings.globalize_path("res://../../../release/starter-local/effect.starter-neon-1.0.0.ocp")
	var reader = ReaderScript.new()
	var read_result = reader.read(path)
	var read_ok := bool(read_result.ok)
	var type_ok := read_ok and str(read_result.manifest.get("type", "")) == "effect-pack"
	var validation = ValidatorScript.new().validate(read_result) if read_ok else null
	var validation_ok := validation != null and bool(validation.ok)
	var entry: Dictionary = read_result.entry if read_ok and read_result.entry is Dictionary else {}
	var slots: Dictionary = entry.get("slots", {}) if entry.get("slots", {}) is Dictionary else {}
	var slots_ok := slots.has("bodyAura") and slots.has("groundRune") and slots.has("levelUpBurst")
	var burst: Dictionary = slots.get("levelUpBurst", {}) if slots.get("levelUpBurst", {}) is Dictionary else {}
	var burst_contract_ok := str(burst.get("anchor", "")) == "character-feet-bottom" \
		and str(burst.get("scaleMode", "")) == "character-height" \
		and is_equal_approx(float(burst.get("scale", 0.0)), 1.05) \
		and is_zero_approx(float(burst.get("offsetY", 999.0)))
	var progression: Dictionary = entry.get("progression", {}) if entry.get("progression", {}) is Dictionary else {}
	var variants: Array = progression.get("variants", []) if progression.get("variants", []) is Array else []
	var progression_ok := str(progression.get("mode", "")) == "bond-rank" and variants.size() == 5
	if read_ok:
		read_result.close()
	var ok := read_ok and type_ok and validation_ok and slots_ok and burst_contract_ok and progression_ok
	print("[EFFECT-PACK-STARTER] read=%s type=%s validation=%s slots=%s burst_ground=%s progression=%s" % [
		str(read_ok).to_lower(),
		str(type_ok).to_lower(),
		str(validation_ok).to_lower(),
		str(slots_ok).to_lower(),
		str(burst_contract_ok).to_lower(),
		str(progression_ok).to_lower(),
	])
	quit(0 if ok else 1)
