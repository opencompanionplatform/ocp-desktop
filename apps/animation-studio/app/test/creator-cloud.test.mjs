import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { analyzeCreatorCloudVersionConflict, buildWebStudioOAuthRedirect, createStudioCreatorCloud, createStudioCreatorIdentity, readCreatorCloudConfig, readWebStudioOAuthCallback } from "../src/creator-cloud.js";
import {
  characterScaleDeviation,
  computeSourceCropPlacement,
  computeStandardizedSourcePlacement,
  computeSubjectPlacement,
  createCharacterMasterProfile,
  poseGroupForAnimation,
  unionSubjectBounds,
} from "../src/features/character/subject-fit.js";

const ACCESS = "access-token-demo";
const SUBMISSION_ID = "11111111-1111-4111-8111-111111111111";

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

test("C6 Creator version preflight blocks reused versions and suggests the next patch", () => {
  const conflict = analyzeCreatorCloudVersionConflict([
    { submissionId: "a", packageId: "character.nene", version: "1.0.0", status: "published" },
    { submissionId: "b", packageId: "character.nene", version: "1.0.1", status: "published" },
    { submissionId: "c", packageId: "character.other", version: "9.9.9", status: "published" },
  ], "character.nene", "1.0.1");
  assert.deepEqual(conflict, {
    packageId: "character.nene",
    version: "1.0.1",
    status: "published",
    submissionId: "b",
    suggestedVersion: "1.0.2",
  });
});

test("C6 Creator version preflight allows a new version and skips unrelated submissions", () => {
  const conflict = analyzeCreatorCloudVersionConflict([
    { submissionId: "a", packageId: "character.nene", version: "1.0.1", status: "review-ready" },
    { submissionId: "b", packageId: "character.other", version: "1.0.2", status: "published" },
  ], "character.nene", "1.0.2");
  assert.equal(conflict, null);
});

test("C6 Studio version conflict UI exposes the suggested patch action", () => {
  const source = readFileSync(new URL("../src/main.jsx", import.meta.url), "utf8");
  assert.match(source, /Suggested next version: \{creatorVersionConflict\.suggestedVersion\}/);
  assert.match(source, /Use \{creatorVersionConflict\.suggestedVersion\}/);
  assert.match(source, /onUseSuggestedCreatorVersion/);
});

test("C6 Animation Studio accepts only browser-safe Creator Cloud URLs", () => {
  const config = readCreatorCloudConfig({
    VITE_OCP_CLOUD_API_URL: "https://example.functions.supabase.co/cloud-api/",
    VITE_SUPABASE_URL: "https://example.supabase.co/",
    VITE_SUPABASE_ANON_KEY: "public-anon-key",
    VITE_OCP_CREATOR_PORTAL_URL: "http://127.0.0.1:3100",
  });
  assert.equal(config.ready, true);
  assert.equal(config.cloudApiUrl, "https://example.functions.supabase.co/cloud-api");
  assert.equal(config.creatorPortalUrl, "http://127.0.0.1:3100");
  assert.throws(() => readCreatorCloudConfig({
    VITE_OCP_CLOUD_API_URL: "http://remote.example/cloud-api",
  }), /HTTPS or local HTTP/);
});


test("C6 Animation Studio OAuth uses a popup-safe non-redirect authorization URL", async () => {
  const calls = [];
  const createClientImpl = () => ({
    auth: {
      async signInWithOAuth(input) {
        calls.push(input);
        return { data: { url: "https://accounts.example/oauth" }, error: null };
      },
      async exchangeCodeForSession(code) {
        calls.push({ exchangeCode: code });
        return {
          data: {
            session: {
              access_token: "desktop-oauth-access-token",
              user: { id: "11111111-1111-4111-8111-111111111111", email: "creator@example.com", user_metadata: {}, app_metadata: { provider: "google" } },
            },
          },
          error: null,
        };
      },
    },
  });
  const identity = createStudioCreatorIdentity({
    supabaseUrl: "https://example.supabase.co",
    supabaseAnonKey: "public-anon-key",
  }, createClientImpl, async () => jsonResponse({ external: { google: true, azure: true } }));

  const google = await identity.signInWithOAuth("google", "http://127.0.0.1:47833/v1/studio-oauth");
  assert.equal(google.url, "https://accounts.example/oauth");
  assert.equal(calls[0].provider, "google");
  assert.equal(calls[0].options.redirectTo, "http://127.0.0.1:47833/v1/studio-oauth");
  assert.equal(calls[0].options.skipBrowserRedirect, true);

  await identity.signInWithOAuth("microsoft", "http://127.0.0.1:5184");
  assert.equal(calls[1].provider, "azure");
  assert.equal(calls[1].options.scopes, "email");
  assert.equal(calls[1].options.skipBrowserRedirect, true);

  const session = await identity.exchangeOAuthCode("desktop-pkce-code");
  assert.equal(session.accessToken, "desktop-oauth-access-token");
  assert.equal(session.user.provider, "google");
  assert.deepEqual(calls[2], { exchangeCode: "desktop-pkce-code" });
});

