import { describe, expect, it } from "vitest";

import type { RuntimeSnapshot } from "../../electron/runtime-bridge";
import { DEFAULT_ONBOARDING_STATE, completeOnboarding } from "../../electron/onboarding-state";
import {
  firstRunCompletionCommands,
  resolveFirstRunCommandResults,
  resolveFirstRunModelDiscovery,
  resolveFirstRunProbeResult,
  shouldMigrateExistingLibrary,
  shouldShowFirstRunWizard,
  BUILTIN_CHARACTER_ID,
  STARTER_CHARACTER_ID,
  STARTER_CHARACTER_VERSION,
  starterCharacterInstallCommand,
  starterCharacterInstalled,
  starterCharacterThumbnailSource,
} from "./first-run";

const runtime = (characters: Array<{ packageId: string }>) => ({ characters } as unknown as Parameters<typeof shouldShowFirstRunWizard>[1]);

const firstRunRuntime = (overrides: Partial<RuntimeSnapshot> = {}): RuntimeSnapshot => ({
  characters: [],
  commandResults: [],
  account: { signedIn: true },
  cloud: null,
  controlCenter: {
    settings: {
      themePreset: "solid",
      fontFamily: "Inter",
      textScale: "standard",
      bubbleStyle: "Rounded",
      language: "en",
      showBubbles: true,
      clickThroughEnabled: true,
      startWithWindows: false,
      offlinePresenceEnabled: true,
      llmCompanionModeEnabled: false,
      updateChannel: "stable",
      reduceMotion: false,
    },
    resources: null,
    ai: null,
    updates: null,
  },
  ...overrides,
} as unknown as RuntimeSnapshot);

