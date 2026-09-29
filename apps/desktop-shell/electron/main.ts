import { app, BrowserWindow, dialog, ipcMain, net, safeStorage, screen, session, shell, type Session, type WebContents } from "electron";
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync, writeSync } from "node:fs";
import path from "node:path";

import { DEFAULT_SHELL_APPEARANCE, sanitizeShellAppearance, type ShellAppearance } from "../src/contracts/appearance";
import { parseShellIntentArgs, sanitizeShellIntent, shellViews, type ShellIntent, type ShellView } from "../src/contracts/shell-intent";
import { findStoreDeepLinkArg, parseStoreDeepLink, sanitizeStoreDeepLink, type StoreDeepLink } from "../src/contracts/store-deep-link";
import { findInstallHandoffArg, parseInstallHandoff, sanitizeInstallHandoff, type InstallHandoff } from "./install-handoff";
import { CredentialBrokerClient, parseCredentialBrokerLaunch, sanitizeCredentialStoreInput } from "./credential-broker";
import { summarizeProtocolInvocation } from "./protocol-invocation-diagnostic";
import { completeOnboarding, DEFAULT_ONBOARDING_STATE, installHandoffShellView, onboardingCompletionReasons, sanitizeOnboardingState, type OnboardingState } from "./onboarding-state";
import { startStoreLoopbackHandoffServer, type DesktopAuthHandoff, type StoreLoopbackServer } from "./store-loopback-handoff";
import { startStudioOAuthLoopback, type StudioOAuthLoopback } from "./studio-oauth-loopback";
import { FileRuntimeBridge, parseRuntimeBridgeLaunch, projectRuntimeSnapshotForView, resolveRuntimeBridgeLaunch, sanitizeRuntimeBridgeCommand, type RuntimeBridgeLaunch, type RuntimeSnapshot } from "./runtime-bridge";
import { resolveWindowPlacement, sanitizeStoredWindowState, type StoredWindowState } from "./window-state";
import { resolveNativeShellView, viewUsesRuntimePreviewMedia, windowMinimums, windowStateFileName, windowTitles, type NativeShellView } from "./window-configuration";
import { CHAT_WARM_RECLAIM_MS, isRuntimeOwnerShutdownLaunch, isWarmShellLaunch, shouldCloseCharactersWindow, shouldKeepWindowWarmOnClose, shouldQuitRuntimeOwnedShell, shouldReclaimWarmWindow, shouldRevealWindowOnAppActivate } from "./window-lifecycle";
import { isCharacterPreviewActive, isChatPresentationActive, isCompanionSuppressionActive, shouldSynchronizeChatPresentation } from "./chat-focus-policy";
import {
  resolveStudioDevelopmentUrl,
  resolveStudioIndexPath,
  sanitizeStudioOAuthOpenInput,
  sanitizeStudioPackageSaveInput,
  sanitizeStudioPackageSignInput,
  sanitizeStudioProjectSaveInput,
  sanitizeStudioSigningProvisionInput,
  type StudioCloudResponse,
  type StudioEnvironment,
  type StudioOAuthBeginResult,
  type StudioOAuthCallbackResult,
  type StudioPresignedUploadResult,
  type StudioRevealResult,
  type StudioRuntimeTestResult,
  type StudioSaveResult,
  type StudioSignedPackageResult,
  type StudioSigningIdentity,
  type StudioWorkspaceResult,
} from "./studio-bridge";
import {
  createStudioSigningConfiguration,
  resolveStudioSigningConfiguration,
  sanitizeStudioSigningConfiguration,
  signStudioPackageDraft,
  studioSignerExecutablePath,
  studioSigningAvailable,
  studioSigningIdentityFromConfiguration,
} from "./studio-signing";
import {
  resolveStudioCloudApiBase,
  sanitizeStudioCloudRequest,
  sanitizeStudioPresignedUploadInput,
  studioCloudResponseBodyWithinLimit,
} from "./studio-network";

type ShellWindow = Readonly<{ window: BrowserWindow; view: NativeShellView; intent: ShellIntent; lastNormalBounds: StoredWindowState["bounds"]; createdAtMs: number; warm: boolean }>;
const STORE_LOOPBACK_PORT = 47832;
const STUDIO_OAUTH_LOOPBACK_PORT = 47833;
const GEMINI_API_KEYS_URL = "https://aistudio.google.com/api-keys";
const shellProcessStartedAtMs = Date.now();
let storeLoopbackServer: StoreLoopbackServer | null = null;
let studioOAuthLoopback: StudioOAuthLoopback | null = null;
const initialWarmLaunch = isWarmShellLaunch(process.argv.slice(1));
const initialRuntimeOwnerShutdown = isRuntimeOwnerShutdownLaunch(process.argv.slice(1));
let warmRevealRequested = !initialWarmLaunch;
let appQuitting = false;
const initialInstallHandoff = findInstallHandoffArg(process.argv.slice(1));
const initialStoreLink = findStoreDeepLinkArg(process.argv.slice(1));
const initialResult = parseShellIntentArgs(process.argv.slice(1));
let currentIntent: ShellIntent = initialStoreLink
  ? { view: "characters", source: "command-line" }
  : initialInstallHandoff
    ? { view: "home", source: "command-line" }
    : initialResult.ok
      ? initialResult.value
      : { view: "home", source: "command-line" };
let pendingStoreLink: StoreDeepLink | null = initialStoreLink;
let pendingInstallHandoff: InstallHandoff | null = initialInstallHandoff;
const shellWindows = new Map<NativeShellView, ShellWindow>();
const closingShellWindows = new WeakSet<BrowserWindow>();
const saveTimers = new Map<NativeShellView, NodeJS.Timeout>();
const warmReclaimTimers = new Map<NativeShellView, NodeJS.Timeout>();
let appearance: ShellAppearance = DEFAULT_SHELL_APPEARANCE;
let onboardingState: OnboardingState = DEFAULT_ONBOARDING_STATE;
const initialRuntimeBridge = parseRuntimeBridgeLaunch(process.argv.slice(1));
let runtimeBridgeClient = initialRuntimeBridge ? new FileRuntimeBridge(initialRuntimeBridge) : null;
let runtimeNetworkTransferActive = false;
let runtimeSnapshot: RuntimeSnapshot | null = null;
let lastRuntimeAvailability: "connected" | "unavailable" | null = null;
let runtimeConnectionObserved = false;
let runtimeOwnerExitRequested = false;
let consecutiveRuntimeMisses = 0;
let runtimeConnectedTimingLogged = false;
let lastChatPresentationActive: boolean | null = null;
let lastChatPresentationSyncAtMs = 0;
let chatPresentationRepairUntilMs = 0;
const CHAT_PRESENTATION_REPAIR_INTERVAL_MS = 100;
const CHAT_PRESENTATION_REPAIR_WINDOW_MS = 750;
let lastCompanionSuppressionActive: boolean | null = null;
let lastCompanionSuppressionSyncAtMs = 0;
let companionSuppressionRepairUntilMs = 0;
const COMPANION_SUPPRESSION_REPAIR_INTERVAL_MS = 100;
const COMPANION_SUPPRESSION_REPAIR_WINDOW_MS = 750;
const initialCredentialBroker = parseCredentialBrokerLaunch(process.argv.slice(1));
let credentialBrokerClient = initialCredentialBroker ? new CredentialBrokerClient(initialCredentialBroker) : null;
let studioWindow: BrowserWindow | null = null;
let studioWorkspacePath: string | null = null;
let studioLastOutputPath: string | null = null;

