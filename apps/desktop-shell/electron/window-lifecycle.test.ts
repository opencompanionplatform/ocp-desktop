import { describe, expect, it } from "vitest";

import { CHAT_WARM_RECLAIM_MS, isRuntimeOwnerShutdownLaunch, isWarmShellLaunch, shouldCloseCharactersWindow, shouldKeepWindowWarmOnClose, shouldQuitRuntimeOwnedShell, shouldReclaimWarmWindow, shouldRevealWindowOnAppActivate } from "./window-lifecycle";

describe("Runtime-owned Characters window lifecycle", () => {
  it("keeps Characters open when Runtime disconnects", () => {
    expect(shouldCloseCharactersWindow({ connected: true, characterCount: 1 }, { connected: false, characterCount: 0 })).toBe(false);
  });

  it("keeps Characters open when the last character is removed", () => {
    expect(shouldCloseCharactersWindow({ connected: true, characterCount: 1 }, { connected: true, characterCount: 0 })).toBe(false);
  });

  it("keeps Characters open on initial empty state and while characters change", () => {
    expect(shouldCloseCharactersWindow(null, { connected: false, characterCount: 0 })).toBe(false);
    expect(shouldCloseCharactersWindow({ connected: true, characterCount: 2 }, { connected: true, characterCount: 1 })).toBe(false);
  });
});

describe("Warm Desktop Shell lifecycle", () => {
  it("recognizes only the explicit bounded warm launch flag", () => {
    expect(isWarmShellLaunch(["--ocp-open=chat", "--ocp-warm=1"])).toBe(true);
    expect(isWarmShellLaunch(["--ocp-open=chat"])).toBe(false);
    expect(isWarmShellLaunch(["--ocp-warm=true"])).toBe(false);
  });

  it("destroys Chat on user close so presentation ownership is released immediately", () => {
    expect(shouldKeepWindowWarmOnClose(true, false, "chat")).toBe(false);
    expect(shouldKeepWindowWarmOnClose(true, false, "characters")).toBe(false);
    expect(shouldKeepWindowWarmOnClose(true, true, "chat")).toBe(false);
    expect(shouldKeepWindowWarmOnClose(false, false, "chat")).toBe(false);
  });

  it("reclaims only a hidden runtime-owned warm Chat window after the bounded timeout", () => {
    expect(CHAT_WARM_RECLAIM_MS).toBe(60_000);
    expect(shouldReclaimWarmWindow(true, false, "chat", true, false)).toBe(true);
    expect(shouldReclaimWarmWindow(true, false, "chat", false, false)).toBe(false);
    expect(shouldReclaimWarmWindow(true, false, "chat", true, true)).toBe(false);
    expect(shouldReclaimWarmWindow(true, false, "characters", true, false)).toBe(false);
    expect(shouldReclaimWarmWindow(false, false, "chat", true, false)).toBe(false);
    expect(shouldReclaimWarmWindow(true, true, "chat", true, false)).toBe(false);
  });

  it("never auto-reveals a runtime-owned warm window on app activation", () => {
    expect(shouldRevealWindowOnAppActivate(true, true)).toBe(false);
    expect(shouldRevealWindowOnAppActivate(true, false)).toBe(true);
    expect(shouldRevealWindowOnAppActivate(false, true)).toBe(true);
  });
});

describe("Runtime-owned Electron process lifecycle", () => {
  it("recognizes only the explicit Runtime-owner shutdown signal", () => {
    expect(isRuntimeOwnerShutdownLaunch(["--ocp-exit=runtime-owner-shutdown"])).toBe(true);
    expect(isRuntimeOwnerShutdownLaunch(["--ocp-exit=runtime-owner-restart"])).toBe(false);
    expect(isRuntimeOwnerShutdownLaunch([])).toBe(false);
  });

  it("keeps the authenticated shell alive after Runtime owner loss so a restarted Runtime can rebind", () => {
    expect(shouldQuitRuntimeOwnedShell(true, true, false)).toBe(false);
  });

  it("does not exit before ownership and terminal loss are both established", () => {
    expect(shouldQuitRuntimeOwnedShell(true, false, false)).toBe(false);
    expect(shouldQuitRuntimeOwnedShell(false, true, false)).toBe(false);
    expect(shouldQuitRuntimeOwnedShell(true, true, true)).toBe(false);
  });
});
