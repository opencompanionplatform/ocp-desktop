import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";

import { sanitizeShellAppearance, type ShellAppearance } from "../src/contracts/appearance";
import { sanitizeAIControlSettings, sanitizeControlCenterSettings, sanitizeControlCenterSnapshot, type AIControlSettings, type ControlCenterSettings, type ControlCenterSnapshot } from "../src/contracts/control-center";

const TOKEN_PATTERN = /^[a-f0-9]{64}$/;
const PACKAGE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/i;
const VERSION_PATTERN = /^[0-9][0-9A-Za-z.+-]{0,63}$/;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const INSTALL_GRANT_PATTERN = /^[A-Za-z0-9_-]{43,128}$/;
const AUTH_GRANT_PATTERN = /^[A-Za-z0-9_-]{32,256}$/;
const MAX_PROMPT_LENGTH = 4_000;
const MAX_PREVIEW_FRAME_BASE64_LENGTH = 262_144;
const MAX_PREVIEW_SHORTCUT_THUMBNAILS = 7;
const MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH = 65_536;
const PREVIEW_MEDIA_SCHEMA_VERSION = 1;
const PREVIEW_SPEEDS = [0.5, 1, 1.5, 2] as const;
// Runtime writes a heartbeat to state.json once per second while it is alive.
// Character preview generation can briefly stall the Godot main thread, so the
// lease must tolerate several missed heartbeats without flapping the Electron
// shell between connected/unavailable. An explicit `status: unavailable`
// marker still disconnects immediately during a clean Runtime shutdown.
export const MAX_RUNTIME_SNAPSHOT_AGE_MS = 10_000;
// Command delivery is stricter than UI continuity. A stale last-good snapshot
// may keep windows visually connected for a few seconds, but Store/install
// commands must only target a Runtime heartbeat that is currently fresh.
export const MAX_RUNTIME_COMMAND_SNAPSHOT_AGE_MS = 3_000;
const COMMAND_TYPES = new Set([
  "settings.update", "control.settings.update", "control.ai.update", "control.ai.test", "control.ai.discover", "control.voice.test", "character.activate", "character.uninstall", "character.effects.update", "character.effects.preview-level-up", "effect-pack.equip", "effect-pack.unequip", "effect-pack.slot-enabled", "effect-pack.preview", "effect-pack.preview-tune", "effect-pack.character-profile.save", "effect-pack.character-profile.reset", "effect-pack.preview-rank", "character.preview.open", "character.preview.select", "character.preview.thumbnail-page",
  "control.update.check", "control.update.apply", "control.update.install-on-restart",
  "character.preview.play", "character.preview.pause", "character.preview.set-loop",
  "character.preview.set-speed", "character.preview.close", "chat.submit", "chat.reconnect", "chat.session.clear",
  "chat.turn.cancel", "chat.message.edit", "chat.message.regenerate", "chat.feedback.set", "chat.message.read-aloud", "chat.session.new", "account.sign-out",
  "cloud.library.refresh", "cloud.library.install", "cloud.sync.now",
]);

export type RuntimeBridgeLaunch = Readonly<{ directory: string; token: string }>;
export type RuntimeNetworkTransferRequest = Readonly<{ id: string; url: string; outputPath: string; claimPath: string }>;
export type RuntimeNetworkTransferResult = Readonly<{ status: "succeeded" | "failed"; bytes?: number; error?: string }>;
export type RuntimeBridgeCommand =
  | Readonly<{ type: "settings.update"; appearance: ShellAppearance }>
  | Readonly<{ type: "control.settings.update"; settings: ControlCenterSettings }>
  | Readonly<{ type: "control.ai.update" | "control.ai.test" | "control.ai.discover" | "control.voice.test"; settings: AIControlSettings }>
  | Readonly<{ type: "control.update.check" | "control.update.apply" }>
  | Readonly<{ type: "control.update.install-on-restart"; enabled: boolean }>
  | Readonly<{ type: "character.activate" | "character.uninstall" | "character.effects.preview-level-up" | "character.preview.open" | "character.preview.play" | "character.preview.pause" | "character.preview.close"; packageId: string; version: string }>
  | Readonly<{ type: "character.effects.update"; levelUpEnabled: boolean; auraEnabled: boolean }>
  | Readonly<{ type: "effect-pack.equip"; packageId: string; version: string; slot: "" | "bodyAura" | "groundRune" | "levelUpBurst" }>
  | Readonly<{ type: "effect-pack.unequip"; slot: "bodyAura" | "groundRune" | "levelUpBurst" }>
  | Readonly<{ type: "effect-pack.slot-enabled"; slot: "bodyAura" | "groundRune" | "levelUpBurst"; enabled: boolean }>
  | Readonly<{ type: "effect-pack.preview"; mode: "all" | "bodyAura" | "groundRune" | "levelUpBurst" | "off"; variant?: "equipped" | "video-original" | "video-blend" | "starter-mist" }>
  | Readonly<{ type: "effect-pack.preview-tune"; slot: "bodyAura" | "groundRune" | "levelUpBurst"; tuning: Readonly<{ fps: number; startFrame: number; endFrame: number; scale: number; offsetX: number; offsetY: number; anchor: "character-center" | "character-feet" | "character-feet-bottom" | "character-above-head"; scaleMode: "character-width" | "character-height" | "native-surface" }> }>
  | Readonly<{ type: "effect-pack.character-profile.save"; characterId: string; slot: "bodyAura" | "groundRune" | "levelUpBurst"; tuning: Readonly<{ fps: number; startFrame: number; endFrame: number; scale: number; offsetX: number; offsetY: number; anchor: "character-center" | "character-feet" | "character-feet-bottom" | "character-above-head"; scaleMode: "character-width" | "character-height" | "native-surface" }> }>
  | Readonly<{ type: "effect-pack.character-profile.reset"; characterId: string; slot: "bodyAura" | "groundRune" | "levelUpBurst" }>
  | Readonly<{ type: "effect-pack.preview-rank"; rank: "" | "stranger" | "friend" | "close-friend" | "partner" | "best-companion" }>
  | Readonly<{ type: "character.preview.select"; packageId: string; version: string; animation: string }>
  | Readonly<{ type: "character.preview.thumbnail-page"; packageId: string; version: string; offset: number }>
  | Readonly<{ type: "character.preview.set-loop"; packageId: string; version: string; enabled: boolean }>
  | Readonly<{ type: "character.preview.set-speed"; packageId: string; version: string; speed: (typeof PREVIEW_SPEEDS)[number] }>
  | Readonly<{ type: "chat.submit"; prompt: string }>
  | Readonly<{ type: "chat.message.edit"; messageId: string; prompt: string; expectedRevision: number }>
  | Readonly<{ type: "chat.feedback.set"; messageId: string; feedback: "none" | "positive" | "negative"; expectedRevision: number }>
  | Readonly<{ type: "chat.message.regenerate" | "chat.message.read-aloud"; messageId: string; expectedRevision: number }>
  | Readonly<{ type: "chat.turn.cancel" | "chat.session.new"; expectedRevision: number }>
  | Readonly<{ type: "chat.reconnect" | "chat.session.clear" }>
  | Readonly<{ type: "account.sign-out" | "cloud.library.refresh" | "cloud.sync.now" }>
  | Readonly<{ type: "cloud.library.install"; packageId: string; version: string }>;
export type RuntimeSystemCommand =
  | Readonly<{ type: "store.install-handoff"; packageId: string; version: string; grant: string }>
  | Readonly<{ type: "account.auth-handoff"; grant: string }>
  | Readonly<{ type: "local.install-package" | "local.install-effect"; path: string }>
  | Readonly<{ type: "shell.chat-focus" | "shell.chat-visibility"; active: boolean }>
  | Readonly<{ type: "shell.companion-suppression"; active: boolean }>;
export type RuntimeBridgeMessage = Readonly<{ id: string; token: string; command: RuntimeBridgeCommand | RuntimeSystemCommand }>;
export type RuntimeCharacter = Readonly<{
  packageId: string;
  version: string;
  name: string;
  active: boolean;
  animations: readonly string[];
  thumbnailPngBase64?: string;
  thumbnailWidth?: number;
  thumbnailHeight?: number;
}>;

export type RuntimeProgressionSkill = Readonly<{
  skillId: string;
  level: number;
  xp: number;
}>;

export type RuntimeProgressionCompanion = Readonly<{
  companionId: string;
  characterId: string;
  relationship: Readonly<{ level: number; xp: number; bondRank?: string; currentLevelXp?: number; nextLevelXp?: number | null; progressPermille?: number }>;
  skills: readonly RuntimeProgressionSkill[];
}>;

