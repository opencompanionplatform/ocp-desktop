import { createClient } from "@supabase/supabase-js";

import { createDesktopCreatorCloudFetch, getDesktopSigningIdentity, getDesktopStudioBridge, provisionDesktopSigningIdentity, signPackageWithDesktop } from "./desktop-bridge.js";

const PACKAGE_ID_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const SEMVER_PATTERN = /^(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const KEY_ID_PATTERN = /^ed25519:[A-Za-z0-9._-]+$/;
const HEX_32_PATTERN = /^[0-9a-f]{64}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_PACKAGE_BYTES = 64 * 1024 * 1024;

function publicText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function normalizeWebUrl(value, label, { allowPath = true } = {}) {
  const raw = publicText(value);
  if (!raw) return "";
  const url = new URL(raw);
  const localHttp = url.protocol === "http:" && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
  if (url.protocol !== "https:" && !localHttp) throw new TypeError(`${label} must use HTTPS or local HTTP`);
  if (url.username || url.password) throw new TypeError(`${label} must not contain credentials`);
  if (!allowPath && url.pathname !== "/") throw new TypeError(`${label} must be an origin`);
  url.pathname = allowPath ? url.pathname.replace(/\/+$/, "") : "/";
  url.search = "";
  url.hash = "";
  return allowPath ? url.toString().replace(/\/$/, "") : url.origin;
}

export function readCreatorCloudConfig(env = import.meta.env ?? {}) {
  const cloudApiUrl = normalizeWebUrl(env.VITE_OCP_CLOUD_API_URL, "OCP Cloud API URL");
  const supabaseUrl = normalizeWebUrl(env.VITE_SUPABASE_URL, "Supabase URL");
  const supabaseAnonKey = publicText(env.VITE_SUPABASE_ANON_KEY);
  const creatorPortalUrl = normalizeWebUrl(env.VITE_OCP_CREATOR_PORTAL_URL, "Creator Portal URL", { allowPath: false });
  return {
    cloudApiUrl,
    supabaseUrl,
    supabaseAnonKey,
    creatorPortalUrl,
    ready: Boolean(cloudApiUrl && supabaseUrl && supabaseAnonKey),
  };
}

export function buildWebStudioOAuthRedirect(locationLike = globalThis.location) {
  const origin = publicText(locationLike?.origin);
  if (!origin) throw new TypeError("Web Studio OAuth origin is unavailable");
  return new URL("/oauth/callback", origin).toString();
}

export function readWebStudioOAuthCallback(locationLike = globalThis.location) {
  const href = publicText(locationLike?.href);
  if (!href) return null;
  const url = new URL(href);
  if (url.pathname !== "/oauth/callback") return null;
  const code = publicText(url.searchParams.get("code"));
  const error = publicText(url.searchParams.get("error_description") || url.searchParams.get("error"));
  const cleanUrl = new URL("/", url.origin).toString();
  return { code, error, cleanUrl };
}

function validateEmail(value) {
  const email = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new TypeError("email is invalid");
  return email;
}

function validatePassword(value) {
  if (typeof value !== "string" || value.length < 8 || value.length > 1024) throw new TypeError("password is invalid");
  return value;
}

function projectSession(session) {
  if (!session) return null;
  if (typeof session.access_token !== "string" || session.access_token.length < 8 || !session.user || typeof session.user.id !== "string") {
    throw new Error("identity provider returned an invalid session");
  }
  const userMetadata = session.user.user_metadata && typeof session.user.user_metadata === "object" ? session.user.user_metadata : {};
  const appMetadata = session.user.app_metadata && typeof session.user.app_metadata === "object" ? session.user.app_metadata : {};
  const displayName = [userMetadata.full_name, userMetadata.name, userMetadata.user_name]
    .find((value) => typeof value === "string" && value.trim().length > 0);
  return {
    accessToken: session.access_token,
    user: {
      id: session.user.id,
      email: typeof session.user.email === "string" ? session.user.email : null,
      displayName: displayName?.trim() ?? null,
      provider: typeof appMetadata.provider === "string" ? appMetadata.provider.trim().toLowerCase() : null,
    },
  };
}

export function createStudioCreatorIdentity(config, createClientImpl = createClient, fetchImpl = fetch) {
  if (!config.supabaseUrl || !config.supabaseAnonKey) throw new Error("Creator Cloud authentication is not configured");
  const client = createClientImpl(config.supabaseUrl, config.supabaseAnonKey, {
    auth: { flowType: "pkce", persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  });
  const providerError = (error) => { if (error) throw new Error(error.message || "Authentication failed"); };
  return {
    async getSession() {
      const { data, error } = await client.auth.getSession();
      providerError(error);
      return projectSession(data?.session ?? null);
    },
    onAuthStateChange(callback) {
      const { data } = client.auth.onAuthStateChange((event, session) => callback(event, projectSession(session)));
      return () => data?.subscription?.unsubscribe?.();
    },
    async getOAuthAvailability() {
      const response = await fetchImpl(`${config.supabaseUrl}/auth/v1/settings`, {
        headers: { apikey: config.supabaseAnonKey },
      });
      if (!response.ok) return { google: false, microsoft: false };
      const payload = await response.json().catch(() => null);
      const external = payload && typeof payload.external === "object" && payload.external !== null ? payload.external : {};
      return { google: external.google === true, microsoft: external.azure === true };
    },
    async signIn(email, password) {
      const { data, error } = await client.auth.signInWithPassword({ email: validateEmail(email), password: validatePassword(password) });
      providerError(error);
      return projectSession(data?.session ?? null);
    },
    async signInWithOAuth(provider, redirectTo) {
      const providerMap = { google: "google", microsoft: "azure" };
      const resolvedProvider = providerMap[provider];
      if (!resolvedProvider) throw new TypeError("OAuth provider is not supported");
      const redirectUrl = normalizeWebUrl(redirectTo, "OAuth redirect URL");
      const options = resolvedProvider === "azure"
        ? { redirectTo: redirectUrl, scopes: "email", skipBrowserRedirect: true }
        : { redirectTo: redirectUrl, skipBrowserRedirect: true };
      const { data, error } = await client.auth.signInWithOAuth({ provider: resolvedProvider, options });
      providerError(error);
      return data;
    },
    async exchangeOAuthCode(code) {
      if (typeof code !== "string" || code.trim().length < 8) throw new TypeError("OAuth authorization code is invalid");
      const { data, error } = await client.auth.exchangeCodeForSession(code.trim());
      providerError(error);
      return projectSession(data?.session ?? null);
    },
    async signOut() {
      const { error } = await client.auth.signOut();
      providerError(error);
    },
  };
}

async function parseJsonResponse(response, label) {
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const errorObject = payload && typeof payload === "object" && payload.error && typeof payload.error === "object"
      ? payload.error
      : null;
    const providerMessage = errorObject && typeof errorObject.message === "string"
      ? errorObject.message
      : payload && typeof payload === "object" && typeof payload.error === "string" ? payload.error : null;
    const providerCode = errorObject && typeof errorObject.code === "string" ? errorObject.code : "";
    const correlationId = errorObject && typeof errorObject.correlationId === "string" ? errorObject.correlationId : "";
    const detail = [String(response.status), providerCode, correlationId ? `ref ${correlationId}` : ""].filter(Boolean).join(" · ");
    const error = new Error(`${label}: ${providerMessage || "request failed"}${detail ? ` (${detail})` : ""}`);
    error.status = response.status;
    error.code = providerCode;
    error.correlationId = correlationId;
    throw error;
  }
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) throw new Error(`${label} returned invalid data`);
  return payload;
}

