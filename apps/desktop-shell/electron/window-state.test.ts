import { describe, expect, it } from "vitest";

import { resolveWindowPlacement, sanitizeStoredWindowState } from "./window-state";

const displays = [
  { id: "primary", workArea: { x: 0, y: 0, width: 1920, height: 1040 } },
  { id: "secondary", workArea: { x: 1920, y: 0, width: 2560, height: 1400 } },
];

describe("desktop shell window geometry", () => {
  it("keeps valid normal bounds on the original monitor", () => {
    expect(
      resolveWindowPlacement(
        { bounds: { x: 2200, y: 140, width: 1280, height: 820 }, maximized: false },
        displays,
      ),
    ).toEqual({ bounds: { x: 2200, y: 140, width: 1280, height: 820 }, maximized: false });
  });

  it("centers invalid off-screen bounds on the preferred display", () => {
    expect(
      resolveWindowPlacement(
        { bounds: { x: 9000, y: 9000, width: 1200, height: 800 }, maximized: true },
        displays,
        { x: 2500, y: 500 },
      ),
    ).toEqual({ bounds: { x: 2560, y: 290, width: 1280, height: 820 }, maximized: true });
  });

  it("clamps restored size to the supported minimum and display work area", () => {
    expect(
      resolveWindowPlacement(
        { bounds: { x: 20, y: 20, width: 200, height: 100 }, maximized: false },
        displays,
      ).bounds,
    ).toEqual({ x: 20, y: 20, width: 960, height: 680 });
  });

  it("keeps a valid window on a secondary monitor placed left of the primary display", () => {
    const leftSecondary = [
      { id: "left", workArea: { x: -1600, y: 0, width: 1600, height: 900 } },
      { id: "primary", workArea: { x: 0, y: 0, width: 1920, height: 1040 } },
    ];
    expect(
      resolveWindowPlacement(
        { bounds: { x: -1500, y: 40, width: 1200, height: 760 }, maximized: false },
        leftSecondary,
      ),
    ).toEqual({ bounds: { x: -1500, y: 40, width: 1200, height: 760 }, maximized: false });
  });

  it("recovers a disconnected-monitor window onto the display containing the activation point", () => {
    expect(
      resolveWindowPlacement(
        { bounds: { x: -2600, y: 100, width: 1280, height: 820 }, maximized: false },
        displays,
        { x: 3000, y: 600 },
      ),
    ).toEqual({ bounds: { x: 2560, y: 290, width: 1280, height: 820 }, maximized: false });
  });

  it("supports a monitor positioned above the primary display", () => {
    const verticalDisplays = [
      { id: "primary", workArea: { x: 0, y: 0, width: 1920, height: 1040 } },
      { id: "upper", workArea: { x: 200, y: -1200, width: 1920, height: 1200 } },
    ];
    expect(
      resolveWindowPlacement(
        { bounds: { x: 500, y: -1100, width: 1200, height: 760 }, maximized: true },
        verticalDisplays,
      ),
    ).toEqual({ bounds: { x: 500, y: -1100, width: 1200, height: 760 }, maximized: true });
  });

  it("rejects malformed persisted JSON state", () => {
    expect(sanitizeStoredWindowState({ bounds: { x: "0" }, maximized: "yes" })).toBeNull();
  });
});