export type RuntimeProgression = Readonly<{
  revision: number;
  levelCap?: number;
  companions: readonly RuntimeProgressionCompanion[];
  effects?: Readonly<{ levelUpEnabled: boolean; auraEnabled: boolean }>;
}>;
export type RuntimeEffectSlotName = "bodyAura" | "groundRune" | "levelUpBurst";
export type RuntimeEffectPackInstalled = Readonly<{
  packageId: string;
  version: string;
  name: string;
  slots: readonly RuntimeEffectSlotName[];
  progression: unknown | null;
}>;
export type RuntimeEffectPackResolved = Readonly<{
  packageId: string;
  version: string;
  name: string;
  slot: RuntimeEffectSlotName;
  config: Readonly<Record<string, unknown>>;
}>;
export type RuntimeEffectPacks = Readonly<{
  installed: readonly RuntimeEffectPackInstalled[];
  loadout: Readonly<Partial<Record<RuntimeEffectSlotName, Readonly<{ packageId: string; version: string }>>>>;
  enabled: Readonly<Record<RuntimeEffectSlotName, boolean>>;
  resolved: Readonly<Partial<Record<RuntimeEffectSlotName, RuntimeEffectPackResolved>>>;
  previewRank: "" | "stranger" | "friend" | "close-friend" | "partner" | "best-companion";
}>;

export type RuntimeChatMessage = Readonly<{ id: string; role: "user" | "assistant"; text: string; status: "complete" | "streaming" | "failed"; feedback?: "none" | "positive" | "negative" }>;
export type RuntimePreview = Readonly<{
  status: "idle" | "loading" | "ready" | "playing" | "paused" | "failed";
  errorCode: string;
  packageId: string;
  version: string;
  clips: readonly string[];
  selectedAnimation: string;
  isPlaying: boolean;
  loop: boolean;
  speed: (typeof PREVIEW_SPEEDS)[number];
  clipThumbnailPngBase64?: Readonly<Record<string, string>>;
  framePngBase64: string;
  frameWidth: number;
  frameHeight: number;
}>;
export type RuntimeCommandResult = Readonly<{
  id: string;
  type: RuntimeBridgeCommand["type"];
  status: "accepted" | "succeeded" | "failed";
  errorCode: string;
  models?: readonly string[];
}>;
export type RuntimeVoiceHealth = Readonly<{
  status: "disabled" | "idle" | "synthesizing" | "playing" | "healthy" | "degraded" | "failed";
  reasonCode: "" | "provider-credential-required" | "local-voice-not-installed" | "dns-unreachable" | "provider-auth-failed" | "provider-quota-exceeded" | "provider-rate-limited" | "tts-unavailable" | "playback-failed" | "interrupted";
  lastSuccessAtMs: number;
  retryAtMs: number;
}>;
export type RuntimeChatPresentationState = "idle" | "think" | "talk";
export type RuntimeChatPresentation = Readonly<{
  owner: "chat" | "native";
  state: RuntimeChatPresentationState;
  sequence: number;
  turnId: string;
  messageId: string;
  speechId: string;
  reasonCode: "ready" | "turn-active" | "voice-synthesizing" | "voice-playing" | "voice-failed";
}>;
export type RuntimeAccount = Readonly<{
  signedIn: boolean;
  userId: string;
  email: string;
  deviceId: string;
}>;
export type RuntimeCloudLibraryItem = Readonly<{
  productId: string;
  productType: string;
  entitled: boolean;
  source: "free-install" | "grant" | "purchase";
  grantedAt: string;
  revokedAt: string;
  name: string;
  latestVersion: string;
  thumbnailUrl: string;
  availability: "free" | "entitlement-required" | "unknown";
}>;
export type RuntimeCloudState = Readonly<{
  library: Readonly<{
    status: "signed-out" | "idle" | "loading" | "synced" | "error" | "not-configured";
    items: readonly RuntimeCloudLibraryItem[];
  }>;
  sync: Readonly<{
    status: "signed-out" | "idle" | "syncing" | "synced" | "error" | "device-registration-required";
    deviceRegistered: boolean;
    progressionRevision: number;
  }>;
  download: Readonly<{
    status: "idle" | "authorizing" | "downloading" | "installed" | "error";
    packageId: string;
    version: string;
    trust?: Readonly<{
      mode: "none" | "local-beta" | "marketplace-release";
      sequence: number;
      trustedPublishers: number;
      revocationStale: boolean;
    }>;
  }>;
}>;
export type RuntimeSnapshot = Readonly<{
  schemaVersion: 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20;
  status: "connected" | "unavailable";
  appearance: ShellAppearance;
  characters: readonly RuntimeCharacter[];
  progression?: RuntimeProgression;
  effectPacks?: RuntimeEffectPacks;
  account?: RuntimeAccount;
  cloud?: RuntimeCloudState;
  chat: Readonly<{ providerId: string; status: "ready" | "thinking" | "offline" | "failed"; messages: readonly RuntimeChatMessage[]; presentationState?: RuntimeChatPresentationState; sessionId?: string; revision?: number; activeMessageId?: string; presentation?: RuntimeChatPresentation }>;
  preview: RuntimePreview;
  controlCenter: ControlCenterSnapshot | null;
  commandResults: readonly RuntimeCommandResult[];
  voice?: RuntimeVoiceHealth;
}>;

/** Keep large preview image payloads scoped to the Character window. Other
 * windows still receive the complete authoritative Runtime state, but do not
 * retain duplicate base64 frame/thumbnail strings they never render. */
export function projectRuntimeSnapshotForView(snapshot: RuntimeSnapshot | null, includePreviewMedia: boolean): RuntimeSnapshot | null {
  if (!snapshot || includePreviewMedia || (snapshot.preview.framePngBase64.length === 0 && Object.keys(snapshot.preview.clipThumbnailPngBase64 ?? {}).length === 0)) return snapshot;
  return {
    ...snapshot,
    preview: {
      ...snapshot.preview,
      clipThumbnailPngBase64: {},
      framePngBase64: "",
      frameWidth: 0,
      frameHeight: 0,
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}

function readArgument(args: readonly string[], name: string): string | undefined {
  const prefix = `--${name}=`;
  return args.find((argument) => argument.startsWith(prefix))?.slice(prefix.length);
}

function hasDisallowedControlCharacter(value: string): boolean {
  return [...value].some((character) => {
    const code = character.charCodeAt(0);
    return code < 32 && code !== 9 && code !== 10 && code !== 13;
  });
}

function validText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maximum && !hasDisallowedControlCharacter(value);
}

function validOptionalText(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length <= maximum && !hasDisallowedControlCharacter(value);
}

function validIdentity(value: Record<string, unknown>): value is Record<string, unknown> & { packageId: string; version: string } {
  return typeof value.packageId === "string" && typeof value.version === "string" && PACKAGE_ID_PATTERN.test(value.packageId) && VERSION_PATTERN.test(value.version);
}

export function sanitizeRuntimeBridgeLaunch(value: unknown): RuntimeBridgeLaunch | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["directory", "token"])) return null;
  const directory = value.directory;
  const token = value.token;
  if (typeof directory !== "string" || typeof token !== "string" || !path.isAbsolute(directory) || !TOKEN_PATTERN.test(token)) return null;
  return { directory: path.normalize(directory), token };
}

export function parseRuntimeBridgeLaunch(args: readonly string[]): RuntimeBridgeLaunch | null {
  return sanitizeRuntimeBridgeLaunch({
    directory: readArgument(args, "ocp-bridge-dir"),
    token: readArgument(args, "ocp-bridge-token"),
  });
}

export function resolveRuntimeBridgeLaunch(args: readonly string[], additionalData: unknown): RuntimeBridgeLaunch | null {
  if (isRecord(additionalData)) {
    const forwarded = sanitizeRuntimeBridgeLaunch(additionalData.runtimeBridge);
    if (forwarded) return forwarded;
  }
  return parseRuntimeBridgeLaunch(args);
}