function bearer(accessToken) {
  if (typeof accessToken !== "string" || accessToken.length < 8) throw new TypeError("Creator Cloud session is required");
  return { authorization: `Bearer ${accessToken}`, accept: "application/json" };
}

function projectSigningIdentity(value) {
  const identity = value && typeof value === "object" && !Array.isArray(value) ? value : null;
  if (!identity) throw new Error("local signing identity is invalid");
  const publisherId = publicText(identity.publisherId);
  const keyId = publicText(identity.keyId);
  const publicKeyHex = publicText(identity.publicKeyHex).toLowerCase();
  if (!PACKAGE_ID_PATTERN.test(publisherId) || !KEY_ID_PATTERN.test(keyId) || !HEX_32_PATTERN.test(publicKeyHex)) throw new Error("local signing identity is invalid");
  return { publisherId, keyId, publicKeyHex };
}

function normalizeMarketplaceIdentityInput(packageId, displayName) {
  const normalizedPackageId = publicText(packageId).toLowerCase();
  const normalizedDisplayName = publicText(displayName).replace(/\s+/g, " ");
  if (!/^character\.[a-z0-9]+(?:-[a-z0-9]+)*$/.test(normalizedPackageId) || normalizedPackageId.length > 128) {
    throw new TypeError("marketplace package id is invalid");
  }
  if (normalizedDisplayName.length < 2 || normalizedDisplayName.length > 80) {
    throw new TypeError("marketplace display name is invalid");
  }
  return { packageId: normalizedPackageId, displayName: normalizedDisplayName };
}