test("C6 Animation Studio keeps account bearer off direct R2 upload", async () => {
  const calls = [];
  const fetchImpl = async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).endsWith("/v1/creator/uploads")) {
      return jsonResponse({
        submission: { submissionId: SUBMISSION_ID },
        upload: { url: "https://r2.example/private-upload?signature=ok" },
      }, 201);
    }
    if (String(url).startsWith("https://r2.example/")) return new Response(null, { status: 200 });
    if (String(url).endsWith(`/${SUBMISSION_ID}/complete`)) {
      return jsonResponse({ submission: { submissionId: SUBMISSION_ID, status: "uploaded" } });
    }
    if (String(url).endsWith(`/${SUBMISSION_ID}/validate`)) {
      return jsonResponse({ submission: {
        submissionId: SUBMISSION_ID,
        packageId: "character.demo",
        version: "1.0.0",
        status: "validated",
      } });
    }
    throw new Error(`unexpected URL ${url}`);
  };
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, fetchImpl);
  const signedBlob = new Blob([new Uint8Array([1, 2, 3])], { type: "application/octet-stream" });
  const progress = [];
  const result = await client.uploadAndValidate(ACCESS, signedBlob, "character.demo", "1.0.0", (item) => progress.push(item));
  assert.equal(result.status, "validated");
  assert.deepEqual(progress.map((item) => item.stage), ["hashing", "authorizing", "uploading", "completing", "validating", "validated"]);
  assert.equal(progress.at(-1).percent, 94);
  assert.equal(progress.find((item) => item.stage === "uploading").submissionId, SUBMISSION_ID);

  const cloudCalls = calls.filter((call) => call.url.startsWith("https://api.example/"));
  assert.equal(cloudCalls.length, 3);
  for (const call of cloudCalls) assert.equal(call.options.headers.authorization, `Bearer ${ACCESS}`);
  const authorization = cloudCalls.find((call) => call.url.endsWith("/v1/creator/uploads"));
  assert.equal(JSON.parse(authorization.options.body).packageType, "character");

  const r2 = calls.find((call) => call.url.startsWith("https://r2.example/"));
  assert.ok(r2);
  assert.equal(r2.options.method, "PUT");
  assert.equal("authorization" in r2.options.headers, false);
});

test("C6 Animation Studio sends effect.* uploads as effect-pack", async () => {
  const calls = [];
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).endsWith("/v1/creator/uploads")) {
      return jsonResponse({
        submission: { submissionId: SUBMISSION_ID },
        upload: { url: "https://r2.example/private-upload?signature=ok" },
      }, 201);
    }
    if (String(url).startsWith("https://r2.example/")) return new Response(null, { status: 200 });
    if (String(url).endsWith(`/${SUBMISSION_ID}/complete`)) {
      return jsonResponse({ submission: { submissionId: SUBMISSION_ID, status: "uploaded" } });
    }
    if (String(url).endsWith(`/${SUBMISSION_ID}/validate`)) {
      return jsonResponse({ submission: { submissionId: SUBMISSION_ID, packageId: "effect.demo", version: "1.0.0", status: "validated" } });
    }
    throw new Error(`unexpected URL ${url}`);
  });
  const blob = new Blob([new Uint8Array([1, 2, 3])], { type: "application/octet-stream" });
  const result = await client.uploadAndValidate(ACCESS, blob, "effect.demo", "1.0.0");
  assert.equal(result.status, "validated");
  const authorization = calls.find((call) => call.url.endsWith("/v1/creator/uploads"));
  assert.equal(JSON.parse(authorization.options.body).packageType, "effect-pack");
});

