# OCP Modular Runtime v3

Godot 4.7 parse-fix release.

Changes from v2:
- Removed cross-script custom-class type dependencies from parse-time annotations.
- Added explicit types for Rect2, Vector2, arrays, textures, and polygons where Godot 4.7 could not infer them.
- Fixed `merged.size` to `merged.size()`.
- Keeps Main.tscn connected to the six modular runtime controllers.

Copy the `godot` folder over the existing desktop-runtime/godot folder, stop all Godot processes, then run the POC script again.
