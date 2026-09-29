# project.godot startup settings

Verify:

```ini
[application]

run/main_scene="res://scenes/runtime_v3/RuntimeApp.tscn"
boot_splash/show_image=false
boot_splash/fullsize=false
boot_splash/use_filter=false
```

Verify window properties:

```ini
[display]

window/size/borderless=true
window/size/transparent=true
window/size/always_on_top=true
window/per_pixel_transparency/allowed=true
```

The native startup artifact at the top-left is addressed primarily by hiding
the root Window before bootstrap and revealing it only after overlay geometry
has stabilized. Boot splash settings alone are not sufficient.
