import { contextBridge, ipcRenderer } from "electron";
import type { ShellAppearance } from "../src/contracts/appearance";
import type { ShellIntent, ShellView } from "../src/contracts/shell-intent";
import type { StoreDeepLink } from "../src/contracts/store-deep-link";
import type { RuntimeBridgeCommand, RuntimeSnapshot } from "./runtime-bridge";
import type { CredentialProviderId, CredentialStoreResult } from "./credential-broker";
import type { OnboardingCompletionReason, OnboardingState } from "./onboarding-state";

export type ShellBootstrap = Readonly<{ intent: ShellIntent; platform: NodeJS.Platform; runtimeBridge: "connected" | "unavailable"; appearance: ShellAppearance; storeUrl: string | null; storeLink: StoreDeepLink | null; onboarding: OnboardingState }>;
export type LocalCharacterInstallResult =
  | Readonly<{ status: "cancelled" }>
  | Readonly<{ status: "submitted"; requestId: string; fileName: string }>
  | Readonly<{ status: "failed"; errorCode: "invalid-window" | "runtime-unavailable" | "invalid-package-path" }>;
export type LocalEffectInstallResult = LocalCharacterInstallResult;
const shellApi = Object.freeze({
  getBootstrap: (): Promise<ShellBootstrap> => ipcRenderer.invoke("ocp:get-bootstrap") as Promise<ShellBootstrap>,
  completeOnboarding: (reason: OnboardingCompletionReason): Promise<OnboardingState> => ipcRenderer.invoke("ocp:complete-onboarding", reason) as Promise<OnboardingState>,
  openView: (view: ShellView): Promise<void> => ipcRenderer.invoke("ocp:open-view", view) as Promise<void>,
  openAnimationStudio: (): Promise<void> => ipcRenderer.invoke("ocp:open-animation-studio") as Promise<void>,
  openStore: (): Promise<void> => ipcRenderer.invoke("ocp:open-store") as Promise<void>,
  confirmCharacterUninstall: (name: string, active: boolean, locale: "en" | "th"): Promise<boolean> => ipcRenderer.invoke("ocp:confirm-character-uninstall", { name, active, locale }) as Promise<boolean>,
  openAccount: (connectDesktop = false): Promise<void> => ipcRenderer.invoke("ocp:open-account", connectDesktop) as Promise<void>,
  openGeminiApiKeys: (): Promise<void> => ipcRenderer.invoke("ocp:open-gemini-api-keys") as Promise<void>,
  installLocalCharacter: (): Promise<LocalCharacterInstallResult> => ipcRenderer.invoke("ocp:install-local-character") as Promise<LocalCharacterInstallResult>,
  installLocalEffect: (): Promise<LocalEffectInstallResult> => ipcRenderer.invoke("ocp:install-local-effect") as Promise<LocalEffectInstallResult>,
  saveAppearance: (appearance: ShellAppearance): Promise<ShellAppearance> => ipcRenderer.invoke("ocp:set-appearance", appearance) as Promise<ShellAppearance>,
  getRuntimeState: (): Promise<RuntimeSnapshot | null> => ipcRenderer.invoke("ocp:get-runtime-state") as Promise<RuntimeSnapshot | null>,
  sendRuntimeCommand: (command: RuntimeBridgeCommand): Promise<string> => ipcRenderer.invoke("ocp:runtime-command", command) as Promise<string>,
  storeProviderCredential: (providerId: CredentialProviderId, credential: string): Promise<CredentialStoreResult> => ipcRenderer.invoke("ocp:store-provider-credential", { providerId, credential }) as Promise<CredentialStoreResult>,
  onIntent: (listener: (intent: ShellIntent) => void): (() => void) => { const handler = (_event: Electron.IpcRendererEvent, intent: ShellIntent): void => listener(intent); ipcRenderer.on("ocp:shell-intent", handler); return () => ipcRenderer.removeListener("ocp:shell-intent", handler); },
  onStoreLink: (listener: (link: StoreDeepLink) => void): (() => void) => { const handler = (_event: Electron.IpcRendererEvent, link: StoreDeepLink): void => listener(link); ipcRenderer.on("ocp:store-link", handler); return () => ipcRenderer.removeListener("ocp:store-link", handler); },
  onAppearance: (listener: (appearance: ShellAppearance) => void): (() => void) => { const handler = (_event: Electron.IpcRendererEvent, next: ShellAppearance): void => listener(next); ipcRenderer.on("ocp:appearance-changed", handler); return () => ipcRenderer.removeListener("ocp:appearance-changed", handler); },
  onRuntimeState: (listener: (state: RuntimeSnapshot | null) => void): (() => void) => { const handler = (_event: Electron.IpcRendererEvent, next: RuntimeSnapshot | null): void => listener(next); ipcRenderer.on("ocp:runtime-state", handler); return () => ipcRenderer.removeListener("ocp:runtime-state", handler); },
});
contextBridge.exposeInMainWorld("ocpShell", shellApi);
