import type { RuntimeBridgeCommand, RuntimeCommandResult, RuntimeSnapshot } from "../../electron/runtime-bridge";
import type { OnboardingCompletionReason, OnboardingState } from "../../electron/onboarding-state";
import type { AIControlSettings, ControlLanguage } from "./control-center";

export const BUILTIN_CHARACTER_ID = "character.bible" as const;
export const STARTER_CHARACTER_ID = "character.sabai-sompoo" as const;
export const STARTER_CHARACTER_VERSION = "1.0.1" as const;

export function shouldShowFirstRunWizard(onboarding: OnboardingState | null, runtime: RuntimeSnapshot | null): boolean {
  // Once a clean-profile onboarding session has started, installing the starter
  // character must not make the Wizard disappear. Existing libraries are
  // migrated only from the initial bootstrap snapshot in App.tsx.
  return Boolean(onboarding && !onboarding.completed && runtime);
}

export function shouldMigrateExistingLibrary(onboarding: OnboardingState | null, runtime: RuntimeSnapshot | null): boolean {
  return Boolean(
    onboarding
    && !onboarding.completed
    && runtime
    && runtime.characters.some((character) => character.packageId !== BUILTIN_CHARACTER_ID),
  );
}

export function starterCharacterInstalled(runtime: RuntimeSnapshot | null): boolean {
  return Boolean(runtime?.characters.some((character) => character.packageId === STARTER_CHARACTER_ID));
}

export function starterCharacterThumbnailSource(runtime: RuntimeSnapshot | null): string {
  const character = runtime?.characters.find((candidate) => candidate.packageId === STARTER_CHARACTER_ID);
  return character?.thumbnailPngBase64 ? `data:image/png;base64,${character.thumbnailPngBase64}` : "";
}

export function starterCharacterInstallCommand(runtime: RuntimeSnapshot | null): Extract<RuntimeBridgeCommand, { type: "cloud.library.install" }> | null {
  if (!runtime?.account?.signedIn || starterCharacterInstalled(runtime)) return null;
  const download = runtime.cloud?.download;
  if (download?.packageId === STARTER_CHARACTER_ID && ["authorizing", "downloading"].includes(download.status)) return null;
  return { type: "cloud.library.install", packageId: STARTER_CHARACTER_ID, version: STARTER_CHARACTER_VERSION };
}

export function firstRunCompletionCommands(
  runtime: RuntimeSnapshot,
  language: ControlLanguage,
  startWithWindows: boolean,
  aiSettings: AIControlSettings | null,
  reason: OnboardingCompletionReason,
): RuntimeBridgeCommand[] {
  if (reason === "skipped") return [];
  const commands: RuntimeBridgeCommand[] = [];
  const settings = runtime.controlCenter?.settings;
  if (settings) commands.push({ type: "control.settings.update", settings: { ...settings, language, startWithWindows } });
  if (aiSettings) commands.push({ type: "control.ai.update", settings: aiSettings });
  return commands;
}

export type FirstRunCommandResolution = Readonly<{
  status: "pending" | "failed" | "succeeded";
  errorCode: string;
}>;

export function resolveFirstRunCommandResults(ids: readonly string[], results: readonly RuntimeCommandResult[]): FirstRunCommandResolution {
  if (ids.length === 0) return { status: "succeeded", errorCode: "" };
  const matches = ids.map((id) => results.find((candidate) => candidate.id === id));
  if (matches.some((result) => !result)) return { status: "pending", errorCode: "" };
  const failure = matches.find((result) => result?.status === "failed");
  if (failure) return { status: "failed", errorCode: failure.errorCode || "runtime-error" };
  if (matches.some((result) => result?.status !== "succeeded")) return { status: "pending", errorCode: "" };
  return { status: "succeeded", errorCode: "" };
}

export function resolveFirstRunProbeResult(id: string, results: readonly RuntimeCommandResult[]): FirstRunCommandResolution {
  return resolveFirstRunCommandResults([id], results);
}

export type FirstRunModelDiscoveryResolution = FirstRunCommandResolution & Readonly<{ models: readonly string[] }>;

export function resolveFirstRunModelDiscovery(id: string, results: readonly RuntimeCommandResult[]): FirstRunModelDiscoveryResolution {
  const result = results.find((candidate) => candidate.id === id && candidate.type === "control.ai.discover");
  if (!result || result.status === "accepted") return { status: "pending", errorCode: "", models: [] };
  if (result.status === "failed") return { status: "failed", errorCode: result.errorCode || "model-discovery-failed", models: [] };
  return { status: "succeeded", errorCode: "", models: result.models ?? [] };
}
