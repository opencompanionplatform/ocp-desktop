# runtime_app.gd integration

Add preload or rely on class_name:

```gdscript
@onready var startup_visibility: RuntimeV3StartupVisibilityController = (
	$RuntimeServices/StartupVisibilityController
)

@onready var bubble_anchor_controller: RuntimeV3BubbleAnchorController = (
	$Controllers/BubbleAnchorController
)

@onready var geometry_debug_overlay: RuntimeV3GeometryDebugOverlay = (
	$RuntimeUI/GeometryDebugOverlay
)
```

At the first line of `_ready()`:

```gdscript
func _ready() -> void:
	startup_visibility.begin_startup(get_window())

	await runtime_bootstrap.start_system()

	# Apply overlay/window geometry before revealing the native window.
	window_controller.apply_startup_mode()
	multi_monitor_controller.refresh_monitors()

	await get_tree().process_frame

	startup_visibility.reveal_when_ready()
```

When the character and Bubble Box are ready:

```gdscript
bubble_anchor_controller.configure(
	companion_layer.character_node,
	bubble_layer.bubble_box,
	geometry_debug_overlay
)

geometry_debug_overlay.bind_controller(
	bubble_anchor_controller
)

bubble_anchor_controller.apply_character_config(
	runtime_context.character.config
)
```

When character changes:

```gdscript
event_bus.subscribe(
	RuntimeV3Events.CHARACTER_CHANGED,
	func(_event):
		bubble_anchor_controller.apply_character_config(
			runtime_context.character.config
		)
)
```

When debug mode changes:

```gdscript
bubble_anchor_controller.set_debug_enabled(debug_enabled)
```
