# Phase 6.4.2 — Generic OCP Character Builder

## Files

```text
build_ocp_character.ps1
new_ocp_character.ps1
test_ocp_character_source.ps1
character.build.example.json
```

## Install

Place the three PowerShell files at:

```text
apps/desktop-runtime/
```

Each character gets its own configuration:

```text
poc-assets/<character>/character.build.json
```

## Create a new workspace

```powershell
.\new_ocp_character.ps1 `
  -CharacterRoot .\poc-assets\meowsom `
  -CharacterId character.meowsom `
  -CharacterName Meowsom
```

This creates:

```text
poc-assets/meowsom/
├── character.build.json
└── animations/
```

For an existing character, copy `character.build.example.json` to:

```text
poc-assets/meowsom/character.build.json
```

and edit its identity and presentation values.

## Required animation sources

```text
idle.png
appear.png
disappear.png
wave.png
speak.png
think.png
walk_left.png
walk_right.png
sit.png
sleep.png
wake.png
happy.png
sad.png
angry.png
surprised.png
```

Accepted migration aliases:

```text
walk-left.png
walkleft.png
walk-right.png
walkright.png
thinking.png
```

Output names are always normalized to `walk_left.png`, `walk_right.png` and
`think.png`.

## Validate source

```powershell
.\test_ocp_character_source.ps1 `
  -CharacterRoot .\poc-assets\meowsom
```

## Preview chroma removal

```powershell
.\build_ocp_character.ps1 `
  -CharacterRoot .\poc-assets\meowsom `
  -ChromaFuzz 7 `
  -PreviewOnly
```

Review:

```text
poc-assets/meowsom/runtime/animations/
```

Preview also generates:

```text
poc-assets/meowsom/runtime/character.json
poc-assets/meowsom/runtime/_package/
```

It intentionally does not create `.ocp`.

## Build package

```powershell
.\build_ocp_character.ps1 `
  -CharacterRoot .\poc-assets\meowsom `
  -ChromaFuzz 7
```

Expected:

```text
poc-assets/meowsom/meowsom.ocp
poc-assets/meowsom/runtime/character.json
poc-assets/meowsom/runtime/animations/
poc-assets/meowsom/runtime/_package/manifest.json
```

## Chroma logic

The builder:

1. crops each frame from the sprite sheet;
2. flood-fills transparency from all four frame corners;
3. removes only connected green background;
4. reassembles a transparent sprite sheet;
5. creates transparent blank cells for unused grid slots.

This avoids global green replacement damaging green details inside a
character.

## Frame counts

`character.build.json` is the source of truth.

A six-frame animation still uses a 4×2 sheet, but Runtime receives:

```json
"frames": 6
```

so cells 7 and 8 are never played.

## Package layout

```text
manifest.json
assets/
├── character.json
├── idle.png
├── appear.png
└── ...
```

The builder creates ZIP entries with forward slashes and verifies these entries
after writing:

```text
manifest.json
assets/character.json
assets/idle.png
```

## Install test

```powershell
.\run_install_poc.ps1 `
  -Action Run `
  -StartupMode debug
```

Then use Character Picker → Install Character.

## Bible configuration

Create:

```text
poc-assets/bible/character.build.json
```

with:

```json
{
  "id": "character.bible",
  "name": "Bible",
  "version": "1.0.0",
  "outputFile": "bible.ocp"
}
```

and copy the remaining sheet, presentation and animation sections from the
example file.

## Builder consolidation

After both Bible and Meowsom build and install successfully:

```text
build_poc_character_v3.ps1
build_meowsom_ocp.ps1
```

can be archived. Keep them for one stable sprint before deletion.
