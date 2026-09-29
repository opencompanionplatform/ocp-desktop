extends Node
class_name AppRouter
## Manages routing and switching scenes inside the main application viewport/shell container.

signal page_changed(page_name: String)

var current_page: String = "home"
var active_page_node: Node = null
var page_container: Control = null

var page_scenes := {
	"home": "res://scenes/pages/HomePage.tscn",
	"studio": "res://scenes/pages/studio/CharacterStudioPage.tscn",
	"runtime_test": "res://scenes/pages/RuntimeTestPage.tscn"
}

func setup(container: Control) -> void:
	page_container = container
	go_to_page("home")

func go_to_page(page_name: String) -> void:
	if !page_scenes.has(page_name):
		push_warning("AppRouter: page not found - " + page_name)
		return
		
	current_page = page_name
	
	# Clear old page
	if active_page_node:
		active_page_node.queue_free()
		active_page_node = null
		
	# Instantiate new page
	var path: String = page_scenes[page_name]
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		if scene:
			active_page_node = scene.instantiate()
			if page_container:
				page_container.add_child(active_page_node)
				
	page_changed.emit(page_name)