export function sanitizeRuntimeBridgeCommand(value: unknown): RuntimeBridgeCommand | null {
  if (!isRecord(value) || typeof value.type !== "string" || !COMMAND_TYPES.has(value.type)) return null;
  if (value.type === "settings.update" && hasOnlyKeys(value, ["type", "appearance"])) {
    const appearance = sanitizeShellAppearance(value.appearance);
    return appearance ? { type: "settings.update", appearance } : null;
  }
  if (value.type === "control.settings.update" && hasOnlyKeys(value, ["type", "settings"])) {
    const settings = sanitizeControlCenterSettings(value.settings);
    return settings ? { type: "control.settings.update", settings } : null;
  }
  if ((value.type === "control.ai.update" || value.type === "control.ai.test" || value.type === "control.ai.discover" || value.type === "control.voice.test") && hasOnlyKeys(value, ["type", "settings"])) {
    const settings = sanitizeAIControlSettings(value.settings);
    return settings ? { type: value.type, settings } : null;
  }
  if ((value.type === "control.update.check" || value.type === "control.update.apply") && hasOnlyKeys(value, ["type"]) && Object.keys(value).length === 1) {
    return { type: value.type };
  }
  if (value.type === "control.update.install-on-restart" && hasOnlyKeys(value, ["type", "enabled"]) && Object.keys(value).length === 2 && typeof value.enabled === "boolean") {
    return { type: value.type, enabled: value.enabled };
  }
  const type = value.type;
  if ((type === "character.activate" || type === "character.uninstall" || type === "character.effects.preview-level-up" || type === "character.preview.open" || type === "character.preview.play" || type === "character.preview.pause" || type === "character.preview.close") && hasOnlyKeys(value, ["type", "packageId", "version"]) && validIdentity(value)) {
    return { type, packageId: value.packageId, version: value.version };
  }
  if (value.type === "character.effects.update" && hasOnlyKeys(value, ["type", "levelUpEnabled", "auraEnabled"]) && typeof value.levelUpEnabled === "boolean" && typeof value.auraEnabled === "boolean") {
    return { type: "character.effects.update", levelUpEnabled: value.levelUpEnabled, auraEnabled: value.auraEnabled };
  }
  const validEffectSlot = (slot: unknown): slot is "bodyAura" | "groundRune" | "levelUpBurst" =>
    slot === "bodyAura" || slot === "groundRune" || slot === "levelUpBurst";
  if (value.type === "effect-pack.equip" && hasOnlyKeys(value, ["type", "packageId", "version", "slot"]) && validIdentity(value) && (value.slot === "" || validEffectSlot(value.slot))) {
    return { type: "effect-pack.equip", packageId: value.packageId, version: value.version, slot: value.slot };
  }
  if (value.type === "effect-pack.unequip" && hasOnlyKeys(value, ["type", "slot"]) && validEffectSlot(value.slot)) {
    return { type: "effect-pack.unequip", slot: value.slot };
  }
  if (value.type === "effect-pack.slot-enabled" && hasOnlyKeys(value, ["type", "slot", "enabled"]) && validEffectSlot(value.slot) && typeof value.enabled === "boolean") {
    return { type: "effect-pack.slot-enabled", slot: value.slot, enabled: value.enabled };
  }
  if (value.type === "effect-pack.preview" && hasOnlyKeys(value, ["type", "mode", "variant"])) {
    const mode = Object.keys(value).length === 1 ? "all" : value.mode;
    if (!["all", "bodyAura", "groundRune", "levelUpBurst", "off"].includes(String(mode))) return null;
    if (value.variant !== undefined && (typeof value.variant !== "string" || !["equipped", "video-original", "video-blend", "starter-mist"].includes(value.variant))) return null;
    return { type: "effect-pack.preview", mode: mode as "all" | "bodyAura" | "groundRune" | "levelUpBurst" | "off", ...(value.variant !== undefined ? { variant: value.variant as "equipped" | "video-original" | "video-blend" | "starter-mist" } : {}) };
  }
  if (value.type === "effect-pack.preview-tune" && hasOnlyKeys(value, ["type", "slot", "tuning"]) && Object.keys(value).length === 3 && validEffectSlot(value.slot) && isRecord(value.tuning) && hasOnlyKeys(value.tuning, ["fps", "startFrame", "endFrame", "scale", "offsetX", "offsetY", "anchor", "scaleMode"]) && Object.keys(value.tuning).length === 8) {
    const tuning = value.tuning;
    if (typeof tuning.fps !== "number" || !Number.isInteger(tuning.fps) || tuning.fps < 1 || tuning.fps > 30) return null;
    if (typeof tuning.startFrame !== "number" || !Number.isInteger(tuning.startFrame) || tuning.startFrame < 0 || tuning.startFrame > 119) return null;
    if (typeof tuning.endFrame !== "number" || !Number.isInteger(tuning.endFrame) || tuning.endFrame < tuning.startFrame || tuning.endFrame > 119) return null;
    if (typeof tuning.scale !== "number" || !Number.isFinite(tuning.scale) || tuning.scale < 0.25 || tuning.scale > 4) return null;
    if (typeof tuning.offsetX !== "number" || !Number.isFinite(tuning.offsetX) || Math.abs(tuning.offsetX) > 512 || typeof tuning.offsetY !== "number" || !Number.isFinite(tuning.offsetY) || Math.abs(tuning.offsetY) > 512) return null;
    if (!["character-center", "character-feet", "character-feet-bottom", "character-above-head"].includes(String(tuning.anchor))) return null;
    if (!["character-width", "character-height", "native-surface"].includes(String(tuning.scaleMode))) return null;
    return { type: "effect-pack.preview-tune", slot: value.slot, tuning: { fps: tuning.fps, startFrame: tuning.startFrame, endFrame: tuning.endFrame, scale: tuning.scale, offsetX: tuning.offsetX, offsetY: tuning.offsetY, anchor: tuning.anchor as "character-center" | "character-feet" | "character-feet-bottom" | "character-above-head", scaleMode: tuning.scaleMode as "character-width" | "character-height" | "native-surface" } };
  }
  if (value.type === "effect-pack.character-profile.save" && hasOnlyKeys(value, ["type", "characterId", "slot", "tuning"]) && Object.keys(value).length === 4 && validText(value.characterId, 128) && PACKAGE_ID_PATTERN.test(value.characterId as string) && validEffectSlot(value.slot) && isRecord(value.tuning) && hasOnlyKeys(value.tuning, ["fps", "startFrame", "endFrame", "scale", "offsetX", "offsetY", "anchor", "scaleMode"]) && Object.keys(value.tuning).length === 8) {
    const tuning = value.tuning;
    if (typeof tuning.fps !== "number" || !Number.isInteger(tuning.fps) || tuning.fps < 1 || tuning.fps > 30) return null;
    if (typeof tuning.startFrame !== "number" || !Number.isInteger(tuning.startFrame) || tuning.startFrame < 0 || tuning.startFrame > 119) return null;
    if (typeof tuning.endFrame !== "number" || !Number.isInteger(tuning.endFrame) || tuning.endFrame < tuning.startFrame || tuning.endFrame > 119) return null;
    if (typeof tuning.scale !== "number" || !Number.isFinite(tuning.scale) || tuning.scale < 0.25 || tuning.scale > 4) return null;
    if (typeof tuning.offsetX !== "number" || !Number.isFinite(tuning.offsetX) || Math.abs(tuning.offsetX) > 512 || typeof tuning.offsetY !== "number" || !Number.isFinite(tuning.offsetY) || Math.abs(tuning.offsetY) > 512) return null;
    if (!["character-center", "character-feet", "character-feet-bottom", "character-above-head"].includes(String(tuning.anchor))) return null;
    if (!["character-width", "character-height", "native-surface"].includes(String(tuning.scaleMode))) return null;
    return { type: "effect-pack.character-profile.save", characterId: value.characterId as string, slot: value.slot, tuning: { fps: tuning.fps, startFrame: tuning.startFrame, endFrame: tuning.endFrame, scale: tuning.scale, offsetX: tuning.offsetX, offsetY: tuning.offsetY, anchor: tuning.anchor as "character-center" | "character-feet" | "character-feet-bottom" | "character-above-head", scaleMode: tuning.scaleMode as "character-width" | "character-height" | "native-surface" } };
  }
  if (value.type === "effect-pack.character-profile.reset" && hasOnlyKeys(value, ["type", "characterId", "slot"]) && Object.keys(value).length === 3 && validText(value.characterId, 128) && PACKAGE_ID_PATTERN.test(value.characterId as string) && validEffectSlot(value.slot)) {
    return { type: "effect-pack.character-profile.reset", characterId: value.characterId as string, slot: value.slot };
  }
  if (value.type === "effect-pack.preview-rank" && hasOnlyKeys(value, ["type", "rank"]) && Object.keys(value).length === 2 && ["", "stranger", "friend", "close-friend", "partner", "best-companion"].includes(String(value.rank))) {
    return { type: "effect-pack.preview-rank", rank: value.rank as "" | "stranger" | "friend" | "close-friend" | "partner" | "best-companion" };
  }
  if (value.type === "character.preview.select" && hasOnlyKeys(value, ["type", "packageId", "version", "animation"]) && validIdentity(value) && validText(value.animation, 80)) {
    return { type: "character.preview.select", packageId: value.packageId, version: value.version, animation: value.animation };
  }
  if (value.type === "character.preview.thumbnail-page" && hasOnlyKeys(value, ["type", "packageId", "version", "offset"]) && validIdentity(value) && Number.isInteger(value.offset) && typeof value.offset === "number" && value.offset >= 0 && value.offset <= 120 && value.offset % 6 === 0) {
    return { type: "character.preview.thumbnail-page", packageId: value.packageId, version: value.version, offset: value.offset };
  }
  if (value.type === "character.preview.set-loop" && hasOnlyKeys(value, ["type", "packageId", "version", "enabled"]) && validIdentity(value) && typeof value.enabled === "boolean") {
    return { type: "character.preview.set-loop", packageId: value.packageId, version: value.version, enabled: value.enabled };
  }
  if (value.type === "character.preview.set-speed" && hasOnlyKeys(value, ["type", "packageId", "version", "speed"]) && validIdentity(value) && typeof value.speed === "number" && PREVIEW_SPEEDS.includes(value.speed as (typeof PREVIEW_SPEEDS)[number])) {
    return { type: "character.preview.set-speed", packageId: value.packageId, version: value.version, speed: value.speed as (typeof PREVIEW_SPEEDS)[number] };
  }
  if (value.type === "chat.submit" && hasOnlyKeys(value, ["type", "prompt"]) && validText(value.prompt, MAX_PROMPT_LENGTH)) {
    return { type: "chat.submit", prompt: value.prompt.trim() };
  }
  const expectedRevision = typeof value.expectedRevision === "number" ? value.expectedRevision : -1;
  const validRevision = Number.isSafeInteger(expectedRevision) && expectedRevision >= 0;
  if (value.type === "chat.message.edit" && hasOnlyKeys(value, ["type", "messageId", "prompt", "expectedRevision"]) && validText(value.messageId, 128) && validText(value.prompt, MAX_PROMPT_LENGTH) && validRevision) {
    return { type: "chat.message.edit", messageId: value.messageId, prompt: value.prompt.trim(), expectedRevision };
  }
  if (value.type === "chat.feedback.set" && hasOnlyKeys(value, ["type", "messageId", "feedback", "expectedRevision"]) && validText(value.messageId, 128) && ["none", "positive", "negative"].includes(String(value.feedback)) && validRevision) {
    return { type: "chat.feedback.set", messageId: value.messageId, feedback: value.feedback as "none" | "positive" | "negative", expectedRevision };
  }
  if ((value.type === "chat.message.regenerate" || value.type === "chat.message.read-aloud") && hasOnlyKeys(value, ["type", "messageId", "expectedRevision"]) && validText(value.messageId, 128) && validRevision) {
    return { type: value.type, messageId: value.messageId, expectedRevision };
  }
  if ((value.type === "chat.turn.cancel" || value.type === "chat.session.new") && hasOnlyKeys(value, ["type", "expectedRevision"]) && validRevision) {
    return { type: value.type, expectedRevision };
  }
  if ((value.type === "chat.reconnect" || value.type === "chat.session.clear" || value.type === "account.sign-out" || value.type === "cloud.library.refresh" || value.type === "cloud.sync.now") && hasOnlyKeys(value, ["type"]) && Object.keys(value).length === 1) {
    return { type: value.type } as RuntimeBridgeCommand;
  }
  if (value.type === "cloud.library.install" && hasOnlyKeys(value, ["type", "packageId", "version"]) && validIdentity(value)) {
    return { type: "cloud.library.install", packageId: value.packageId, version: value.version };
  }
  return null;
}

