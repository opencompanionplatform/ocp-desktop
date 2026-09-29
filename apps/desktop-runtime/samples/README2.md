# OCP Desktop Runtime Feature Upgrade v7

This package continues from `ocp_runtime_modular_bridge_v6` and keeps the stable fullscreen transparent overlay and non-flickering hover menu.

## Included changes

1. Dragging moves the companion node inside the fullscreen overlay. It no longer moves the native window.
2. Activating or installing a character reloads its `SpriteFrames` without restarting the scene.
3. The Quick Panel and popup animation menus are generated from the animations actually present in the active package.
4. Bubbles use a character-relative anchor rather than the host rectangle top edge.
5. `character.json` supports runtime presentation metadata: `bubbleAnchor`, `scale`, and `hitbox`.

## Files

```text
godot/scripts/companion.gd
build_poc_character_v3.ps1
examples/character.runtime.example.json
README.md
CHECKLIST.md
```

## Install

Back up the current file first:

```powershell
Copy-Item .\godot\scripts\companion.gd .\godot\scripts\companion.gd.bak-v6
```

Copy this package over the repository root so this file replaces:

```text
godot/scripts/companion.gd
```

The PowerShell builder is optional. Copy it beside the existing POC build scripts when you want newly generated `character.json` files to contain runtime metadata.

## Run

```powershell
Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force
.un_install_poc.ps1 -Action Run -Arch arm64 -Profile debug
```

## `character.json` runtime metadata

Recommended form:

```json
{
  "schema": "character/1",
  "runtime": {
    "bubbleAnchor": [0, -176],
    "scale": 0.60,
    "hitbox": [44, 40, 220, 248]
  }
}
```

`bubbleAnchor` is measured from the center of the companion host in logical pixels. Negative Y places the bubble above the character.

`scale` is the `AnimatedSprite2D` render scale. The runtime clamps it to `0.05..4.0`.

`hitbox` is `[x, y, width, height]` relative to the companion host. It controls drag hit-testing and click-through input. It should cover the visible body, not the full transparent 512×512 frame.

For compatibility, these three keys may also be placed at the top level, but the `runtime` object is preferred.

## Character switching flow

```text
Change Character
→ select installed package or install .ocp
→ persist state.json
→ reload active SpriteFrames
→ apply runtime metadata
→ rebuild animation menus
→ refresh bubble and click-through geometry
```

The scene is not restarted during activation.

## Animation menu behavior

Only names returned by:

```gdscript
sprite_frames.get_animation_names()
```

are displayed. A package with only `idle`, `wave`, and `speak` will show only those entries.

## Rollback

```powershell
Copy-Item .\godot\scripts\companion.gd.bak-v6 .\godot\scripts\companion.gd -Force
```

## Limitations

This bundle was statically reviewed but not executed with Godot inside the packaging environment. Run the checklist below on the Surface device before committing.
