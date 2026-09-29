extends SceneTree

func _initialize() -> void:
	print("[SCENE-PROBE] before load")
	var packed := load("res://scenes/runtime_v3/RuntimeApp.tscn") as PackedScene
	print("[SCENE-PROBE] after load ok=", packed != null)
	if packed == null:
		quit(1)
		return
	print("[SCENE-PROBE] before instantiate")
	var app := packed.instantiate()
	var instantiated := app != null
	print("[SCENE-PROBE] after instantiate ok=", instantiated)
	if instantiated:
		app.free()
	quit(0 if instantiated else 1)
