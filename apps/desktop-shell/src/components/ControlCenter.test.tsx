import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { RuntimeSnapshot } from "../../electron/runtime-bridge";
import { updateApplyCommandForDecision } from "../contracts/control-center";
import { ControlCenter } from "./ControlCenter";

const runtime: RuntimeSnapshot = {
  schemaVersion: 6,
  status: "connected",
  appearance: { theme: "solid", locale: "en", fontFamily: "inter", textScale: "standard", reduceMotion: false },
  characters: [],
  chat: { providerId: "ollama", status: "ready", messages: [] },
  preview: { status: "idle", errorCode: "", packageId: "", version: "", clips: [], selectedAnimation: "", isPlaying: false, loop: false, speed: 1, framePngBase64: "", frameWidth: 0, frameHeight: 0 },
  controlCenter: {
    settings: { themePreset: "solid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded", language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false, offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false },
    resources: { available: true, cpuPercent: 10, memoryPercent: 20, ocpMemoryMb: 642, runtimeMemoryMb: 284, desktopShellMemoryMb: 326, kernelMemoryMb: 18, nativeHostMemoryMb: 14, aiMemoryMb: 4820, pressure: "normal", sampledAtMs: 1 },
    ai: {
      settings: { providerId: "openai-compatible", baseUrl: "https://api.openai.com/v1", model: "gpt-test", timeoutSeconds: 45, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "Zephyr", ttsVoiceMode: "custom", ttsVoiceGender: "female", ttsVoiceAge: "adult", thaiSpeechStyle: "feminine" },
      provider: { providerId: "openai-compatible", available: true, configured: true, reachable: true, test: { status: "succeeded", errorCode: "" } },
      credentials: { brokerAvailable: true, openAiCompatiblePresent: true, geminiPresent: false },
      voiceTest: { status: "idle", errorCode: "" },
    },
    updates: { currentVersion: "0.1.0", channel: "stable", state: "ready", messageCode: "update-ready", message: "A verified update is staged and ready to install.", targetVersion: "0.2.0", canCheck: true, canApply: true },
  },
  commandResults: [],
};

describe("AI & Voice Control Center page", () => {
  it("renders real provider, write-only credential and Runtime test controls", () => {
    const markup = renderToStaticMarkup(<ControlCenter page="ai-voice" runtime={runtime} setPage={() => undefined} />);
    expect(markup).toContain("Choose how your companion thinks and speaks");
    expect(markup).toContain('aria-label="Cloud API key"');
    expect(markup).toContain('type="password"');
    expect(markup).toContain("Test connection");
    expect(markup).toContain("Test voice");
    expect(markup).toContain("Gemini 2.5 Flash TTS — Economy");
    expect(markup).toContain("Effective custom profile: Female, Adult; Thai style: Feminine (ค่ะ/คะ).");
    expect(markup).not.toContain("implementation is scheduled for G16.13 Phase B");
  });

  it("fails closed when the Phase B Runtime projection is unavailable", () => {
    const markup = renderToStaticMarkup(<ControlCenter page="ai-voice" runtime={{ ...runtime, schemaVersion: 2, controlCenter: { ...runtime.controlCenter!, ai: null, updates: null } }} setPage={() => undefined} />);
    expect(markup).toContain("Runtime AI &amp; Voice unavailable");
    expect(markup).not.toContain("Save key securely");
  });

  it("renders Runtime-owned signed update state and enables Apply only for a staged release", () => {
    const markup = renderToStaticMarkup(<ControlCenter page="updates" runtime={runtime} setPage={() => undefined} />);
    expect(markup).toContain("Keep OCP current—safely");
    expect(markup).toContain("A verified update is staged and ready to install.");
    expect(markup).toContain("Install and restart OCP");
    expect(markup).not.toContain("releaseUrl");
    expect(markup).not.toContain("artifactPath");
  });

  it("shows whole-system pressure separately from OCP and local-AI memory", () => {
    const markup = renderToStaticMarkup(<ControlCenter page="settings" runtime={runtime} setPage={() => undefined} />);
    expect(markup).toContain("System CPU");
    expect(markup).toContain("System memory");
    expect(markup).toContain("OCP total");
    expect(markup).toContain("642 MB");
    expect(markup).toContain("Desktop Shell");
    expect(markup).toContain("326 MB");
    expect(markup).toContain("Local AI (separate)");
    expect(markup).toContain("4.7 GB");
  });

  it("renders Control Center chrome in Thai when the active locale is Thai", () => {
    const markup = renderToStaticMarkup(<ControlCenter locale="th" page="settings" runtime={runtime} setPage={() => undefined} />);
    expect(markup).toContain("ศูนย์ควบคุม");
    expect(markup).toContain("ปรับ OCP ให้เป็นแบบของคุณ");
    expect(markup).toContain("การตั้งค่า");
    expect(markup).not.toContain("Make OCP feel like yours");
  });

  it("keeps cancellation side-effect free and fails closed without the Phase C projection", () => {
    expect(updateApplyCommandForDecision("cancel", true)).toBeNull();
    expect(updateApplyCommandForDecision("confirm", false)).toBeNull();
    expect(updateApplyCommandForDecision("confirm", true)).toEqual({ type: "control.update.apply" });
    const markup = renderToStaticMarkup(<ControlCenter page="updates" runtime={{ ...runtime, schemaVersion: 3, controlCenter: { ...runtime.controlCenter!, updates: null } }} setPage={() => undefined} />);
    expect(markup).toContain("Runtime Updates unavailable");
    expect(markup).not.toContain("Install and restart OCP");
  });
});