function projectMarketplaceIdentity(value) {
  const identity = value && typeof value === "object" && !Array.isArray(value) ? value : null;
  if (!identity) throw new Error("Marketplace identity returned invalid data");
  const decision = publicText(identity.decision);
  if (!["available", "reserved-by-you", "owned-published", "owned-submission", "unavailable", "reserved-name", "invalid-display-name"].includes(decision)) {
    throw new Error("Marketplace identity returned an invalid decision");
  }
  const reservationExpiresAt = identity.reservationExpiresAt == null ? null : publicText(identity.reservationExpiresAt);
  if (reservationExpiresAt !== null && Number.isNaN(Date.parse(reservationExpiresAt))) throw new Error("Marketplace identity returned an invalid reservation expiry");
  return { decision, reservationExpiresAt };
}

export function createStudioCreatorCloud(config, fetchImpl = fetch, desktopBridge = getDesktopStudioBridge()) {
  const api = config.cloudApiUrl;
  const requestFetch = createDesktopCreatorCloudFetch(api, desktopBridge, fetchImpl);
  return {
    async getSigningIdentity() {
      if (desktopBridge) {
        const identity = await getDesktopSigningIdentity(desktopBridge);
        return projectSigningIdentity(identity);
      }
      throw new Error("Creator package signing requires OCP Desktop. Browser mode is preview/development only.");
    },
    async provisionSigningIdentity(publisherId) {
      if (!desktopBridge) throw new Error("Creator signing provisioning requires OCP Desktop");
      const identity = await provisionDesktopSigningIdentity(publisherId, desktopBridge);
      return projectSigningIdentity(identity);
    },
    async enrollKey(accessToken, identity) {
      const signer = projectSigningIdentity(identity);
      const response = await requestFetch(`${api}/v1/creator/keys`, {
        method: "POST",
        headers: { ...bearer(accessToken), "content-type": "application/json" },
        body: JSON.stringify({ publisherId: signer.publisherId, keyId: signer.keyId, publicKeyHex: signer.publicKeyHex }),
      });
      const payload = await parseJsonResponse(response, "Creator key enrollment");
      return payload.creator;
    },
    async signDraft(blob) {
      if (!(blob instanceof Blob) || blob.size < 1 || blob.size > MAX_PACKAGE_BYTES) throw new TypeError("draft package is invalid");
      if (desktopBridge) {
        const signed = await signPackageWithDesktop(blob, desktopBridge);
        if (!(signed instanceof Blob) || signed.size < 1 || signed.size > MAX_PACKAGE_BYTES) throw new Error("Desktop signer returned an invalid package");
        return signed;
      }
      throw new Error("Creator package signing requires OCP Desktop. Browser mode is preview/development only.");
    },
    async getCreatorProfile(accessToken) {
      const response = await requestFetch(`${api}/v1/creator/profile`, { headers: bearer(accessToken) });
      if (response.status === 404) return null;
      const payload = await parseJsonResponse(response, "Creator profile");
      return payload.creator;
    },
    async listCreatorPublishers(accessToken) {
      const response = await requestFetch(`${api}/v1/creator/publishers`, { headers: bearer(accessToken) });
      const payload = await parseJsonResponse(response, "Creator publishers");
      return Array.isArray(payload.items) ? payload.items : [];
    },
    async onboard(accessToken, { displayName, ...identity }) {
      const options = {
        method: "POST",
        headers: { ...bearer(accessToken), "content-type": "application/json" },
        body: JSON.stringify({ ...identity, displayName }),
      };
      let response = await requestFetch(`${api}/v1/creator/publishers`, options);
      if (response.status === 404) {
        // Compatibility with Cloud deployments from before multi-publisher support.
        response = await requestFetch(`${api}/v1/creator/profile`, options);
      }
      const payload = await parseJsonResponse(response, "Creator onboarding");
      return payload.creator;
    },
    async getPackageIdentity(accessToken, packageId, displayName, publisherId = "") {
      const input = normalizeMarketplaceIdentityInput(packageId, displayName);
      const url = new URL(`${api}/v1/creator/identity`);
      url.searchParams.set("packageId", input.packageId);
      url.searchParams.set("displayName", input.displayName);
      if (publisherId) url.searchParams.set("publisherId", publicText(publisherId));
      const response = await requestFetch(url.toString(), { headers: bearer(accessToken) });
      const payload = await parseJsonResponse(response, "Marketplace identity");
      return projectMarketplaceIdentity(payload.identity);
    },
    async reservePackageIdentity(accessToken, packageId, displayName, publisherId = "") {
      const input = normalizeMarketplaceIdentityInput(packageId, displayName);
      const response = await requestFetch(`${api}/v1/creator/identity/reservations`, {
        method: "POST",
        headers: { ...bearer(accessToken), "content-type": "application/json" },
        body: JSON.stringify(publisherId ? { ...input, publisherId: publicText(publisherId) } : input),
      });
      const payload = await parseJsonResponse(response, "Marketplace identity reservation");
      return projectMarketplaceIdentity(payload.identity);
    },
    async releasePackageIdentity(accessToken, packageId, publisherId = "") {
      const input = normalizeMarketplaceIdentityInput(packageId, "ok");
      const url = new URL(`${api}/v1/creator/identity/reservations/${encodeURIComponent(input.packageId)}`);
      if (publisherId) url.searchParams.set("publisherId", publicText(publisherId));
      const response = await requestFetch(url.toString(), {
        method: "DELETE",
        headers: bearer(accessToken),
      });
      const payload = await parseJsonResponse(response, "Marketplace identity release");
      const identity = payload.identity && typeof payload.identity === "object" ? payload.identity : null;
      const status = publicText(identity?.status);
      if (status !== "released") throw new Error("Marketplace identity release returned invalid data");
      return { status };
    },
    async listSubmissions(accessToken, publisherId = "") {
      const url = new URL(`${api}/v1/creator/submissions`);
      if (publisherId) url.searchParams.set("publisherId", publicText(publisherId));
      const response = await requestFetch(url.toString(), { headers: bearer(accessToken) });
      const payload = await parseJsonResponse(response, "Creator submissions");
      return Array.isArray(payload.items) ? payload.items : [];
    },
    async uploadAndValidate(accessToken, signedBlob, packageId, version, publisherId = "", onProgress = () => {}) {
      if (typeof publisherId === "function") {
        onProgress = publisherId;
        publisherId = "";
      }
      if (!(signedBlob instanceof Blob) || signedBlob.size < 1 || signedBlob.size > MAX_PACKAGE_BYTES) throw new TypeError("signed package is invalid");
      if (!PACKAGE_ID_PATTERN.test(packageId) || packageId.length > 128) throw new TypeError("package id is invalid");
      const packageType = packageId.startsWith("character.")
        ? "character"
        : packageId.startsWith("effect.")
          ? "effect-pack"
          : "";
      if (!packageType) throw new TypeError("package id does not map to a supported Creator package type");
      if (!SEMVER_PATTERN.test(version) || version.length > 128) throw new TypeError("version is invalid");
      onProgress({ stage: "hashing", percent: 8, message: "Hashing signed package locally..." });
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await signedBlob.arrayBuffer()));
      const archiveSha256 = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
      const fileName = `${packageId.replaceAll(".", "-")}-v${version}.ocp`;

      onProgress({ stage: "authorizing", percent: 18, message: "Creating private Creator Cloud submission..." });
      const createResponse = await requestFetch(`${api}/v1/creator/uploads`, {
        method: "POST",
        headers: { ...bearer(accessToken), "content-type": "application/json" },
        body: JSON.stringify({ ...(publisherId ? { publisherId: publicText(publisherId) } : {}), packageId, packageType, version, fileName, sizeBytes: signedBlob.size, archiveSha256 }),
      });
      const prepared = await parseJsonResponse(createResponse, "Creator upload authorization");
      const submissionId = publicText(prepared?.submission?.submissionId);
      const uploadUrl = publicText(prepared?.upload?.url);
      if (!submissionId || !uploadUrl.startsWith("https://")) throw new Error("Creator upload authorization returned invalid data");

      let activeStage = "uploading";
      try {
        onProgress({ stage: "uploading", percent: 35, message: "Uploading signed package to private R2 staging...", submissionId });
        const uploadResponse = await requestFetch(uploadUrl, {
          method: "PUT",
          headers: { "content-type": "application/octet-stream" },
          body: signedBlob,
        });
        if (!uploadResponse.ok) throw new Error(`Private package upload failed (${uploadResponse.status})`);

        activeStage = "completing";
        onProgress({ stage: "completing", percent: 72, message: "Upload complete. Finalizing private submission...", submissionId });
        const completeResponse = await requestFetch(`${api}/v1/creator/submissions/${encodeURIComponent(submissionId)}/complete`, {
          method: "POST",
          headers: bearer(accessToken),
        });
        await parseJsonResponse(completeResponse, "Creator upload completion");

        activeStage = "validating";
        onProgress({ stage: "validating", percent: 88, message: "Cloud validation in progress...", submissionId });
        const validationResponse = await requestFetch(`${api}/v1/creator/submissions/${encodeURIComponent(submissionId)}/validate`, {
          method: "POST",
          headers: bearer(accessToken),
        });
        const validated = await parseJsonResponse(validationResponse, "Creator Cloud validation");
        onProgress({ stage: "validated", percent: 94, message: "Cloud validation passed.", submissionId });
        return validated.submission;
      } catch (error) {
        if (error && typeof error === "object") {
          error.submissionId = submissionId;
          if (!error.stage) error.stage = activeStage;
        }
        throw error;
      }
    },
    async validateSubmission(accessToken, submissionId, onProgress = () => {}) {
      if (!UUID_PATTERN.test(submissionId)) throw new TypeError("submission id is invalid");
      onProgress({ stage: "validating", percent: 88, message: "Cloud validation in progress...", submissionId });
      try {
        const validationResponse = await requestFetch(`${api}/v1/creator/submissions/${encodeURIComponent(submissionId)}/validate`, {
          method: "POST",
          headers: bearer(accessToken),
        });
        const validated = await parseJsonResponse(validationResponse, "Creator Cloud validation");
        onProgress({ stage: "validated", percent: 94, message: "Cloud validation passed.", submissionId });
        return validated.submission;
      } catch (error) {
        if (error && typeof error === "object") {
          error.submissionId = submissionId;
          error.stage = "validating";
        }
        throw error;
      }
    },
    async submitForReview(accessToken, submissionId, onProgress = () => {}) {
      if (!UUID_PATTERN.test(submissionId)) throw new TypeError("submission id is invalid");
      onProgress({ stage: "submitting-review", percent: 97, message: "Submitting validated package for C8 review...", submissionId });
      try {
        const response = await requestFetch(`${api}/v1/creator/submissions/${encodeURIComponent(submissionId)}/review`, {
          method: "POST",
          headers: bearer(accessToken),
        });
        const payload = await parseJsonResponse(response, "Creator review submission");
        onProgress({ stage: "review-ready", percent: 100, message: "Submitted for C8 moderation review.", submissionId });
        return payload.submission;
      } catch (error) {
        if (error && typeof error === "object") {
          error.submissionId = submissionId;
          error.stage = "submitting-review";
        }
        throw error;
      }
    },
  };
}

