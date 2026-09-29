extends RefCounted
class_name PackageBuilder
## Builds the character configuration directory and outputs the character.json.

static func build(project: StudioProject) -> String:
	var dir := OS.get_environment("OCP_CHARACTER_DIR")
	if dir == "":
		var temp_env := OS.get_environment("TEMP")
		if temp_env != "":
			dir = temp_env.path_join("ocp-character")
		else:
			dir = "user://ocp-character"
			
	var err := DirAccess.make_dir_recursive_absolute(dir.path_join("assets"))
	if err != OK:
		return "Failed to create directory at: " + dir
		
	var sprites: Array = []
	for sheet in project.sheets:
		var rel := "assets/%s.png" % sheet["id"]
		var save_err: Error = (sheet["image"] as Image).save_png(dir.path_join(rel))
		if save_err != OK:
			return "Failed to save PNG sprite sheet: " + sheet["id"]
		sprites.append({
			"id": sheet["id"],
			"path": rel,
			"frameSize": [int(sheet["fw"]), int(sheet["fh"])]
		})
		
	var default_id := str(project.sheets[0]["id"]) if !project.sheets.is_empty() else ""
	var out_animations := {}
	for clip_name in project.animations.keys():
		var clip: Dictionary = project.animations[clip_name]
		if clip["frames"].is_empty():
			continue
		var sid := str(clip.get("sprite", ""))
		if project.get_sheet_index(sid) < 0:
			sid = default_id
		out_animations[clip_name] = {
			"sprite": sid,
			"frames": clip["frames"],
			"fps": clip["fps"],
			"loop": clip["loop"]
		}
		
	var out_expressions := {}
	for expr_id in project.expressions.keys():
		var expr: Dictionary = project.expressions[expr_id]
		if expr["frames"].is_empty():
			continue
		var sid := str(expr.get("sprite", ""))
		if project.get_sheet_index(sid) < 0:
			sid = default_id
		out_expressions[expr_id] = {
			"sprite": sid,
			"frames": expr["frames"]
		}
		
	var authorship: Array = []
	if !project.creator_artist.strip_edges().is_empty():
		authorship.append({
			"component": "sprites",
			"author": project.creator_artist.strip_edges(),
			"license": project.license.strip_edges()
		})
		
	var voice_id = null
	if !project.voice_hint.strip_edges().is_empty():
		voice_id = project.voice_hint.strip_edges()

	var entry := {
		"schema": "character/1",
		"name": project.character_name.strip_edges(),
		"renderer": "sprite-sheet-2d",
		"sprites": sprites,
		"animations": out_animations,
		"expressions": out_expressions,
		"voiceId": voice_id,
		"authorship": authorship
	}
	
	var output := FileAccess.open(dir.path_join("character.json"), FileAccess.WRITE)
	if output:
		output.store_string(JSON.stringify(entry, "  "))
		output.close()
		return "Staged character.json + %d sheet(s) to %s." % [sprites.size(), dir]
	else:
		return "Failed to open character.json for writing."