function sanitizeCharacter(value: unknown, schemaVersion: RuntimeSnapshot["schemaVersion"]): RuntimeCharacter | null {
  const keys = schemaVersion >= 11
    ? ["packageId", "version", "name", "active", "animations", "thumbnailPngBase64", "thumbnailWidth", "thumbnailHeight"]
    : ["packageId", "version", "name", "active", "animations"];
  if (!isRecord(value) || !hasOnlyKeys(value, keys) || Object.keys(value).length !== keys.length) return null;
  if (typeof value.packageId !== "string" || typeof value.version !== "string" || !PACKAGE_ID_PATTERN.test(value.packageId) || !VERSION_PATTERN.test(value.version) || !validText(value.name, 160) || typeof value.active !== "boolean" || !Array.isArray(value.animations) || value.animations.length > 256 || !value.animations.every((animation) => validText(animation, 80))) return null;
  if (schemaVersion < 11) return { packageId: value.packageId, version: value.version, name: value.name, active: value.active, animations: value.animations };
  const thumbnailPngBase64 = value.thumbnailPngBase64;
  const thumbnailWidth = value.thumbnailWidth;
  const thumbnailHeight = value.thumbnailHeight;
  if (!validOptionalText(thumbnailPngBase64, 87_384) || typeof thumbnailWidth !== "number" || !Number.isInteger(thumbnailWidth) || typeof thumbnailHeight !== "number" || !Number.isInteger(thumbnailHeight) || thumbnailWidth < 0 || thumbnailWidth > 128 || thumbnailHeight < 0 || thumbnailHeight > 128) return null;
  if ((thumbnailWidth === 0) !== (thumbnailHeight === 0) || (thumbnailWidth === 0) !== (thumbnailPngBase64.length === 0) || (thumbnailPngBase64.length > 0 && !BASE64_PATTERN.test(thumbnailPngBase64))) return null;
  return { packageId: value.packageId, version: value.version, name: value.name, active: value.active, animations: value.animations, thumbnailPngBase64, thumbnailWidth, thumbnailHeight };
}

function sanitizeProgression(value: unknown, schemaVersion: RuntimeSnapshot["schemaVersion"]): RuntimeProgression | null {
  const hasEffects = schemaVersion >= 19;
  const allowedKeys = hasEffects ? ["revision", "companions", "levelCap", "effects"] : ["revision", "companions", "levelCap"];
  if (!isRecord(value) || !hasOnlyKeys(value, allowedKeys)) return null;
  const v2 = value.levelCap !== undefined;
  if (Object.keys(value).length !== (hasEffects ? 4 : (v2 ? 3 : 2))) return null;
  const levelCap = v2 ? value.levelCap : 100;
  if (typeof levelCap !== "number" || !Number.isSafeInteger(levelCap) || levelCap < 1 || levelCap > 200) return null;
  if (typeof value.revision !== "number" || !Number.isSafeInteger(value.revision) || value.revision < 0 || !Array.isArray(value.companions) || value.companions.length > 128) return null;
  let effects: RuntimeProgression["effects"] | undefined;
  if (hasEffects) {
    if (!isRecord(value.effects) || !hasOnlyKeys(value.effects, ["levelUpEnabled", "auraEnabled"]) || Object.keys(value.effects).length !== 2 || typeof value.effects.levelUpEnabled !== "boolean" || typeof value.effects.auraEnabled !== "boolean") return null;
    effects = { levelUpEnabled: value.effects.levelUpEnabled, auraEnabled: value.effects.auraEnabled };
  }
  const companions: RuntimeProgressionCompanion[] = [];
  for (const companion of value.companions) {
    if (!isRecord(companion) || !hasOnlyKeys(companion, ["companionId", "characterId", "relationship", "skills"]) || Object.keys(companion).length !== 4) return null;
    if (!validText(companion.companionId, 128) || !validText(companion.characterId, 128) || !isRecord(companion.relationship) || !hasOnlyKeys(companion.relationship, v2 ? ["level", "xp", "bondRank", "currentLevelXp", "nextLevelXp", "progressPermille"] : ["level", "xp"]) || Object.keys(companion.relationship).length !== (v2 ? 6 : 2) || !Array.isArray(companion.skills) || companion.skills.length > 64) return null;
    const level = companion.relationship.level;
    const xp = companion.relationship.xp;
    if (typeof level !== "number" || !Number.isSafeInteger(level) || level < 1 || level > levelCap || typeof xp !== "number" || !Number.isSafeInteger(xp) || xp < 0) return null;
    let relationship: RuntimeProgressionCompanion["relationship"] = { level, xp };
    if (v2) {
      const { bondRank, currentLevelXp, nextLevelXp, progressPermille } = companion.relationship;
      if (typeof bondRank !== "string" || !["stranger","friend","close-friend","partner","best-companion"].includes(bondRank)
        || typeof currentLevelXp !== "number" || !Number.isSafeInteger(currentLevelXp) || currentLevelXp < 0 || currentLevelXp > xp
        || (nextLevelXp !== null && (typeof nextLevelXp !== "number" || !Number.isSafeInteger(nextLevelXp) || nextLevelXp <= currentLevelXp || nextLevelXp <= xp))
        || typeof progressPermille !== "number" || !Number.isSafeInteger(progressPermille) || progressPermille < 0 || progressPermille > 1000) return null;
      relationship = { level, xp, bondRank, currentLevelXp, nextLevelXp: nextLevelXp as number | null, progressPermille };
    }
    const skills: RuntimeProgressionSkill[] = [];
    for (const skill of companion.skills) {
      if (!isRecord(skill) || !hasOnlyKeys(skill, ["skillId", "level", "xp"]) || Object.keys(skill).length !== 3 || !validText(skill.skillId, 80) || typeof skill.level !== "number" || !Number.isSafeInteger(skill.level) || skill.level < 0 || skill.level > 100 || typeof skill.xp !== "number" || !Number.isSafeInteger(skill.xp) || skill.xp < 0) return null;
      skills.push({ skillId: skill.skillId, level: skill.level, xp: skill.xp });
    }
    companions.push({ companionId: companion.companionId, characterId: companion.characterId, relationship, skills });
  }
  return v2 ? { revision: value.revision, levelCap, companions, ...(effects ? { effects } : {}) } : { revision: value.revision, companions };
}