const defaultCreatorConfig = readCreatorCloudConfig(import.meta.env ?? {});
const defaultCreatorIdentity = defaultCreatorConfig.ready ? createStudioCreatorIdentity(defaultCreatorConfig) : null;
const defaultCreatorCloud = defaultCreatorConfig.ready ? createStudioCreatorCloud(defaultCreatorConfig) : null;

export const creatorCloudReady = defaultCreatorConfig.ready;
export const creatorPortalUrl = defaultCreatorConfig.creatorPortalUrl;

export const creatorIdentity = defaultCreatorIdentity ? {
  getSession: () => defaultCreatorIdentity.getSession(),
  getOAuthAvailability: () => defaultCreatorIdentity.getOAuthAvailability(),
  signIn: (email, password) => defaultCreatorIdentity.signIn(email, password),
  signInWithOAuth: (provider, redirectTo) => defaultCreatorIdentity.signInWithOAuth(provider, redirectTo),
  exchangeOAuthCode: (code) => defaultCreatorIdentity.exchangeOAuthCode(code),
  signOut: () => defaultCreatorIdentity.signOut(),
  onAuthStateChange(callback) {
    return defaultCreatorIdentity.onAuthStateChange((_event, session) => callback(session));
  },
} : null;

export async function getCreatorCloudProfile(accessToken) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  const profile = await defaultCreatorCloud.getCreatorProfile(accessToken);
  if (!profile) throw new Error("Complete Creator Portal onboarding before uploading from Animation Studio");
  return profile;
}