describe("first run policy", () => {
  it("keeps an active incomplete onboarding session visible after the starter character is installed", () => {
    expect(shouldShowFirstRunWizard(DEFAULT_ONBOARDING_STATE, runtime([]))).toBe(true);
    expect(shouldShowFirstRunWizard(DEFAULT_ONBOARDING_STATE, runtime([{ packageId: STARTER_CHARACTER_ID }]))).toBe(true);
    expect(shouldShowFirstRunWizard(DEFAULT_ONBOARDING_STATE, null)).toBe(false);
    expect(shouldShowFirstRunWizard(completeOnboarding("completed"), runtime([]))).toBe(false);
  });

  it("silently migrates existing user libraries but does not treat built-in Bible as prior onboarding", () => {
    expect(shouldMigrateExistingLibrary(DEFAULT_ONBOARDING_STATE, runtime([{ packageId: "character.meowsom" }]))).toBe(true);
    expect(shouldMigrateExistingLibrary(DEFAULT_ONBOARDING_STATE, runtime([{ packageId: BUILTIN_CHARACTER_ID }]))).toBe(false);
    expect(shouldMigrateExistingLibrary(DEFAULT_ONBOARDING_STATE, runtime([
      { packageId: BUILTIN_CHARACTER_ID },
      { packageId: "character.meowsom" },
    ]))).toBe(true);
    expect(shouldMigrateExistingLibrary(DEFAULT_ONBOARDING_STATE, runtime([]))).toBe(false);
  });

  it("recognizes Sabai as installed independent of version", () => {
    expect(starterCharacterInstalled(runtime([{ packageId: STARTER_CHARACTER_ID }]))).toBe(true);
    expect(starterCharacterInstalled(runtime([{ packageId: "character.meowsom" }]))).toBe(false);
  });

  it("uses only the verified local Sabai thumbnail payload for Wizard artwork", () => {
    const withThumbnail = { characters: [{ packageId: STARTER_CHARACTER_ID, thumbnailPngBase64: "QUJD" }] } as unknown as RuntimeSnapshot;
    expect(starterCharacterThumbnailSource(withThumbnail)).toBe("data:image/png;base64,QUJD");
    expect(starterCharacterThumbnailSource(runtime([]))).toBe("");
  });

  it("issues exactly the signed starter package command only when the account is ready", () => {
    expect(starterCharacterInstallCommand(firstRunRuntime())).toEqual({
      type: "cloud.library.install",
      packageId: STARTER_CHARACTER_ID,
      version: STARTER_CHARACTER_VERSION,
    });
    expect(starterCharacterInstallCommand(firstRunRuntime({ account: { signedIn: false } } as unknown as Partial<RuntimeSnapshot>))).toBeNull();
    expect(starterCharacterInstallCommand(firstRunRuntime({ characters: [{ packageId: STARTER_CHARACTER_ID }] } as unknown as Partial<RuntimeSnapshot>))).toBeNull();
    expect(starterCharacterInstallCommand(firstRunRuntime({
      cloud: { download: { packageId: STARTER_CHARACTER_ID, version: STARTER_CHARACTER_VERSION, status: "downloading" } },
    } as unknown as Partial<RuntimeSnapshot>))).toBeNull();
  });

  it("keeps Skip side-effect free and builds deterministic Finish commands", () => {
    const state = firstRunRuntime();
    expect(firstRunCompletionCommands(state, "th", true, null, "skipped")).toEqual([]);
    expect(firstRunCompletionCommands(state, "th", true, null, "completed")).toEqual([
      {
        type: "control.settings.update",
        settings: { ...state.controlCenter!.settings, language: "th", startWithWindows: true },
      },
    ]);
  });

  it("does not complete onboarding until every Runtime write reports succeeded", () => {
    const ids = ["settings-1", "ai-1"];
    expect(resolveFirstRunCommandResults(ids, [])).toEqual({ status: "pending", errorCode: "" });
    expect(resolveFirstRunCommandResults(ids, [
      { id: "settings-1", type: "control.settings.update", status: "succeeded", errorCode: "" },
      { id: "ai-1", type: "control.ai.update", status: "accepted", errorCode: "" },
    ])).toEqual({ status: "pending", errorCode: "" });
    expect(resolveFirstRunCommandResults(ids, [
      { id: "settings-1", type: "control.settings.update", status: "succeeded", errorCode: "" },
      { id: "ai-1", type: "control.ai.update", status: "failed", errorCode: "credential-required" },
    ])).toEqual({ status: "failed", errorCode: "credential-required" });
    expect(resolveFirstRunCommandResults(ids, [
      { id: "settings-1", type: "control.settings.update", status: "succeeded", errorCode: "" },
      { id: "ai-1", type: "control.ai.update", status: "succeeded", errorCode: "" },
    ])).toEqual({ status: "succeeded", errorCode: "" });
  });

  it("reports the actual Runtime result for AI and voice probes instead of treating submission as success", () => {
    expect(resolveFirstRunProbeResult("probe-1", [])).toEqual({ status: "pending", errorCode: "" });
    expect(resolveFirstRunProbeResult("probe-1", [
      { id: "probe-1", type: "control.ai.test", status: "accepted", errorCode: "" },
    ])).toEqual({ status: "pending", errorCode: "" });
    expect(resolveFirstRunProbeResult("probe-1", [
      { id: "probe-1", type: "control.ai.test", status: "failed", errorCode: "provider-unreachable" },
    ])).toEqual({ status: "failed", errorCode: "provider-unreachable" });
    expect(resolveFirstRunProbeResult("probe-1", [
      { id: "probe-1", type: "control.voice.test", status: "succeeded", errorCode: "" },
    ])).toEqual({ status: "succeeded", errorCode: "" });
  });

  it("returns only the correlated Ollama model-discovery result", () => {
    expect(resolveFirstRunModelDiscovery("discover-1", [])).toEqual({ status: "pending", errorCode: "", models: [] });
    expect(resolveFirstRunModelDiscovery("discover-1", [
      { id: "discover-1", type: "control.ai.discover", status: "accepted", errorCode: "" },
    ])).toEqual({ status: "pending", errorCode: "", models: [] });
    expect(resolveFirstRunModelDiscovery("discover-1", [
      { id: "discover-1", type: "control.ai.discover", status: "succeeded", errorCode: "", models: ["qwen3.5:latest", "gemma3:4b"] },
    ])).toEqual({ status: "succeeded", errorCode: "", models: ["qwen3.5:latest", "gemma3:4b"] });
    expect(resolveFirstRunModelDiscovery("discover-1", [
      { id: "discover-1", type: "control.ai.discover", status: "failed", errorCode: "model-discovery-timeout", models: [] },
    ])).toEqual({ status: "failed", errorCode: "model-discovery-timeout", models: [] });
  });
});
