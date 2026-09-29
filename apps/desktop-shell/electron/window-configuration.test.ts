import { describe, expect, it } from "vitest";

import { nativeShellViews, resolveNativeShellView, viewUsesRuntimePreviewMedia, windowMinimums, windowStateFileName } from "./window-configuration";

describe("multi-window configuration", () => {
  it("gives every native window an independent persistence key", () => {
    const keys = nativeShellViews.map(windowStateFileName);
    expect(new Set(keys).size).toBe(3);
    expect(keys).toContain("desktop-shell-window-characters.json");
  });

  it("routes compatibility intents into their canonical native windows", () => {
    expect(resolveNativeShellView("settings")).toBe("home");
    expect(resolveNativeShellView("updates")).toBe("home");
    expect(resolveNativeShellView("library")).toBe("characters");
    expect(resolveNativeShellView("home")).toBe("home");
    expect(resolveNativeShellView("chat")).toBe("chat");
  });

  it("projects Runtime preview media into Character and Chat windows only", () => {
    expect(viewUsesRuntimePreviewMedia("characters")).toBe(true);
    expect(viewUsesRuntimePreviewMedia("chat")).toBe(true);
    expect(viewUsesRuntimePreviewMedia("home")).toBe(false);
  });

  it("keeps every native window resizable above a usable minimum", () => {
    for (const minimum of Object.values(windowMinimums)) {
      expect(minimum.width).toBeGreaterThanOrEqual(560);
      expect(minimum.height).toBeGreaterThanOrEqual(500);
    }
  });
});
