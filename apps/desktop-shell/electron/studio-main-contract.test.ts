import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

const mainSource = readFileSync(path.join(__dirname, "main.ts"), "utf8");
const preloadSource = readFileSync(path.join(__dirname, "studio-preload.ts"), "utf8");

describe("Desktop Studio security integration", () => {
  it("hosts Studio in a separate hardened BrowserWindow", () => {
    expect(mainSource).toContain('title: "OCP Animation Studio"');
    expect(mainSource).toContain('preload: path.join(__dirname, "studio-preload.js")');
    expect(mainSource).toContain("contextIsolation: true");
    expect(mainSource).toContain("nodeIntegration: false");
    expect(mainSource).toContain("sandbox: true");
    expect(mainSource).toContain("webSecurity: true");
    expect(mainSource).toContain('partition: "persist:ocp-studio"');
    expect(mainSource).toContain("setPermissionRequestHandler");
    expect(mainSource).toContain("setPermissionCheckHandler");
  });

  it("resolves the Studio source build correctly under the OCP-branded development executable", () => {
    expect(mainSource).toContain("resolveStudioIndexPath({");
    expect(mainSource).toContain("defaultApp: process.defaultApp === true");
    expect(mainSource).toContain("resourcesPath: process.resourcesPath");
  });

  it("falls back to the local Studio build when an optional dev server is unavailable", () => {
    expect(mainSource).toContain("async function loadAnimationStudioContent(window: BrowserWindow)");
    expect(mainSource).toContain("await window.loadURL(developmentUrl)");
    expect(mainSource).toContain("development URL unavailable; falling back to local build");
    expect(mainSource).toContain("await window.loadFile(localIndex)");
    expect(mainSource).toContain("Studio UI could not be loaded for this launcher.");
  });

  it("exposes only the narrow ocpStudio API instead of fs or raw ipc", () => {
    expect(preloadSource).toContain('contextBridge.exposeInMainWorld("ocpStudio", studioApi)');
    for (const method of [
      "getEnvironment",
      "beginOAuth",
      "openOAuth",
      "waitOAuth",
      "chooseWorkspace",
      "saveProject",
      "savePackage",
      "getSigningIdentity",
      "signPackageDraft",
      "cloudRequest",
      "uploadPresigned",
      "revealLastOutput",
      "installLastBuildToRuntime",
    ]) expect(preloadSource).toContain(method);
    expect(preloadSource).not.toContain('exposeInMainWorld("fs"');
    expect(preloadSource).not.toContain('exposeInMainWorld("ipcRenderer"');
  });

  it("keeps one protected signing identity per Publisher and migrates the legacy single-key store", () => {
    expect(mainSource).toContain("type StudioSigningStore");
    expect(mainSource).toContain("source.version !== 1 && source.version !== 2");
    expect(mainSource).toContain("activePublisherId");
    expect(mainSource).toContain("configurations: [...store.configurations, configuration]");
    expect(mainSource).toContain("store.configurations.find((item) => item.publisherId === normalizedPublisherId)");
    expect(mainSource).not.toContain("sign out before provisioning another publisher");
  });

  it("routes Studio Cloud traffic through Chromium's system-proxy aware session", () => {
    expect(mainSource).toContain('session.fromPartition("persist:ocp-studio")');
    expect(mainSource).toContain('await cloudSession.setProxy({ mode: "system" })');
    expect(mainSource).toContain("await cloudSession.resolveProxy(studioCloudApiBase().toString())");
    expect(mainSource).toContain("await cloudSession.fetch(input.url");
    expect(mainSource).not.toContain("await fetch(input.url");
  });

  it("uploads large presigned packages through Electron net.request instead of Session.fetch", () => {
    expect(mainSource).toContain("function uploadStudioPresignedBytes");
    expect(mainSource).toContain("net.request({");
    expect(mainSource).toContain('request.setHeader("content-type", "application/octet-stream")');
    expect(mainSource).toContain("request.end(Buffer.from(bytes))");
    expect(mainSource).toContain("await uploadStudioPresignedBytes(cloudSession, input.url, input.bytes)");
    expect(mainSource).not.toContain('request.setHeader("content-length"');
  });

  it("never accepts a renderer-supplied destination path for Studio writes", () => {
    expect(mainSource).toContain("sanitizeStudioOAuthOpenInput(candidate)");
    expect(mainSource).toContain("const result = await loopback.waitForCallback()");
    expect(mainSource).toContain("void loopback.close().catch");
    expect(mainSource).not.toContain("await loopback.close().catch(() => undefined);");
    expect(mainSource).toContain("sanitizeStudioProjectSaveInput(candidate)");
    expect(mainSource).toContain("sanitizeStudioPackageSaveInput(candidate)");
    expect(mainSource).toContain("sanitizeStudioPackageSignInput(candidate)");
    expect(mainSource).toContain("signStudioPackageDraft(input.bytes, configuration, signerPath)");
    expect(mainSource).toContain("packaged: app.isPackaged && process.defaultApp !== true");
    expect(mainSource).toContain("sanitizeStudioCloudRequest(candidate, studioCloudApiBase())");
    expect(mainSource).toContain("sanitizeStudioPresignedUploadInput(candidate)");
    expect(mainSource).toContain("sanitizeStudioCloudRequest(candidate, studioCloudApiBase())");
    expect(mainSource).toContain("sanitizeStudioPresignedUploadInput(candidate)");
    expect(mainSource).toContain('headers.set("authorization", ["Bearer", input.accessToken].join(" "))');
    expect(mainSource).toContain("sanitizeStudioCloudRequest(candidate, studioCloudApiBase())");
    expect(mainSource).toContain("sanitizeStudioPresignedUploadInput(candidate)");
    expect(mainSource).toContain('path.join(workspace, input.fileName)');
    expect(mainSource).toContain('path.join(workspace, "build")');
    expect(preloadSource).not.toContain("destinationPath");
    expect(preloadSource).not.toContain("workspacePath");
  });
});
