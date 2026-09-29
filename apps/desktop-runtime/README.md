# OCP Desktop Runtime — Sprint A v8

Sprint A stabilizes runtime state and character switching on top of the known-good fullscreen, DPI-scaled, non-flickering overlay.

## Delivered

- Dragging a companion hides the Hover Menu immediately.
- After drag release, Hover Menu stays hidden until the pointer leaves the companion once and enters again.
- Restoring from tray shows only the companion. Quick Panel, Hover Menu, and Character Picker remain closed.
- Replaces the native `PopupMenu` character selector with an in-window Character Picker, avoiding scaled-overlay and mouse-passthrough issues.
- Lists all installed character versions from `InstalledCharacterRepository`.
- Activates a character and reloads its frames without restarting the scene.
- Installs `.ocp` through `OcpPackageReader → OcpPackageValidator → CharacterPackageInstaller`.
- Supports uninstall and chooses the first remaining package as fallback when the active package is removed.
- Uses generated placeholder frames only when no valid active package remains.

## Files

```text
godot/scripts/companion.gd
build_poc_character_v3.ps1
examples/character.runtime.example.json
README.md
CHECKLIST.md
COMMIT_MESSAGE.txt
```

## Install

From `apps/desktop-runtime`:

```powershell
Copy-Item `
  .\godot\scripts\companion.gd `
  .\godot\scripts\companion.gd.bak-sprint-a
```

Extract this ZIP and copy its `godot` directory over the repository `godot` directory.

Do not delete `.godot` caches for this update.

## Run

```powershell
Get-Process Godot* -ErrorAction SilentlyContinue |
Stop-Process -Force

.\run_install_poc.ps1 `
  -Action Run `
  -Arch arm64 `
  -Profile debug
```

## Expected interaction

### Drag

```text
Hover companion
→ Hover Menu appears
→ press and drag
→ Hover Menu disappears immediately
→ release
→ menu remains hidden
→ move pointer outside companion
→ hover companion again
→ menu appears
```

### Tray

```text
Hide to tray
→ companion and all runtime panels are hidden

Left-click tray / Show companion
→ companion is restored at its existing position
→ Quick Panel remains closed
→ Character Picker remains closed
→ Hover Menu remains closed until hover
```

### Change Character

```text
Hover Menu or Quick Panel
→ Change Character
→ in-window Character Picker opens
→ Activate switches immediately
→ Install .ocp validates, installs, activates, and reloads
→ Uninstall removes the selected version
```

Installed package layout remains:

```text
user://packages/characters/<packageId>/<version>/
user://runtime/state.json
```

## Runtime metadata

Recommended `character.json`:

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

## Rollback

```powershell
Copy-Item `
  .\godot\scripts\companion.gd.bak-sprint-a `
  .\godot\scripts\companion.gd `
  -Force
```

## Known limitations

- There is no uninstall confirmation dialog yet.
- Fallback selection after uninstall currently chooses the first installed package returned by the repository.
- Character position persistence across process restarts is planned for Sprint B.
- `OCP_IPC_TOKEN` warning remains unrelated to local UI testing.
