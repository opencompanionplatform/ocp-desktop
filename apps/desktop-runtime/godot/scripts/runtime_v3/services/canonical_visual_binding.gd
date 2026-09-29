extends RefCounted
class_name RuntimeV3CanonicalVisualBinding

const DRAG_ACK_TOLERANCE_PX: float = 3.0

var companion_id: String = "default"
var body_id: int = -1
var last_sequence: int = -1
var last_revision: int = -1
var canonical_seen: bool = false
var pending_drag_commit: bool = false
var pending_drag_feet: Vector2 = Vector2.ZERO


func reset() -> void:
	body_id = -1
	last_sequence = -1
	last_revision = -1
	canonical_seen = false
	pending_drag_commit = false
	pending_drag_feet = Vector2.ZERO


func begin_drag_commit(desktop_feet: Vector2) -> void:
	pending_drag_commit = true
	pending_drag_feet = desktop_feet


func cancel_drag_commit() -> void:
	pending_drag_commit = false
	pending_drag_feet = Vector2.ZERO


func accept_canonical(payload: Dictionary) -> Dictionary:
	if int(payload.get("schemaVersion", 0)) != 1:
		return _rejected("unsupported-schema", payload)

	if str(payload.get("companionId", "")) != companion_id:
		return _rejected("wrong-companion", payload)

	var incoming_body_id: int = int(payload.get("bodyId", -1))
	if incoming_body_id < 0:
		return _rejected("missing-body-id", payload)
	if body_id < 0:
		body_id = incoming_body_id
	elif incoming_body_id != body_id:
		return _rejected("body-identity-mismatch", payload)

	var sequence: int = int(payload.get("sequence", -1))
	var revision: int = int(payload.get("revision", -1))
	if canonical_seen and sequence <= last_sequence:
		return _rejected("stale-sequence", payload)
	# `sequence` is the sole ordering authority for presentation. Revision is
	# diagnostic metadata: it can be observed out of order when Kernel facts
	# traverse separate subscriber workers, and must never suppress an
	# authoritative drag-commit (especially WindowTop -> sitting).

	var update_kind: String = str(payload.get("updateKind", "continuous"))
	var desktop_feet: Vector2 = payload.get("desktopFeet", Vector2.ZERO)

	if pending_drag_commit:
		if update_kind == "continuous":
			# Consume ordering metadata so an older frame can never be replayed,
			# but do not allow stale motion to regain visual authority.
			last_sequence = sequence
			last_revision = revision
			canonical_seen = true
			return _rejected("drag-commit-pending", payload)

		if update_kind == "drag-commit":
			# Desktop Physics may snap the released point vertically onto a
			# WindowTop, TaskbarTop, or DesktopFloor. The Kernel-resolved point is
			# authoritative; body identity and ordering still guard this ACK.
			cancel_drag_commit()
		elif update_kind in ["correction", "teleport"]:
			if desktop_feet.distance_to(pending_drag_feet) > DRAG_ACK_TOLERANCE_PX:
				return _rejected("drag-ack-position-mismatch", payload)
			cancel_drag_commit()

	last_sequence = sequence
	last_revision = revision
	canonical_seen = true

	return {
		"accepted": true,
		"companionId": companion_id,
		"bodyId": body_id,
		"sequence": sequence,
		"revision": revision,
		"desktopFeet": desktop_feet,
		"velocity": payload.get("velocity", Vector2.ZERO),
		"movementState": str(payload.get("movementState", "stationary")),
		"attachmentState": str(payload.get("attachmentState", "grounded")),
		"facing": str(payload.get("facing", "unchanged")),
		"updateKind": update_kind,
		"snap": update_kind != "continuous",
	}


func accept_legacy(payload: Dictionary) -> Dictionary:
	if canonical_seen:
		return _rejected("canonical-active", payload)

	var sequence: int = int(payload.get("sequence", -1))
	if sequence <= last_sequence:
		return _rejected("stale-sequence", payload)

	last_sequence = sequence
	return {
		"accepted": true,
		"companionId": companion_id,
		"bodyId": body_id,
		"sequence": sequence,
		"revision": int(payload.get("revision", last_revision)),
		"desktopFeet": payload.get("position", Vector2.ZERO),
		"velocity": payload.get("velocity", Vector2.ZERO),
		"movementState": str(payload.get("movementState", "stationary")),
		"attachmentState": (
			"grounded" if bool(payload.get("grounded", false)) else "airborne"
		),
		"facing": "unchanged",
		"updateKind": (
			"continuous"
			if str(payload.get("motion", "continuous")) == "continuous"
			else "correction"
		),
		"snap": str(payload.get("motion", "continuous")) != "continuous",
	}


func _rejected(reason: String, payload: Dictionary) -> Dictionary:
	return {
		"accepted": false,
		"reason": reason,
		"bodyId": int(payload.get("bodyId", -1)),
		"sequence": int(payload.get("sequence", -1)),
		"revision": int(payload.get("revision", -1)),
	}