test("C6 Animation Studio retries validation without re-uploading the package", async () => {
  const calls = [];
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).endsWith(`/${SUBMISSION_ID}/validate`)) {
      return jsonResponse({ submission: { submissionId: SUBMISSION_ID, packageId: "character.demo", version: "1.0.0", status: "validated" } });
    }
    throw new Error(`unexpected URL ${url}`);
  });
  const progress = [];
  const result = await client.validateSubmission(ACCESS, SUBMISSION_ID, (item) => progress.push(item));
  assert.equal(result.status, "validated");
  assert.deepEqual(progress.map((item) => item.stage), ["validating", "validated"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.headers.authorization, `Bearer ${ACCESS}`);
});

test("C6 Animation Studio submits a validated Studio package for C8 review without re-uploading", async () => {
  const calls = [];
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async (url, options = {}) => {
    calls.push({ url: String(url), options });
    if (String(url).endsWith(`/${SUBMISSION_ID}/review`)) {
      return jsonResponse({ submission: { submissionId: SUBMISSION_ID, packageId: "character.demo", version: "1.0.0", status: "review-ready" } });
    }
    throw new Error(`unexpected URL ${url}`);
  });
  const progress = [];
  const result = await client.submitForReview(ACCESS, SUBMISSION_ID, (item) => progress.push(item));
  assert.equal(result.status, "review-ready");
  assert.deepEqual(progress.map((item) => item.stage), ["submitting-review", "review-ready"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.headers.authorization, `Bearer ${ACCESS}`);
});

test("STUDIO-M1 Desktop signing bypasses the localhost signer API and exposes public identity only", async () => {
  let fetchCalls = 0;
  const bridgeCalls = [];
  const desktopBridge = {
    getSigningIdentity: async () => {
      bridgeCalls.push("identity");
      return {
        publisherId: "ocp.official",
        keyId: "ed25519:desktop-1",
        publicKeyHex: "b".repeat(64),
      };
    },
    signPackageDraft: async ({ bytes }) => {
      bridgeCalls.push("sign");
      return { bytes: new Uint8Array([...bytes, 9]) };
    },
  };
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async () => {
    fetchCalls += 1;
    throw new Error("Desktop signing must not call localhost signer API");
  }, desktopBridge);

  assert.deepEqual(await client.getSigningIdentity(), {
    publisherId: "ocp.official",
    keyId: "ed25519:desktop-1",
    publicKeyHex: "b".repeat(64),
  });
  const signed = await client.signDraft(new Blob([new Uint8Array([1, 2, 3])]));
  assert.deepEqual([...new Uint8Array(await signed.arrayBuffer())], [1, 2, 3, 9]);
  assert.equal(fetchCalls, 0);
  assert.deepEqual(bridgeCalls, ["identity", "sign"]);
  assert.equal(JSON.stringify(await client.getSigningIdentity()).includes("privateSeed"), false);
});

test("STUDIO-M1 packaged Creator Cloud routes API reads through Desktop transport", async () => {
  let fallbackCalls = 0;
  const bridgeCalls = [];
  const desktopBridge = {
    cloudRequest: async (input) => {
      bridgeCalls.push(input);
      return {
        status: 200,
        contentType: "application/json",
        bodyText: JSON.stringify({
          creator: {
            publisherId: "ocp.official",
            displayName: "OCP Official",
            status: "active",
          },
        }),
      };
    },
    uploadPresigned: async () => ({ status: 200 }),
  };
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async () => {
    fallbackCalls += 1;
    throw new Error("browser fetch must not run for packaged Cloud API calls");
  }, desktopBridge);

  const profile = await client.getCreatorProfile(ACCESS);
  assert.equal(profile.publisherId, "ocp.official");
  assert.equal(bridgeCalls.length, 1);
  assert.equal(bridgeCalls[0].url, "https://api.example/cloud-api/v1/creator/profile");
  assert.equal(bridgeCalls[0].method, "GET");
  assert.equal(bridgeCalls[0].accessToken, ACCESS);
  assert.equal(fallbackCalls, 0);
});

test("C6 Animation Studio builds a dedicated same-origin web OAuth callback", () => {
  const redirect = buildWebStudioOAuthRedirect({ origin: "http://localhost:5184" });
  assert.equal(redirect, "http://localhost:5184/oauth/callback");
  const callback = readWebStudioOAuthCallback({
    href: "http://localhost:5184/oauth/callback?code=oauth-code-12345678",
  });
  assert.deepEqual(callback, {
    code: "oauth-code-12345678",
    error: "",
    cleanUrl: "http://localhost:5184/",
  });
  assert.equal(readWebStudioOAuthCallback({ href: "http://localhost:5184/" }), null);
});


