extends RefCounted
class_name StudioProject

var character_name := "Aiko"
var package_id := "ocp.character.aiko"
var version := "0.1.0"
var creator_artist := ""
var license := "CC-BY-4.0"
var voice_hint := ""
var current := -1
var preview_generated := false
var sheets: Array = []
var animations: Dictionary = {
	"idle": {"sprite": "", "frames": [], "fps": 2.0, "loop": true},
	"wave": {"sprite": "", "frames": [], "fps": 6.0, "loop": false},
	"speak": {"sprite": "", "frames": [], "fps": 8.0, "loop": true},
	"think": {"sprite": "", "frames": [], "fps": 4.0, "loop": true},
}
var expressions: Dictionary = {}

func get_sheet_index(id: String) -> int:
	for i in sheets.size():
		if str(sheets[i].get("id", "")) == id:
			return i
	return -1
