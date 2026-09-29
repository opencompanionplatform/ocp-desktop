import {
  MAX_STUDIO_PACKAGE_BYTES,
  type StudioCloudMethod,
  type StudioCloudRequestInput,
  type StudioPresignedUploadInput,
} from "./studio-bridge";

export const DEFAULT_OCP_STUDIO_CLOUD_API_URL =
  "https://cpetxqbqyrtpppbicdbw.supabase.co/functions/v1/cloud-api";

const MAX_CLOUD_REQUEST_BODY_CHARS = 512_000;
const MAX_CLOUD_RESPONSE_BODY_CHARS = 2_000_000;
const MAX_ACCESS_TOKEN_CHARS = 16_384;
const PACKAGE_ID_PATTERN = /^character\.[a-z0-9]+(?:-[a-z0-9]+)*$/;
const PUBLISHER_ID_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type RouteRule = Readonly<{
  method: StudioCloudMethod;
  match: (url: URL, relativePath: string) => boolean;
}>;

const ROUTES: readonly RouteRule[] = [
  { method: "GET", match: (url, path) => path === "/v1/creator/profile" && url.search === "" },
  { method: "POST", match: (url, path) => path === "/v1/creator/profile" && url.search === "" },
  { method: "GET", match: (url, path) => path === "/v1/creator/publishers" && url.search === "" },
  { method: "POST", match: (url, path) => path === "/v1/creator/publishers" && url.search === "" },
  { method: "POST", match: (url, path) => path === "/v1/creator/keys" && url.search === "" },
  {
    method: "GET",
    match: (url, path) => {
      if (path !== "/v1/creator/identity") return false;
      const keys = [...url.searchParams.keys()].sort();
      const legacy = keys.length === 2 && keys[0] === "displayName" && keys[1] === "packageId";
      const scoped = keys.length === 3 && keys[0] === "displayName" && keys[1] === "packageId" && keys[2] === "publisherId";
      if (!legacy && !scoped) return false;
      const packageId = url.searchParams.get("packageId") ?? "";
      const displayName = url.searchParams.get("displayName") ?? "";
      const publisherId = url.searchParams.get("publisherId") ?? "";
      return PACKAGE_ID_PATTERN.test(packageId)
        && displayName.trim().length >= 2
        && displayName.trim().length <= 80
        && (!publisherId || PUBLISHER_ID_PATTERN.test(publisherId));
    },
  },
  { method: "POST", match: (url, path) => path === "/v1/creator/identity/reservations" && url.search === "" },
  {
    method: "DELETE",
    match: (url, path) => {
      const prefix = "/v1/creator/identity/reservations/";
      if (!path.startsWith(prefix)) return false;
      const queryKeys = [...url.searchParams.keys()];
      if (queryKeys.length > 1 || (queryKeys.length === 1 && queryKeys[0] !== "publisherId")) return false;
      const publisherId = url.searchParams.get("publisherId") ?? "";
      if (publisherId && !PUBLISHER_ID_PATTERN.test(publisherId)) return false;
      try {
        const packageId = decodeURIComponent(path.slice(prefix.length));
        return PACKAGE_ID_PATTERN.test(packageId);
      } catch {
        return false;
      }
    },
  },
  {
    method: "GET",
    match: (url, path) => {
      if (path !== "/v1/creator/submissions") return false;
      const queryKeys = [...url.searchParams.keys()];
      if (queryKeys.length === 0) return true;
      return queryKeys.length === 1
        && queryKeys[0] === "publisherId"
        && PUBLISHER_ID_PATTERN.test(url.searchParams.get("publisherId") ?? "");
    },
  },
  { method: "POST", match: (url, path) => path === "/v1/creator/uploads" && url.search === "" },
  {
    method: "POST",
    match: (url, path) => {
      if (url.search !== "") return false;
      const match = /^\/v1\/creator\/submissions\/([^/]+)\/(complete|validate|review)$/.exec(path);
      return Boolean(match && UUID_PATTERN.test(match[1]));
    },
  },
];

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const sorted = [...expected].sort();
  return actual.length === sorted.length && actual.every((key, index) => key === sorted[index]);
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

