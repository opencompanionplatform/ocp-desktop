extends SceneTree

const PackageServiceScript = preload("res://scripts/runtime_v3/services/package_service.gd")


func _initialize() -> void:
	var target_persisted := {
		"packageId": "character.bible",
		"version": "1.0.0",
	}
	var old_runtime := {
		"active_id": "character.sabai-sompoo",
		"active_version": "1.0.1",
	}
	var target_runtime := {
		"active_id": "character.bible",
		"active_version": "1.0.0",
	}
	var other_persisted := {
		"packageId": "character.sabai-sompoo",
		"version": "1.0.1",
	}

	var installer_persisted_but_runtime_old := not PackageServiceScript._activation_already_live(
		target_persisted,
		old_runtime,
		"character.bible",
		"1.0.0"
	)
	var truly_live_is_idempotent := PackageServiceScript._activation_already_live(
		target_persisted,
		target_runtime,
		"character.bible",
		"1.0.0"
	)
	var mismatched_persistence_requires_activation := not PackageServiceScript._activation_already_live(
		other_persisted,
		target_runtime,
		"character.bible",
		"1.0.0"
	)

	var ok := installer_persisted_but_runtime_old 		and truly_live_is_idempotent 		and mismatched_persistence_requires_activation
	print("[PACKAGE-ACTIVATION-IDEMPOTENCE] installer_persisted_runtime_old=", installer_persisted_but_runtime_old,
		" truly_live=", truly_live_is_idempotent,
		" mismatched_persistence=", mismatched_persistence_requires_activation,
		" ok=", ok)
	quit(0 if ok else 1)
