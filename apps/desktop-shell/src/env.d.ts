/// <reference types="vite/client" />

import type { LocalCharacterInstallResult, LocalEffectInstallResult, ShellBootstrap } from "../electron/preload";
import type { ShellAppearance } from "./contracts/appearance";
import type { ShellIntent, ShellView } from "./contracts/shell-intent";
import type { StoreDeepLink } from "./contracts/store-deep-link";
import type { RuntimeBridgeCommand, RuntimeSnapshot } from "../electron/runtime-bridge";
import type { CredentialProviderId, CredentialStoreResult } from "../electron/credential-broker";
import type { OnboardingCompletionReason, OnboardingState } from "../electron/onboarding-state";

declare global {
  interface Window {
    ocpShell: Readonly<{
      getBootstrap: () => Promise<ShellBootstrap>;
      completeOnboarding: (reason: OnboardingCompletionReason) => Promise<OnboardingState>;
      openView: (view: ShellView) => Promise<void>;
      openAnimationStudio: () => Promise<void>;
      openStore: () => Promise<void>;
      confirmCharacterUninstall: (name: string, active: boolean, locale: "en" | "th") => Promise<boolean>;
      openAccount: (connectDesktop?: boolean) => Promise<void>;
      openGeminiApiKeys: () => Promise<void>;
      installLocalCharacter: () => Promise<LocalCharacterInstallResult>;
      installLocalEffect: () => Promise<LocalEffectInstallResult>;
      saveAppearance: (appearance: ShellAppearance) => Promise<ShellAppearance>;
      getRuntimeState: () => Promise<RuntimeSnapshot | null>;
      sendRuntimeCommand: (command: RuntimeBridgeCommand) => Promise<string>;
      storeProviderCredential: (providerId: CredentialProviderId, credential: string) => Promise<CredentialStoreResult>;
      onIntent: (listener: (intent: ShellIntent) => void) => () => void;
      onStoreLink: (listener: (link: StoreDeepLink) => void) => () => void;
      onAppearance: (listener: (appearance: ShellAppearance) => void) => () => void;
      onRuntimeState: (listener: (state: RuntimeSnapshot | null) => void) => () => void;
    }>;
  }
}

export {};
