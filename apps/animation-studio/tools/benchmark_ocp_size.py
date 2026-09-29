#!/usr/bin/env python3
"""Benchmark an OCP character package's sprite storage profile.

Developer utility only; it does not modify the package. When Pillow is installed,
it re-encodes sprite PNG entries to transparent WebP in memory so Studio changes
can be compared against a real package before/after a browser build.
"""

from __future__ import annotations

import argparse
import io
import json
import zipfile
from pathlib import Path


def mb(value: int) -> float:
    return round(value / (1024 * 1024), 2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    parser.add_argument("--webp-quality", type=int, default=92)
    args = parser.parse_args()

    with zipfile.ZipFile(args.package) as archive:
        infos = archive.infolist()
        pngs = [info for info in infos if info.filename.startswith("assets/") and info.filename.endswith(".png") and info.filename != "assets/preview.png"]
        webps = [info for info in infos if info.filename.startswith("assets/") and info.filename.endswith(".webp")]
        wavs = [info for info in infos if info.filename.startswith("assets/audio/") and info.filename.endswith(".wav")]
        oggs = [info for info in infos if info.filename.startswith("assets/audio/") and info.filename.endswith(".ogg")]

        entry = json.loads(archive.read("assets/character.json"))
        total_frames = sum(len(clip.get("frames", [])) for clip in entry.get("animations", {}).values() if isinstance(clip, dict))
        raw_rgba = total_frames * 512 * 512 * 4

        print(f"package_mb={mb(args.package.stat().st_size)}")
        print(f"sprite_png_mb={mb(sum(info.file_size for info in pngs))} count={len(pngs)}")
        print(f"sprite_webp_mb={mb(sum(info.file_size for info in webps))} count={len(webps)}")
        print(f"audio_wav_mb={mb(sum(info.file_size for info in wavs))} count={len(wavs)}")
        print(f"audio_ogg_mb={mb(sum(info.file_size for info in oggs))} count={len(oggs)}")
        print(f"logical_frame_entries={total_frames} raw_rgba_mb={mb(raw_rgba)}")

        if not pngs:
            return 0
        try:
            from PIL import Image
        except ImportError:
            print("webp_benchmark=skipped (Pillow is not installed)")
            return 0

        converted = 0
        for info in pngs:
            image = Image.open(io.BytesIO(archive.read(info.filename))).convert("RGBA")
            output = io.BytesIO()
            image.save(output, format="WEBP", quality=args.webp_quality, method=6)
            converted += output.tell()
        original = sum(info.file_size for info in pngs)
        saving = 0.0 if original == 0 else (1.0 - converted / original) * 100.0
        print(f"webp_q{args.webp_quality}_estimate_mb={mb(converted)} saving_pct={saving:.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
