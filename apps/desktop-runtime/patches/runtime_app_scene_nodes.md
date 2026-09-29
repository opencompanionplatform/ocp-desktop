# RuntimeApp.tscn nodes to add

Add these nodes under the existing V3 structure:

```text
RuntimeApp
├── RuntimeServices
│   └── StartupVisibilityController
├── Controllers
│   └── BubbleAnchorController
└── RuntimeUI
    └── GeometryDebugOverlay
```

Example TSCN resources:

```ini
[ext_resource type="Script" path="res://scripts/runtime_v3/controllers/startup_visibility_controller.gd" id="startup_visibility"]
[ext_resource type="Script" path="res://scripts/runtime_v3/controllers/bubble_anchor_controller.gd" id="bubble_anchor"]
[ext_resource type="Script" path="res://scripts/runtime_v3/ui/runtime_geometry_debug_overlay.gd" id="geometry_debug"]

[node name="StartupVisibilityController" type="Node" parent="RuntimeServices"]
script = ExtResource("startup_visibility")

[node name="BubbleAnchorController" type="Node" parent="Controllers"]
script = ExtResource("bubble_anchor")

[node name="GeometryDebugOverlay" type="Control" parent="RuntimeUI"]
visible = false
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
mouse_filter = 2
script = ExtResource("geometry_debug")
```

Adjust `parent=` paths to match the current RuntimeApp scene.