// Set a stable product identity before creating the single-instance lock so
// taskbar grouping and Windows shell integration never inherit Electron's
// development defaults in the packaged application.
app.setName("คู่หูบนหน้าจอ");
const softwareRenderingRequested = ["1", "true", "yes", "on"].includes(
  String(process.env.OCP_DESKTOP_SHELL_SOFTWARE_RENDERING ?? "").trim().toLowerCase(),
);
if (softwareRenderingRequested) {
  // Godot owns the real-time animated companion. On Qualcomm/Adreno systems
  // Chromium's D3D12 GPU process can contend for the same unified memory and
  // reset while Character Manager preview media is warming. Keep the shell UI
  // on Chromium's software compositor for those devices; video/source assets
  // and Runtime animation remain unchanged.
  app.disableHardwareAcceleration();
  console.info("[DesktopShell] software rendering enabled for GPU stability");
}
// Keep the display/product name localized, but pin Electron's persistent state
// to a stable ASCII path. This avoids branding/locale changes moving user data
// and keeps scripts/tools reliable on Windows PowerShell 5.1.
const appDataRoot = app.getPath("appData");
const stableUserDataPath = path.join(appDataRoot, "OCP");
const legacyUserDataCandidates = [
  app.getPath("userData"),
  path.join(appDataRoot, "คู่หูบนหน้าจอ"),
  path.join(appDataRoot, "OCP Desktop"),
  path.join(appDataRoot, "@ocp", "desktop-shell"),
].filter((candidate, index, values) =>
  path.resolve(candidate).toLowerCase() !== path.resolve(stableUserDataPath).toLowerCase()
  && values.findIndex((value) => path.resolve(value).toLowerCase() === path.resolve(candidate).toLowerCase()) === index
);
if (!existsSync(stableUserDataPath)) {
  const legacyUserDataPath = legacyUserDataCandidates.find((candidate) => existsSync(candidate));
  if (legacyUserDataPath) {
    try {
      renameSync(legacyUserDataPath, stableUserDataPath);
      console.info(`[DesktopShell] migrated userData ${legacyUserDataPath} -> ${stableUserDataPath}`);
    } catch (error) {
      console.warn("[DesktopShell] userData migration failed; starting with stable OCP profile", error instanceof Error ? error.message : "unknown");
    }
  }
}
// Electron requires an overridden special path to exist before setPath().
mkdirSync(stableUserDataPath, { recursive: true });
app.setPath("userData", stableUserDataPath);
if (process.platform === "win32" && app.isPackaged) {
  // Packaged builds have a stable installed application identity. In development
  // there is no Start-menu shortcut registered for this explicit AppUserModelID;
  // forcing it makes Windows resolve the taskbar group through a missing app
  // identity and fall back to Electron's atom icon even though the window and
  // OCP-Desktop-Dev.exe both carry the OCP icon. Let Windows derive the dev
  // identity from the branded executable instead.
  app.setAppUserModelId("com.opencompanion.desktop");
}
// ADR-0041 / Release Hardening: protocol registration is owned by the
// installer/launcher, not Electron. The installed handler must be able to start
// Runtime first when OCP is not running, then forward the exact ocp:// URI to
// this Shell. Electron therefore receives deep links but never rewrites the
// Windows association to point directly at OCP.exe. Development registration
// remains explicit and user-scoped via register_ocp_dev_protocol.ps1 -Register.
app.on("open-url", (event, url) => {
  event.preventDefault();
  const installHandoff = parseInstallHandoff(url);
  if (installHandoff) {
    pendingInstallHandoff = installHandoff;
    // Before onboarding state is loaded, keep an install callback on Home.
    // app.whenReady() will correct this to Characters for returning users.
    currentIntent = { view: "home", source: "command-line" };
    if (app.isReady()) routeInstallHandoff(installHandoff);
    return;
  }
  const link = parseStoreDeepLink(url);
  if (!link) return;
  pendingStoreLink = link;
  currentIntent = { view: "characters", source: "command-line" };
  if (app.isReady()) routeStoreLink(link);
});
const hasLock = app.requestSingleInstanceLock({
  intent: currentIntent,
  ...(initialRuntimeBridge ? { runtimeBridge: initialRuntimeBridge } : {}),
  ...(initialInstallHandoff ? { installHandoff: initialInstallHandoff } : {}),
  ...(initialStoreLink ? { storeLink: initialStoreLink } : {}),
});
// requestSingleInstanceLock has already delivered this launch intent to the
// primary process before returning false. Exit synchronously so the secondary
// process cannot continue far enough to initialize Chromium's shared disk
// cache while the primary instance still owns it.
if (!hasLock) app.exit(0);
else if (initialRuntimeOwnerShutdown) app.exit(0);
else console.info(`[DesktopShell] runtime-bridge-launch=${initialRuntimeBridge ? "accepted" : "absent"}`);

function windowStatePath(view: NativeShellView): string { return path.join(app.getPath("userData"), windowStateFileName(view)); }
function appearancePath(): string { return path.join(app.getPath("userData"), "desktop-shell-appearance.json"); }
function onboardingPath(): string { return path.join(app.getPath("userData"), "desktop-shell-onboarding.json"); }
function studioDesktopStatePath(): string { return path.join(app.getPath("userData"), "desktop-studio-state.json"); }
function shellIconPath(): string {
  return app.isPackaged
    ? path.join(process.resourcesPath, "assets", "ocp.ico")
    : path.resolve(__dirname, "../../../desktop-runtime/godot/assets/icons/ocp.ico");
}
function resolveStoreUrl(): string | null {
  const raw = process.env.OCP_STORE_URL?.trim();
  if (!raw || raw.length > 2_048) return null;
  try {
    const url = new URL(raw);
    const localHttp = url.protocol === "http:" && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
    if (url.protocol !== "https:" && !localHttp) return null;
    if (url.username || url.password) return null;
    return url.toString();
  } catch { return null; }
}
const storeUrl = resolveStoreUrl();
function readJson(filePath: string): unknown { try { return existsSync(filePath) ? JSON.parse(readFileSync(filePath, "utf8")) : null; } catch { return null; } }
function writeJsonAtomically(filePath: string, value: unknown): void {
  const temporaryPath = `${filePath}.tmp`;
  try { mkdirSync(path.dirname(filePath), { recursive: true }); writeFileSync(temporaryPath, JSON.stringify(value), { encoding: "utf8", mode: 0o600 }); renameSync(temporaryPath, filePath); }
  catch (error) { console.warn("[DesktopShell] state-write-failed", error instanceof Error ? error.message : "unknown"); }
}
function readStudioDesktopState(): void {
  const raw = readJson(studioDesktopStatePath());
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return;
  const source = raw as Record<string, unknown>;
  const workspace = typeof source.workspacePath === "string" && source.workspacePath.length <= 4_096 && path.isAbsolute(source.workspacePath)
    ? path.normalize(source.workspacePath)
    : null;
  studioWorkspacePath = workspace && existsSync(workspace) ? workspace : null;

  const output = typeof source.lastOutputPath === "string" && source.lastOutputPath.length <= 4_096 && path.isAbsolute(source.lastOutputPath)
    ? path.normalize(source.lastOutputPath)
    : null;
  if (!studioWorkspacePath || !output || path.extname(output).toLowerCase() !== ".ocp") {
    studioLastOutputPath = null;
    return;
  }
  const relative = path.relative(studioWorkspacePath, output);
  studioLastOutputPath = relative && !relative.startsWith("..") && !path.isAbsolute(relative) && existsSync(output)
    ? output
    : null;
}
function persistStudioDesktopState(): void {
  writeJsonAtomically(studioDesktopStatePath(), {
    workspacePath: studioWorkspacePath,
    lastOutputPath: studioLastOutputPath,
  });
}
function studioCloudApiBase(): URL {
  return resolveStudioCloudApiBase(process.env.OCP_STUDIO_CLOUD_API_URL);
}
let studioCloudSessionPromise: Promise<Session> | null = null;
function studioCloudSession(): Promise<Session> {
  if (studioCloudSessionPromise !== null) return studioCloudSessionPromise;
  studioCloudSessionPromise = (async () => {
    const cloudSession = session.fromPartition("persist:ocp-studio");
    // Studio Cloud must use Chromium's system-proxy aware network stack. Node's
    // global fetch resolves DNS directly and fails on corporate networks where
    // Internet hostnames are intentionally resolved by the proxy instead.
    await cloudSession.setProxy({ mode: "system" });
    try {
      const proxy = await cloudSession.resolveProxy(studioCloudApiBase().toString());
      console.log(`[OCP Studio Cloud] network proxy: ${proxy || "DIRECT"}`);
    } catch (reason) {
      console.warn("[OCP Studio Cloud] unable to resolve system proxy", reason);
    }
    return cloudSession;
  })().catch((reason) => {
    studioCloudSessionPromise = null;
    throw reason;
  });
  return studioCloudSessionPromise;
}

function uploadStudioPresignedBytes(cloudSession: Session, url: string, bytes: Uint8Array): Promise<number> {
  return new Promise((resolve, reject) => {
    const request = net.request({
      method: "PUT",
      url,
      session: cloudSession,
      redirect: "error",
    });
    request.setHeader("content-type", "application/octet-stream");
    const timeout = setTimeout(() => {
      request.abort();
      reject(new Error("Studio presigned upload timed out"));
    }, 120_000);
    let settled = false;
    const fail = (reason: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      reject(reason instanceof Error ? reason : new Error(String(reason)));
    };
    request.once("error", fail);
    request.once("response", (response) => {
      response.on("data", () => undefined);
      response.once("error", fail);
      response.once("end", () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolve(response.statusCode);
      });
    });
    // Electron forbids applications from setting Content-Length explicitly.
    // Passing the complete Buffer to end() lets Chromium frame the request while
    // avoiding the large-body reset observed with Session.fetch on R2 PUTs.
    request.end(Buffer.from(bytes));
  });
}

