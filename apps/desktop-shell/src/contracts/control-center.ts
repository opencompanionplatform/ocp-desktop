import type { ShellView } from "./shell-intent";

export const controlCenterPages = ["settings", "ai-voice", "updates"] as const;
export const controlThemes = ["solid", "glass", "liquid"] as const;
export const controlFontFamilies = ["Noto Sans Thai", "Segoe UI", "Tahoma", "Leelawadee UI", "Arial", "Inter"] as const;
// Keep Inter in the accepted contract for existing settings and future signed
// Font Packs, but only expose fonts that are present on supported Windows
// installations today. Store-installed fonts will be appended from the Font
// Registry instead of pretending an unavailable family is built in.
export const controlSelectableFontFamilies = ["Noto Sans Thai", "Segoe UI", "Leelawadee UI", "Tahoma", "Arial"] as const;
export const controlTextScales = ["normal", "standard", "comfortable", "large", "extra"] as const;
export const controlBubbleStyles = ["Rounded", "Compact", "Soft"] as const;
export const controlLanguages = ["en", "th"] as const;
export const controlUpdateChannels = ["stable", "preview"] as const;
export const aiProviderIds = ["offline", "ollama", "openai-compatible"] as const;
export const aiTimeoutSeconds = [15, 30, 45, 60, 120] as const;
export const ttsProviderIds = ["auto", "system"] as const;
export const chatVoiceModes = ["off", "on-demand", "auto-speak", "live-voice"] as const;
export const ttsVoiceModes = ["character", "custom"] as const;
export const ttsVoiceGenders = ["female", "male", "neutral"] as const;
export const ttsVoiceAges = ["child", "adult"] as const;
export const thaiSpeechStyles = ["feminine", "masculine", "neutral"] as const;
export const DEFAULT_TTS_MODEL_ID = "gemini-3.1-flash-tts-preview" as const;
export const ttsModelIds = [DEFAULT_TTS_MODEL_ID, "gemini-2.5-flash-preview-tts"] as const;
export const ttsVoiceIds = [
  "auto", "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe",
  "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib",
  "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
  "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat",
] as const;
export const updateStates = [
  "unavailable", "idle", "checking", "up-to-date", "ready", "apply-requested",
  "stopping", "validating", "swapping", "restarting", "applied", "rolled-back", "failed",
] as const;
export const updateMessages = Object.freeze({
  "update-unavailable": "Signed updates are unavailable in this Runtime.",
  "update-idle": "Ready to check the signed update channel.",
  "update-checking": "Runtime is checking and verifying the signed update manifest.",
  "update-current": "OCP is up to date.",
  "update-ready": "A verified update is staged and ready to install.",
  "update-apply-requested": "Runtime accepted the install request and is preparing to restart.",
  "update-stopping": "Waiting for OCP processes to stop safely.",
  "update-validating": "Validating the staged update bundle.",
  "update-swapping": "Switching the per-user installation transactionally.",
  "update-restarting": "Restarting OCP and waiting for the health check.",
  "update-applied": "The update was applied and passed its startup health check.",
  "update-rolled-back": "The update failed and the previous version was restored.",
  "update-config-incomplete": "Signed update configuration is incomplete.",
  "update-preview-config-incomplete": "Preview update configuration is incomplete.",
  "update-stable-trust-pending": "Stable updates stay locked until Production signing trust is ready.",
  "update-updater-missing": "The signed Runtime updater is not installed.",
  "update-check-start-failed": "Runtime could not start the signed update check.",
  "update-check-failed": "The signed update check failed.",
  "update-check-timeout": "The signed update check timed out.",
  "update-not-ready": "No verified staged update is available.",
  "update-apply-not-configured": "Update installation is not configured for this installation.",
  "update-helper-missing": "The update apply helper is not installed.",
  "update-apply-start-failed": "Runtime could not start the update apply helper.",
  "update-rollback-failed": "The update and automatic rollback both failed.",
  "update-failed": "The update was rejected and the installation was not changed.",
} as const);

