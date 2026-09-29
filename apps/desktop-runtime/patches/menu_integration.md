# Menu integration

## Hover Menu

The Hover Menu should contain:

```text
Quick Panel
Animations
Change Character
Hide to Tray
Exit
```

On Hide to Tray:

```gdscript
event_bus.publish(
	RuntimeV3Events.HIDE_TO_TRAY_REQUESTED,
	{}
)
```

On Exit:

```gdscript
event_bus.publish(
	RuntimeV3Events.EXIT_REQUESTED,
	{"source": "hover_menu"}
)
```

## Quick Panel

Remove or hide both lifecycle controls:

```gdscript
hide_to_tray_button.visible = false
exit_button.visible = false
```

The Quick Panel should close only its own window:

```gdscript
close_button.pressed.connect(
	func():
		event_bus.publish(
			RuntimeV3Events.QUICK_PANEL_CLOSE_REQUESTED,
			{}
		)
)
```

## Tray Menu

Keep Exit in the tray as a recovery route.

Recommended order:

```text
Restore
Open Quick Panel
────────────
Exit
```

Tray Exit handler:

```gdscript
func _on_tray_exit_requested() -> void:
	event_bus.publish(
		RuntimeV3Events.EXIT_REQUESTED,
		{"source": "system_tray"}
	)
```

Do not call `get_tree().quit()` directly from tray code. WindowController or
RuntimeApp should own the final shutdown sequence.