async function serviceRuntimeNetworkTransfer(): Promise<void> {
  const bridge = runtimeBridgeClient;
  if (!bridge || runtimeNetworkTransferActive || !bridge.isCommandChannelLive()) return;
  const request = bridge.claimNetworkTransferRequest();
  if (!request) return;
  runtimeNetworkTransferActive = true;
  const temporary = `${request.outputPath}.tmp`;
  const maxBytes = 128 * 1024 * 1024;
  let fileDescriptor: number | null = null;
  try {
    const cloudSession = await studioCloudSession();
    const response = await cloudSession.fetch(request.url, {
      method: "GET",
      headers: { accept: "application/octet-stream" },
      redirect: "error",
      signal: AbortSignal.timeout(10 * 60_000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    if (!response.body) throw new Error("download-body-missing");
    const declaredLength = Number(response.headers.get("content-length") ?? "0");
    if (Number.isFinite(declaredLength) && declaredLength > maxBytes) throw new Error("download-size-out-of-range");

    rmSync(temporary, { force: true });
    fileDescriptor = openSync(temporary, "w", 0o600);
    const reader = response.body.getReader();
    let totalBytes = 0;
    let lastProgressAtMs = Date.now();
    let nextProgressBytes = 5 * 1024 * 1024;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!value || value.byteLength === 0) continue;
        totalBytes += value.byteLength;
        if (totalBytes > maxBytes) throw new Error("download-size-out-of-range");
        const chunk = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
        let offset = 0;
        while (offset < chunk.length) {
          offset += writeSync(fileDescriptor, chunk, offset, chunk.length - offset);
        }
        const now = Date.now();
        if (totalBytes >= nextProgressBytes || now - lastProgressAtMs >= 10_000) {
          console.info(`[DesktopCloudDownload] progress id=${request.id} bytes=${totalBytes}`);
          lastProgressAtMs = now;
          nextProgressBytes = totalBytes + 5 * 1024 * 1024;
        }
      }
    } finally {
      reader.releaseLock();
    }
    if (totalBytes < 1) throw new Error("download-size-out-of-range");
    fsyncSync(fileDescriptor);
    closeSync(fileDescriptor);
    fileDescriptor = null;
    renameSync(temporary, request.outputPath);
    bridge.completeNetworkTransfer(request, { status: "succeeded", bytes: totalBytes });
    console.info(`[DesktopCloudDownload] completed id=${request.id} bytes=${totalBytes}`);
  } catch (reason) {
    if (fileDescriptor !== null) {
      try { closeSync(fileDescriptor); } catch { /* already closed */ }
      fileDescriptor = null;
    }
    rmSync(temporary, { force: true });
    rmSync(request.outputPath, { force: true });
    bridge.completeNetworkTransfer(request, {
      status: "failed",
      error: reason instanceof Error ? reason.message : "network-transfer-failed",
    });
    console.warn(`[DesktopCloudDownload] failed id=${request.id}`, reason);
  } finally {
    runtimeNetworkTransferActive = false;
  }
}

function studioSignerPath(): string {
  // The renamed OCP development Electron executable reports app.isPackaged=true
  // even though process.defaultApp remains true. Keep the signer resolution on
  // the source-tree path in that case, matching studioIndexPath().
  return studioSignerExecutablePath({
    packaged: app.isPackaged && process.defaultApp !== true,
    resourcesPath: process.resourcesPath,
    dirname: __dirname,
    arch: process.arch,
  });
}
function studioSigningSecretPath(): string {
  return path.join(app.getPath("userData"), "studio", "creator-signing.json");
}
type StudioSigningStore = Readonly<{
  activePublisherId: string | null;
  configurations: ReadonlyArray<ReturnType<typeof createStudioSigningConfiguration>>;
}>;
function readProtectedStudioSigningStore(): StudioSigningStore {
  const raw = readJson(studioSigningSecretPath());
  if (typeof raw !== "object" || raw === null || Array.isArray(raw) || !safeStorage.isEncryptionAvailable()) {
    return { activePublisherId: null, configurations: [] };
  }
  const source = raw as Record<string, unknown>;
  if (typeof source.ciphertext !== "string" || (source.version !== 1 && source.version !== 2)) {
    return { activePublisherId: null, configurations: [] };
  }
  try {
    const plaintext = safeStorage.decryptString(Buffer.from(source.ciphertext, "base64"));
    const parsed = JSON.parse(plaintext) as unknown;
    if (source.version === 1) {
      const configuration = sanitizeStudioSigningConfiguration(parsed);
      return configuration
        ? { activePublisherId: configuration.publisherId, configurations: [configuration] }
        : { activePublisherId: null, configurations: [] };
    }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      return { activePublisherId: null, configurations: [] };
    }
    const store = parsed as Record<string, unknown>;
    const rawConfigurations = Array.isArray(store.configurations) ? store.configurations : [];
    const configurations = rawConfigurations
      .map((candidate) => sanitizeStudioSigningConfiguration(candidate))
      .filter((candidate): candidate is ReturnType<typeof createStudioSigningConfiguration> => candidate !== null);
    const requestedActive = typeof store.activePublisherId === "string" ? store.activePublisherId.trim().toLowerCase() : "";
    const activePublisherId = configurations.some((item) => item.publisherId === requestedActive)
      ? requestedActive
      : configurations[0]?.publisherId ?? null;
    return { activePublisherId, configurations };
  } catch (error) {
    console.warn("[OCP Studio] protected signing identities could not be read", error instanceof Error ? error.message : "unknown");
    return { activePublisherId: null, configurations: [] };
  }
}
function writeProtectedStudioSigningStore(store: StudioSigningStore): void {
  if (!safeStorage.isEncryptionAvailable()) throw new Error("Windows protected storage is unavailable for Creator signing");
  const ciphertext = safeStorage.encryptString(JSON.stringify(store)).toString("base64");
  writeJsonAtomically(studioSigningSecretPath(), { version: 2, ciphertext });
}
function studioSigningConfigurationForDesktop(publisherId: string | null = null) {
  const store = readProtectedStudioSigningStore();
  const selectedPublisherId = publisherId?.trim().toLowerCase() || store.activePublisherId;
  const protectedConfiguration = selectedPublisherId
    ? store.configurations.find((item) => item.publisherId === selectedPublisherId) ?? null
    : null;
  if (protectedConfiguration) return protectedConfiguration;
  if (store.configurations.length > 0) return store.configurations[0];
  return resolveStudioSigningConfiguration(process.env, null);
}
function provisionStudioSigningIdentity(publisherId: string): StudioSigningIdentity {
  const normalizedPublisherId = publisherId.trim().toLowerCase();
  const store = readProtectedStudioSigningStore();
  const existing = store.configurations.find((item) => item.publisherId === normalizedPublisherId);
  if (existing) {
    if (store.activePublisherId !== normalizedPublisherId) {
      writeProtectedStudioSigningStore({ ...store, activePublisherId: normalizedPublisherId });
    }
    return studioSigningIdentityFromConfiguration(existing);
  }
  const configuration = createStudioSigningConfiguration(normalizedPublisherId);
  writeProtectedStudioSigningStore({
    activePublisherId: normalizedPublisherId,
    configurations: [...store.configurations, configuration],
  });
  return studioSigningIdentityFromConfiguration(configuration);
}
function studioPublicSigningIdentity(): StudioSigningIdentity | null {
  const configuration = studioSigningConfigurationForDesktop();
  const signerPath = studioSignerPath();
  if (!studioSigningAvailable(configuration, signerPath) || !configuration) return null;
  return studioSigningIdentityFromConfiguration(configuration);
}
function studioEnvironment(): StudioEnvironment {
  const identity = studioPublicSigningIdentity();
  return {
    host: "ocp-desktop",
    workspaceName: studioWorkspacePath ? path.basename(studioWorkspacePath) : null,
    hasLastOutput: Boolean(studioLastOutputPath && existsSync(studioLastOutputPath)),
    runtimeAvailable: runtimeBridgeClient?.isCommandChannelLive() === true,
    signingAvailable: identity !== null,
    signingPublisherId: identity?.publisherId ?? null,
  };
}
function trustedStudioSender(sender: WebContents): boolean {
  return Boolean(studioWindow && !studioWindow.isDestroyed() && studioWindow.webContents === sender);
}

async function chooseStudioWorkspace(): Promise<StudioWorkspaceResult> {
  if (!studioWindow || studioWindow.isDestroyed()) return { status: "cancelled" };
  const result = await dialog.showOpenDialog(studioWindow, {
    title: "Choose OCP Studio Workspace",
    defaultPath: studioWorkspacePath ?? undefined,
    properties: ["openDirectory"],
  });
  if (result.canceled || result.filePaths.length !== 1) return { status: "cancelled" };
  const selected = path.normalize(result.filePaths[0]);
  if (!path.isAbsolute(selected) || selected.length > 4_096 || !existsSync(selected)) return { status: "cancelled" };
  studioWorkspacePath = selected;
  if (studioLastOutputPath) {
    const relative = path.relative(selected, studioLastOutputPath);
    if (!relative || relative.startsWith("..") || path.isAbsolute(relative)) studioLastOutputPath = null;
  }
  persistStudioDesktopState();
  return { status: "selected", workspaceName: path.basename(selected) };
}
async function ensureStudioWorkspace(): Promise<string | null> {
  if (studioWorkspacePath && existsSync(studioWorkspacePath)) return studioWorkspacePath;
  const result = await chooseStudioWorkspace();
  return result.status === "selected" ? studioWorkspacePath : null;
}
function installHandoffStatusPath(): string { return path.join(app.getPath("userData"), "desktop-shell-install-handoff-status.json"); }
function protocolInvocationStatusPath(): string { return path.join(app.getPath("userData"), "desktop-shell-protocol-invocation-status.json"); }
function recordInstallHandoffStatus(stage: string, handoff: InstallHandoff, extra: Record<string, unknown> = {}): void {
  writeJsonAtomically(installHandoffStatusPath(), {
    observedAt: new Date().toISOString(),
    stage,
    packageId: handoff.packageId,
    version: handoff.version,
    runtimeBridgeAttached: runtimeBridgeClient !== null,
    ...extra,
  });
}
function readWindowState(view: NativeShellView): StoredWindowState | null { return sanitizeStoredWindowState(readJson(windowStatePath(view))); }
function flushWindowState(view: NativeShellView): void {
  const record = shellWindows.get(view); if (!record) return;
  writeJsonAtomically(windowStatePath(view), { bounds: record.lastNormalBounds, maximized: record.window.isMaximized() } satisfies StoredWindowState);
}
function scheduleWindowStateSave(view: NativeShellView): void {
  const record = shellWindows.get(view);
  if (!record || record.window.isMaximized() || record.window.isMinimized()) return;
  shellWindows.set(view, { ...record, lastNormalBounds: record.window.getBounds() });
  const existing = saveTimers.get(view); if (existing) clearTimeout(existing);
  saveTimers.set(view, setTimeout(() => flushWindowState(view), 180));
}