export function resolveStudioCloudApiBase(value: unknown): URL {
  const raw = typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : DEFAULT_OCP_STUDIO_CLOUD_API_URL;
  const url = new URL(raw);
  if (
    url.protocol !== "https:"
    || url.username
    || url.password
    || url.search
    || url.hash
    || url.pathname.replace(/\/+$/, "") !== "/functions/v1/cloud-api"
  ) {
    throw new Error("OCP Studio Cloud API URL is invalid");
  }
  url.pathname = "/functions/v1/cloud-api";
  return url;
}

export function sanitizeStudioCloudRequest(
  value: unknown,
  allowedBase: URL,
): StudioCloudRequestInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["url", "method", "accessToken", "body"])) return null;
  if (typeof source.url !== "string" || source.url.length > 4_096) return null;
  if (source.method !== "GET" && source.method !== "POST" && source.method !== "DELETE") return null;
  if (typeof source.accessToken !== "string" || source.accessToken.length < 8 || source.accessToken.length > MAX_ACCESS_TOKEN_CHARS) return null;
  if (source.body !== null && typeof source.body !== "string") return null;
  if (typeof source.body === "string" && source.body.length > MAX_CLOUD_REQUEST_BODY_CHARS) return null;
  if (source.method !== "POST" && source.body !== null) return null;

  let url: URL;
  try {
    url = new URL(source.url);
  } catch {
    return null;
  }
  if (
    url.protocol !== "https:"
    || url.origin !== allowedBase.origin
    || url.username
    || url.password
    || url.hash
    || !url.pathname.startsWith(allowedBase.pathname + "/")
  ) return null;

  const relativePath = url.pathname.slice(allowedBase.pathname.length);
  if (!ROUTES.some((rule) => rule.method === source.method && rule.match(url, relativePath))) return null;

  return {
    url: url.toString(),
    method: source.method,
    accessToken: source.accessToken,
    body: source.body,
  };
}

export function sanitizeStudioPresignedUploadInput(value: unknown): StudioPresignedUploadInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["url", "bytes"])) return null;
  if (typeof source.url !== "string" || source.url.length > 8_192) return null;

  let bytes: Uint8Array;
  if (source.bytes instanceof Uint8Array) bytes = source.bytes;
  else if (source.bytes instanceof ArrayBuffer) bytes = new Uint8Array(source.bytes);
  else return null;
  if (bytes.byteLength < 1 || bytes.byteLength > MAX_STUDIO_PACKAGE_BYTES) return null;

  let url: URL;
  try {
    url = new URL(source.url);
  } catch {
    return null;
  }

  if (
    url.protocol !== "https:"
    || url.username
    || url.password
    || url.hash
    || !/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\.[a-z0-9]{16,64}\.r2\.cloudflarestorage\.com$/i.test(url.hostname)
    || url.pathname === "/"
  ) return null;

  const algorithm = url.searchParams.get("X-Amz-Algorithm");
  const signature = url.searchParams.get("X-Amz-Signature") ?? "";
  const expires = Number(url.searchParams.get("X-Amz-Expires"));
  const credential = url.searchParams.get("X-Amz-Credential") ?? "";
  const date = url.searchParams.get("X-Amz-Date") ?? "";
  if (
    algorithm !== "AWS4-HMAC-SHA256"
    || !/^[0-9a-f]{64}$/i.test(signature)
    || !Number.isInteger(expires)
    || expires < 1
    || expires > 604_800
    || credential.length < 8
    || credential.length > 512
    || !/^\d{8}T\d{6}Z$/.test(date)
  ) return null;

  return { url: url.toString(), bytes };
}

export function studioCloudResponseBodyWithinLimit(bodyText: string): boolean {
  return bodyText.length <= MAX_CLOUD_RESPONSE_BODY_CHARS;
}
