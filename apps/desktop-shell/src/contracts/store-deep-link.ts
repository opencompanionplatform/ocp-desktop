const PACKAGE_ID_PATTERN = /^[a-z][a-z0-9-]*(?:\.[a-z0-9][a-z0-9_-]*)+$/;
const SEMVER_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

export type StoreDeepLink = Readonly<{ packageId: string; version: string }>;

export function sanitizeStoreDeepLink(value: unknown): StoreDeepLink | null {
  if (typeof value !== "object" || value === null) return null;
  const candidate = value as Record<string, unknown>;
  if (typeof candidate.packageId !== "string" || typeof candidate.version !== "string") return null;
  if (!PACKAGE_ID_PATTERN.test(candidate.packageId) || !SEMVER_PATTERN.test(candidate.version)) return null;
  return { packageId: candidate.packageId, version: candidate.version };
}

export function parseStoreDeepLink(value: string): StoreDeepLink | null {
  if (typeof value !== "string" || value.length > 512) return null;
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== "ocp:" || url.hostname !== "store" || url.username || url.password || url.hash) return null;
  const keys = [...url.searchParams.keys()];
  if (keys.length !== 1 || keys[0] !== "version") return null;
  const packageId = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
  const version = url.searchParams.get("version") ?? "";
  if (!PACKAGE_ID_PATTERN.test(packageId) || !SEMVER_PATTERN.test(version)) return null;
  return { packageId, version };
}

export function findStoreDeepLinkArg(args: readonly string[]): StoreDeepLink | null {
  for (const argument of args) {
    if (!argument.toLowerCase().startsWith("ocp://")) continue;
    const parsed = parseStoreDeepLink(argument);
    if (parsed) return parsed;
  }
  return null;
}
