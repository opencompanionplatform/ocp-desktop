#!/usr/bin/env python3
"""
make_aiko_ocp.py — bake samples/aiko.ocp for end-to-end testing.

Generates:
  aiko.ocp (ZIP):
  ├── manifest.json
  └── assets/
      ├── character.json
      └── sprite.png   (procedural 96-px sprite-sheet, 6 frames)

Run from the samples/ directory:
    python make_aiko_ocp.py

Requires: Pillow  (pip install Pillow)
"""

import json
import zipfile
import io
import os
import hashlib
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit("Pillow is required: pip install Pillow")

# ── Config ────────────────────────────────────────────────────────────────────
SPRITE_PX   = 96
FRAME_COUNT = 6          # 0-1 idle,  2-5 wave
BODY_COLOR  = (140, 191, 255, 255)   # pastel blue

OUTPUT = Path(__file__).parent / "aiko.ocp"


# ── Frame renderer ────────────────────────────────────────────────────────────
def fill_rect(img: Image.Image, x, y, w, h, color):
    draw = ImageDraw.Draw(img)
    draw.rectangle([x, y, x + w - 1, y + h - 1], fill=color)


def make_frame(arm_up: bool, eyes_open: bool) -> Image.Image:
    img = Image.new("RGBA", (SPRITE_PX, SPRITE_PX), (0, 0, 0, 0))
    body = BODY_COLOR
    head = tuple(min(255, c + 38) for c in body[:3]) + (255,)
    dark = tuple(max(0, c - 30) for c in body[:3]) + (255,)
    eye_h = 6 if eyes_open else 2
    eye_c = (26, 26, 31, 255) if eyes_open else dark

    fill_rect(img, 24, 30, 48, 54, body)           # body
    fill_rect(img, 28, 12, 40, 26, head)            # head
    fill_rect(img, 36, 20, 6, eye_h, eye_c)         # left eye
    fill_rect(img, 54, 20, 6, eye_h, eye_c)         # right eye
    # smile
    fill_rect(img, 43, 32, 12, 2, (38, 20, 26, 255))
    fill_rect(img, 41, 30, 2, 2,  (38, 20, 26, 255))
    fill_rect(img, 55, 30, 2, 2,  (38, 20, 26, 255))
    # arm
    arm_y = 18 if arm_up else 52
    fill_rect(img, 70, arm_y, 12, 26, dark)

    return img


def build_sheet() -> Image.Image:
    """6-frame sheet: [idle0, idle1, wave0, wave1, wave2, wave3]"""
    frames = [
        make_frame(arm_up=False, eyes_open=True),   # 0 idle open
        make_frame(arm_up=False, eyes_open=False),  # 1 idle blink
        make_frame(arm_up=True,  eyes_open=True),   # 2 wave up
        make_frame(arm_up=False, eyes_open=True),   # 3 wave down
        make_frame(arm_up=True,  eyes_open=True),   # 4 wave up
        make_frame(arm_up=False, eyes_open=True),   # 5 wave down
    ]
    sheet = Image.new("RGBA", (SPRITE_PX * FRAME_COUNT, SPRITE_PX), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        sheet.paste(f, (i * SPRITE_PX, 0))
    return sheet


def sha256_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ── Build OCP ─────────────────────────────────────────────────────────────────
def main():
    # 1. Generate sprite sheet PNG bytes
    sheet   = build_sheet()
    buf     = io.BytesIO()
    sheet.save(buf, format="PNG")
    sprite_bytes = buf.getvalue()
    sprite_sha   = sha256_of(sprite_bytes)

    # 2. character/1 entry JSON
    character_json = json.dumps({
        "schema":   "character/1",
        "name":     "Aiko",
        "renderer": "sprite-sheet-2d",
        "sprites": [{
            "id":        "body",
            "path":      "assets/sprite.png",
            "frameSize": [SPRITE_PX, SPRITE_PX],
        }],
        "animations": {
            "idle": {
                "frames": [0, 1],
                "fps":    2,
                "loop":   True,
            },
            "idle_neutral": {
                "frames": [0, 1],
                "fps":    2,
                "loop":   True,
            },
            "wave": {
                "frames": [2, 3, 4, 5],
                "fps":    6,
                "loop":   False,
            },
        },
    }, indent=2)
    character_bytes = character_json.encode("utf-8")
    character_sha   = sha256_of(character_bytes)

    # 3. manifest.json
    manifest_json = json.dumps({
        "manifestVersion": "1",
        "type":       "character",
        "packageId":  "character.aiko",
        "name":       "Aiko",
        "version":    "1.0.0",
        "entry":      "assets/character.json",
        "assets": [
            {"path": "assets/character.json", "sha256": character_sha},
            {"path": "assets/sprite.png",     "sha256": sprite_sha},
        ],
    }, indent=2)
    manifest_bytes = manifest_json.encode("utf-8")

    # 4. Write aiko.ocp (ZIP)
    with zipfile.ZipFile(OUTPUT, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json",          manifest_bytes)
        zf.writestr("assets/character.json",  character_bytes)
        zf.writestr("assets/sprite.png",      sprite_bytes)

    size_kb = OUTPUT.stat().st_size / 1024
    print(f"✅  Written: {OUTPUT}  ({size_kb:.1f} KB)")
    print(f"    manifest.json          {len(manifest_bytes):>6} bytes")
    print(f"    assets/character.json  {len(character_bytes):>6} bytes")
    print(f"    assets/sprite.png      {len(sprite_bytes):>6} bytes  sha256={sprite_sha[:16]}…")
    print()
    print("Install in-editor:")
    print("  1. Run Godot → Runtime Test page")
    print("  2. Click [📦 Install .ocp] → select samples/aiko.ocp")
    print("  3. Click [▶ Play Idle] and [👋 Play Wave] to verify")


if __name__ == "__main__":
    main()
