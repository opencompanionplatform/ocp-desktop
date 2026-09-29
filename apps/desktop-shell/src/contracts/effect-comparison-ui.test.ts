import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

describe("production character effect controls", () => {
  it("does not expose the temporary three-version comparison in the character page", () => {
    const appSource = readFileSync(fileURLToPath(new URL("../App.tsx", import.meta.url)), "utf8");
    expect(appSource).not.toContain("effect_comparison_title");
    expect(appSource).not.toContain("video-blend");
    expect(appSource).not.toContain("starter-mist");
  });
});