function sanitizeEffectPacks(value: unknown): RuntimeEffectPacks | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["installed", "loadout", "enabled", "resolved", "previewRank"]) || Object.keys(value).length !== 5) return null;
  if (!Array.isArray(value.installed) || value.installed.length > 128 || !isRecord(value.loadout) || !isRecord(value.enabled) || !isRecord(value.resolved) || !["", "stranger", "friend", "close-friend", "partner", "best-companion"].includes(String(value.previewRank))) return null;
  const slots: RuntimeEffectSlotName[] = ["bodyAura", "groundRune", "levelUpBurst"];
  const enabledRecord = value.enabled as Record<string, unknown>;
  if (!hasOnlyKeys(enabledRecord, slots) || Object.keys(enabledRecord).length !== 3 || !slots.every((slot) => typeof enabledRecord[slot] === "boolean")) return null;

  const installed: RuntimeEffectPackInstalled[] = [];
  for (const item of value.installed) {
    if (!isRecord(item) || !hasOnlyKeys(item, ["packageId", "version", "name", "slots", "progression"]) || Object.keys(item).length !== 5) return null;
    if (!validText(item.packageId, 128) || !PACKAGE_ID_PATTERN.test(item.packageId as string) || !validText(item.version, 96) || !VERSION_PATTERN.test(item.version as string) || !validText(item.name, 160) || !Array.isArray(item.slots) || item.slots.length > 3 || !item.slots.every((slot) => slots.includes(slot as RuntimeEffectSlotName))) return null;
    installed.push({
      packageId: item.packageId as string,
      version: item.version as string,
      name: item.name as string,
      slots: item.slots as RuntimeEffectSlotName[],
      progression: item.progression ?? null,
    });
  }

  const loadout: Partial<Record<RuntimeEffectSlotName, Readonly<{ packageId: string; version: string }>>> = {};
  for (const [slot, identity] of Object.entries(value.loadout)) {
    if (!slots.includes(slot as RuntimeEffectSlotName) || !isRecord(identity) || !hasOnlyKeys(identity, ["packageId", "version"]) || Object.keys(identity).length !== 2 || !validIdentity(identity)) return null;
    loadout[slot as RuntimeEffectSlotName] = { packageId: identity.packageId, version: identity.version };
  }

  const resolved: Partial<Record<RuntimeEffectSlotName, RuntimeEffectPackResolved>> = {};
  for (const [slot, item] of Object.entries(value.resolved)) {
    if (!slots.includes(slot as RuntimeEffectSlotName) || !isRecord(item) || !hasOnlyKeys(item, ["packageId", "version", "name", "slot", "config"]) || Object.keys(item).length !== 5 || !validIdentity(item) || item.slot !== slot || !validText(item.name, 160) || !isRecord(item.config)) return null;
    const configJson = JSON.stringify(item.config);
    if (configJson.length > 16_384) return null;
    resolved[slot as RuntimeEffectSlotName] = {
      packageId: item.packageId,
      version: item.version,
      name: item.name as string,
      slot: item.slot as RuntimeEffectSlotName,
      config: { ...item.config },
    };
  }

  return {
    installed,
    loadout,
    enabled: {
      bodyAura: enabledRecord.bodyAura as boolean,
      groundRune: enabledRecord.groundRune as boolean,
      levelUpBurst: enabledRecord.levelUpBurst as boolean,
    },
    resolved,
    previewRank: value.previewRank as RuntimeEffectPacks["previewRank"],
  };
}


function sanitizeChatMessage(value: unknown, schemaVersion: RuntimeSnapshot["schemaVersion"]): RuntimeChatMessage | null {
  const expectedKeys = schemaVersion >= 9 ? ["id", "role", "text", "status", "feedback"] : ["id", "role", "text", "status"];
  if (!isRecord(value) || !hasOnlyKeys(value, expectedKeys) || Object.keys(value).length !== expectedKeys.length) return null;
  if (!validText(value.id, 128) || (value.role !== "user" && value.role !== "assistant") || !validText(value.text, 16_000) || (value.status !== "complete" && value.status !== "streaming" && value.status !== "failed")) return null;
  if (schemaVersion >= 9 && !["none", "positive", "negative"].includes(String(value.feedback))) return null;
  return { id: value.id, role: value.role, text: value.text, status: value.status, ...(schemaVersion >= 9 ? { feedback: value.feedback as RuntimeChatMessage["feedback"] } : {}) };
}

function sanitizeChatPresentation(value: unknown): RuntimeChatPresentation | null {
  const keys = ["owner", "state", "sequence", "turnId", "messageId", "speechId", "reasonCode"];
  if (!isRecord(value) || !hasOnlyKeys(value, keys) || Object.keys(value).length !== keys.length) return null;
  if (value.owner !== "chat" && value.owner !== "native") return null;
  if (!["idle", "think", "talk"].includes(String(value.state))) return null;
  if (typeof value.sequence !== "number" || !Number.isSafeInteger(value.sequence) || value.sequence < 0) return null;
  if (!validOptionalText(value.turnId, 128) || !validOptionalText(value.messageId, 128) || !validOptionalText(value.speechId, 128)) return null;
  const reasons: readonly RuntimeChatPresentation["reasonCode"][] = ["ready", "turn-active", "voice-synthesizing", "voice-playing", "voice-failed"];
  if (!reasons.includes(value.reasonCode as RuntimeChatPresentation["reasonCode"])) return null;
  return value as RuntimeChatPresentation;
}

function sanitizePreview(value: unknown, schemaVersion: RuntimeSnapshot["schemaVersion"]): RuntimePreview | null {
  const previewKeys = schemaVersion >= 12
    ? ["status", "errorCode", "packageId", "version", "clips", "selectedAnimation", "isPlaying", "loop", "speed", "clipThumbnailPngBase64", "framePngBase64", "frameWidth", "frameHeight"]
    : ["status", "errorCode", "packageId", "version", "clips", "selectedAnimation", "isPlaying", "loop", "speed", "framePngBase64", "frameWidth", "frameHeight"];
  if (!isRecord(value) || !hasOnlyKeys(value, previewKeys)) return null;
  const status = value.status;
  const frameWidth = value.frameWidth;
  const frameHeight = value.frameHeight;
  if (!["idle", "loading", "ready", "playing", "paused", "failed"].includes(String(status)) || !validOptionalText(value.errorCode, 80) || !validOptionalText(value.packageId, 128) || !validOptionalText(value.version, 64) || !Array.isArray(value.clips) || value.clips.length > 256 || !value.clips.every((clip) => validText(clip, 80)) || !validOptionalText(value.selectedAnimation, 80) || typeof value.isPlaying !== "boolean" || typeof value.loop !== "boolean" || typeof value.speed !== "number" || !PREVIEW_SPEEDS.includes(value.speed as (typeof PREVIEW_SPEEDS)[number]) || !validOptionalText(value.framePngBase64, MAX_PREVIEW_FRAME_BASE64_LENGTH) || typeof frameWidth !== "number" || !Number.isInteger(frameWidth) || typeof frameHeight !== "number" || !Number.isInteger(frameHeight) || frameWidth < 0 || frameWidth > 512 || frameHeight < 0 || frameHeight > 512) return null;
  const isIdle = status === "idle";
  if (!isIdle && (!PACKAGE_ID_PATTERN.test(value.packageId) || !VERSION_PATTERN.test(value.version))) return null;
  if ((frameWidth === 0) !== (frameHeight === 0) || (frameWidth === 0) !== (value.framePngBase64.length === 0) || (value.framePngBase64.length > 0 && !BASE64_PATTERN.test(value.framePngBase64))) return null;

  let clipThumbnailPngBase64: Readonly<Record<string, string>> | undefined;
  if (schemaVersion >= 12) {
    if (!isRecord(value.clipThumbnailPngBase64)) return null;
    const entries = Object.entries(value.clipThumbnailPngBase64);
    if (entries.length > MAX_PREVIEW_SHORTCUT_THUMBNAILS) return null;
    for (const [animation, encoded] of entries) {
      if (!validText(animation, 80) || !value.clips.includes(animation) || !validText(encoded, MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH) || !BASE64_PATTERN.test(encoded)) return null;
    }
    clipThumbnailPngBase64 = value.clipThumbnailPngBase64 as Readonly<Record<string, string>>;
  }

  return {
    status: status as RuntimePreview["status"], errorCode: value.errorCode, packageId: value.packageId, version: value.version,
    clips: value.clips, selectedAnimation: value.selectedAnimation, isPlaying: value.isPlaying, loop: value.loop,
    speed: value.speed as RuntimePreview["speed"], ...(clipThumbnailPngBase64 ? { clipThumbnailPngBase64 } : {}),
    framePngBase64: value.framePngBase64, frameWidth, frameHeight,
  };
}