export type ControlCenterPage = (typeof controlCenterPages)[number];
export type ControlTheme = (typeof controlThemes)[number];
export type ControlFontFamily = (typeof controlFontFamilies)[number];
export type ControlTextScale = (typeof controlTextScales)[number];
export type ControlBubbleStyle = (typeof controlBubbleStyles)[number];
export type ControlLanguage = (typeof controlLanguages)[number];
export type ControlUpdateChannel = (typeof controlUpdateChannels)[number];
export type AIProviderId = (typeof aiProviderIds)[number];
export type AITimeoutSeconds = (typeof aiTimeoutSeconds)[number];
export type TTSProviderId = (typeof ttsProviderIds)[number];
export type ChatVoiceMode = (typeof chatVoiceModes)[number];
export type TTSModelId = (typeof ttsModelIds)[number];
export type TTSVoiceId = (typeof ttsVoiceIds)[number];
export type TTSVoiceMode = (typeof ttsVoiceModes)[number];
export type TTSVoiceGender = (typeof ttsVoiceGenders)[number];
export type TTSVoiceAge = (typeof ttsVoiceAges)[number];
export type ThaiSpeechStyle = (typeof thaiSpeechStyles)[number];
export type UpdateState = (typeof updateStates)[number];
export type UpdateMessageCode = keyof typeof updateMessages;

export type ControlCenterSettings = Readonly<{
  themePreset: ControlTheme;
  fontFamily: ControlFontFamily;
  textScale: ControlTextScale;
  bubbleStyle: ControlBubbleStyle;
  language: ControlLanguage;
  showBubbles: boolean;
  clickThroughEnabled: boolean;
  startWithWindows: boolean;
  offlinePresenceEnabled: boolean;
  llmCompanionModeEnabled: boolean;
  updateChannel: ControlUpdateChannel;
  automaticUpdateChecks: boolean;
  reduceMotion: boolean;
}>;

export type ResourceSnapshot = Readonly<{
  available: boolean;
  /** Whole-machine CPU percentage, not OCP-only CPU. */
  cpuPercent: number;
  /** Whole-machine memory percentage, not OCP-only memory. */
  memoryPercent: number;
  ocpMemoryMb?: number;
  runtimeMemoryMb?: number;
  desktopShellMemoryMb?: number;
  kernelMemoryMb?: number;
  nativeHostMemoryMb?: number;
  /** Ollama/local-AI memory is deliberately outside the OCP total. */
  aiMemoryMb?: number;
  pressure: "normal" | "high" | "unavailable";
  sampledAtMs: number;
}>;

export type AIControlSettings = Readonly<{
  providerId: AIProviderId;
  baseUrl: string;
  model: string;
  timeoutSeconds: AITimeoutSeconds;
  ttsEnabled: boolean;
  chatVoiceMode: ChatVoiceMode;
  ttsProviderId: TTSProviderId;
  ttsModel: TTSModelId;
  ttsVoice: TTSVoiceId;
  ttsVoiceMode: TTSVoiceMode;
  ttsVoiceGender: TTSVoiceGender;
  ttsVoiceAge: TTSVoiceAge;
  thaiSpeechStyle: ThaiSpeechStyle;
}>;

export type SafeTestStatus = Readonly<{
  status: "idle" | "testing" | "succeeded" | "failed";
  errorCode: string;
}>;

export type AIControlSnapshot = Readonly<{
  settings: AIControlSettings;
  provider: Readonly<{
    providerId: AIProviderId;
    available: boolean;
    configured: boolean;
    reachable: boolean;
    test: SafeTestStatus;
  }>;
  credentials: Readonly<{
    brokerAvailable: boolean;
    openAiCompatiblePresent: boolean;
    geminiPresent: boolean;
  }>;
  voiceTest: SafeTestStatus;
}>;

export type UpdateControlSnapshot = Readonly<{
  currentVersion: string;
  channel: ControlUpdateChannel;
  state: UpdateState;
  messageCode: UpdateMessageCode;
  message: (typeof updateMessages)[UpdateMessageCode];
  targetVersion: string;
  canCheck: boolean;
  canApply: boolean;
  automaticChecksEnabled: boolean;
  nextAutomaticCheckSeconds: number;
  stableTrustReady: boolean;
  installOnRestart: boolean;
}>;

export type ControlCenterSnapshot = Readonly<{
  settings: ControlCenterSettings;
  resources: ResourceSnapshot;
  ai: AIControlSnapshot | null;
  updates: UpdateControlSnapshot | null;
}>;