export async function findCreatorCloudProfile(accessToken) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.getCreatorProfile(accessToken);
}

export async function listCreatorCloudPublishers(accessToken) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.listCreatorPublishers(accessToken);
}

export async function findPendingCreatorCloudSubmission(accessToken, publisherId = "") {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  const items = await defaultCreatorCloud.listSubmissions(accessToken, publisherId);
  const resumable = new Set(["uploaded", "validated", "review-ready"]);
  return items.find((item) => item && resumable.has(item.status) && typeof item.submissionId === "string") ?? null;
}

function stableSemverParts(value) {
  if (typeof value !== "string" || !SEMVER_PATTERN.test(value)) return null;
  const stable = value.split(/[+-]/, 1)[0];
  const parts = stable.split(".").map((part) => Number(part));
  return parts.length === 3 && parts.every(Number.isSafeInteger) ? parts : null;
}

function compareSemverParts(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

export function analyzeCreatorCloudVersionConflict(items, packageId, version) {
  const normalizedPackageId = publicText(packageId).toLowerCase();
  const normalizedVersion = publicText(version);
  if (!PACKAGE_ID_PATTERN.test(normalizedPackageId) || normalizedPackageId.length > 128) throw new TypeError("package id is invalid");
  if (!SEMVER_PATTERN.test(normalizedVersion)) throw new TypeError("version must be SemVer");
  const submissions = Array.isArray(items) ? items.filter((item) => item && item.packageId === normalizedPackageId && typeof item.version === "string") : [];
  const conflict = submissions.find((item) => item.version === normalizedVersion) ?? null;
  if (!conflict) return null;

  const versions = submissions
    .map((item) => stableSemverParts(item.version))
    .filter(Boolean);
  const requested = stableSemverParts(normalizedVersion);
  if (requested) versions.push(requested);
  const highest = versions.sort(compareSemverParts).at(-1) ?? requested ?? [0, 0, 0];
  const suggestedVersion = `${highest[0]}.${highest[1]}.${highest[2] + 1}`;
  return {
    packageId: normalizedPackageId,
    version: normalizedVersion,
    status: publicText(conflict.status) || "existing",
    submissionId: publicText(conflict.submissionId) || null,
    suggestedVersion,
  };
}

export async function preflightCreatorCloudVersion(accessToken, packageId, version, publisherId = "") {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  const items = await defaultCreatorCloud.listSubmissions(accessToken, publisherId);
  return analyzeCreatorCloudVersionConflict(items, packageId, version);
}

export async function getCreatorCloudSigningIdentity() {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.getSigningIdentity();
}

export async function provisionCreatorCloudSigningIdentity(publisherId) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.provisionSigningIdentity(publisherId);
}