function clearWarmReclaim(view: NativeShellView): void {
  const existing = warmReclaimTimers.get(view);
  if (existing) clearTimeout(existing);
  warmReclaimTimers.delete(view);
}

function scheduleWarmReclaim(record: ShellWindow): void {
  clearWarmReclaim(record.view);
  if (!shouldReclaimWarmWindow(
    runtimeBridgeClient !== null,
    appQuitting,
    record.view,
    record.warm,
    record.window.isVisible(),
  )) return;

  const targetWindow = record.window;
  warmReclaimTimers.set(record.view, setTimeout(() => {
    warmReclaimTimers.delete(record.view);
    const latest = shellWindows.get(record.view);
    if (!latest || latest.window !== targetWindow || latest.window.isDestroyed()) return;
    if (!shouldReclaimWarmWindow(
      runtimeBridgeClient !== null,
      appQuitting,
      latest.view,
      latest.warm,
      latest.window.isVisible(),
    )) return;
    console.info(`[DesktopShellMemory] reclaim-warm view=${latest.view} hidden_ms=${CHAT_WARM_RECLAIM_MS}`);
    latest.window.destroy();
  }, CHAT_WARM_RECLAIM_MS));
}

function senderWindow(sender: WebContents): ShellWindow | undefined { return [...shellWindows.values()].find((record) => record.window.webContents === sender); }

function shellCompanionSuppressionRequired(excludingView?: NativeShellView): boolean {
  return (["home", "characters"] as const).some((view) => {
    if (view === excludingView) return false;
    const record = shellWindows.get(view);
    return Boolean(record && isCompanionSuppressionActive({
      view: record.view,
      visible: record.window.isVisible(),
      focused: record.window.isFocused(),
      minimized: record.window.isMinimized(),
    }));
  });
}

function releaseChatPresentationFastPath(): void {
  if (!runtimeBridgeClient) return;
  const nowMs = Date.now();
  try {
    // Close must release native ownership immediately, independent of Chat turn,
    // preview, or Runtime snapshot cadence. Runtime acknowledgement/self-heal
    // still runs through syncChatPresentation().
    runtimeBridgeClient.submitSystemChatVisibility(false);
    lastChatPresentationActive = false;
    lastChatPresentationSyncAtMs = nowMs;
    chatPresentationRepairUntilMs = nowMs + CHAT_PRESENTATION_REPAIR_WINDOW_MS;
  } catch {
    console.warn("[DesktopShell] chat-close-fast-path-failed");
  }
}

function syncChatPresentation(): void {
  const characters = shellWindows.get("characters");
  // Window visibility is the presentation truth. The warm flag is only a
  // lifecycle/reuse hint and can briefly lag a reveal request; using it here
  // could leave a visibly open Chat stuck with Runtime owner=native and a
  // paused idle frame.
  const characterPreviewActive = Boolean(characters && isCharacterPreviewActive({
    view: characters.view,
    visible: characters.window.isVisible(),
    focused: characters.window.isFocused(),
    minimized: characters.window.isMinimized(),
  }));

  const record = shellWindows.get("chat");
  const active = record ? isChatPresentationActive({
    view: record.view,
    visible: record.window.isVisible(),
    focused: record.window.isFocused(),
    minimized: record.window.isMinimized(),
  }, characterPreviewActive, closingShellWindows.has(record.window)) : false;
  if (!runtimeBridgeClient) return;
  const nowMs = Date.now();
  const runtimeOwner = runtimeSnapshot?.chat.presentation?.owner;
  const chatPresentationChanged = lastChatPresentationActive !== active;
  if (chatPresentationChanged) chatPresentationRepairUntilMs = nowMs + CHAT_PRESENTATION_REPAIR_WINDOW_MS;
  const chatRepairDue = nowMs < chatPresentationRepairUntilMs
    && shouldSynchronizeChatPresentation(
      active,
      lastChatPresentationActive,
      runtimeOwner,
      nowMs,
      lastChatPresentationSyncAtMs,
      CHAT_PRESENTATION_REPAIR_INTERVAL_MS,
    );
  if (chatPresentationChanged || chatRepairDue) {
    try {
      runtimeBridgeClient.submitSystemChatVisibility(active);
      lastChatPresentationActive = active;
      lastChatPresentationSyncAtMs = nowMs;
    } catch {
      console.warn("[DesktopShell] chat-presentation-sync-failed");
    }
  }
  if (runtimeOwner !== undefined && (runtimeOwner === "chat") === active) {
    chatPresentationRepairUntilMs = 0;
  }

  // Home/Settings and Character Manager are full shell safe-zones. Character
  // Manager owns an isolated inline preview, so the native companion stays hidden
  // while the manager is visible and is restored with the newly active character
  // as soon as the surface closes or minimizes.
  const suppressCompanion = shellCompanionSuppressionRequired();
  // System visibility commands cross an atomic file bridge. Send a short,
  // bounded repair burst after each state transition so a delayed/missed write
  // cannot leave the native companion hidden for minutes. Do not keep polling
  // forever while Desktop is idle.
  const suppressionChanged = lastCompanionSuppressionActive !== suppressCompanion;
  if (suppressionChanged) companionSuppressionRepairUntilMs = nowMs + COMPANION_SUPPRESSION_REPAIR_WINDOW_MS;
  const suppressionRepairDue = nowMs < companionSuppressionRepairUntilMs
    && nowMs - lastCompanionSuppressionSyncAtMs >= COMPANION_SUPPRESSION_REPAIR_INTERVAL_MS;
  if (suppressionChanged || suppressionRepairDue) {
    try {
      runtimeBridgeClient.submitSystemCompanionSuppression(suppressCompanion);
      lastCompanionSuppressionActive = suppressCompanion;
      lastCompanionSuppressionSyncAtMs = nowMs;
    } catch {
      console.warn("[DesktopShell] companion-suppression-sync-failed");
    }
  }
}
function sendIntent(record: ShellWindow, intent: ShellIntent): void {
  const deliver = (): void => record.window.webContents.send("ocp:shell-intent", intent);
  if (record.window.webContents.isLoadingMainFrame()) record.window.webContents.once("did-finish-load", deliver); else deliver();
}
function sendStoreLink(record: ShellWindow, link: StoreDeepLink): void {
  const deliver = (): void => record.window.webContents.send("ocp:store-link", link);
  if (record.window.webContents.isLoadingMainFrame()) record.window.webContents.once("did-finish-load", deliver); else deliver();
}
function routeStoreLink(link: StoreDeepLink): void {
  pendingStoreLink = link;
  const intent: ShellIntent = { view: "characters", source: shellWindows.has("characters") ? "second-instance" : "command-line" };
  routeIntent(intent);
  const record = shellWindows.get("characters");
  if (record) sendStoreLink(record, link);
}

function trySubmitInstallHandoff(): void {
  if (!pendingInstallHandoff) return;
  if (!runtimeBridgeClient) {
    recordInstallHandoffStatus("waiting-runtime-bridge", pendingInstallHandoff);
    return;
  }
  const handoff = pendingInstallHandoff;
  const commandId = runtimeBridgeClient.submitSystemInstallHandoff(handoff);
  recordInstallHandoffStatus("submitted-runtime-bridge", handoff, { commandId });
  pendingInstallHandoff = null;
}

function routeInstallHandoff(link: InstallHandoff): void {
  pendingInstallHandoff = link;
  recordInstallHandoffStatus("received", link);
  // A Store/install callback arriving during First Run must stay inside the
  // existing Home window. Opening Characters would create a second native
  // window, and that renderer would also see the incomplete onboarding state.
  // Returning users still get the normal Character Manager route.
  const target: ShellView = installHandoffShellView(onboardingState);
  const nativeTarget = resolveNativeShellView(target);
  const intent: ShellIntent = { view: target, source: shellWindows.has(nativeTarget) ? "second-instance" : "command-line" };
  routeIntent(intent);
  trySubmitInstallHandoff();
}