const SETTINGS_RESULT_COPY: Readonly<Record<string, string>> = Object.freeze({
  "invalid-settings-command": "Runtime rejected the Settings request.",
  "invalid-settings": "One or more Settings values are invalid.",
  "settings-service-unavailable": "Runtime Settings service is unavailable.",
  "startup-registration-failed": "Start with Windows could not be changed; no Settings were saved.",
  "settings-save-failed": "Runtime could not persist Settings.",
  "adapter-unavailable": "The authenticated Runtime adapter is unavailable.",
  "runtime-timeout": "Runtime did not confirm the Settings request in time.",
});

const SETTINGS_KEYS = new Set([
  "themePreset", "fontFamily", "textScale", "bubbleStyle", "language", "showBubbles",
  "clickThroughEnabled", "startWithWindows", "offlinePresenceEnabled", "llmCompanionModeEnabled", "updateChannel", "automaticUpdateChecks", "reduceMotion",
]);
const RESOURCE_KEYS = new Set([
  "available", "cpuPercent", "memoryPercent", "ocpMemoryMb", "runtimeMemoryMb",
  "desktopShellMemoryMb", "kernelMemoryMb", "nativeHostMemoryMb", "aiMemoryMb",
  "pressure", "sampledAtMs",
]);
const LEGACY_RESOURCE_KEYS = new Set(["available", "cpuPercent", "memoryPercent", "pressure", "sampledAtMs"]);
const AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "chatVoiceMode", "ttsProviderId", "ttsModel", "ttsVoice", "ttsVoiceMode", "ttsVoiceGender", "ttsVoiceAge", "thaiSpeechStyle"]);
const PRE_CHAT_VOICE_MODE_AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "ttsProviderId", "ttsModel", "ttsVoice", "ttsVoiceMode", "ttsVoiceGender", "ttsVoiceAge", "thaiSpeechStyle"]);
const CHAT_VOICE_MODE_LEGACY_MODEL_AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "chatVoiceMode", "ttsProviderId", "ttsVoice", "ttsVoiceMode", "ttsVoiceGender", "ttsVoiceAge", "thaiSpeechStyle"]);
const CHAT_VOICE_MODE_BASIC_AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "chatVoiceMode", "ttsProviderId", "ttsModel", "ttsVoice"]);
const PRIOR_AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "ttsProviderId", "ttsModel", "ttsVoice"]);
const LEGACY_AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "ttsProviderId", "ttsVoice"]);
const PROFILE_LEGACY_AI_SETTINGS_KEYS = new Set(["providerId", "baseUrl", "model", "timeoutSeconds", "ttsEnabled", "ttsProviderId", "ttsVoice", "ttsVoiceMode", "ttsVoiceGender", "ttsVoiceAge", "thaiSpeechStyle"]);
const TEST_STATUS_KEYS = new Set(["status", "errorCode"]);
const PROVIDER_STATUS_KEYS = new Set(["providerId", "available", "configured", "reachable", "test"]);
const CREDENTIAL_STATUS_KEYS = new Set(["brokerAvailable", "openAiCompatiblePresent", "geminiPresent"]);
const AI_CONTROL_KEYS = new Set(["settings", "provider", "credentials", "voiceTest"]);
const UPDATE_CONTROL_KEYS = new Set(["currentVersion", "channel", "state", "messageCode", "message", "targetVersion", "canCheck", "canApply", "automaticChecksEnabled", "nextAutomaticCheckSeconds", "stableTrustReady", "installOnRestart"]);
const CONTROL_CENTER_V2_KEYS = new Set(["settings", "resources"]);
const CONTROL_CENTER_V3_KEYS = new Set(["settings", "resources", "ai"]);
const CONTROL_CENTER_V4_KEYS = new Set(["settings", "resources", "ai", "updates"]);
const VERSION_PATTERN = /^[0-9][0-9A-Za-z.+-]{0,63}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: ReadonlySet<string>): boolean {
  return Object.keys(value).length === keys.size && Object.keys(value).every((key) => keys.has(key));
}

function boundedPercent(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100;
}

function boundedMemoryMb(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1_048_576;
}

function boundedSafeText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length <= maximum && ![...value].some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127);
}

export function controlPageForShellView(view: ShellView): ControlCenterPage | null {
  if (view === "updates") return "updates";
  return view === "home" || view === "settings" ? "settings" : null;
}

