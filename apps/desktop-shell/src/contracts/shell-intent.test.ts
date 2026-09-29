import { describe, expect, it } from "vitest";

import { parseShellIntentArgs, sanitizeShellIntent } from "./shell-intent";

describe("shell intent boundary", () => {
  it("accepts an allowlisted hover-menu route and finite display point", () => {
    expect(
      parseShellIntentArgs([
        "--ocp-open=characters",
        "--ocp-source=hover-menu",
        "--ocp-display-x=2860",
        "--ocp-display-y=420",
      ]),
    ).toEqual({
      ok: true,
      value: {
        view: "characters",
        source: "hover-menu",
        displayPoint: { x: 2860, y: 420 },
      },
    });
  });

  it("accepts the bounded My Library alias without creating a fourth native window", () => {
    expect(parseShellIntentArgs(["--ocp-open=library", "--ocp-source=shell-navigation"])).toEqual({ ok: true, value: { view: "library", source: "shell-navigation" } });
  });

  it("routes the tray Updates shortcut through the existing Control Center window", () => {
    expect(parseShellIntentArgs(["--ocp-open=updates", "--ocp-source=tray"])).toEqual({ ok: true, value: { view: "updates", source: "tray" } });
  });

  it("rejects unknown routes instead of best-effort navigation", () => {
    expect(parseShellIntentArgs(["--ocp-open=developer-console"]).ok).toBe(false);
  });

  it("rejects extra object fields to prevent payload smuggling", () => {
    expect(
      sanitizeShellIntent({
        view: "characters",
        source: "second-instance",
        execute: "powershell.exe",
      }).ok,
    ).toBe(false);
  });

  it("rejects partial, non-finite, and unbounded display coordinates", () => {
    expect(
      sanitizeShellIntent({
        view: "chat",
        source: "command-line",
        displayPoint: { x: Number.POSITIVE_INFINITY, y: 10 },
      }).ok,
    ).toBe(false);
    expect(parseShellIntentArgs(["--ocp-display-x=10"]).ok).toBe(false);
  });
});