function sanitizeCommandResult(value: unknown, schemaVersion: RuntimeSnapshot["schemaVersion"]): RuntimeCommandResult | null {
  if (!isRecord(value) || !validText(value.id, 128) || typeof value.type !== "string" || !COMMAND_TYPES.has(value.type)) return null;
  if (value.status !== "accepted" && value.status !== "succeeded" && value.status !== "failed") return null;
  if (!validOptionalText(value.errorCode, 80)) return null;
  const allowsModels = schemaVersion >= 18 && value.type === "control.ai.discover";
  const allowedKeys = allowsModels ? ["id", "type", "status", "errorCode", "models"] : ["id", "type", "status", "errorCode"];
  if (!hasOnlyKeys(value, allowedKeys)) return null;
  if (!allowsModels && Object.keys(value).length !== 4) return null;
  if (allowsModels && value.models !== undefined) {
    if (!Array.isArray(value.models) || value.models.length > 16) return null;
    const models = value.models.map((model) => typeof model === "string" && validText(model, 160) ? model : null);
    if (models.some((model) => model === null)) return null;
    const safeModels = models as string[];
    if (new Set(safeModels).size !== safeModels.length) return null;
    return { id: value.id, type: value.type as RuntimeBridgeCommand["type"], status: value.status, errorCode: value.errorCode, models: safeModels };
  }
  return { id: value.id, type: value.type as RuntimeBridgeCommand["type"], status: value.status, errorCode: value.errorCode };
}

function sanitizeAccount(value: unknown): RuntimeAccount | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["signedIn", "userId", "email", "deviceId"]) || Object.keys(value).length !== 4) return null;
  if (typeof value.signedIn !== "boolean" || !validOptionalText(value.userId, 160) || !validOptionalText(value.email, 320) || !validOptionalText(value.deviceId, 160)) return null;
  if (value.signedIn && typeof value.userId === "string" && value.userId.length === 0) return null;
  if (!value.signedIn && (value.userId !== "" || value.email !== "" || value.deviceId !== "")) return null;
  return { signedIn: value.signedIn, userId: value.userId as string, email: value.email as string, deviceId: value.deviceId as string };
}

function sanitizeCloudState(value: unknown, schemaVersion: number): RuntimeCloudState | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["library", "sync", "download"]) || Object.keys(value).length !== 3) return null;
  if (!isRecord(value.library) || !hasOnlyKeys(value.library, ["status", "items"]) || Object.keys(value.library).length !== 2 || !Array.isArray(value.library.items) || value.library.items.length > 128) return null;
  const libraryStatuses: readonly RuntimeCloudState["library"]["status"][] = ["signed-out", "idle", "loading", "synced", "error", "not-configured"];
  if (!libraryStatuses.includes(value.library.status as RuntimeCloudState["library"]["status"])) return null;
  const items: RuntimeCloudLibraryItem[] = [];
  for (const raw of value.library.items) {
    if (!isRecord(raw) || !hasOnlyKeys(raw, ["productId", "productType", "entitled", "source", "grantedAt", "revokedAt", "name", "latestVersion", "thumbnailUrl", "availability"]) || Object.keys(raw).length !== 10) return null;
    if (!validText(raw.productId, 160) || !validText(raw.productType, 80) || typeof raw.entitled !== "boolean" || !["free-install", "grant", "purchase"].includes(String(raw.source)) || !validText(raw.grantedAt, 80) || !validOptionalText(raw.revokedAt, 80) || !validOptionalText(raw.name, 160) || !validOptionalText(raw.latestVersion, 64) || !validOptionalText(raw.thumbnailUrl, 2048) || !["free", "entitlement-required", "unknown"].includes(String(raw.availability))) return null;
    items.push({
      productId: raw.productId,
      productType: raw.productType,
      entitled: raw.entitled,
      source: raw.source as RuntimeCloudLibraryItem["source"],
      grantedAt: raw.grantedAt,
      revokedAt: raw.revokedAt,
      name: raw.name,
      latestVersion: raw.latestVersion,
      thumbnailUrl: raw.thumbnailUrl,
      availability: raw.availability as RuntimeCloudLibraryItem["availability"],
    });
  }
  if (!isRecord(value.sync) || !hasOnlyKeys(value.sync, ["status", "deviceRegistered", "progressionRevision"]) || Object.keys(value.sync).length !== 3) return null;
  const syncStatuses: readonly RuntimeCloudState["sync"]["status"][] = ["signed-out", "idle", "syncing", "synced", "error", "device-registration-required"];
  if (!syncStatuses.includes(value.sync.status as RuntimeCloudState["sync"]["status"]) || typeof value.sync.deviceRegistered !== "boolean" || typeof value.sync.progressionRevision !== "number" || !Number.isSafeInteger(value.sync.progressionRevision) || value.sync.progressionRevision < 0) return null;
  const downloadKeys = schemaVersion >= 17 ? ["status", "packageId", "version", "trust"] : ["status", "packageId", "version"];
  if (!isRecord(value.download) || !hasOnlyKeys(value.download, downloadKeys) || Object.keys(value.download).length !== downloadKeys.length) return null;
  const downloadStatuses: readonly RuntimeCloudState["download"]["status"][] = ["idle", "authorizing", "downloading", "installed", "error"];
  if (!downloadStatuses.includes(value.download.status as RuntimeCloudState["download"]["status"]) || !validOptionalText(value.download.packageId, 160) || !validOptionalText(value.download.version, 64)) return null;
  let trust: RuntimeCloudState["download"]["trust"] | undefined;
  if (schemaVersion >= 17) {
    if (!isRecord(value.download.trust) || !hasOnlyKeys(value.download.trust, ["mode", "sequence", "trustedPublishers", "revocationStale"]) || Object.keys(value.download.trust).length !== 4) return null;
    if (!["none", "local-beta", "marketplace-release"].includes(String(value.download.trust.mode)) || typeof value.download.trust.sequence !== "number" || !Number.isSafeInteger(value.download.trust.sequence) || value.download.trust.sequence < 0 || typeof value.download.trust.trustedPublishers !== "number" || !Number.isSafeInteger(value.download.trust.trustedPublishers) || value.download.trust.trustedPublishers < 0 || value.download.trust.trustedPublishers > 256 || typeof value.download.trust.revocationStale !== "boolean") return null;
    trust = {
      mode: value.download.trust.mode as "none" | "local-beta" | "marketplace-release",
      sequence: value.download.trust.sequence,
      trustedPublishers: value.download.trust.trustedPublishers,
      revocationStale: value.download.trust.revocationStale,
    };
  }
  return {
    library: { status: value.library.status as RuntimeCloudState["library"]["status"], items },
    sync: { status: value.sync.status as RuntimeCloudState["sync"]["status"], deviceRegistered: value.sync.deviceRegistered, progressionRevision: value.sync.progressionRevision },
    download: { status: value.download.status as RuntimeCloudState["download"]["status"], packageId: value.download.packageId, version: value.download.version, ...(trust ? { trust } : {}) },
  };
}

function sanitizeVoiceHealth(value: unknown): RuntimeVoiceHealth | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["status", "reasonCode", "lastSuccessAtMs", "retryAtMs"]) || Object.keys(value).length !== 4) return null;
  const statuses: readonly RuntimeVoiceHealth["status"][] = ["disabled", "idle", "synthesizing", "playing", "healthy", "degraded", "failed"];
  const reasons: readonly RuntimeVoiceHealth["reasonCode"][] = ["", "provider-credential-required", "local-voice-not-installed", "dns-unreachable", "provider-auth-failed", "provider-quota-exceeded", "provider-rate-limited", "tts-unavailable", "playback-failed", "interrupted"];
  if (!statuses.includes(value.status as RuntimeVoiceHealth["status"]) || !reasons.includes(value.reasonCode as RuntimeVoiceHealth["reasonCode"])) return null;
  if (typeof value.lastSuccessAtMs !== "number" || !Number.isSafeInteger(value.lastSuccessAtMs) || value.lastSuccessAtMs < 0) return null;
  if (typeof value.retryAtMs !== "number" || !Number.isSafeInteger(value.retryAtMs) || value.retryAtMs < 0) return null;
  return value as RuntimeVoiceHealth;
}