export function settingsResultMessage(status: "idle" | "saving" | "saved" | "failed", errorCode = "", dirty = false): string {
  if (status === "saved") return "Settings saved by Runtime.";
  if (status === "saving") return "Waiting for Runtime confirmation…";
  if (status === "failed") return SETTINGS_RESULT_COPY[errorCode] ?? "Runtime could not complete the Settings request.";
  return dirty ? "Unsaved changes" : "Settings are synchronized with Runtime.";
}

export function updateApplyCommandForDecision(decision: "confirm" | "cancel", canApply: boolean): Readonly<{ type: "control.update.apply" }> | null {
  return decision === "confirm" && canApply ? { type: "control.update.apply" } : null;
}

export function controlCenterSettingsSignature(settings: ControlCenterSettings | null): string {
  if (!settings) return "";
  return [
    settings.themePreset, settings.fontFamily, settings.textScale, settings.bubbleStyle, settings.language,
    settings.showBubbles, settings.clickThroughEnabled, settings.startWithWindows,
    settings.offlinePresenceEnabled, settings.llmCompanionModeEnabled, settings.updateChannel, settings.automaticUpdateChecks, settings.reduceMotion,
  ].join("\u001f");
}

export function aiControlSettingsSignature(settings: AIControlSettings | null): string {
  if (!settings) return "";
  return [settings.providerId, settings.baseUrl, settings.model, settings.timeoutSeconds, settings.ttsEnabled, settings.chatVoiceMode, settings.ttsProviderId, settings.ttsModel, settings.ttsVoice, settings.ttsVoiceMode, settings.ttsVoiceGender, settings.ttsVoiceAge, settings.thaiSpeechStyle].join("\u001f");
}

export function sanitizeControlCenterSettings(value: unknown): ControlCenterSettings | null {
  if (!isRecord(value) || !hasExactKeys(value, SETTINGS_KEYS)) return null;
  if (!controlThemes.includes(value.themePreset as ControlTheme)) return null;
  if (!controlFontFamilies.includes(value.fontFamily as ControlFontFamily)) return null;
  if (!controlTextScales.includes(value.textScale as ControlTextScale)) return null;
  if (!controlBubbleStyles.includes(value.bubbleStyle as ControlBubbleStyle)) return null;
  if (!controlLanguages.includes(value.language as ControlLanguage)) return null;
  if (!controlUpdateChannels.includes(value.updateChannel as ControlUpdateChannel)) return null;
  for (const key of ["showBubbles", "clickThroughEnabled", "startWithWindows", "offlinePresenceEnabled", "llmCompanionModeEnabled", "automaticUpdateChecks", "reduceMotion"] as const) {
    if (typeof value[key] !== "boolean") return null;
  }
  return value as ControlCenterSettings;
}

export function sanitizeResourceSnapshot(value: unknown): ResourceSnapshot | null {
  if (!isRecord(value)) return null;
  const current = hasExactKeys(value, RESOURCE_KEYS);
  const legacy = hasExactKeys(value, LEGACY_RESOURCE_KEYS);
  if (!current && !legacy) return null;
  if (typeof value.available !== "boolean" || !boundedPercent(value.cpuPercent) || !boundedPercent(value.memoryPercent)) return null;
  if (value.pressure !== "normal" && value.pressure !== "high" && value.pressure !== "unavailable") return null;
  if (typeof value.sampledAtMs !== "number" || !Number.isSafeInteger(value.sampledAtMs) || value.sampledAtMs < 0) return null;
  if (!value.available && (value.cpuPercent !== 0 || value.memoryPercent !== 0 || value.pressure !== "unavailable")) return null;
  if (value.available && value.pressure === "unavailable") return null;

  if (legacy) return value as ResourceSnapshot;

  for (const key of ["ocpMemoryMb", "runtimeMemoryMb", "desktopShellMemoryMb", "kernelMemoryMb", "nativeHostMemoryMb", "aiMemoryMb"] as const) {
    if (!boundedMemoryMb(value[key])) return null;
  }
  return value as ResourceSnapshot;
}

