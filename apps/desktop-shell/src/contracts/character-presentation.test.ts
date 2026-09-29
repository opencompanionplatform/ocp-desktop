import { describe, expect, it } from "vitest";

import {
  animationGlyph,
  chatAnimationForPresentation,
  characterDisplayName,
  characterInitials,
  cloudCharacterThumbnailUrl,
  previewStatusLabel,
  visibleAnimationShortcuts,
} from "./character-presentation";

describe("character presentation helpers", () => {
  it("derives bounded plain-text initials without inventing artwork", () => {
    expect(characterInitials("Meow Som")).toBe("MS");
    expect(characterInitials("  น้องส้ม  ")).toBe("น้");
    expect(characterInitials("<script>")).toBe("<S");
    expect(characterInitials("   ")).toBe("OC");
  });

  it("accepts only credential-free HTTPS artwork URLs from Cloud catalog metadata", () => {
    expect(cloudCharacterThumbnailUrl("https://cdn.example/sabai.webp")).toBe("https://cdn.example/sabai.webp");
    expect(cloudCharacterThumbnailUrl("  https://cdn.example/sabai.webp  ")).toBe("https://cdn.example/sabai.webp");
    expect(cloudCharacterThumbnailUrl("http://cdn.example/sabai.webp")).toBe("");
    expect(cloudCharacterThumbnailUrl("javascript:alert(1)")).toBe("");
    expect(cloudCharacterThumbnailUrl("https://user:secret@cdn.example/sabai.webp")).toBe("");
  });

  it("uses a friendly display name when package metadata only repeats its identity", () => {
    expect(characterDisplayName("character.sabai-sompoo", "character.sabai-sompoo")).toBe("Sabai Sompoo");
    expect(characterDisplayName("meowsom", "character.meowsom")).toBe("Meowsom");
    expect(characterDisplayName("", "character.scifi-woman")).toBe("Sci-Fi Woman");
    expect(characterDisplayName("Nong Mali", "character.mali")).toBe("Nong Mali");
  });

  it("maps common animation names to presentation-only glyphs", () => {
    expect(animationGlyph("idle")).toBe("●");
    expect(animationGlyph("walk_left")).toBe("↙");
    expect(animationGlyph("walk-right")).toBe("↘");
    expect(animationGlyph("wave")).toBe("⌁");
    expect(animationGlyph("custom_clip")).toBe("◇");
  });

  it("uses authoritative preview state labels", () => {
    expect(previewStatusLabel("playing", "idle")).toBe("Previewing: idle");
    expect(previewStatusLabel("paused", "wave")).toBe("Paused: wave");
    expect(previewStatusLabel("loading", "")).toBe("Preparing preview");
    expect(previewStatusLabel("failed", "idle")).toBe("Preview unavailable");
  });

  it("keeps the selected animation visible in a bounded shortcut row", () => {
    const clips = ["idle", "walk_left", "walk_right", "wave", "happy", "sad", "sleep"];
    expect(visibleAnimationShortcuts(clips, "sleep", 6)).toEqual([
      "idle",
      "walk_left",
      "walk_right",
      "wave",
      "happy",
      "sleep",
    ]);
    expect(visibleAnimationShortcuts(clips, "wave", 6)).toEqual(clips.slice(0, 6));
    expect(visibleAnimationShortcuts(clips, "wave", 0)).toEqual([]);
  });

  it("selects the Runtime preview clip for Chat idle, think and talk states", () => {
    const clips = ["idle", "think", "speak", "wave"];
    expect(chatAnimationForPresentation("idle", clips)).toBe("idle");
    expect(chatAnimationForPresentation("think", clips)).toBe("think");
    expect(chatAnimationForPresentation("talk", clips)).toBe("speak");
    expect(chatAnimationForPresentation("talk", ["idle", "talk"])).toBe("talk");
    expect(chatAnimationForPresentation("think", ["idle"], "idle")).toBe("idle");
  });
});