export function sanitizeRuntimeSnapshot(value: unknown): RuntimeSnapshot | null {
  if (!isRecord(value) || ![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20].includes(value.schemaVersion as number) || (value.status !== "connected" && value.status !== "unavailable")) return null;
  const schemaVersion = value.schemaVersion as RuntimeSnapshot["schemaVersion"];
  const runtimeStatus = value.status as RuntimeSnapshot["status"];
  const expectedKeys = value.schemaVersion === 1
    ? ["schemaVersion", "status", "appearance", "characters", "chat", "preview"]
    : schemaVersion >= 20
      ? ["schemaVersion", "status", "appearance", "characters", "progression", "effectPacks", "account", "cloud", "chat", "preview", "controlCenter", "commandResults", "voice"]
    : schemaVersion >= 16
      ? ["schemaVersion", "status", "appearance", "characters", "progression", "account", "cloud", "chat", "preview", "controlCenter", "commandResults", "voice"]
      : schemaVersion >= 15
        ? ["schemaVersion", "status", "appearance", "characters", "progression", "account", "chat", "preview", "controlCenter", "commandResults", "voice"]
      : schemaVersion >= 13
        ? ["schemaVersion", "status", "appearance", "characters", "progression", "chat", "preview", "controlCenter", "commandResults", "voice"]
        : schemaVersion >= 7
          ? ["schemaVersion", "status", "appearance", "characters", "chat", "preview", "controlCenter", "commandResults", "voice"]
          : ["schemaVersion", "status", "appearance", "characters", "chat", "preview", "controlCenter", "commandResults"];
  if (!hasOnlyKeys(value, expectedKeys) || Object.keys(value).length !== expectedKeys.length) return null;
  const appearance = sanitizeShellAppearance(value.appearance);
  const chatKeys = schemaVersion >= 10
    ? ["providerId", "status", "messages", "presentationState", "sessionId", "revision", "activeMessageId", "presentation"]
    : schemaVersion === 9
    ? ["providerId", "status", "messages", "presentationState", "sessionId", "revision", "activeMessageId"]
    : schemaVersion === 8 ? ["providerId", "status", "messages", "presentationState"] : ["providerId", "status", "messages"];
  if (!appearance || !Array.isArray(value.characters) || value.characters.length > 128 || !isRecord(value.chat) || !hasOnlyKeys(value.chat, chatKeys) || Object.keys(value.chat).length !== chatKeys.length || !validText(value.chat.providerId, 80) || !["ready", "thinking", "offline", "failed"].includes(String(value.chat.status)) || !Array.isArray(value.chat.messages) || value.chat.messages.length > 200) return null;
  if (schemaVersion >= 8 && !["idle", "think", "talk"].includes(String(value.chat.presentationState))) return null;
  if (schemaVersion >= 9 && (!validText(value.chat.sessionId, 128) || typeof value.chat.revision !== "number" || !Number.isSafeInteger(value.chat.revision) || value.chat.revision < 0 || !validOptionalText(value.chat.activeMessageId, 128))) return null;
  const presentation = schemaVersion >= 10 ? sanitizeChatPresentation(value.chat.presentation) : null;
  if (schemaVersion >= 10 && !presentation) return null;
  const characters = value.characters.map((character) => sanitizeCharacter(character, schemaVersion));
  const messages = value.chat.messages.map((message) => sanitizeChatMessage(message, schemaVersion));
  const preview = sanitizePreview(value.preview, schemaVersion);
  const progression = schemaVersion >= 13 ? sanitizeProgression(value.progression, schemaVersion) : null;
  const effectPacks = schemaVersion >= 20 ? sanitizeEffectPacks(value.effectPacks) : null;
  const account = schemaVersion >= 15 ? sanitizeAccount(value.account) : null;
  const cloud = schemaVersion >= 16 ? sanitizeCloudState(value.cloud, schemaVersion) : null;
  if (characters.some((character) => character === null) || messages.some((message) => message === null) || !preview || (schemaVersion >= 13 && !progression) || (schemaVersion >= 20 && !effectPacks) || (schemaVersion >= 15 && !account) || (schemaVersion >= 16 && !cloud)) return null;
  let controlCenter: ControlCenterSnapshot | null = null;
  let commandResults: RuntimeCommandResult[] = [];
  if (schemaVersion !== 1) {
    controlCenter = sanitizeControlCenterSnapshot(value.controlCenter, schemaVersion);
    if (!controlCenter || !Array.isArray(value.commandResults) || value.commandResults.length > 64) return null;
    const results = value.commandResults.map((result) => sanitizeCommandResult(result, schemaVersion));
    if (results.some((result) => result === null)) return null;
    commandResults = results as RuntimeCommandResult[];
  }
  const voice = schemaVersion >= 7 ? sanitizeVoiceHealth(value.voice) : null;
  if (schemaVersion >= 7 && !voice) return null;
  const chat = {
    providerId: value.chat.providerId,
    status: value.chat.status as RuntimeSnapshot["chat"]["status"],
    messages: messages as RuntimeChatMessage[],
    ...(schemaVersion >= 8 ? { presentationState: value.chat.presentationState as RuntimeChatPresentationState } : {}),
    ...(schemaVersion >= 9 ? { sessionId: value.chat.sessionId as string, revision: value.chat.revision as number, activeMessageId: value.chat.activeMessageId as string } : {}),
    ...(presentation ? { presentation } : {}),
  };
  const base: RuntimeSnapshot = { schemaVersion, status: runtimeStatus, appearance, characters: characters as RuntimeCharacter[], ...(progression ? { progression } : {}), ...(effectPacks ? { effectPacks } : {}), ...(account ? { account } : {}), ...(cloud ? { cloud } : {}), chat, preview, controlCenter, commandResults };
  return voice ? { ...base, voice } : base;
}

type RuntimePreviewMedia = Readonly<{
  schemaVersion: 1;
  revision: number;
  packageId: string;
  version: string;
  selectedAnimation: string;
  clipThumbnailPngBase64: Readonly<Record<string, string>>;
  framePngBase64: string;
  frameWidth: number;
  frameHeight: number;
}>;

function sanitizePreviewMedia(value: unknown, preview: RuntimePreview): RuntimePreviewMedia | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["schemaVersion", "revision", "packageId", "version", "selectedAnimation", "clipThumbnailPngBase64", "framePngBase64", "frameWidth", "frameHeight"])) return null;
  if (value.schemaVersion !== PREVIEW_MEDIA_SCHEMA_VERSION || typeof value.revision !== "number" || !Number.isSafeInteger(value.revision) || value.revision < 0) return null;
  if (value.packageId !== preview.packageId || value.version !== preview.version) return null;
  if (!validText(value.selectedAnimation, 80) || !preview.clips.includes(value.selectedAnimation)) return null;
  if (!isRecord(value.clipThumbnailPngBase64)) return null;
  const thumbnails = Object.entries(value.clipThumbnailPngBase64);
  if (thumbnails.length > MAX_PREVIEW_SHORTCUT_THUMBNAILS) return null;
  for (const [animation, encoded] of thumbnails) {
    if (!preview.clips.includes(animation) || !validText(animation, 80) || !validText(encoded, MAX_PREVIEW_THUMBNAIL_BASE64_LENGTH) || !BASE64_PATTERN.test(encoded)) return null;
  }
  if (!validOptionalText(value.framePngBase64, MAX_PREVIEW_FRAME_BASE64_LENGTH) || typeof value.frameWidth !== "number" || !Number.isInteger(value.frameWidth) || typeof value.frameHeight !== "number" || !Number.isInteger(value.frameHeight) || value.frameWidth < 0 || value.frameWidth > 512 || value.frameHeight < 0 || value.frameHeight > 512) return null;
  if ((value.frameWidth === 0) !== (value.frameHeight === 0) || (value.frameWidth === 0) !== (String(value.framePngBase64).length === 0) || (String(value.framePngBase64).length > 0 && !BASE64_PATTERN.test(String(value.framePngBase64)))) return null;
  return {
    schemaVersion: 1,
    revision: value.revision,
    packageId: value.packageId,
    version: value.version,
    selectedAnimation: value.selectedAnimation,
    clipThumbnailPngBase64: value.clipThumbnailPngBase64 as Readonly<Record<string, string>>,
    framePngBase64: value.framePngBase64 as string,
    frameWidth: value.frameWidth,
    frameHeight: value.frameHeight,
  };
}

function mergePreviewMedia(snapshot: RuntimeSnapshot, media: RuntimePreviewMedia): RuntimeSnapshot {
  const frameMatchesSelection = media.selectedAnimation === snapshot.preview.selectedAnimation;
  return {
    ...snapshot,
    preview: {
      ...snapshot.preview,
      // Thumbnail paging is independent from the currently selected animation,
      // so a one-revision media lag during selection must not blank the carousel.
      clipThumbnailPngBase64: media.clipThumbnailPngBase64,
      framePngBase64: frameMatchesSelection ? media.framePngBase64 : "",
      frameWidth: frameMatchesSelection ? media.frameWidth : 0,
      frameHeight: frameMatchesSelection ? media.frameHeight : 0,
    },
  };
}

export class FileRuntimeBridge {
  readonly #launch: RuntimeBridgeLaunch;
  #lastGoodSnapshot: RuntimeSnapshot | null = null;
  #lastGoodObservedAtMs = 0;
  #commandSequence = 0;