export function sanitizeAIControlSettings(value: unknown): AIControlSettings | null {
  if (!isRecord(value) || (!hasExactKeys(value, AI_SETTINGS_KEYS) && !hasExactKeys(value, PRE_CHAT_VOICE_MODE_AI_SETTINGS_KEYS) && !hasExactKeys(value, CHAT_VOICE_MODE_LEGACY_MODEL_AI_SETTINGS_KEYS) && !hasExactKeys(value, CHAT_VOICE_MODE_BASIC_AI_SETTINGS_KEYS) && !hasExactKeys(value, PRIOR_AI_SETTINGS_KEYS) && !hasExactKeys(value, LEGACY_AI_SETTINGS_KEYS) && !hasExactKeys(value, PROFILE_LEGACY_AI_SETTINGS_KEYS))) return null;
  if (!aiProviderIds.includes(value.providerId as AIProviderId) || !boundedSafeText(value.baseUrl, 2_048) || !boundedSafeText(value.model, 160)) return null;
  if (!aiTimeoutSeconds.includes(value.timeoutSeconds as AITimeoutSeconds) || typeof value.ttsEnabled !== "boolean") return null;
  const ttsModel = value.ttsModel === undefined ? DEFAULT_TTS_MODEL_ID : value.ttsModel;
  const chatVoiceMode = value.chatVoiceMode ?? "on-demand";
  if (!chatVoiceModes.includes(chatVoiceMode as ChatVoiceMode) || !ttsProviderIds.includes(value.ttsProviderId as TTSProviderId) || !ttsModelIds.includes(ttsModel as TTSModelId) || !ttsVoiceIds.includes(value.ttsVoice as TTSVoiceId)) return null;
  const ttsVoiceMode = value.ttsVoiceMode ?? "character";
  const ttsVoiceGender = value.ttsVoiceGender ?? "neutral";
  const ttsVoiceAge = value.ttsVoiceAge ?? "adult";
  const thaiSpeechStyle = value.thaiSpeechStyle ?? "neutral";
  if (!ttsVoiceModes.includes(ttsVoiceMode as TTSVoiceMode) || !ttsVoiceGenders.includes(ttsVoiceGender as TTSVoiceGender) || !ttsVoiceAges.includes(ttsVoiceAge as TTSVoiceAge) || !thaiSpeechStyles.includes(thaiSpeechStyle as ThaiSpeechStyle)) return null;
  const providerId = value.providerId as AIProviderId;
  const baseUrl = value.baseUrl.trim();
  const model = value.model.trim();
  if (providerId !== "offline") {
    if (!baseUrl || !model) return null;
    let parsed: URL;
    try { parsed = new URL(baseUrl); } catch { return null; }
    if (parsed.username || parsed.password || parsed.hash) return null;
    if (providerId === "ollama" && parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    if (providerId === "openai-compatible" && parsed.protocol !== "https:") return null;
  }
  return {
    ...value,
    providerId,
    baseUrl,
    model,
    chatVoiceMode: chatVoiceMode as ChatVoiceMode,
    ttsModel: ttsModel as TTSModelId,
    ...(value.ttsVoiceMode === undefined ? {} : { ttsVoiceMode, ttsVoiceGender, ttsVoiceAge, thaiSpeechStyle }),
  } as AIControlSettings;
}

export type AIControlSettingsValidationError =
  | "invalid-ai-settings"
  | "provider-base-url-required"
  | "provider-model-required"
  | "provider-base-url-invalid";

/** Returns bounded, user-actionable validation copy without exposing input values. */
export function aiControlSettingsValidationError(value: unknown): AIControlSettingsValidationError | "" {
  if (isRecord(value) && aiProviderIds.includes(value.providerId as AIProviderId) && value.providerId !== "offline") {
    if (typeof value.baseUrl === "string" && !value.baseUrl.trim()) return "provider-base-url-required";
    if (typeof value.model === "string" && !value.model.trim()) return "provider-model-required";
    if (typeof value.baseUrl === "string" && value.baseUrl.trim()) {
      try {
        const parsed = new URL(value.baseUrl.trim());
        const validProtocol = value.providerId === "ollama"
          ? parsed.protocol === "http:" || parsed.protocol === "https:"
          : parsed.protocol === "https:";
        if (parsed.username || parsed.password || parsed.hash || !validProtocol) return "provider-base-url-invalid";
      } catch { return "provider-base-url-invalid"; }
    }
  }
  return sanitizeAIControlSettings(value) ? "" : "invalid-ai-settings";
}

function sanitizeTestStatus(value: unknown): SafeTestStatus | null {
  if (!isRecord(value) || !hasExactKeys(value, TEST_STATUS_KEYS)) return null;
  if (!["idle", "testing", "succeeded", "failed"].includes(String(value.status)) || !boundedSafeText(value.errorCode, 80)) return null;
  if ((value.status === "idle" || value.status === "testing" || value.status === "succeeded") && value.errorCode !== "") return null;
  return value as SafeTestStatus;
}

export function sanitizeAIControlSnapshot(value: unknown): AIControlSnapshot | null {
  if (!isRecord(value) || !hasExactKeys(value, AI_CONTROL_KEYS)) return null;
  const settings = sanitizeAIControlSettings(value.settings);
  if (!settings || !isRecord(value.provider) || !hasExactKeys(value.provider, PROVIDER_STATUS_KEYS)) return null;
  if (!aiProviderIds.includes(value.provider.providerId as AIProviderId)) return null;
  for (const key of ["available", "configured", "reachable"] as const) if (typeof value.provider[key] !== "boolean") return null;
  const providerTest = sanitizeTestStatus(value.provider.test);
  if (!providerTest || !isRecord(value.credentials) || !hasExactKeys(value.credentials, CREDENTIAL_STATUS_KEYS)) return null;
  for (const key of ["brokerAvailable", "openAiCompatiblePresent", "geminiPresent"] as const) if (typeof value.credentials[key] !== "boolean") return null;
  const voiceTest = sanitizeTestStatus(value.voiceTest);
  if (!voiceTest) return null;
  return {
    settings,
    provider: { providerId: value.provider.providerId as AIProviderId, available: value.provider.available as boolean, configured: value.provider.configured as boolean, reachable: value.provider.reachable as boolean, test: providerTest },
    credentials: value.credentials as AIControlSnapshot["credentials"],
    voiceTest,
  };
}

export function sanitizeUpdateControlSnapshot(value: unknown): UpdateControlSnapshot | null {
  if (!isRecord(value) || !hasExactKeys(value, UPDATE_CONTROL_KEYS)) return null;
  if (!VERSION_PATTERN.test(String(value.currentVersion)) || !controlUpdateChannels.includes(value.channel as ControlUpdateChannel)) return null;
  if (!updateStates.includes(value.state as UpdateState) || typeof value.messageCode !== "string" || !(value.messageCode in updateMessages)) return null;
  const messageCode = value.messageCode as UpdateMessageCode;
  if (value.message !== updateMessages[messageCode]) return null;
  if (typeof value.targetVersion !== "string" || (value.targetVersion !== "" && !VERSION_PATTERN.test(value.targetVersion))) return null;
  if (typeof value.canCheck !== "boolean" || typeof value.canApply !== "boolean" || typeof value.automaticChecksEnabled !== "boolean" || typeof value.stableTrustReady !== "boolean" || typeof value.installOnRestart !== "boolean") return null;
  if (typeof value.nextAutomaticCheckSeconds !== "number" || !Number.isSafeInteger(value.nextAutomaticCheckSeconds) || value.nextAutomaticCheckSeconds < 0) return null;
  if (value.canApply && (value.state !== "ready" || value.targetVersion === "")) return null;
  if (value.installOnRestart && !value.canApply) return null;
  if (["ready", "apply-requested", "stopping", "validating", "swapping", "restarting"].includes(String(value.state)) && value.targetVersion === "") return null;
  return value as UpdateControlSnapshot;
}

export function sanitizeControlCenterSnapshot(value: unknown, schemaVersion: 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 = 2): ControlCenterSnapshot | null {
  const keys = schemaVersion >= 4 ? CONTROL_CENTER_V4_KEYS : schemaVersion === 3 ? CONTROL_CENTER_V3_KEYS : CONTROL_CENTER_V2_KEYS;
  if (!isRecord(value) || !hasExactKeys(value, keys)) return null;
  const settings = sanitizeControlCenterSettings(value.settings);
  const resources = sanitizeResourceSnapshot(value.resources);
  const ai = schemaVersion >= 3 ? sanitizeAIControlSnapshot(value.ai) : null;
  const updates = schemaVersion >= 4 ? sanitizeUpdateControlSnapshot(value.updates) : null;
  return settings && resources && (schemaVersion < 3 || ai) && (schemaVersion < 4 || updates) ? { settings, resources, ai, updates } : null;
}
