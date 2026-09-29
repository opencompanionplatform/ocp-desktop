import { describe, expect, it } from "vitest";
import { sanitizeRuntimeBridgeCommand } from "./runtime-bridge";

describe("temporary effect comparison command", () => {
  it("accepts exactly the three comparisons and the equipped baseline", () => {
    for (const variant of ["equipped", "video-original", "video-blend", "starter-mist"]) {
      const command = { type: "effect-pack.preview", mode: "bodyAura", variant };
      expect(sanitizeRuntimeBridgeCommand(command)).toEqual(command);
    }
  });
  it("rejects unknown variants and package/path injection", () => {
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", variant: "arbitrary" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", variant: "video-blend", path: "C:/other" })).toBeNull();
  });
  it("keeps legacy callers compatible", () => {
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", mode: "off" })).toEqual({ type: "effect-pack.preview", mode: "off" });
  });
});
