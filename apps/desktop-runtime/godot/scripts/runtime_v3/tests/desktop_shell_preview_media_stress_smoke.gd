extends SceneTree

const AdapterScript = preload("res://scripts/runtime_v3/services/desktop_shell_functional_adapter.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var adapter := AdapterScript.new()
	holder.add_child(adapter)

	var directory := ProjectSettings.globalize_path("user://preview-media-stress")
	DirAccess.make_dir_recursive_absolute(directory)
	adapter.session_directory = directory

	var thumbnail_payload := "A".repeat(AdapterScript.MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH)
	var thumbnails := {}
	for index in range(AdapterScript.MAX_PREVIEW_SHORTCUT_THUMBNAILS):
		thumbnails["clip_%d" % index] = thumbnail_payload
	var frame_payload := "A".repeat(AdapterScript.MAX_PREVIEW_BASE64_LENGTH)

	adapter.preview_state = {
		"packageId": "character.bible",
		"version": "1.0.0",
		"selectedAnimation": "idle",
		"clipThumbnailPngBase64": thumbnails,
		"framePngBase64": frame_payload,
		"frameWidth": 512,
		"frameHeight": 512,
	}

	for _frame in range(240):
		adapter._write_preview_media()

	var destination := directory.path_join("preview-media.json")
	var valid := false
	if FileAccess.file_exists(destination):
		var file := FileAccess.open(destination, FileAccess.READ)
		if file != null:
			var parsed: Variant = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				var media := parsed as Dictionary
				valid = int(media.get("revision", 0)) == 240 \
					and str(media.get("packageId", "")) == "character.bible" \
					and str(media.get("framePngBase64", "")).length() == AdapterScript.MAX_PREVIEW_BASE64_LENGTH \
					and (media.get("clipThumbnailPngBase64", {}) as Dictionary).size() == AdapterScript.MAX_PREVIEW_SHORTCUT_THUMBNAILS

	DirAccess.remove_absolute(destination)
	DirAccess.remove_absolute(directory.path_join("preview-media.json.tmp"))
	DirAccess.remove_absolute(directory)
	print("[PREVIEW-MEDIA-STRESS] writes=240 valid=", valid)
	holder.queue_free()
	await process_frame
	quit(0 if valid else 1)
