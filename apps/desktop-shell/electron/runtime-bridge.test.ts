import { describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  FileRuntimeBridge,
  MAX_RUNTIME_COMMAND_SNAPSHOT_AGE_MS,
  MAX_RUNTIME_SNAPSHOT_AGE_MS,
  parseRuntimeBridgeLaunch,
  sanitizeRuntimeBridgeLaunch,
  projectRuntimeSnapshotForView,
  resolveRuntimeBridgeLaunch,
  sanitizeRuntimeBridgeCommand,
  sanitizeRuntimeSnapshot,
  type RuntimeSnapshot,
} from "./runtime-bridge";

describe("runtime bridge contract", () => {
  const snapshot = {
    schemaVersion: 1,
    status: "connected",
    appearance: { theme: "solid", locale: "en", fontFamily: "system", textScale: "standard", reduceMotion: false },
    characters: [],
    chat: { providerId: "offline", status: "ready", messages: [] },
    preview: { status: "idle", errorCode: "", packageId: "", version: "", clips: [], selectedAnimation: "", isPlaying: false, loop: false, speed: 1, framePngBase64: "", frameWidth: 0, frameHeight: 0 },
  } as const;

  it("keeps preview media only for the Character window projection", () => {
    const withMedia = {
      ...snapshot,
      preview: {
        ...snapshot.preview,
        status: "ready",
        packageId: "character.scifi",
        version: "2.0.0",
        clips: ["idle"],
        selectedAnimation: "idle",
        clipThumbnailPngBase64: { idle: "AAAA" },
        framePngBase64: "AAAA",
        frameWidth: 1,
        frameHeight: 1,
      },
    } as RuntimeSnapshot;

    expect(projectRuntimeSnapshotForView(withMedia, true)).toBe(withMedia);
    const withoutMedia = projectRuntimeSnapshotForView(withMedia, false);
    expect(withoutMedia?.preview.framePngBase64).toBe("");
    expect(withoutMedia?.preview.frameWidth).toBe(0);
    expect(withoutMedia?.preview.clipThumbnailPngBase64).toEqual({});
    expect(withMedia.preview.framePngBase64).toBe("AAAA");
  });

  it("treats an explicit Runtime stop marker as unavailable", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-stop-"));
    try {
      writeFileSync(path.join(directory, "state.json"), JSON.stringify({ ...snapshot, status: "unavailable" }));
      const bridge = new FileRuntimeBridge({ directory, token: "a".repeat(64) });
      expect(bridge.readSnapshot()).toBeNull();
      expect(bridge.isCommandChannelLive()).toBe(false);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("accepts a fresh connected heartbeat snapshot", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-live-"));
    try {
      const statePath = path.join(directory, "state.json");
      writeFileSync(statePath, JSON.stringify(snapshot));
      // Pin a clearly fresh mtime inside the strict command lease. Windows can
      // report sub-millisecond file times slightly ahead of Date.now(), and the
      // production bridge deliberately rejects negative ages.
      const freshSeconds = (Date.now() - 1_000) / 1_000;
      utimesSync(statePath, freshSeconds, freshSeconds);
      const bridge = new FileRuntimeBridge({ directory, token: "c".repeat(64) });
      expect(bridge.readSnapshot()?.status).toBe("connected");
      expect(bridge.isCommandChannelLive()).toBe(true);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("merges split preview-media.json into the authenticated Runtime snapshot", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-preview-media-"));
    try {
      const mediaState = {
        ...snapshot,
        preview: {
          ...snapshot.preview,
          status: "ready" as const,
          packageId: "character.scifi",
          version: "2.0.0",
          clips: ["idle"],
          selectedAnimation: "idle",
        },
      };
      writeFileSync(path.join(directory, "state.json"), JSON.stringify(mediaState));
      writeFileSync(path.join(directory, "preview-media.json"), JSON.stringify({
        schemaVersion: 1,
        revision: 7,
        packageId: "character.scifi",
        version: "2.0.0",
        selectedAnimation: "idle",
        clipThumbnailPngBase64: { idle: "aGVsbG8=" },
        framePngBase64: "d29ybGQ=",
        frameWidth: 1,
        frameHeight: 1,
      }));
      const bridge = new FileRuntimeBridge({ directory, token: "f".repeat(64) });
      const merged = bridge.readSnapshot();
      expect(merged?.preview.clipThumbnailPngBase64).toEqual({ idle: "aGVsbG8=" });
      expect(merged?.preview.framePngBase64).toBe("d29ybGQ=");
      expect(merged?.preview.frameWidth).toBe(1);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("keeps same-character thumbnails while rejecting a stale live frame after animation selection", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-preview-selection-lag-"));
    try {
      const mediaState = {
        ...snapshot,
        preview: {
          ...snapshot.preview,
          status: "ready" as const,
          packageId: "character.scifi",
          version: "2.0.0",
          clips: ["appear", "climb_down"],
          selectedAnimation: "climb_down",
        },
      };
      writeFileSync(path.join(directory, "state.json"), JSON.stringify(mediaState));
      writeFileSync(path.join(directory, "preview-media.json"), JSON.stringify({
        schemaVersion: 1,
        revision: 8,
        packageId: "character.scifi",
        version: "2.0.0",
        selectedAnimation: "appear",
        clipThumbnailPngBase64: { appear: "aGVsbG8=", climb_down: "d29ybGQ=" },
        framePngBase64: "d29ybGQ=",
        frameWidth: 1,
        frameHeight: 1,
      }));
      const bridge = new FileRuntimeBridge({ directory, token: "8".repeat(64) });
      const result = bridge.readSnapshot();
      expect(result?.preview.clipThumbnailPngBase64).toEqual({ appear: "aGVsbG8=", climb_down: "d29ybGQ=" });
      expect(result?.preview.framePngBase64).toBe("");
      expect(result?.preview.frameWidth).toBe(0);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("ignores stale preview media from a different character identity", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-preview-stale-"));
    try {
      const mediaState = {
        ...snapshot,
        preview: {
          ...snapshot.preview,
          status: "ready" as const,
          packageId: "character.scifi",
          version: "2.0.0",
          clips: ["idle"],
          selectedAnimation: "idle",
        },
      };
      writeFileSync(path.join(directory, "state.json"), JSON.stringify(mediaState));
      writeFileSync(path.join(directory, "preview-media.json"), JSON.stringify({
        schemaVersion: 1,
        revision: 8,
        packageId: "character.sabai",
        version: "1.0.0",
        selectedAnimation: "idle",
        clipThumbnailPngBase64: { idle: "aGVsbG8=" },
        framePngBase64: "d29ybGQ=",
        frameWidth: 1,
        frameHeight: 1,
      }));
      const bridge = new FileRuntimeBridge({ directory, token: "1".repeat(64) });
      const result = bridge.readSnapshot();
      expect(result?.preview.clipThumbnailPngBase64 ?? {}).toEqual({});
      expect(result?.preview.framePngBase64).toBe("");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("retains last-good preview media through a transient media rewrite", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-preview-partial-"));
    try {
      const statePath = path.join(directory, "state.json");
      const mediaPath = path.join(directory, "preview-media.json");
      const mediaState = {
        ...snapshot,
        preview: {
          ...snapshot.preview,
          status: "ready" as const,
          packageId: "character.scifi",
          version: "2.0.0",
          clips: ["idle"],
          selectedAnimation: "idle",
        },
      };
      writeFileSync(statePath, JSON.stringify(mediaState));
      writeFileSync(mediaPath, JSON.stringify({
        schemaVersion: 1,
        revision: 9,
        packageId: "character.scifi",
        version: "2.0.0",
        selectedAnimation: "idle",
        clipThumbnailPngBase64: { idle: "aGVsbG8=" },
        framePngBase64: "d29ybGQ=",
        frameWidth: 1,
        frameHeight: 1,
      }));
      const bridge = new FileRuntimeBridge({ directory, token: "2".repeat(64) });
      const connected = bridge.readSnapshot();
      expect(connected?.preview.clipThumbnailPngBase64).toEqual({ idle: "aGVsbG8=" });
      writeFileSync(mediaPath, "{");
      const duringRewrite = bridge.readSnapshot();
      expect(duringRewrite?.preview.clipThumbnailPngBase64).toEqual({ idle: "aGVsbG8=" });
      expect(duringRewrite?.preview.framePngBase64).toBe("d29ybGQ=");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("retains the last authenticated snapshot through a transient partial rewrite", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-partial-"));
    try {
      const statePath = path.join(directory, "state.json");
      writeFileSync(statePath, JSON.stringify(snapshot));
      const bridge = new FileRuntimeBridge({ directory, token: "d".repeat(64) });
      const connected = bridge.readSnapshot();
      expect(connected?.status).toBe("connected");
      writeFileSync(statePath, '{"schemaVersion":');
      expect(bridge.readSnapshot()).toEqual(connected);
      writeFileSync(statePath, JSON.stringify({ ...snapshot, chat: { ...snapshot.chat, providerId: "ollama" } }));
      expect(bridge.readSnapshot()?.chat.providerId).toBe("ollama");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("does not retain the last snapshot after an explicit Runtime stop marker", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-explicit-stop-"));
    try {
      const statePath = path.join(directory, "state.json");
      writeFileSync(statePath, JSON.stringify(snapshot));
      const bridge = new FileRuntimeBridge({ directory, token: "e".repeat(64) });
      expect(bridge.readSnapshot()).not.toBeNull();
      writeFileSync(statePath, JSON.stringify({ ...snapshot, status: "unavailable" }));
      expect(bridge.readSnapshot()).toBeNull();
      writeFileSync(statePath, "{");
      expect(bridge.readSnapshot()).toBeNull();
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("keeps a temporarily delayed Runtime heartbeat connected within the lease", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-delayed-heartbeat-"));
    try {
      const statePath = path.join(directory, "state.json");
      writeFileSync(statePath, JSON.stringify(snapshot));
      const delayedSeconds = (Date.now() - 4_000) / 1_000;
      utimesSync(statePath, delayedSeconds, delayedSeconds);
      const bridge = new FileRuntimeBridge({ directory, token: "b".repeat(64) });
      expect(bridge.readSnapshot()?.status).toBe("connected");
      expect(Date.now() - (delayedSeconds * 1_000)).toBeGreaterThan(MAX_RUNTIME_COMMAND_SNAPSHOT_AGE_MS);
      expect(bridge.isCommandChannelLive()).toBe(false);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("treats a stale connected snapshot as unavailable after the lease expires", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-stale-"));
    try {
      const statePath = path.join(directory, "state.json");
      writeFileSync(statePath, JSON.stringify(snapshot));
      const staleSeconds = (Date.now() - MAX_RUNTIME_SNAPSHOT_AGE_MS - 100) / 1_000;
      utimesSync(statePath, staleSeconds, staleSeconds);
      const bridge = new FileRuntimeBridge({ directory, token: "b".repeat(64) });
      expect(bridge.readSnapshot()).toBeNull();
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("prefers the single-instance runtime bridge payload over incomplete argv", () => {
    const forwarded = {
      directory: "C:\\Users\\example\\AppData\\Local\\OCP\\fresh-session",
      token: "d".repeat(64),
    };
    expect(resolveRuntimeBridgeLaunch(["electron.exe"], { runtimeBridge: forwarded })).toEqual(forwarded);
    expect(resolveRuntimeBridgeLaunch([
      "--ocp-bridge-dir=C:\\Users\\example\\AppData\\Local\\OCP\\argv-session",
      `--ocp-bridge-token=${"e".repeat(64)}`,
    ], { runtimeBridge: { directory: "relative", token: "bad" } })).toEqual({
      directory: "C:\\Users\\example\\AppData\\Local\\OCP\\argv-session",
      token: "e".repeat(64),
    });
  });

  it("accepts only a validated single-instance runtime bridge payload", () => {
    const payload = {
      directory: "C:\\Users\\example\\AppData\\Local\\OCP\\session",
      token: "b".repeat(64),
    };
    expect(sanitizeRuntimeBridgeLaunch(payload)).toEqual(payload);
    expect(sanitizeRuntimeBridgeLaunch({ ...payload, directory: "relative" })).toBeNull();
    expect(sanitizeRuntimeBridgeLaunch({ ...payload, token: "short" })).toBeNull();
    expect(sanitizeRuntimeBridgeLaunch({ ...payload, extra: true })).toBeNull();
  });

  it("accepts only a complete local launch configuration", () => {
    expect(parseRuntimeBridgeLaunch([
      "--ocp-bridge-dir=C:\\Users\\example\\AppData\\Local\\OCP\\session",
      `--ocp-bridge-token=${"a".repeat(64)}`,
    ])).toEqual({
      directory: "C:\\Users\\example\\AppData\\Local\\OCP\\session",
      token: "a".repeat(64),
    });
    expect(parseRuntimeBridgeLaunch(["--ocp-bridge-dir=C:\\session"])).toBeNull();
    expect(parseRuntimeBridgeLaunch(["--ocp-bridge-dir=relative", `--ocp-bridge-token=${"a".repeat(64)}`])).toBeNull();
  });

  it("routes a local .ocp path only through the trusted system bridge", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-local-install-"));
    try {
      const packagePath = path.join(directory, "character.sabai.ocp");
      writeFileSync(packagePath, "local-package-fixture");
      const bridge = new FileRuntimeBridge({ directory, token: "f".repeat(64) });
      const requestId = bridge.submitSystemLocalInstall(packagePath);
      const commandFile = readdirSync(path.join(directory, "commands")).find((name) => name.endsWith(`-${requestId}.json`));
      expect(commandFile).toBeTruthy();
      const message = JSON.parse(readFileSync(path.join(directory, "commands", commandFile!), "utf8")) as { command: unknown };
      expect(message.command).toEqual({ type: "local.install-package", path: path.normalize(packagePath) });
      const effectRequestId = bridge.submitSystemLocalEffectInstall(packagePath);
      const effectCommandFile = readdirSync(path.join(directory, "commands")).find((name) => name.endsWith(`-${effectRequestId}.json`));
      expect(effectCommandFile).toBeTruthy();
      const effectMessage = JSON.parse(readFileSync(path.join(directory, "commands", effectCommandFile!), "utf8")) as { command: unknown };
      expect(effectMessage.command).toEqual({ type: "local.install-effect", path: path.normalize(packagePath) });
      expect(() => bridge.submitSystemLocalInstall(path.join(directory, "character.zip"))).toThrow("invalid local OCP package path");
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("submits Character Manager companion suppression only through the system command path", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-companion-suppression-"));
    try {
      const bridge = new FileRuntimeBridge({ directory, token: "7".repeat(64) });
      const requestId = bridge.submitSystemCompanionSuppression(true);
      const commandFile = readdirSync(path.join(directory, "commands")).find((name) => name.endsWith(`-${requestId}.json`));
      expect(commandFile).toBeTruthy();
      const message = JSON.parse(readFileSync(path.join(directory, "commands", commandFile!), "utf8")) as { command: unknown };
      expect(message.command).toEqual({ type: "shell.companion-suppression", active: true });
      expect(sanitizeRuntimeBridgeCommand({ type: "shell.companion-suppression", active: true })).toBeNull();
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("claims only token-authenticated HTTPS Runtime network transfers and writes atomic results", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-network-transfer-"));
    try {
      const token = "a".repeat(64);
      const requestDirectory = path.join(directory, "network-requests");
      mkdirSync(requestDirectory, { recursive: true });
      const bridge = new FileRuntimeBridge({ directory, token });
      const invalidId = "1".repeat(32);
      writeFileSync(path.join(requestDirectory, `${invalidId}.json`), JSON.stringify({ schemaVersion: 1, id: invalidId, token, url: "http://unsafe.example/file.ocp" }));
      expect(bridge.claimNetworkTransferRequest()).toBeNull();

      const requestId = "2".repeat(32);
      writeFileSync(path.join(requestDirectory, `${requestId}.json`), JSON.stringify({ schemaVersion: 1, id: requestId, token, url: "https://signed.example/file.ocp?sig=opaque" }));
      const request = bridge.claimNetworkTransferRequest();
      expect(request?.id).toBe(requestId);
      expect(request?.url).toBe("https://signed.example/file.ocp?sig=opaque");
      expect(request?.outputPath).toBe(path.join(directory, "network-downloads", `${requestId}.ocp`));
      writeFileSync(request!.outputPath, "downloaded-package");
      bridge.completeNetworkTransfer(request!, { status: "succeeded", bytes: 18 });
      const result = JSON.parse(readFileSync(path.join(directory, "network-results", `${requestId}.json`), "utf8")) as Record<string, unknown>;
      expect(result).toMatchObject({ schemaVersion: 1, id: requestId, token, status: "succeeded", path: request!.outputPath, bytes: 18, error: "" });
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("preserves command submission order in lexically sorted Runtime files", () => {
    const directory = mkdtempSync(path.join(tmpdir(), "ocp-bridge-command-order-"));
    try {
      const bridge = new FileRuntimeBridge({ directory, token: "9".repeat(64) });
      bridge.submit({ type: "character.preview.open", packageId: "character.scifi", version: "2.0.0" });
      bridge.submit({ type: "character.preview.select", packageId: "character.scifi", version: "2.0.0", animation: "wave" });
      bridge.submit({ type: "character.preview.play", packageId: "character.scifi", version: "2.0.0" });
      const commands = readdirSync(path.join(directory, "commands"))
        .filter((name) => name.endsWith(".json"))
        .sort()
        .map((name) => JSON.parse(readFileSync(path.join(directory, "commands", name), "utf8")) as { command: { type: string } });
      expect(commands.map((message) => message.command.type)).toEqual([
        "character.preview.open",
        "character.preview.select",
        "character.preview.play",
      ]);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });

  it("rejects renderer attempts to smuggle unsupported Runtime requests", () => {
    const controlSettings = {
      themePreset: "glass", fontFamily: "Segoe UI", textScale: "standard", bubbleStyle: "Soft",
      language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false,
      offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false,
    } as const;
    const aiSettings = {
      providerId: "ollama", baseUrl: "http://127.0.0.1:11434", model: "qwen3.5:latest", timeoutSeconds: 45,
      ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "Zephyr",
    } as const;
    expect(sanitizeRuntimeBridgeCommand({ type: "control.settings.update", settings: controlSettings })).toEqual({
      type: "control.settings.update",
      settings: controlSettings,
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.settings.update", settings: { ...controlSettings, updateChannel: "canary" } })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "control.settings.update", settings: controlSettings, token: "stolen" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "control.ai.update", settings: aiSettings })).toEqual({ type: "control.ai.update", settings: aiSettings });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.ai.test", settings: aiSettings })).toEqual({ type: "control.ai.test", settings: aiSettings });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.ai.discover", settings: aiSettings })).toEqual({ type: "control.ai.discover", settings: aiSettings });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.voice.test", settings: aiSettings })).toEqual({ type: "control.voice.test", settings: aiSettings });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.ai.update", settings: { ...aiSettings, apiKey: "secret" } })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "control.update.check" })).toEqual({ type: "control.update.check" });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.update.apply" })).toEqual({ type: "control.update.apply" });
    expect(sanitizeRuntimeBridgeCommand({ type: "control.update.check", url: "https://example.test/manifest.json" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "control.update.apply", artifactPath: "C:\\private\\update.zip" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "control.update.apply", confirmed: true })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "character.activate", packageId: "character.scifi", version: "2.0.0" })).toEqual({
      type: "character.activate",
      packageId: "character.scifi",
      version: "2.0.0",
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "character.uninstall", packageId: "character.scifi", version: "2.0.0" })).toEqual({
      type: "character.uninstall",
      packageId: "character.scifi",
      version: "2.0.0",
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "character.effects.update", levelUpEnabled: true, auraEnabled: false })).toEqual({
      type: "character.effects.update",
      levelUpEnabled: true,
      auraEnabled: false,
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "character.effects.update", levelUpEnabled: "yes", auraEnabled: true })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "character.effects.preview-level-up", packageId: "character.scifi", version: "2.0.0" })).toEqual({
      type: "character.effects.preview-level-up",
      packageId: "character.scifi",
      version: "2.0.0",
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", mode: "all" })).toEqual({ type: "effect-pack.preview", mode: "all" });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", mode: "groundRune" })).toEqual({ type: "effect-pack.preview", mode: "groundRune" });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview" })).toEqual({ type: "effect-pack.preview", mode: "all" });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", mode: "invalid" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview", mode: "all", token: "smuggled" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-tune", slot: "groundRune", tuning: { fps: 12, startFrame: 0, endFrame: 47, scale: 1.45, offsetX: 0, offsetY: -8, anchor: "character-feet", scaleMode: "character-width" } })).toEqual({ type: "effect-pack.preview-tune", slot: "groundRune", tuning: { fps: 12, startFrame: 0, endFrame: 47, scale: 1.45, offsetX: 0, offsetY: -8, anchor: "character-feet", scaleMode: "character-width" } });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-tune", slot: "groundRune", tuning: { fps: 90, startFrame: 0, endFrame: 47, scale: 1.45, offsetX: 0, offsetY: -8, anchor: "character-feet", scaleMode: "character-width" } })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-tune", slot: "groundRune", tuning: { fps: 12, startFrame: 40, endFrame: 12, scale: 1.45, offsetX: 0, offsetY: -8, anchor: "character-feet", scaleMode: "character-width" } })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.character-profile.save", characterId: "character.sabai-sompoo", slot: "groundRune", tuning: { fps: 12, startFrame: 0, endFrame: 47, scale: 1.18, offsetX: 0, offsetY: -4, anchor: "character-feet", scaleMode: "character-width" } })).toEqual({ type: "effect-pack.character-profile.save", characterId: "character.sabai-sompoo", slot: "groundRune", tuning: { fps: 12, startFrame: 0, endFrame: 47, scale: 1.18, offsetX: 0, offsetY: -4, anchor: "character-feet", scaleMode: "character-width" } });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.character-profile.reset", characterId: "character.sabai-sompoo", slot: "groundRune" })).toEqual({ type: "effect-pack.character-profile.reset", characterId: "character.sabai-sompoo", slot: "groundRune" });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.character-profile.save", characterId: "../unsafe", slot: "groundRune", tuning: { fps: 12, startFrame: 0, endFrame: 47, scale: 1.18, offsetX: 0, offsetY: -4, anchor: "character-feet", scaleMode: "character-width" } })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-rank", rank: "partner" })).toEqual({
      type: "effect-pack.preview-rank",
      rank: "partner",
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-rank", rank: "" })).toEqual({
      type: "effect-pack.preview-rank",
      rank: "",
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-rank", rank: "legendary" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "effect-pack.preview-rank", rank: "friend", token: "smuggled" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "character.preview.thumbnail-page", packageId: "character.scifi", version: "2.0.0", offset: 12 })).toEqual({
      type: "character.preview.thumbnail-page",
      packageId: "character.scifi",
      version: "2.0.0",
      offset: 12,
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "character.preview.thumbnail-page", packageId: "character.scifi", version: "2.0.0", offset: 5 })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "character.preview.thumbnail-page", packageId: "character.scifi", version: "2.0.0", offset: 126 })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "character.preview.set-speed", packageId: "character.scifi", version: "2.0.0", speed: 1.5 })).toEqual({
      type: "character.preview.set-speed",
      packageId: "character.scifi",
      version: "2.0.0",
      speed: 1.5,
    });
    expect(sanitizeRuntimeBridgeCommand({ type: "character.preview.select", packageId: "character.scifi", version: "2.0.0", animation: "wave", path: "C:\\private" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "character.preview.set-speed", packageId: "character.scifi", version: "2.0.0", speed: 3 })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.submit", prompt: "hello" })).toEqual({ type: "chat.submit", prompt: "hello" });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.reconnect" })).toEqual({ type: "chat.reconnect" });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.session.clear" })).toEqual({ type: "chat.session.clear" });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.turn.cancel", expectedRevision: 7 })).toEqual({ type: "chat.turn.cancel", expectedRevision: 7 });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.message.edit", messageId: "u-1", prompt: "revised", expectedRevision: 7 })).toEqual({ type: "chat.message.edit", messageId: "u-1", prompt: "revised", expectedRevision: 7 });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.message.regenerate", messageId: "a-1", expectedRevision: 7 })).toEqual({ type: "chat.message.regenerate", messageId: "a-1", expectedRevision: 7 });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.feedback.set", messageId: "a-1", feedback: "positive", expectedRevision: 7 })).toEqual({ type: "chat.feedback.set", messageId: "a-1", feedback: "positive", expectedRevision: 7 });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.message.read-aloud", messageId: "a-1", expectedRevision: 7 })).toEqual({ type: "chat.message.read-aloud", messageId: "a-1", expectedRevision: 7 });
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.session.new", expectedRevision: 7 })).toEqual({ type: "chat.session.new", expectedRevision: 7 });
    expect(sanitizeRuntimeBridgeCommand({ type: "account.sign-out" })).toEqual({ type: "account.sign-out" });
    expect(sanitizeRuntimeBridgeCommand({ type: "account.sign-out", accessToken: "secret" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "account.auth-handoff", grant: "B".repeat(64) })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.turn.cancel", expectedRevision: -1 })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.message.edit", messageId: "u-1", prompt: "revised", expectedRevision: 7, provider: "smuggled" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "shell.chat-focus", active: true })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "shell.chat-visibility", active: true })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.session.clear", transcript: "smuggled" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "cloud.auth.password", email: "user@example.com", password: "password123" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "cloud.library.refresh" })).toEqual({ type: "cloud.library.refresh" });
    expect(sanitizeRuntimeBridgeCommand({ type: "cloud.sync.now" })).toEqual({ type: "cloud.sync.now" });
    expect(sanitizeRuntimeBridgeCommand({ type: "cloud.library.install", packageId: "character.sabai", version: "1.2.0" })).toEqual({ type: "cloud.library.install", packageId: "character.sabai", version: "1.2.0" });
    expect(sanitizeRuntimeBridgeCommand({ type: "cloud.library.install", packageId: "character.sabai", version: "1.2.0", accessToken: "secret" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "cloud.download.install", packageId: "character.sabai", version: "1.2.0" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "store.install-handoff", packageId: "character.sabai", version: "1.2.0", grant: "A".repeat(43) })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "local.install-package", path: "C:\\private\\character.ocp" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "local.install-effect", path: "C:\\private\\effect.ocp" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "package.install", path: "C:\\unsafe.ocp" })).toBeNull();
    expect(sanitizeRuntimeBridgeCommand({ type: "chat.submit", prompt: "hello", token: "stolen" })).toBeNull();
  });

  it("accepts a strict Runtime-owned snapshot only", () => {
    const snapshot = {
      schemaVersion: 2,
      status: "connected",
      appearance: { theme: "liquid", locale: "en", fontFamily: "system", textScale: "standard", reduceMotion: false },
      characters: [{ packageId: "character.scifi", version: "2.0.0", name: "Sci-Fi Woman", active: true, animations: ["idle", "wave"] }],
      chat: { providerId: "offline", status: "ready", messages: [] },
      preview: { status: "playing", errorCode: "", packageId: "character.scifi", version: "2.0.0", clips: ["idle", "wave"], selectedAnimation: "wave", isPlaying: true, loop: true, speed: 1, framePngBase64: "aGVsbG8=", frameWidth: 96, frameHeight: 128 },
      controlCenter: {
        settings: {
          themePreset: "liquid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded",
          language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false,
          offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false,
        },
        resources: { available: true, cpuPercent: 20, memoryPercent: 40, pressure: "normal", sampledAtMs: 1234 },
      },
      commandResults: [{ id: "request-1", type: "control.settings.update", status: "succeeded", errorCode: "" }],
    };
    expect(sanitizeRuntimeSnapshot(snapshot)).toEqual({ ...snapshot, controlCenter: { ...snapshot.controlCenter, ai: null, updates: null } });
    expect(sanitizeRuntimeSnapshot({ ...snapshot, unexpected: true })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, characters: [{ ...snapshot.characters[0], path: "C:\\private" }] })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, preview: { ...snapshot.preview, framePngBase64: "x".repeat(262_145) } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, preview: { ...snapshot.preview, framePngBase64: "javascript:alert(1)" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, preview: { ...snapshot.preview, filePath: "C:\\private" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, cloud: { session: { accessToken: "secret" } } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, controlCenter: { ...snapshot.controlCenter, credential: "secret" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...snapshot, commandResults: [{ ...snapshot.commandResults[0], path: "C:\\private" }] })).toBeNull();
  });

  it("accepts playback-derived voice health only in the additive schema", () => {
    const controlCenter = {
      settings: { themePreset: "solid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded", language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false, offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false },
      resources: { available: false, cpuPercent: 0, memoryPercent: 0, pressure: "unavailable", sampledAtMs: 0 },
      ai: {
        settings: { providerId: "offline", baseUrl: "", model: "", timeoutSeconds: 45, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "auto" },
        provider: { providerId: "offline", available: true, configured: true, reachable: true, test: { status: "idle", errorCode: "" } },
        credentials: { brokerAvailable: false, openAiCompatiblePresent: false, geminiPresent: false },
        voiceTest: { status: "idle", errorCode: "" },
      },
      updates: { currentVersion: "0.1.0", channel: "stable", state: "idle", messageCode: "update-idle", message: "Ready to check the signed update channel.", targetVersion: "", canCheck: false, canApply: false },
    } as const;
    const phase = {
      ...snapshot,
      schemaVersion: 7,
      controlCenter,
      commandResults: [],
      voice: { status: "playing", reasonCode: "", lastSuccessAtMs: 0, retryAtMs: 0 },
    } as const;
    expect(sanitizeRuntimeSnapshot(phase)).toEqual(phase);
    expect(sanitizeRuntimeSnapshot({ ...phase, voice: { ...phase.voice, status: "browser-owned" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...phase, voice: { ...phase.voice, reasonCode: "C:\\private\\speech.wav" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...phase, voice: { ...phase.voice, providerBody: "secret" } })).toBeNull();
  });

  it("accepts only bounded schema-v8 conversation presentation state", () => {
    const controlCenter = {
      settings: { themePreset: "solid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded", language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false, offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false },
      resources: { available: false, cpuPercent: 0, memoryPercent: 0, pressure: "unavailable", sampledAtMs: 0 },
      ai: { settings: { providerId: "offline", baseUrl: "", model: "", timeoutSeconds: 45, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "auto" }, provider: { providerId: "offline", available: true, configured: true, reachable: true, test: { status: "idle", errorCode: "" } }, credentials: { brokerAvailable: false, openAiCompatiblePresent: false, geminiPresent: false }, voiceTest: { status: "idle", errorCode: "" } },
      updates: { currentVersion: "0.1.0", channel: "stable", state: "idle", messageCode: "update-idle", message: "Ready to check the signed update channel.", targetVersion: "", canCheck: false, canApply: false },
    } as const;
    const realtime = { ...snapshot, schemaVersion: 8 as const, chat: { ...snapshot.chat, status: "thinking" as const, messages: [{ id: "a-1", role: "assistant" as const, text: "สวัสดี", status: "streaming" as const }], presentationState: "think" as const }, controlCenter, commandResults: [], voice: { status: "synthesizing" as const, reasonCode: "" as const, lastSuccessAtMs: 0, retryAtMs: 0 } };
    expect(sanitizeRuntimeSnapshot(realtime)).toEqual(realtime);
    expect(sanitizeRuntimeSnapshot({ ...realtime, chat: { ...realtime.chat, presentationState: "walk" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...realtime, chat: { ...realtime.chat, audioPath: "C:\\private\\speech.wav" } })).toBeNull();
  });

  it("accepts exact schema-v9 interaction metadata and schema-v10 atomic presentation", () => {
    const controlCenter = {
      settings: { themePreset: "solid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded", language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false, offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false },
      resources: { available: false, cpuPercent: 0, memoryPercent: 0, pressure: "unavailable", sampledAtMs: 0 },
      ai: { settings: { providerId: "offline", baseUrl: "", model: "", timeoutSeconds: 45, ttsEnabled: false, chatVoiceMode: "off", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "auto" }, provider: { providerId: "offline", available: true, configured: true, reachable: true, test: { status: "idle", errorCode: "" } }, credentials: { brokerAvailable: false, openAiCompatiblePresent: false, geminiPresent: false }, voiceTest: { status: "idle", errorCode: "" } },
      updates: { currentVersion: "0.1.0", channel: "stable", state: "idle", messageCode: "update-idle", message: "Ready to check the signed update channel.", targetVersion: "", canCheck: false, canApply: false },
    } as const;
    const next = { ...snapshot, schemaVersion: 9 as const, chat: { providerId: "ollama", status: "ready" as const, messages: [{ id: "a-1", role: "assistant" as const, text: "hello", status: "complete" as const, feedback: "positive" as const }], presentationState: "idle" as const, sessionId: "session_1", revision: 4, activeMessageId: "" }, controlCenter, commandResults: [], voice: { status: "healthy" as const, reasonCode: "" as const, lastSuccessAtMs: 10, retryAtMs: 0 } };
    expect(sanitizeRuntimeSnapshot(next)).toEqual(next);
    expect(sanitizeRuntimeSnapshot({ ...next, chat: { ...next.chat, revision: -1 } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...next, chat: { ...next.chat, branchPath: ["secret"] } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...next, chat: { ...next.chat, messages: [{ ...next.chat.messages[0], feedback: "liked" }] } })).toBeNull();
    const presentation = { owner: "chat" as const, state: "talk" as const, sequence: 8, turnId: "turn-1", messageId: "a-1", speechId: "speech-1", reasonCode: "voice-playing" as const };
    const atomic = { ...next, schemaVersion: 10 as const, chat: { ...next.chat, presentationState: "talk" as const, presentation } };
    expect(sanitizeRuntimeSnapshot(atomic)).toEqual(atomic);
    expect(sanitizeRuntimeSnapshot({ ...atomic, chat: { ...atomic.chat, presentation: { ...presentation, owner: "renderer" } } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...atomic, chat: { ...atomic.chat, presentation: { ...presentation, sequence: -1 } } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...atomic, chat: { ...atomic.chat, presentation: { ...presentation, filePath: "C:\\private\\speech.wav" } } })).toBeNull();

    const thumbnail = {
      ...atomic,
      schemaVersion: 11 as const,
      characters: [{
        packageId: "character.scifi",
        version: "2.0.0",
        name: "Sci-Fi Woman",
        active: true,
        animations: ["idle", "wave"],
        thumbnailPngBase64: "aGVsbG8=",
        thumbnailWidth: 1,
        thumbnailHeight: 1,
      }],
    };
    expect(sanitizeRuntimeSnapshot(thumbnail)).toEqual(thumbnail);
    expect(sanitizeRuntimeSnapshot({ ...thumbnail, characters: [{ ...thumbnail.characters[0], thumbnailPath: "C:\\private\\preview.png" }] })).toBeNull();

    const shortcutThumbnails = {
      ...thumbnail,
      schemaVersion: 12 as const,
      preview: {
        ...thumbnail.preview,
        clips: ["idle", "wave"],
        clipThumbnailPngBase64: { idle: "aGVsbG8=", wave: "d29ybGQ=" },
      },
    };
    expect(sanitizeRuntimeSnapshot(shortcutThumbnails)).toEqual(shortcutThumbnails);

    const progression = {
      ...shortcutThumbnails,
      schemaVersion: 14 as const,
      progression: {
        revision: 4,
        companions: [{
          companionId: "companion.scifi",
          characterId: "character.scifi",
          relationship: { level: 4, xp: 2340 },
          skills: [
            { skillId: "assistant", level: 7, xp: 720 },
            { skillId: "notes", level: 4, xp: 340 },
          ],
        }],
      },
    };
    expect(sanitizeRuntimeSnapshot(progression)).toEqual(progression);
    // Phase C: match the V2 projection already emitted by the functional adapter.
    const v2Relationship = { level: 150, xp: 1000000000, bondRank: "best-companion", currentLevelXp: 900000000, nextLevelXp: 1100000000, progressPermille: 500 };
    const v2 = { ...progression, progression: { ...progression.progression, levelCap: 200, companions: [{ ...progression.progression.companions[0], relationship: v2Relationship }] } };
    expect(sanitizeRuntimeSnapshot(v2)).toEqual(v2);
    for (const patch of [{ level: 201 }, { progressPermille: 1001 }, { bondRank: "admin" }, { currentLevelXp: -1 }, { nextLevelXp: 800000000 }]) {
      expect(sanitizeRuntimeSnapshot({ ...v2, progression: { ...v2.progression, companions: [{ ...v2.progression.companions[0], relationship: { ...v2Relationship, ...patch } }] } })).toBeNull();
    }
    const accountSnapshot = {
      ...progression,
      schemaVersion: 15 as const,
      account: { signedIn: true, userId: "user-1", email: "user@example.com", deviceId: "device-1" },
    };
    expect(sanitizeRuntimeSnapshot(accountSnapshot)).toEqual(accountSnapshot);
    expect(sanitizeRuntimeSnapshot({ ...accountSnapshot, account: { ...accountSnapshot.account, accessToken: "secret" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...accountSnapshot, account: { signedIn: false, userId: "user-1", email: "", deviceId: "" } })).toBeNull();
    const cloudSnapshot = {
      ...accountSnapshot,
      schemaVersion: 16 as const,
      cloud: {
        library: {
          status: "synced" as const,
          items: [{
            productId: "character.sabai",
            productType: "character",
            entitled: true,
            source: "purchase" as const,
            grantedAt: "2026-09-05T00:00:00Z",
            revokedAt: "",
            name: "Sabai",
            latestVersion: "1.2.0",
            thumbnailUrl: "https://cdn.example/sabai.webp",
            availability: "entitlement-required" as const,
          }],
        },
        sync: { status: "synced" as const, deviceRegistered: true, progressionRevision: 4 },
        download: { status: "idle" as const, packageId: "", version: "" },
      },
    };
    expect(sanitizeRuntimeSnapshot(cloudSnapshot)).toEqual(cloudSnapshot);
    expect(sanitizeRuntimeSnapshot({ ...cloudSnapshot, cloud: { ...cloudSnapshot.cloud, accessToken: "secret" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...cloudSnapshot, cloud: { ...cloudSnapshot.cloud, library: { ...cloudSnapshot.cloud.library, items: [{ ...cloudSnapshot.cloud.library.items[0], signedUrl: "https://secret.example" }] } } })).toBeNull();
    const trustSnapshot = {
      ...cloudSnapshot,
      schemaVersion: 17 as const,
      cloud: {
        ...cloudSnapshot.cloud,
        download: {
          status: "installed" as const,
          packageId: "character.sabai",
          version: "1.2.0",
          trust: { mode: "marketplace-release" as const, sequence: 7, trustedPublishers: 3, revocationStale: false },
        },
      },
    };
    expect(sanitizeRuntimeSnapshot(trustSnapshot)).toEqual(trustSnapshot);
    expect(sanitizeRuntimeSnapshot({ ...trustSnapshot, cloud: { ...trustSnapshot.cloud, download: { ...trustSnapshot.cloud.download, trust: { ...trustSnapshot.cloud.download.trust, signature: "secret" } } } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...trustSnapshot, cloud: { ...trustSnapshot.cloud, download: { ...trustSnapshot.cloud.download, trust: { mode: "marketplace-release", sequence: -1, trustedPublishers: 3, revocationStale: false } } } })).toBeNull();
    const modelDiscoverySnapshot = {
      ...trustSnapshot,
      schemaVersion: 18 as const,
      commandResults: [{ id: "discover-1", type: "control.ai.discover" as const, status: "succeeded" as const, errorCode: "", models: ["qwen3.5:latest", "gemma3:4b"] }],
    };
    expect(sanitizeRuntimeSnapshot(modelDiscoverySnapshot)).toEqual(modelDiscoverySnapshot);
    const progressionEffectsSnapshot = {
      ...modelDiscoverySnapshot,
      schemaVersion: 19 as const,
      progression: {
        ...v2.progression,
        effects: { levelUpEnabled: true, auraEnabled: false },
      },
    };
    expect(sanitizeRuntimeSnapshot(progressionEffectsSnapshot)).toEqual(progressionEffectsSnapshot);
    expect(sanitizeRuntimeSnapshot({ ...progressionEffectsSnapshot, progression: { ...progressionEffectsSnapshot.progression, effects: { levelUpEnabled: true, auraEnabled: "yes" } } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...modelDiscoverySnapshot, commandResults: [{ ...modelDiscoverySnapshot.commandResults[0], models: Array.from({ length: 17 }, (_, index) => `model-${index}`) }] })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...modelDiscoverySnapshot, commandResults: [{ ...modelDiscoverySnapshot.commandResults[0], models: ["qwen3.5:latest", "qwen3.5:latest"] }] })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...modelDiscoverySnapshot, commandResults: [{ id: "probe-1", type: "control.ai.test", status: "succeeded", errorCode: "", models: ["should-not-project"] }] })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...trustSnapshot, commandResults: [{ id: "discover-old", type: "control.ai.discover", status: "succeeded", errorCode: "", models: ["schema-17-must-reject"] }] })).toBeNull();
    const rateLimitedVoice = {
      ...progression,
      voice: { status: "failed" as const, reasonCode: "provider-rate-limited" as const, lastSuccessAtMs: 10, retryAtMs: 2_000_000_000_000 },
    };
    expect(sanitizeRuntimeSnapshot(rateLimitedVoice)).toEqual(rateLimitedVoice);
    expect(sanitizeRuntimeSnapshot({ ...rateLimitedVoice, voice: { ...rateLimitedVoice.voice, retryAtMs: -1 } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...progression, progression: { ...progression.progression, localPath: "C:\\private" } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...progression, progression: { ...progression.progression, companions: [{ ...progression.progression.companions[0], relationship: { level: 0, xp: 2340 } }] } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...shortcutThumbnails, preview: { ...shortcutThumbnails.preview, clipThumbnailPngBase64: { missing: "aGVsbG8=" } } })).toBeNull();
    expect(sanitizeRuntimeSnapshot({ ...shortcutThumbnails, preview: { ...shortcutThumbnails.preview, clipThumbnailPngBase64: { idle: "not base64!" } } })).toBeNull();
  });

  it("keeps Chat and Characters usable with a schema-v1 Runtime", () => {
    const legacy = {
      schemaVersion: 1,
      status: "connected",
      appearance: { theme: "liquid", locale: "en", fontFamily: "system", textScale: "standard", reduceMotion: false },
      characters: [],
      chat: { providerId: "offline", status: "ready", messages: [] },
      preview: { status: "idle", errorCode: "", packageId: "", version: "", clips: [], selectedAnimation: "", isPlaying: false, loop: false, speed: 1, framePngBase64: "", frameWidth: 0, frameHeight: 0 },
    };
    expect(sanitizeRuntimeSnapshot(legacy)).toEqual({ ...legacy, controlCenter: null, commandResults: [] });
  });

  it("accepts the Phase B schema without projecting credentials", () => {
    const base = {
      schemaVersion: 3,
      status: "connected",
      appearance: { theme: "liquid", locale: "en", fontFamily: "system", textScale: "standard", reduceMotion: false },
      characters: [],
      chat: { providerId: "ollama", status: "ready", messages: [] },
      preview: { status: "idle", errorCode: "", packageId: "", version: "", clips: [], selectedAnimation: "", isPlaying: false, loop: false, speed: 1, framePngBase64: "", frameWidth: 0, frameHeight: 0 },
      controlCenter: {
        settings: {
          themePreset: "liquid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded",
          language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false,
          offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false,
        },
        resources: { available: true, cpuPercent: 20, memoryPercent: 40, pressure: "normal", sampledAtMs: 1234 },
        ai: {
          settings: { providerId: "ollama", baseUrl: "http://127.0.0.1:11434", model: "qwen3.5:latest", timeoutSeconds: 45, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "Zephyr" },
          provider: { providerId: "ollama", available: true, configured: true, reachable: false, test: { status: "idle", errorCode: "" } },
          credentials: { brokerAvailable: true, openAiCompatiblePresent: false, geminiPresent: true },
          voiceTest: { status: "idle", errorCode: "" },
        },
      },
      commandResults: [],
    } as const;
    expect(sanitizeRuntimeSnapshot(base)).toEqual({ ...base, controlCenter: { ...base.controlCenter, updates: null } });
    expect(sanitizeRuntimeSnapshot({ ...base, controlCenter: { ...base.controlCenter, ai: { ...base.controlCenter.ai, credential: "secret" } } })).toBeNull();
  });

  it("accepts Phase C update facts but rejects every sensitive updater field", () => {
    const phaseB = {
      schemaVersion: 3,
      status: "connected",
      appearance: { theme: "liquid", locale: "en", fontFamily: "system", textScale: "standard", reduceMotion: false },
      characters: [],
      chat: { providerId: "offline", status: "ready", messages: [] },
      preview: { status: "idle", errorCode: "", packageId: "", version: "", clips: [], selectedAnimation: "", isPlaying: false, loop: false, speed: 1, framePngBase64: "", frameWidth: 0, frameHeight: 0 },
      controlCenter: {
        settings: { themePreset: "solid", fontFamily: "Inter", textScale: "standard", bubbleStyle: "Rounded", language: "en", showBubbles: true, clickThroughEnabled: true, startWithWindows: false, offlinePresenceEnabled: true, llmCompanionModeEnabled: false, updateChannel: "stable", reduceMotion: false },
        resources: { available: false, cpuPercent: 0, memoryPercent: 0, pressure: "unavailable", sampledAtMs: 0 },
        ai: {
          settings: { providerId: "offline", baseUrl: "", model: "", timeoutSeconds: 45, ttsEnabled: false, chatVoiceMode: "off", ttsProviderId: "auto", ttsModel: "gemini-2.5-flash-preview-tts", ttsVoice: "auto" },
          provider: { providerId: "offline", available: true, configured: true, reachable: true, test: { status: "idle", errorCode: "" } },
          credentials: { brokerAvailable: false, openAiCompatiblePresent: false, geminiPresent: false },
          voiceTest: { status: "idle", errorCode: "" },
        },
      },
      commandResults: [],
    } as const;
    const updates = { currentVersion: "0.1.0", channel: "stable", state: "ready", messageCode: "update-ready", message: "A verified update is staged and ready to install.", targetVersion: "0.2.0", canCheck: true, canApply: true } as const;
    const phaseC = { ...phaseB, schemaVersion: 4 as const, controlCenter: { ...phaseB.controlCenter, updates } };
    expect(sanitizeRuntimeSnapshot(phaseC)).toEqual(phaseC);
    for (const extra of [
      { releaseUrl: "https://example.test/release" }, { artifactPath: "C:\\private\\update.zip" },
      { helperPath: "C:\\private\\apply.ps1" }, { signingKey: "secret" }, { commandLine: "powershell -File apply.ps1" },
    ]) {
      expect(sanitizeRuntimeSnapshot({ ...phaseC, controlCenter: { ...phaseC.controlCenter, updates: { ...updates, ...extra } } })).toBeNull();
    }
  });
});