export async function enrollCreatorCloudSigningKey(accessToken, identity) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.enrollKey(accessToken, identity);
}

export async function createCreatorCloudWorkspace(accessToken, publisherId, displayName) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  const signer = await defaultCreatorCloud.provisionSigningIdentity(publisherId);
  const normalizedDisplayName = typeof displayName === "string" && displayName.trim().length > 0
    ? displayName.trim()
    : signer.publisherId;
  return await defaultCreatorCloud.onboard(accessToken, { ...signer, displayName: normalizedDisplayName });
}

export async function linkCreatorCloudDesktopSigner(accessToken, profile) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  if (!profile?.publisherId) throw new Error("Creator profile is unavailable");
  const signer = await defaultCreatorCloud.provisionSigningIdentity(profile.publisherId);
  const alreadyActive = Array.isArray(profile.keys)
    && profile.keys.some((key) => key?.keyId === signer.keyId && key?.status === "active");
  if (alreadyActive) return { profile, signer };
  const nextProfile = await defaultCreatorCloud.enrollKey(accessToken, signer);
  return { profile: nextProfile, signer };
}

export async function checkCreatorCloudPackageIdentity(accessToken, packageId, displayName, publisherId = "") {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.getPackageIdentity(accessToken, packageId, displayName, publisherId);
}

export async function reserveCreatorCloudPackageIdentity(accessToken, packageId, displayName, publisherId = "") {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.reservePackageIdentity(accessToken, packageId, displayName, publisherId);
}

export async function releaseCreatorCloudPackageIdentity(accessToken, packageId, publisherId = "") {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.releasePackageIdentity(accessToken, packageId, publisherId);
}

export async function signArchiveForCreatorCloud(blob) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.signDraft(blob);
}

export async function uploadSignedArchiveToCreatorCloud(accessToken, { blob, packageId, version, publisherId = "", onProgress }) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.uploadAndValidate(accessToken, blob, packageId, version, publisherId, onProgress);
}

export async function validateCreatorCloudSubmission(accessToken, submissionId, onProgress) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.validateSubmission(accessToken, submissionId, onProgress);
}

export async function submitCreatorCloudForReview(accessToken, submissionId, onProgress) {
  if (!defaultCreatorCloud) throw new Error("Creator Cloud is not configured");
  return await defaultCreatorCloud.submitForReview(accessToken, submissionId, onProgress);
}
