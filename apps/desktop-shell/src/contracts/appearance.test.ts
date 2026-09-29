import { describe, expect, it } from "vitest";

import { DEFAULT_SHELL_APPEARANCE, sanitizeShellAppearance } from "./appearance";

describe("shell appearance boundary", () => {
  it("uses the documented Noto/standard presentation defaults", () => {
    expect(DEFAULT_SHELL_APPEARANCE.fontFamily).toBe("noto-sans-thai");
    expect(DEFAULT_SHELL_APPEARANCE.textScale).toBe("standard");
  });

  it("accepts only the complete allowlisted preference object", () => {
    expect(sanitizeShellAppearance({ ...DEFAULT_SHELL_APPEARANCE, fontFamily: "noto-sans-thai" })).toEqual({
      ...DEFAULT_SHELL_APPEARANCE,
      fontFamily: "noto-sans-thai",
    });
  });

  it("rejects partial values and CSS or command smuggling", () => {
    expect(sanitizeShellAppearance({ theme: "liquid" })).toBeNull();
    expect(sanitizeShellAppearance({ ...DEFAULT_SHELL_APPEARANCE, fontFamily: "url(evil)", execute: "cmd" })).toBeNull();
  });
});
