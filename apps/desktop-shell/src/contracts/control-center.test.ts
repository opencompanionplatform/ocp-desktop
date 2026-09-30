import { describe, expect, it } from "vitest";

import {
  controlPageForShellView,
  controlCenterPages,
  controlSelectableFontFamilies,
  controlCenterSettingsSignature,
  aiControlSettingsSignature,
  aiControlSettingsValidationError,
  sanitizeAIControlSettings,
  sanitizeAIControlSnapshot,
  sanitizeControlCenterSettings,
  sanitizeResourceSnapshot,
  sanitizeUpdateControlSnapshot,
  settingsResultMessage,
  updateMessages,
} from "./control-center";

const settings = {
  themePreset: "glass",
  fontFamily: "Leelawadee UI",
  textScale: "large",
  bubbleStyle: "Rounded",
  language: "th",
  showBubbles: true,
  clickThroughEnabled: false,
  startWithWindows: true,
  offlinePresenceEnabled: true,
  llmCompanionModeEnabled: false,
  updateChannel: "preview",
  automaticUpdateChecks: true,
  reduceMotion: true,
} as const;

describe("Control Center boundary", () => {
  it("offers bundled Noto Sans Thai as the first selectable OCP font", () => {
    expect(controlSelectableFontFamilies[0]).toBe("Noto Sans Thai");
  });

  it("maps the legacy Settings window intent to the Settings page in Home", () => {
    expect(controlCenterPages).toEqual(["settings", "ai-voice", "updates"]);
    expect(controlPageForShellView("settings")).toBe("settings");
    expect(controlPageForShellView("home")).toBe("settings");
    expect(controlPageForShellView("updates")).toBe("updates");
    expect(controlPageForShellView("chat")).toBeNull();
  });

  it("uses bounded local copy for correlated Runtime results", () => {
    expect(settingsResultMessage("saved")).toBe("Settings saved by Runtime.");
    expect(settingsResultMessage("failed", "startup-registration-failed")).toContain("no Settings were saved");
    expect(settingsResultMessage("failed", "C:\\private\\raw-error")).toBe("Runtime could not complete the Settings request.");
  });

  it("does not treat identical polling snapshots as a form change", () => {
    expect(controlCenterSettingsSignature(settings)).toBe(controlCenterSettingsSignature({ ...settings }));
    expect(controlCenterSettingsSignature(settings)).not.toBe(controlCenterSettingsSignature({ ...settings, language: "en" }));
  });

  it("accepts only a complete Godot-equivalent Settings projection", () => {
    expect(sanitizeControlCenterSettings(settings)).toEqual(settings);
    expect(sanitizeControlCenterSettings({ ...settings, fontFamily: "url(evil)" })).toBeNull();
    expect(sanitizeControlCenterSettings({ ...settings, execute: "cmd.exe" })).toBeNull();
    const partial = Object.fromEntries(Object.entries(settings).filter(([key]) => key !== "updateChannel"));
    expect(sanitizeControlCenterSettings(partial)).toBeNull();
  });

  it("separates whole-system pressure from OCP-owned memory and accepts legacy samples", () => {
    const current = {
      available: true,
      cpuPercent: 24.5,
      memoryPercent: 61,
      ocpMemoryMb: 642.5,
      runtimeMemoryMb: 284,
      desktopShellMemoryMb: 326,
      kernelMemoryMb: 18,
      nativeHostMemoryMb: 14.5,
      aiMemoryMb: 4820,
      pressure: "normal" as const,
      sampledAtMs: 1234,
    };
    expect(sanitizeResourceSnapshot(current)).toEqual(current);
    expect(sanitizeResourceSnapshot({
      available: true,
      cpuPercent: 24.5,
      memoryPercent: 61,
      pressure: "normal",
      sampledAtMs: 1234,
    })).toEqual({
      available: true,
      cpuPercent: 24.5,
      memoryPercent: 61,
      pressure: "normal",
      sampledAtMs: 1234,
    });
    expect(sanitizeResourceSnapshot({ ...current, cpuPercent: 101 })).toBeNull();
    expect(sanitizeResourceSnapshot({ ...current, ocpMemoryMb: -1 })).toBeNull();
    expect(sanitizeResourceSnapshot({ ...current, path: "C:\\private" })).toBeNull();
  });

  it("accepts only the bounded Godot-equivalent AI and Voice projection", () => {
    const aiSettings = {
      providerId: "ollama", baseUrl: "http://127.0.0.1:11434", model: "qwen3.5:latest", timeoutSeconds: 45,
      ttsEnabled: true, ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "Zephyr", ttsVoiceMode: "custom", ttsVoiceGender: "female", ttsVoiceAge: "adult", thaiSpeechStyle: "feminine", chatVoiceMode: "on-demand",
    } as const;
    expect(sanitizeAIControlSettings(aiSettings)).toEqual(aiSettings);
    expect(sanitizeAIControlSettings({ ...aiSettings, ttsModel: "arbitrary-paid-model" })).toBeNull();
    const { ttsModel: _legacyModel, ...legacyAISettings } = aiSettings;
    void _legacyModel;
    expect(sanitizeAIControlSettings(legacyAISettings)?.ttsModel).toBe("gemini-3.1-flash-tts-preview");
    expect(aiControlSettingsSignature(aiSettings)).toBe(aiControlSettingsSignature({ ...aiSettings }));
    expect(sanitizeAIControlSettings({ ...aiSettings, timeoutSeconds: 46 })).toBeNull();
    expect(sanitizeAIControlSettings({ ...aiSettings, credential: "must-not-project" })).toBeNull();
    expect(sanitizeAIControlSnapshot({
      settings: aiSettings,
      provider: { providerId: "ollama", available: true, configured: true, reachable: false, test: { status: "idle", errorCode: "" } },
      credentials: { brokerAvailable: true, openAiCompatiblePresent: false, geminiPresent: true },
      voiceTest: { status: "failed", errorCode: "tts-unavailable" },
    })).not.toBeNull();
    expect(sanitizeAIControlSnapshot({
      settings: aiSettings,
      provider: { providerId: "ollama", available: true, configured: true, reachable: false, test: { status: "idle", errorCode: "C:\\private\\raw" } },
      credentials: { brokerAvailable: true, openAiCompatiblePresent: false, geminiPresent: true, credential: "leak" },
      voiceTest: { status: "idle", errorCode: "" },
    })).toBeNull();
    expect(aiControlSettingsValidationError({ ...aiSettings, baseUrl: "" })).toBe("provider-base-url-required");
    expect(aiControlSettingsValidationError({ ...aiSettings, model: "  " })).toBe("provider-model-required");
    expect(aiControlSettingsValidationError({ ...aiSettings, baseUrl: "file:///tmp" })).toBe("provider-base-url-invalid");
    expect(sanitizeAIControlSettings({ ...aiSettings, baseUrl: " http://127.0.0.1:11434 ", model: " qwen3.5:latest " })).toMatchObject({ baseUrl: "http://127.0.0.1:11434", model: "qwen3.5:latest" });
  });

  it("accepts only canonical safe update state and never raw updater material", () => {
    const update = {
      currentVersion: "0.1.0", channel: "stable", state: "ready",
      messageCode: "update-ready", message: updateMessages["update-ready"],
      targetVersion: "0.2.0", canCheck: true, canApply: true,
      automaticChecksEnabled: true, nextAutomaticCheckSeconds: 3600, stableTrustReady: true, installOnRestart: false,
    } as const;
    expect(sanitizeUpdateControlSnapshot(update)).toEqual(update);
    expect(sanitizeUpdateControlSnapshot({ ...update, message: "staged at C:\\private\\update.zip" })).toBeNull();
    expect(sanitizeUpdateControlSnapshot({ ...update, releaseUrl: "https://example.test/update.zip" })).toBeNull();
    expect(sanitizeUpdateControlSnapshot({ ...update, signingKey: "secret" })).toBeNull();
    expect(sanitizeUpdateControlSnapshot({ ...update, state: "idle", canApply: true })).toBeNull();
    expect(sanitizeUpdateControlSnapshot({ ...update, canApply: false, installOnRestart: true })).toBeNull();
    expect(sanitizeUpdateControlSnapshot({ ...update, targetVersion: "..\\payload" })).toBeNull();
  });
});
