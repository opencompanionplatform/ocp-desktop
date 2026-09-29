const PACKAGE_ID_PATTERN = /^[a-z][a-z0-9-]*(?:\.[a-z0-9][a-z0-9_-]*)+$/;
const SEMVER_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const GRANT_PATTERN = /^[A-Za-z0-9_-]{43,128}$/;

export type InstallHandoff = Readonly<{ packageId: string; version: string; grant: string }>;

export function sanitizeInstallHandoff(value: unknown): InstallHandoff | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  if (keys.length !== 3 || keys[0] !== "grant" || keys[1] !== "packageId" || keys[2] !== "version") return null;
  if (typeof record.packageId !== "string" || !PACKAGE_ID_PATTERN.test(record.packageId)) return null;
  if (typeof record.version !== "string" || !SEMVER_PATTERN.test(record.version)) return null;
  if (typeof record.grant !== "string" || !GRANT_PATTERN.test(record.grant)) return null;
  return { packageId: record.packageId, version: record.version, grant: record.grant };
}

export function parseInstallHandoff(value: string): InstallHandoff | null {
  if (typeof value !== "string" || value.length > 768) return null;
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== "ocp:" || url.hostname !== "install" || url.username || url.password || url.hash) return null;
  const keys = [...url.searchParams.keys()].sort();
  if (keys.length !== 2 || keys[0] !== "grant" || keys[1] !== "version") return null;
  const packageId = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
  const version = url.searchParams.get("version") ?? "";
  const grant = url.searchParams.get("grant") ?? "";
  if (!PACKAGE_ID_PATTERN.test(packageId) || !SEMVER_PATTERN.test(version) || !GRANT_PATTERN.test(grant)) return null;
  return { packageId, version, grant };
}

export function findInstallHandoffArg(args: readonly string[]): InstallHandoff | null {
  for (const argument of args) {
    if (!argument.toLowerCase().startsWith("ocp://install/")) continue;
    const parsed = parseInstallHandoff(argument);
    if (parsed) return parsed;
  }
  return null;
}
