extends RefCounted
class_name StudioValidator
## Performs validation checks on a StudioProject instance.

static func validate(project: StudioProject) -> Dictionary:
	var has_identity: bool = !project.character_name.strip_edges().is_empty() and \
							 !project.package_id.strip_edges().is_empty() and \
							 !project.version.strip_edges().is_empty()
							
	var has_artwork: bool = !project.sheets.is_empty()
	
	var has_grid: bool = false
	if has_artwork:
		var first_sheet: Dictionary = project.sheets[0]
		has_grid = first_sheet.get("fw", 0) > 0 and first_sheet.get("fh", 0) > 0
		
	var has_idle: bool = project.animations.has("idle") and \
						 !project.animations["idle"].get("frames", []).is_empty()
						
	var has_attribution: bool = !project.creator_artist.strip_edges().is_empty() and \
								 !project.license.strip_edges().is_empty()
								
	# Warning if no preview generated
	var has_preview: bool = has_idle # Basic check if idle frames exist for preview
	
	var can_build: bool = has_identity and has_artwork and has_grid and has_idle and has_attribution
	
	return {
		"identity": has_identity,
		"artwork": has_artwork,
		"grid": has_grid,
		"animations": has_idle,
		"idle": has_idle, # Backward-compatible alias
		"attribution": has_attribution,
		"preview": has_preview,
		"can_build": can_build
	}