  constructor(launch: RuntimeBridgeLaunch) { this.#launch = launch; }

  isCommandChannelLive(): boolean {
    const filePath = path.join(this.#launch.directory, "state.json");
    try {
      if (!existsSync(filePath)) return false;
      const fileStat = statSync(filePath);
      const ageMs = Date.now() - fileStat.mtimeMs;
      if (!Number.isFinite(ageMs) || ageMs < 0 || ageMs > MAX_RUNTIME_COMMAND_SNAPSHOT_AGE_MS) return false;
      const snapshot = sanitizeRuntimeSnapshot(JSON.parse(readFileSync(filePath, "utf8")));
      return snapshot?.status === "connected";
    } catch {
      return false;
    }
  }

  readSnapshot(): RuntimeSnapshot | null {
    const filePath = path.join(this.#launch.directory, "state.json");
    try {
      if (!existsSync(filePath)) return this.#transientFallback();
      const fileStat = statSync(filePath);
      const ageMs = Date.now() - fileStat.mtimeMs;
      if (!Number.isFinite(ageMs) || ageMs > MAX_RUNTIME_SNAPSHOT_AGE_MS) {
        this.#clearLastGood();
        return null;
      }
      // Electron now polls at a modest rate, so always read the current atomic
      // state.json revision. Do not trust mtime equality as a cache key: Windows
      // can coalesce very fast rewrites and an explicit Runtime stop marker must
      // never be hidden behind a cached connected snapshot.
      const snapshot = sanitizeRuntimeSnapshot(JSON.parse(readFileSync(filePath, "utf8")));
      if (!snapshot || snapshot.status !== "connected") {
        if (snapshot?.status === "unavailable") this.#clearLastGood();
        return snapshot ? null : this.#transientFallback();
      }
      const snapshotWithMedia = this.#mergePreviewMedia(snapshot);
      this.#lastGoodSnapshot = snapshotWithMedia;
      this.#lastGoodObservedAtMs = Date.now();
      return snapshotWithMedia;
    }
    catch { return this.#transientFallback(); }
  }

  #mergePreviewMedia(snapshot: RuntimeSnapshot): RuntimeSnapshot {
    const preview = snapshot.preview;
    if (preview.status === "idle" || preview.status === "failed" || !preview.packageId || !preview.version) return snapshot;
    const mediaPath = path.join(this.#launch.directory, "preview-media.json");
    try {
      if (existsSync(mediaPath)) {
        const media = sanitizePreviewMedia(JSON.parse(readFileSync(mediaPath, "utf8")), preview);
        if (media) return mergePreviewMedia(snapshot, media);
      }
    } catch {
      // preview-media.json is atomically replaced by Runtime. A read can land
      // between rename/write operations; keep the last media for the same
      // identity rather than flashing thumbnails back to "No preview".
    }
    const previous = this.#lastGoodSnapshot?.preview;
    if (previous
      && previous.packageId === preview.packageId
      && previous.version === preview.version) {
      const frameMatchesSelection = previous.selectedAnimation === preview.selectedAnimation;
      return {
        ...snapshot,
        preview: {
          ...preview,
          clipThumbnailPngBase64: previous.clipThumbnailPngBase64 ?? {},
          framePngBase64: frameMatchesSelection ? previous.framePngBase64 : "",
          frameWidth: frameMatchesSelection ? previous.frameWidth : 0,
          frameHeight: frameMatchesSelection ? previous.frameHeight : 0,
        },
      };
    }
    return snapshot;
  }

  #transientFallback(): RuntimeSnapshot | null {
    if (!this.#lastGoodSnapshot || Date.now() - this.#lastGoodObservedAtMs > MAX_RUNTIME_SNAPSHOT_AGE_MS) {
      this.#clearLastGood();
      return null;
    }
    return this.#lastGoodSnapshot;
  }

  #clearLastGood(): void {
    this.#lastGoodSnapshot = null;
    this.#lastGoodObservedAtMs = 0;
  }

  claimNetworkTransferRequest(): RuntimeNetworkTransferRequest | null {
    const requestDirectory = path.join(this.#launch.directory, "network-requests");
    const outputDirectory = path.join(this.#launch.directory, "network-downloads");
    if (!existsSync(requestDirectory)) return null;
    mkdirSync(outputDirectory, { recursive: true, mode: 0o700 });
    let names: string[];
    try {
      names = readdirSync(requestDirectory).filter((name) => /^[a-f0-9]{32}\.json$/.test(name)).sort();
    } catch {
      return null;
    }
    for (const name of names) {
      const source = path.join(requestDirectory, name);
      const claimPath = `${source}.processing`;
      try {
        renameSync(source, claimPath);
      } catch {
        continue;
      }
      try {
        const raw = JSON.parse(readFileSync(claimPath, "utf8")) as Record<string, unknown>;
        const id = name.slice(0, -5);
        const urlText = typeof raw.url === "string" ? raw.url : "";
        const token = typeof raw.token === "string" ? raw.token : "";
        const requestId = typeof raw.id === "string" ? raw.id : "";
        if (raw.schemaVersion !== 1 || requestId !== id || token !== this.#launch.token || urlText.length < 1 || urlText.length > 16_384) {
          rmSync(claimPath, { force: true });
          continue;
        }
        const url = new URL(urlText);
        if (url.protocol !== "https:" || url.username || url.password || url.hash) {
          rmSync(claimPath, { force: true });
          continue;
        }
        const outputPath = path.join(outputDirectory, `${id}.ocp`);
        rmSync(outputPath, { force: true });
        rmSync(`${outputPath}.tmp`, { force: true });
        return { id, url: url.toString(), outputPath, claimPath };
      } catch {
        rmSync(claimPath, { force: true });
      }
    }
    return null;
  }

  completeNetworkTransfer(request: RuntimeNetworkTransferRequest, result: RuntimeNetworkTransferResult): void {
    const resultDirectory = path.join(this.#launch.directory, "network-results");
    mkdirSync(resultDirectory, { recursive: true, mode: 0o700 });
    const destination = path.join(resultDirectory, `${request.id}.json`);
    const temporary = `${destination}.tmp`;
    const payload = {
      schemaVersion: 1,
      id: request.id,
      token: this.#launch.token,
      status: result.status,
      path: result.status === "succeeded" ? request.outputPath : "",
      bytes: result.status === "succeeded" && Number.isSafeInteger(result.bytes) && (result.bytes ?? 0) >= 0 ? result.bytes : 0,
      error: result.status === "failed" ? String(result.error ?? "network-transfer-failed").slice(0, 256) : "",
    };
    writeFileSync(temporary, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
    renameSync(temporary, destination);
    rmSync(request.claimPath, { force: true });
  }

  submit(command: RuntimeBridgeCommand): string {
    return this.#submitCommand(command);
  }

  submitSystemInstallHandoff(input: { packageId: string; version: string; grant: string }): string {
    if (!PACKAGE_ID_PATTERN.test(input.packageId) || !VERSION_PATTERN.test(input.version) || !INSTALL_GRANT_PATTERN.test(input.grant)) {
      throw new Error("invalid system install handoff");
    }
    return this.#submitCommand({
      type: "store.install-handoff",
      packageId: input.packageId,
      version: input.version,
      grant: input.grant,
    });
  }

  submitSystemAuthHandoff(input: { grant: string }): string {
    if (!AUTH_GRANT_PATTERN.test(input.grant)) {
      throw new Error("invalid system auth handoff");
    }
    return this.#submitCommand({ type: "account.auth-handoff", grant: input.grant });
  }

  submitSystemLocalInstall(packagePath: string): string {
    const normalized = this.#validatedLocalPackagePath(packagePath);
    return this.#submitCommand({ type: "local.install-package", path: normalized });
  }

  submitSystemLocalEffectInstall(packagePath: string): string {
    const normalized = this.#validatedLocalPackagePath(packagePath);
    return this.#submitCommand({ type: "local.install-effect", path: normalized });
  }

  #validatedLocalPackagePath(packagePath: string): string {
    const normalized = path.normalize(packagePath);
    if (!path.isAbsolute(normalized) || normalized.length > 4_096 || path.extname(normalized).toLowerCase() !== ".ocp" || !existsSync(normalized) || !statSync(normalized).isFile()) {
      throw new Error("invalid local OCP package path");
    }
    return normalized;
  }

  submitSystemChatVisibility(active: boolean): string {
    return this.#submitCommand({ type: "shell.chat-visibility", active });
  }

  submitSystemCompanionSuppression(active: boolean): string {
    return this.#submitCommand({ type: "shell.companion-suppression", active });
  }

  #submitCommand(command: RuntimeBridgeCommand | RuntimeSystemCommand): string {
    const id = randomUUID();
    const commandDirectory = path.join(this.#launch.directory, "commands");
    mkdirSync(commandDirectory, { recursive: true, mode: 0o700 });
    // Runtime consumes command files in lexical order. Prefix the opaque UUID
    // with a monotonic per-bridge sequence so close/open/select operations from
    // the same Electron window cannot be reordered by random UUID filenames.
    this.#commandSequence += 1;
    const submittedAt = String(Date.now()).padStart(13, "0");
    const sequence = String(this.#commandSequence).padStart(8, "0");
    const destination = path.join(commandDirectory, `${submittedAt}-${sequence}-${id}.json`);
    const temporary = `${destination}.tmp`;
    const message: RuntimeBridgeMessage = { id, token: this.#launch.token, command };
    writeFileSync(temporary, JSON.stringify(message), { encoding: "utf8", mode: 0o600 });
    renameSync(temporary, destination);
    return id;
  }
}
