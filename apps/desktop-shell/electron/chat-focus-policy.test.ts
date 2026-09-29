import { describe, expect, it } from "vitest";

import { isCharacterPreviewActive, isChatPresentationActive, isCompanionSuppressionActive, shouldSynchronizeChatPresentation } from "./chat-focus-policy";

describe("Chat presentation ownership policy", () => {
  it("suppresses native presentation for the whole visible non-minimized Chat lifecycle", () => {
    expect(isChatPresentationActive({ view: "chat", visible: true, focused: true, minimized: false })).toBe(true);
    expect(isChatPresentationActive({ view: "chat", visible: true, focused: false, minimized: false })).toBe(true);
    expect(isChatPresentationActive({ view: "chat", visible: true, focused: true, minimized: true })).toBe(false);
    expect(isChatPresentationActive({ view: "chat", visible: false, focused: false, minimized: false })).toBe(false);
    expect(isChatPresentationActive({ view: "chat", visible: true, focused: false, minimized: false }, false, true)).toBe(false);
    expect(isChatPresentationActive({ view: "home", visible: true, focused: true, minimized: false })).toBe(false);
  });

  it("gives the foreground Character Manager preview ownership but lets foreground Chat take it back", () => {
    const characterPreviewActive = isCharacterPreviewActive({ view: "characters", visible: true, focused: true, minimized: false });
    expect(characterPreviewActive).toBe(true);
    expect(isChatPresentationActive({ view: "chat", visible: true, focused: false, minimized: false }, characterPreviewActive)).toBe(false);
    expect(isCharacterPreviewActive({ view: "characters", visible: true, focused: false, minimized: false })).toBe(false);
    expect(isCharacterPreviewActive({ view: "characters", visible: true, focused: true, minimized: true })).toBe(false);
    expect(isChatPresentationActive({ view: "chat", visible: true, focused: true, minimized: false }, false)).toBe(true);
  });

  it("repairs Chat presentation ownership when a visibility command was missed", () => {
    expect(shouldSynchronizeChatPresentation(true, null, "native", 1_000, 0)).toBe(true);
    expect(shouldSynchronizeChatPresentation(true, true, "chat", 1_000, 0)).toBe(false);
    expect(shouldSynchronizeChatPresentation(true, true, "native", 100, 0)).toBe(false);
    expect(shouldSynchronizeChatPresentation(true, true, "native", 200, 0)).toBe(true);
    expect(shouldSynchronizeChatPresentation(false, false, "chat", 900, 0)).toBe(true);
    expect(shouldSynchronizeChatPresentation(false, false, "native", 900, 0)).toBe(false);
    expect(shouldSynchronizeChatPresentation(false, false, undefined, 900, 0)).toBe(false);
  });

  it("suppresses the live companion for visible Home/Settings and Character Manager surfaces", () => {
    expect(isCompanionSuppressionActive({ view: "characters", visible: true, focused: true, minimized: false })).toBe(true);
    expect(isCompanionSuppressionActive({ view: "characters", visible: true, focused: false, minimized: false })).toBe(true);
    expect(isCompanionSuppressionActive({ view: "characters", visible: true, focused: true, minimized: true })).toBe(false);
    expect(isCompanionSuppressionActive({ view: "home", visible: true, focused: true, minimized: false })).toBe(true);
    expect(isCompanionSuppressionActive({ view: "home", visible: true, focused: false, minimized: false })).toBe(true);
    expect(isCompanionSuppressionActive({ view: "home", visible: true, focused: true, minimized: true })).toBe(false);
    expect(isCompanionSuppressionActive({ view: "chat", visible: true, focused: true, minimized: false })).toBe(false);
  });
});