test("C6 Animation Studio browser mode is preview-only for package signing", async () => {
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async () => { throw new Error("browser fetch must not be used for local signing"); });
  await assert.rejects(
    () => client.getSigningIdentity(),
    /requires OCP Desktop/,
  );
});


test("C6 Animation Studio keeps OCP Account global and enables Desktop OAuth with email fallback", () => {
  const source = readFileSync(new URL("../src/main.jsx", import.meta.url), "utf8");
  const accountSource = readFileSync(new URL("../src/components/StudioAccountStatus.jsx", import.meta.url), "utf8");
  const topbarSource = readFileSync(new URL("../src/components/StudioTopbar.jsx", import.meta.url), "utf8");
  const modeNavSource = readFileSync(new URL("../src/components/StudioModeNav.jsx", import.meta.url), "utf8");
  const sidebarSource = readFileSync(new URL("../src/components/WorkflowSidebar.jsx", import.meta.url), "utf8");
  assert.match(accountSource, /function StudioAccountStatus\(/);
  assert.match(accountSource, /Create Creator publisher/);
  assert.match(accountSource, /placeholder="user-xxxxxxxx"/);
  assert.doesNotMatch(accountSource, /placeholder="warinza"/);
  assert.match(accountSource, /Link this PC/);
  assert.match(accountSource, /Continue with Google/);
  assert.match(accountSource, /Email sign in/);
  assert.match(accountSource, /Local mode · Sign in to publish/);
  assert.match(accountSource, /session && <button[^>]+onClick=\{onSignOut\}>Sign out<\/button>/);
  assert.match(accountSource, /Creator setup failed/);
  assert.match(accountSource, /state\.status === "error" && <div className="studio-account-error" role="alert">/);
  assert.match(accountSource, /studio-package-prefix">creator\.<\/span>/);
  assert.match(accountSource, /const publisherId = publisherSlug \? `creator\.\$\{publisherSlug\}` : ""/);
  assert.match(accountSource, /state\.status === "needs-profile" && !hasPublishers/);
  assert.match(accountSource, /studio-publisher-switcher/);
  assert.match(accountSource, /\+ Publisher/);
  assert.match(accountSource, /creator\.ocp is reserved for the verified OCP Official account/);
  assert.match(source, /switchCreatorCloudPublisher/);
  assert.match(source, /publisherLocked/);
  assert.match(source, /Local \/ Unverified · ocp\.local/);
  assert.match(source, /const packagePublisherId = creatorCloudProfile\?\.publisherId \|\| "ocp\.local"/);
  assert.match(source, /publisher: \{ id: packagePublisherId, keyId: "local-poc" \}/);
  assert.match(source, /listCreatorCloudPublishers/);
  assert.match(accountSource, /packagedDesktop = window\.location\.protocol === "file:"/);
  assert.match(accountSource, /oauthAvailability\.google/);
  assert.match(source, /beginDesktopStudioOAuth/);
  assert.match(source, /openDesktopStudioOAuth/);
  assert.match(source, /exchangeOAuthCode/);
  const creatorSource = readFileSync(new URL("../src/creator-cloud.js", import.meta.url), "utf8");
  assert.match(creatorSource, /exchangeOAuthCode: \(code\) => defaultCreatorIdentity\.exchangeOAuthCode\(code\)/);
  assert.match(topbarSource, /onPasswordSignIn=\{onPasswordSignIn\}/);
  assert.match(modeNavSource, /Creator Portal ↗/);
  assert.match(sidebarSource, /How to use/);
  const buildStart = source.indexOf("function BuildStepV2(");
  const buildEnd = source.indexOf("const CHARACTER_PACKAGE_PREFIX", buildStart + 1);
  assert.ok(buildStart >= 0 && buildEnd > buildStart);
  const buildSource = source.slice(buildStart, buildEnd);
  assert.doesNotMatch(buildSource, /OCP account email|type=\"password\"|Create creator workspace from local signer/);
  assert.match(buildSource, /OCP Account is managed globally in the top bar/);
});


test("Animation Studio auto-fits small landscape subjects without shrinking portrait subjects", () => {
  const landscape = computeSubjectPlacement({ x: 176, y: 126, width: 160, height: 252 }, 512, 512);
  assert.ok(landscape);
  assert.equal(landscape.applied, true);
  assert.ok(landscape.scale > 1.5 && landscape.scale < 2.0);
  assert.ok(landscape.drawHeight <= 512);

  const portrait = computeSubjectPlacement({ x: 110, y: 18, width: 292, height: 476 }, 512, 512);
  assert.ok(portrait);
  assert.equal(portrait.scale, 1);
  assert.equal(portrait.applied, false);
});

test("Animation Studio uses one stable union bound across animation frames", () => {
  const union = unionSubjectBounds([
    { x: 180, y: 130, width: 150, height: 250 },
    { x: 168, y: 118, width: 178, height: 266 },
    { x: 174, y: 124, width: 166, height: 258 },
  ]);
  assert.deepEqual(union, { x: 168, y: 118, width: 178, height: 266 });
  const placement = computeSubjectPlacement(union, 512, 512);
  assert.ok(placement?.applied);
  assert.ok(placement.scale > 1);
});

test("Animation Studio crops native landscape pixels before the single 512 resize", () => {
  const sourcePlacement = computeSourceCropPlacement(
    { x: 470, y: 82, width: 340, height: 590 },
    1280,
    720,
    512,
    512,
  );
  assert.ok(sourcePlacement);
  assert.ok(sourcePlacement.cropWidth < 1280);
  assert.ok(sourcePlacement.cropHeight < 720);
  assert.ok(sourcePlacement.drawHeight > 470 && sourcePlacement.drawHeight <= 512);
  assert.ok(sourcePlacement.drawWidth <= 512);
  assert.equal(sourcePlacement.sourceWidth, 1280);
  assert.equal(sourcePlacement.sourceHeight, 720);
});


test("Animation Studio standardizes standing clips to one character master scale", () => {
  const master = createCharacterMasterProfile(
    { x: 470, y: 82, width: 340, height: 590 },
    1280,
    720,
    512,
    512,
    { referenceAnimation: "idle" },
  );
  assert.ok(master);
  assert.equal(master.referenceAnimation, "idle");

  const walk = computeStandardizedSourcePlacement(
    { x: 500, y: 130, width: 300, height: 500 },
    1280,
    720,
    512,
    512,
    master,
    "walk_left",
  );
  assert.ok(walk?.standardized);
  assert.equal(walk.poseGroup, "standing");
  assert.equal(walk.cropWidth, 1280);
  assert.equal(walk.cropHeight, 720);
  assert.ok(walk.correction > 1);
  assert.ok(characterScaleDeviation(walk, master, 720, 512) > 0);
});

test("Animation Studio keeps pose-aware ground clips at the locked master scale", () => {
  const master = createCharacterMasterProfile(
    { x: 470, y: 82, width: 340, height: 590 },
    1280,
    720,
    512,
    512,
  );
  const sit = computeStandardizedSourcePlacement(
    { x: 430, y: 310, width: 420, height: 310 },
    1280,
    720,
    512,
    512,
    master,
    "sit",
  );
  assert.equal(poseGroupForAnimation("sit"), "ground");
  assert.equal(sit.poseGroup, "ground");
  assert.equal(sit.correction, 1);
  assert.equal(sit.standardized, true);
});


test("Animation Studio Cleanup V6 Auto Matte measures after the same connected chroma/de-spill pipeline used for rendering", () => {
  const source = readFileSync(new URL("../src/main.jsx", import.meta.url), "utf8");
  const measureStart = source.indexOf("function measureVideoSubjectBounds");
  const measureEnd = source.indexOf("function pullForegroundColor", measureStart);
  const renderStart = source.indexOf("function renderVideoFrame");
  const renderEnd = source.indexOf("const SUBJECT_ALPHA_THRESHOLD", renderStart);
  assert.ok(measureStart >= 0 && measureEnd > measureStart);
  assert.ok(renderStart >= 0 && renderEnd > renderStart);
  assert.match(source.slice(measureStart, measureEnd), /cleanCharacterImageData\(image, preset\)/);
  assert.match(source.slice(renderStart, renderEnd), /cleanCharacterImageData\(image, preset\)/);

  const cleanupStart = source.indexOf("function cleanCharacterImageData");
  const cleanupEnd = source.indexOf("function renderVideoFrame", cleanupStart);
  const cleanupSource = source.slice(cleanupStart, cleanupEnd);
  const despillCount = (cleanupSource.match(/despillRetainedForegroundEdges\(image, preset\)/g) ?? []).length;
  assert.equal(despillCount, 2);
});