function routeDesktopAuthHandoff(handoff: DesktopAuthHandoff): void {
  if (!runtimeBridgeClient || !runtimeBridgeClient.isCommandChannelLive()) throw new Error("runtime unavailable");
  runtimeBridgeClient.submitSystemAuthHandoff(handoff);
  console.info("[DesktopShell] account-auth-handoff=submitted-runtime-bridge");
}

function configuredStoreLoopbackOrigins(): Set<string> {
  const origins = new Set<string>();
  if (!app.isPackaged) {
    origins.add("http://127.0.0.1:5173");
    origins.add("http://localhost:5173");
  }
  const configured = process.env.OCP_STORE_LOOPBACK_ORIGINS?.split(",") ?? [];
  for (const candidate of configured) {
    const raw = candidate.trim();
    if (!raw) continue;
    try {
      const url = new URL(raw);
      const localHttp = url.protocol === "http:" && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
      if ((url.protocol !== "https:" && !localHttp) || url.username || url.password || url.search || url.hash || url.pathname !== "/") continue;
      origins.add(url.origin);
    } catch {
      continue;
    }
  }
  return origins;
}

async function startStoreLoopbackReceiver(): Promise<void> {
  const allowedOrigins = configuredStoreLoopbackOrigins();
  if (allowedOrigins.size === 0) return;
  try {
    storeLoopbackServer = await startStoreLoopbackHandoffServer({
      port: STORE_LOOPBACK_PORT,
      allowedOrigins,
      runtimeAvailable: () => runtimeBridgeClient?.isCommandChannelLive() === true,
      runtimeState: () => ({
        runtimeAvailable: runtimeBridgeClient?.isCommandChannelLive() === true && runtimeSnapshot !== null,
        characters: runtimeSnapshot?.characters.map((character) => ({
          packageId: character.packageId,
          version: character.version,
          active: character.active,
        })) ?? [],
        effectPacks: runtimeSnapshot?.effectPacks?.installed.map((pack) => ({
          packageId: pack.packageId,
          version: pack.version,
        })) ?? [],
        download: runtimeSnapshot?.cloud ? {
          status: runtimeSnapshot.cloud.download.status,
          packageId: runtimeSnapshot.cloud.download.packageId,
          version: runtimeSnapshot.cloud.download.version,
        } : null,
      }),
      onHandoff: routeInstallHandoff,
      onAuthHandoff: routeDesktopAuthHandoff,
    });
    console.info(`[DesktopShell] store-loopback-ready port=${storeLoopbackServer.port}`);
  } catch (error) {
    console.warn("[DesktopShell] store-loopback-unavailable", error instanceof Error ? error.message : "unknown");
  }
}
function focusWindow(record: ShellWindow, intent: ShellIntent, requestedAtMs = Date.now()): void {
  clearWarmReclaim(record.view);
  shellWindows.set(record.view, { ...record, intent, warm: false });
  if (record.window.isMinimized()) record.window.restore();
  const storedState = readWindowState(record.view);
  if (storedState?.maximized && !record.window.isMaximized()) record.window.maximize();
  else record.window.show();
  record.window.focus();
  sendIntent(record, intent);
  sendRuntimeSnapshotToWindow(record);
  console.info(`[DesktopShellTiming] reveal view=${record.view} request_to_show_ms=${Date.now() - requestedAtMs} process_age_ms=${Date.now() - shellProcessStartedAtMs}`);
}
function createWindow(intent: ShellIntent, showWhenReady = true): ShellWindow {
  const view = resolveNativeShellView(intent.view);
  const displays = screen.getAllDisplays().map((display) => ({ id: String(display.id), workArea: display.workArea }));
  const placement = resolveWindowPlacement(readWindowState(view), displays, intent.displayPoint);
  const minimum = windowMinimums[view];
  const window = new BrowserWindow({
    ...placement.bounds, minWidth: minimum.width, minHeight: minimum.height, title: windowTitles[view],
    frame: true, resizable: true, minimizable: true, maximizable: true, fullscreenable: false, transparent: false, backgroundColor: "#050a14", show: false, autoHideMenuBar: true, icon: shellIconPath(),
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true, allowRunningInsecureContent: false },
  });
  const createdAtMs = Date.now();
  const record: ShellWindow = { window, view, intent, lastNormalBounds: placement.bounds, createdAtMs, warm: !showWhenReady }; shellWindows.set(view, record);
  window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.on("move", () => scheduleWindowStateSave(view)); window.on("resize", () => scheduleWindowStateSave(view));
  window.on("focus", syncChatPresentation); window.on("blur", syncChatPresentation);
  window.on("show", syncChatPresentation); window.on("hide", syncChatPresentation);
  window.on("minimize", syncChatPresentation); window.on("restore", syncChatPresentation);
  window.on("maximize", () => flushWindowState(view)); window.on("unmaximize", () => scheduleWindowStateSave(view));
  window.on("close", (event) => {
    // Release Chat presentation before BrowserWindow teardown. This avoids
    // waiting for the `closed` event, Runtime snapshot polling, or an in-flight
    // chat turn before the native companion can reappear.
    if (view === "chat" && !appQuitting) {
      closingShellWindows.add(window);
      releaseChatPresentationFastPath();
    }
    flushWindowState(view);
    if (shouldKeepWindowWarmOnClose(runtimeBridgeClient !== null, appQuitting, view)) {
      event.preventDefault();
      const latest = shellWindows.get(view) ?? record;
      const warmRecord = { ...latest, warm: true };
      shellWindows.set(view, warmRecord);
      window.hide();
      syncChatPresentation();
      scheduleWarmReclaim(warmRecord);
      console.info(`[DesktopShellTiming] warm-hide view=${view} process_age_ms=${Date.now() - shellProcessStartedAtMs}`);
    }
  });
  window.on("closed", () => {
    closingShellWindows.delete(window);
    shellWindows.delete(view);
    const timer = saveTimers.get(view); if (timer) clearTimeout(timer);
    saveTimers.delete(view);
    clearWarmReclaim(view);
    syncChatPresentation();
  });
  window.webContents.once("did-finish-load", () => {
    console.info(`[DesktopShellTiming] renderer_ready view=${view} create_to_renderer_ms=${Date.now() - createdAtMs} process_ms=${Date.now() - shellProcessStartedAtMs}`);
  });
  window.once("ready-to-show", () => {
    console.info(`[DesktopShellTiming] window_ready view=${view} create_to_ready_ms=${Date.now() - createdAtMs} warm=${!showWhenReady}`);
    // Never maximize a warm hidden BrowserWindow. On Windows maximize() can
    // surface a show:false window, which defeated warm-up and opened Chat at
    // startup whenever the previous session had saved a maximized state.
    if (showWhenReady) {
      if (placement.maximized) window.maximize();
      else window.show();
    } else {
      const latest = shellWindows.get(view) ?? record;
      scheduleWarmReclaim(latest);
    }
  });
  const developmentUrl = process.env.OCP_SHELL_DEV_URL;
  if (developmentUrl?.startsWith("http://127.0.0.1:5173")) void window.loadURL(developmentUrl); else void window.loadFile(path.join(__dirname, "../../dist-renderer/index.html"));
  return record;
}
function studioIndexPath(): string {
  // The development launcher uses an OCP-branded copy of electron.exe.
  // Electron reports app.isPackaged=true for that renamed executable even
  // though process.defaultApp remains true. Use defaultApp as the source-tree
  // signal so Studio resolves to apps/animation-studio/app/dist in development,
  // while real packaged builds continue to use resources/studio.
  return resolveStudioIndexPath({
    defaultApp: process.defaultApp === true,
    resourcesPath: process.resourcesPath,
    moduleDir: __dirname,
  });
}

async function loadAnimationStudioContent(window: BrowserWindow): Promise<void> {
  const localIndex = studioIndexPath();
  const developmentUrl = resolveStudioDevelopmentUrl(process.env.OCP_STUDIO_DEV_URL);

  // OCP_STUDIO_DEV_URL is intentionally optional. A stale inherited value must
  // never strand Studio on an empty BrowserWindow when the Vite dev server is
  // not running; fall back to the bundled/local production build immediately.
  if (developmentUrl) {
    try {
      await window.loadURL(developmentUrl);
      console.info("[OCP Studio] loaded development URL", developmentUrl);
      return;
    } catch (error) {
      console.warn("[OCP Studio] development URL unavailable; falling back to local build", {
        developmentUrl,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  if (!existsSync(localIndex)) {
    const message = `Animation Studio UI files were not found at resolved path: ${localIndex}`;
    console.error("[OCP Studio]", message);
    const html = `<!doctype html><meta charset="utf-8"><title>OCP Animation Studio</title><style>body{margin:0;background:#07111f;color:#dcecff;font:16px system-ui;display:grid;place-items:center;height:100vh}.card{max-width:760px;padding:28px;border:1px solid #24456a;border-radius:16px;background:#0b1b2d}code{display:block;margin-top:12px;color:#7fdbff;overflow-wrap:anywhere}</style><div class="card"><h1>OCP Animation Studio</h1><p>Studio UI could not be loaded for this launcher.</p><p>Resolved path:</p><code>${localIndex.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")}</code><p>For a source checkout, rebuild with:</p><code>npm --prefix apps/animation-studio/app run build</code></div>`;
    await window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`);
    return;
  }

  try {
    await window.loadFile(localIndex);
    console.info("[OCP Studio] loaded local build", localIndex);
  } catch (error) {
    console.error("[OCP Studio] failed to load local build", {
      localIndex,
      error: error instanceof Error ? error.message : String(error),
    });
    throw error;
  }
}

function openAnimationStudioWindow(): void {
  if (studioWindow && !studioWindow.isDestroyed()) {
    if (studioWindow.isMinimized()) studioWindow.restore();
    studioWindow.show();
    studioWindow.focus();
    return;
  }

  const window = new BrowserWindow({
    width: 1480,
    height: 920,
    minWidth: 1100,
    minHeight: 720,
    title: "OCP Animation Studio",
    frame: true,
    resizable: true,
    minimizable: true,
    maximizable: true,
    fullscreenable: false,
    transparent: false,
    backgroundColor: "#07111f",
    show: false,
    autoHideMenuBar: true,
    icon: shellIconPath(),
    webPreferences: {
      preload: path.join(__dirname, "studio-preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      partition: "persist:ocp-studio",
    },
  });
  studioWindow = window;

  window.webContents.setWindowOpenHandler(({ url }) => {
    if (url === "about:blank") {
      return {
        action: "allow",
        overrideBrowserWindowOptions: {
          autoHideMenuBar: true,
          webPreferences: {
            contextIsolation: true,
            nodeIntegration: false,
            sandbox: true,
            webSecurity: true,
            allowRunningInsecureContent: false,
            partition: "persist:ocp-studio",
          },
        },
      };
    }
    try {
      const target = new URL(url);
      if (target.protocol === "https:" || (target.protocol === "http:" && (target.hostname === "127.0.0.1" || target.hostname === "localhost"))) {
        void shell.openExternal(target.toString());
      }
    } catch {
      // Invalid/unsupported URLs remain blocked.
    }
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event) => event.preventDefault());
  window.webContents.on("will-attach-webview", (event) => event.preventDefault());
  window.webContents.session.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
  window.webContents.session.setPermissionCheckHandler(() => false);
  window.on("closed", () => {
    if (studioWindow === window) studioWindow = null;
  });

  void loadAnimationStudioContent(window).then(() => {
    if (window.isDestroyed()) return;
    window.show();
    window.focus();
  }).catch((error) => {
    console.error("[OCP Studio] window load failed", error);
    if (!window.isDestroyed()) window.show();
  });
}

function routeIntent(intent: ShellIntent, showWhenReady = true, requestedAtMs = Date.now()): void {
  currentIntent = intent;
  const nativeView = resolveNativeShellView(intent.view);
  const existing = shellWindows.get(nativeView);
  if (existing) {
    if (showWhenReady) focusWindow(existing, intent, requestedAtMs);
    else {
      const warmRecord = { ...existing, intent, warm: true };
      shellWindows.set(existing.view, warmRecord);
      sendIntent(warmRecord, intent);
      scheduleWarmReclaim(warmRecord);
    }
  } else createWindow(intent, showWhenReady);
}
function persistAppearance(next: ShellAppearance): void { appearance = next; writeJsonAtomically(appearancePath(), appearance); for (const record of shellWindows.values()) record.window.webContents.send("ocp:appearance-changed", appearance); }
function persistOnboarding(next: OnboardingState): void { onboardingState = next; writeJsonAtomically(onboardingPath(), onboardingState); }
function sendRuntimeSnapshotToWindow(record: ShellWindow): void {
  if (record.window.isDestroyed()) return;
  record.window.webContents.send("ocp:runtime-state", projectRuntimeSnapshotForView(runtimeSnapshot, viewUsesRuntimePreviewMedia(record.view)));
}
function refreshRuntimeSnapshot(): void {
  void serviceRuntimeNetworkTransfer();
  const previousRuntimeState = runtimeSnapshot ? { connected: true, characterCount: runtimeSnapshot.characters.length } : null;
  runtimeSnapshot = runtimeBridgeClient?.readSnapshot() ?? null;
  runtimeConnectionObserved ||= runtimeSnapshot !== null;
  consecutiveRuntimeMisses = runtimeSnapshot ? 0 : consecutiveRuntimeMisses + 1;
  const nextRuntimeState = { connected: runtimeSnapshot !== null, characterCount: runtimeSnapshot?.characters.length ?? 0 };
  if (shouldCloseCharactersWindow(previousRuntimeState, nextRuntimeState)) shellWindows.get("characters")?.window.close();
  const availability = runtimeSnapshot ? "connected" : "unavailable";
  if (availability !== lastRuntimeAvailability) {
    console.info(`[DesktopShell] runtime-state=${availability}`);
    lastRuntimeAvailability = availability;
  }
  if (runtimeSnapshot && !runtimeConnectedTimingLogged) {
    runtimeConnectedTimingLogged = true;
    console.info(`[DesktopShellTiming] runtime_connected process_ms=${Date.now() - shellProcessStartedAtMs}`);
  }
  const ownerLossConfirmed = consecutiveRuntimeMisses >= 4;
  if (!runtimeOwnerExitRequested && shouldQuitRuntimeOwnedShell(runtimeBridgeClient !== null, runtimeConnectionObserved, !ownerLossConfirmed)) {
    runtimeOwnerExitRequested = true;
    console.info("[DesktopShell] runtime-owner-lost; exiting authenticated shell");
    app.quit();
    return;
  }
  for (const record of shellWindows.values()) {
    // Warm hidden windows stay mounted for instant reopen, but pushing the
    // Runtime snapshot into them forces React to reconcile a large hidden UI
    // every poll. Skip hidden/minimized renderers and push the latest snapshot
    // synchronously from focusWindow() when the user reveals one again.
    if (!record.window.isVisible() || record.window.isMinimized()) continue;
    sendRuntimeSnapshotToWindow(record);
  }
  // Visibility events can happen before the Runtime bridge becomes writable
  // (especially the warm Chat window). Reconcile ownership on the normal
  // snapshot cadence so a visible Chat self-heals from native/paused preview
  // state instead of staying on a static frame forever.
  syncChatPresentation();
}
function scheduleRuntimeSnapshotPoll(): void {
  const charactersWindow = shellWindows.get("characters")?.window;
  const chatWindow = shellWindows.get("chat")?.window;
  const charactersVisible = Boolean(charactersWindow && !charactersWindow.isDestroyed() && charactersWindow.isVisible() && !charactersWindow.isMinimized());
  const chatVisible = Boolean(chatWindow && !chatWindow.isDestroyed() && chatWindow.isVisible() && !chatWindow.isMinimized());
  const previewVisible = charactersVisible || chatVisible;
  const previewActive = previewVisible && Boolean(runtimeSnapshot?.preview.isPlaying || runtimeSnapshot?.preview.status === "loading");
  // Character Manager keeps 20 FPS for editing. Chat only needs 10 FPS for its
  // companion card; halving its snapshot cadence reduces file/React pressure
  // while a turn is streaming and keeps close/reveal commands responsive.
  const pollMs = previewActive ? (charactersVisible ? 50 : 100) : previewVisible ? 250 : 500;
  const timer = setTimeout(() => {
    refreshRuntimeSnapshot();
    scheduleRuntimeSnapshotPoll();
  }, pollMs);
  timer.unref();
}
function setRuntimeBridgeLaunch(next: RuntimeBridgeLaunch | null): void {
  if (!next) return;
  runtimeBridgeClient = new FileRuntimeBridge(next);
  lastChatPresentationActive = null;
  lastChatPresentationSyncAtMs = 0;
  runtimeConnectionObserved = false;
  runtimeOwnerExitRequested = false;
  consecutiveRuntimeMisses = 0;
  runtimeConnectedTimingLogged = false;
  refreshRuntimeSnapshot();
  trySubmitInstallHandoff();
  syncChatPresentation();
}
function setCredentialBroker(args: readonly string[]): void {
  const next = parseCredentialBrokerLaunch(args);
  if (next) credentialBrokerClient = new CredentialBrokerClient(next);
}

ipcMain.handle("ocp:get-bootstrap", (event) => { const record = senderWindow(event.sender); if (!record) throw new Error("untrusted renderer"); return { intent: record.intent, platform: process.platform, runtimeBridge: runtimeSnapshot ? "connected" : "unavailable", appearance, storeUrl, storeLink: pendingStoreLink, onboarding: onboardingState } as const; });
ipcMain.handle("ocp:complete-onboarding", (event, reason: unknown) => {
  if (!senderWindow(event.sender) || typeof reason !== "string" || !onboardingCompletionReasons.includes(reason as (typeof onboardingCompletionReasons)[number])) throw new Error("invalid onboarding completion request");
  const next = completeOnboarding(reason as (typeof onboardingCompletionReasons)[number]);
  persistOnboarding(next);
  return next;
});
ipcMain.handle("ocp:open-view", (event, view: unknown) => { if (!senderWindow(event.sender) || !shellViews.includes(view as ShellView)) throw new Error("invalid view request"); routeIntent({ view: view as ShellView, source: "shell-navigation" }); });
ipcMain.handle("ocp:open-animation-studio", (event) => {
  if (!senderWindow(event.sender)) throw new Error("untrusted renderer");
  openAnimationStudioWindow();
});
ipcMain.handle("ocp:studio:get-environment", (event): StudioEnvironment => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  return studioEnvironment();
});
ipcMain.handle("ocp:studio:oauth-begin", async (event): Promise<StudioOAuthBeginResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const previous = studioOAuthLoopback;
  studioOAuthLoopback = null;
  if (previous) await previous.close().catch(() => undefined);
  const loopback = await startStudioOAuthLoopback(STUDIO_OAUTH_LOOPBACK_PORT);
  studioOAuthLoopback = loopback;
  console.info("[OCP Studio] OAuth loopback ready", loopback.redirectUrl);
  return { redirectUrl: loopback.redirectUrl };
});
ipcMain.handle("ocp:studio:oauth-open", async (event, candidate: unknown): Promise<void> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  if (!studioOAuthLoopback) throw new Error("Studio OAuth callback is not active");
  const input = sanitizeStudioOAuthOpenInput(candidate);
  if (!input) throw new Error("invalid Studio OAuth URL");
  await shell.openExternal(input.url);
});
ipcMain.handle("ocp:studio:oauth-wait", async (event): Promise<StudioOAuthCallbackResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const loopback = studioOAuthLoopback;
  if (!loopback) return { status: "error", error: "Studio OAuth callback is not active" };

  // Return the callback result to the renderer before waiting for HTTP server
  // teardown. Browser keep-alive sockets previously made server.close() wait,
  // leaving Studio stuck at "Not signed in" even though Chrome displayed the
  // successful callback page.
  const result = await loopback.waitForCallback();
  if (studioOAuthLoopback === loopback) studioOAuthLoopback = null;
  void loopback.close().catch((error) => {
    console.warn("[OCP Studio] OAuth loopback close degraded", error instanceof Error ? error.message : String(error));
  });
  return result;
});
ipcMain.handle("ocp:studio:choose-workspace", async (event): Promise<StudioWorkspaceResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  return await chooseStudioWorkspace();
});
ipcMain.handle("ocp:studio:save-project", async (event, candidate: unknown): Promise<StudioSaveResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const input = sanitizeStudioProjectSaveInput(candidate);
  if (!input) throw new Error("invalid Studio project save request");
  const workspace = await ensureStudioWorkspace();
  if (!workspace) return { status: "cancelled" };
  const target = path.join(workspace, input.fileName);
  writeFileSync(target, input.content, { encoding: "utf8", mode: 0o600 });
  return { status: "saved", fileName: input.fileName, workspaceName: path.basename(workspace) };
});
ipcMain.handle("ocp:studio:save-package", async (event, candidate: unknown): Promise<StudioSaveResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const input = sanitizeStudioPackageSaveInput(candidate);
  if (!input) throw new Error("invalid Studio package save request");
  const workspace = await ensureStudioWorkspace();
  if (!workspace) return { status: "cancelled" };
  const outputDirectory = path.join(workspace, "build");
  mkdirSync(outputDirectory, { recursive: true });
  const target = path.join(outputDirectory, input.fileName);
  writeFileSync(target, Buffer.from(input.bytes), { mode: 0o600 });
  studioLastOutputPath = target;
  persistStudioDesktopState();
  console.log(`[OCP Studio] package saved: ${target} (${input.bytes.byteLength} bytes)`);
  return { status: "saved", fileName: input.fileName, workspaceName: path.basename(workspace) };
});
ipcMain.handle("ocp:studio:get-signing-identity", (event): StudioSigningIdentity => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const identity = studioPublicSigningIdentity();
  if (!identity) throw new Error("OCP Studio signing is not configured for this Desktop");
  return identity;
});
ipcMain.handle("ocp:studio:provision-signing-identity", (event, candidate: unknown): StudioSigningIdentity => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const input = sanitizeStudioSigningProvisionInput(candidate);
  if (!input) throw new Error("invalid Studio signing provisioning request");
  return provisionStudioSigningIdentity(input.publisherId);
});
ipcMain.handle("ocp:studio:sign-package-draft", (event, candidate: unknown): StudioSignedPackageResult => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const input = sanitizeStudioPackageSignInput(candidate);
  if (!input) throw new Error("invalid Studio signing request");
  const configuration = studioSigningConfigurationForDesktop();
  const signerPath = studioSignerPath();
  if (!configuration || !studioSigningAvailable(configuration, signerPath)) {
    throw new Error("OCP Studio signing is not configured for this Desktop");
  }
  return { bytes: signStudioPackageDraft(input.bytes, configuration, signerPath) };
});
ipcMain.handle("ocp:studio:cloud-request", async (event, candidate: unknown): Promise<StudioCloudResponse> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const input = sanitizeStudioCloudRequest(candidate, studioCloudApiBase());
  if (!input) throw new Error("invalid Studio Cloud request");

  const headers = new Headers({ accept: "application/json" });
  headers.set("authorization", ["Bearer", input.accessToken].join(" "));
  if (input.body !== null) headers.set("content-type", "application/json");

  const cloudSession = await studioCloudSession();
  const response = await cloudSession.fetch(input.url, {
    method: input.method,
    headers,
    body: input.body ?? undefined,
    redirect: "error",
    signal: AbortSignal.timeout(30_000),
  });
  const bodyText = await response.text();
  if (!studioCloudResponseBodyWithinLimit(bodyText)) {
    throw new Error("Studio Cloud response exceeded the allowed size");
  }
  return {
    status: response.status,
    contentType: response.headers.get("content-type") ?? "application/json",
    bodyText,
  };
});
ipcMain.handle("ocp:studio:upload-presigned", async (event, candidate: unknown): Promise<StudioPresignedUploadResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  const input = sanitizeStudioPresignedUploadInput(candidate);
  if (!input) throw new Error("invalid Studio presigned upload request");

  const cloudSession = await studioCloudSession();
  const status = await uploadStudioPresignedBytes(cloudSession, input.url, input.bytes);
  return { status };
});
ipcMain.handle("ocp:studio:reveal-last-output", async (event): Promise<StudioRevealResult> => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  if (!studioLastOutputPath || !existsSync(studioLastOutputPath)) {
    studioLastOutputPath = null;
    persistStudioDesktopState();
    return { status: "no-output" };
  }
  shell.showItemInFolder(studioLastOutputPath);
  return { status: "revealed", fileName: path.basename(studioLastOutputPath) };
});
ipcMain.handle("ocp:studio:install-last-build-to-runtime", (event): StudioRuntimeTestResult => {
  if (!trustedStudioSender(event.sender)) throw new Error("untrusted Studio renderer");
  if (!studioLastOutputPath || !existsSync(studioLastOutputPath)) {
    studioLastOutputPath = null;
    persistStudioDesktopState();
    return { status: "no-output" };
  }
  if (!runtimeBridgeClient || !runtimeBridgeClient.isCommandChannelLive()) return { status: "runtime-unavailable" };
  const requestId = runtimeBridgeClient.submitSystemLocalInstall(studioLastOutputPath);
  routeIntent({ view: "characters", source: "shell-navigation" });
  return { status: "submitted", requestId, fileName: path.basename(studioLastOutputPath) };
});
ipcMain.handle("ocp:open-store", async (event) => { if (!senderWindow(event.sender) || !storeUrl) throw new Error("store unavailable"); await shell.openExternal(storeUrl); });
ipcMain.handle("ocp:confirm-character-uninstall", async (event, candidate: unknown) => {
  const record = senderWindow(event.sender);
  if (!record || record.view !== "characters" || !candidate || typeof candidate !== "object") return false;
  const input = candidate as { name?: unknown; active?: unknown; locale?: unknown };
  const name = typeof input.name === "string" ? input.name.trim().slice(0, 120) : "";
  const active = input.active === true;
  const locale = input.locale === "th" ? "th" : "en";
  if (!name) return false;
  const thai = locale === "th";
  const result = await dialog.showMessageBox(record.window, {
    type: "warning",
    title: thai ? "ถอนการติดตั้งตัวละคร?" : "Uninstall character?",
    message: thai ? `นำ ${name} ออกจากเครื่องนี้หรือไม่?` : `Remove ${name} from this computer?`,
    detail: active
      ? (thai ? "ตัวละครนี้กำลังใช้งานอยู่ Runtime จะสลับไปยังตัวละครที่ติดตั้งตัวอื่นก่อนถอนการติดตั้ง" : "This is the active character. Runtime will switch to another installed character before removal.")
      : "",
    buttons: thai ? ["ยกเลิก", "ถอนการติดตั้ง"] : ["Cancel", "Uninstall"],
    defaultId: 1,
    cancelId: 0,
    noLink: true,
  });
  return result.response === 1;
});
ipcMain.handle("ocp:open-account", async (event, connectDesktop: unknown) => {
  if (!senderWindow(event.sender) || !storeUrl || typeof connectDesktop !== "boolean") throw new Error("store unavailable or request invalid");
  const accountUrl = new URL(storeUrl);
  accountUrl.searchParams.set("view", "account");
  if (connectDesktop) accountUrl.searchParams.set("desktop", "1");
  else accountUrl.searchParams.delete("desktop");
  await shell.openExternal(accountUrl.toString());
});
ipcMain.handle("ocp:open-gemini-api-keys", async (event) => {
  if (!senderWindow(event.sender)) throw new Error("untrusted renderer");
  await shell.openExternal(GEMINI_API_KEYS_URL);
});
ipcMain.handle("ocp:install-local-character", async (event) => {
  const record = senderWindow(event.sender);
  if (!record || record.view !== "characters") return { status: "failed", errorCode: "invalid-window" } as const;
  if (!runtimeBridgeClient) return { status: "failed", errorCode: "runtime-unavailable" } as const;
  const selection = await dialog.showOpenDialog(record.window, {
    title: "Install OCP Character Package",
    properties: ["openFile"],
    filters: [{ name: "OCP Character Package", extensions: ["ocp"] }],
  });
  if (selection.canceled || selection.filePaths.length !== 1) return { status: "cancelled" } as const;
  const packagePath = path.normalize(selection.filePaths[0]);
  try {
    const requestId = runtimeBridgeClient.submitSystemLocalInstall(packagePath);
    return { status: "submitted", requestId, fileName: path.basename(packagePath) } as const;
  } catch {
    return { status: "failed", errorCode: "invalid-package-path" } as const;
  }
});
ipcMain.handle("ocp:install-local-effect", async (event) => {
  const record = senderWindow(event.sender);
  if (!record || record.view !== "characters") return { status: "failed", errorCode: "invalid-window" } as const;
  if (!runtimeBridgeClient) return { status: "failed", errorCode: "runtime-unavailable" } as const;
  const selection = await dialog.showOpenDialog(record.window, {
    title: "Upload OCP Effect Pack",
    properties: ["openFile"],
    filters: [{ name: "OCP Effect Pack", extensions: ["ocp"] }],
  });
  if (selection.canceled || selection.filePaths.length !== 1) return { status: "cancelled" } as const;
  const packagePath = path.normalize(selection.filePaths[0]);
  try {
    const requestId = runtimeBridgeClient.submitSystemLocalEffectInstall(packagePath);
    return { status: "submitted", requestId, fileName: path.basename(packagePath) } as const;
  } catch {
    return { status: "failed", errorCode: "invalid-package-path" } as const;
  }
});
ipcMain.handle("ocp:set-appearance", (event, candidate: unknown) => { if (!senderWindow(event.sender)) throw new Error("untrusted renderer"); const next = sanitizeShellAppearance(candidate); if (!next) throw new Error("invalid appearance preference"); persistAppearance(next); return appearance; });
ipcMain.handle("ocp:get-runtime-state", (event) => {
  const record = senderWindow(event.sender);
  if (!record) throw new Error("untrusted renderer");
  return projectRuntimeSnapshotForView(runtimeSnapshot, viewUsesRuntimePreviewMedia(record.view));
});
ipcMain.handle("ocp:runtime-command", (event, candidate: unknown) => {
  if (!senderWindow(event.sender)) throw new Error("untrusted renderer");
  const command = sanitizeRuntimeBridgeCommand(candidate);
  if (!command || !runtimeBridgeClient) throw new Error("runtime adapter unavailable or request invalid");
  if (command.type === "character.uninstall") {
    console.info(`[CharacterUninstall] electron-request package=${command.packageId} version=${command.version}`);
  }
  const id = runtimeBridgeClient.submit(command);
  if (command.type === "character.uninstall") {
    console.info(`[CharacterUninstall] electron-submitted id=${id}`);
  }
  return id;
});
ipcMain.handle("ocp:store-provider-credential", async (event, candidate: unknown) => {
  const record = senderWindow(event.sender);
  const input = sanitizeCredentialStoreInput(candidate);
  // The first-run wizard can be rendered above any trusted native Shell view.
  // Credentials still cross only the narrow sanitized IPC boundary into the OS
  // keystore broker; they are never persisted in renderer/onboarding state.
  if (!record || !input) return { ok: false, code: "invalid-request" } as const;
  if (!credentialBrokerClient) return { ok: false, code: "broker-unavailable" } as const;
  return credentialBrokerClient.store(input);
});
app.on("second-instance", (_event, argv, _workingDirectory, additionalData) => {
  if (isRuntimeOwnerShutdownLaunch(argv)) {
    runtimeOwnerExitRequested = true;
    console.info("[DesktopShell] runtime-owner-shutdown-requested; exiting authenticated shell");
    app.quit();
    return;
  }
  const requestedAtMs = Date.now();
  writeJsonAtomically(protocolInvocationStatusPath(), {
    observedAt: new Date(requestedAtMs).toISOString(),
    ...summarizeProtocolInvocation(argv, additionalData),
  });
  // Electron does not guarantee that second-instance argv is byte-for-byte the
  // same as the launched process argv. Scan the full array (rather than
  // dropping argv[0]) and prefer validated additionalData for one-time install
  // handoffs; this is the channel Electron recommends when exact arguments
  // matter.
  const args = argv;
  const warmRequest = isWarmShellLaunch(args);
  if (!warmRequest) warmRevealRequested = true;
  const nextRuntimeBridge = resolveRuntimeBridgeLaunch(args, additionalData);
  if (nextRuntimeBridge) {
    const source = typeof additionalData === "object" && additionalData !== null && Object.prototype.hasOwnProperty.call(additionalData, "runtimeBridge")
      ? "single-instance-additional-data"
      : "argv";
    console.info(`[DesktopShell] runtime-bridge-rebound source=${source}`);
    setRuntimeBridgeLaunch(nextRuntimeBridge);
  }
  setCredentialBroker(args);
  const additionalInstallHandoff = typeof additionalData === "object" && additionalData !== null
    ? sanitizeInstallHandoff((additionalData as Record<string, unknown>).installHandoff)
    : null;
  const additionalStoreLink = typeof additionalData === "object" && additionalData !== null
    ? sanitizeStoreDeepLink((additionalData as Record<string, unknown>).storeLink)
    : null;
  const installHandoff = additionalInstallHandoff ?? findInstallHandoffArg(args);
  if (installHandoff) { routeInstallHandoff(installHandoff); return; }
  const storeLink = additionalStoreLink ?? findStoreDeepLinkArg(args);
  if (storeLink) { routeStoreLink(storeLink); return; }
  const candidate = typeof additionalData === "object" && additionalData !== null && Object.prototype.hasOwnProperty.call(additionalData, "intent") ? sanitizeShellIntent((additionalData as { intent: unknown }).intent) : parseShellIntentArgs(args);
  if (!candidate.ok) return;
  currentIntent = candidate.value;
  if (app.isReady()) routeIntent(candidate.value, !warmRequest, requestedAtMs);
});
app.whenReady().then(() => {
  console.info(`[DesktopShellTiming] app_ready process_ms=${Date.now() - shellProcessStartedAtMs} warm=${initialWarmLaunch}`);
  appearance = sanitizeShellAppearance(readJson(appearancePath())) ?? DEFAULT_SHELL_APPEARANCE;
  onboardingState = sanitizeOnboardingState(readJson(onboardingPath())) ?? DEFAULT_ONBOARDING_STATE;
  readStudioDesktopState();
  if (pendingInstallHandoff) {
    currentIntent = { view: installHandoffShellView(onboardingState), source: "command-line" };
  }
  void startStoreLoopbackReceiver();
  refreshRuntimeSnapshot();
  routeIntent(currentIntent, warmRevealRequested);
  scheduleRuntimeSnapshotPoll();
  trySubmitInstallHandoff();
  syncChatPresentation();
  app.on("activate", () => {
    if (shellWindows.size === 0) {
      if (!runtimeBridgeClient) routeIntent({ view: "home", source: "command-line" });
      return;
    }
    const record = shellWindows.get(resolveNativeShellView(currentIntent.view));
    if (record && shouldRevealWindowOnAppActivate(runtimeBridgeClient !== null, record.warm)) focusWindow(record, currentIntent);
  });
});
app.on("before-quit", () => {
  appQuitting = true;
  for (const view of shellWindows.keys()) flushWindowState(view);
  const server = storeLoopbackServer;
  storeLoopbackServer = null;
  if (server) void server.close();
  const studioOAuth = studioOAuthLoopback;
  studioOAuthLoopback = null;
  if (studioOAuth) void studioOAuth.close();
});
app.on("window-all-closed", () => { if (!runtimeBridgeClient) app.quit(); });
