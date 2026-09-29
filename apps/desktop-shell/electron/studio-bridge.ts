import path from "node:path";

export const MAX_STUDIO_PROJECT_CHARS = 2_000_000;
export const MAX_STUDIO_PACKAGE_BYTES = 64 * 1024 * 1024;

export type StudioEnvironment = Readonly<{
  host: "ocp-desktop";
  workspaceName: string | null;
  hasLastOutput: boolean;
  runtimeAvailable: boolean;
  signingAvailable: boolean;
  signingPublisherId: string | null;
}>;

export type StudioWorkspaceResult =
  | Readonly<{ status: "selected"; workspaceName: string }>
  | Readonly<{ status: "cancelled" }>;

export type StudioSaveResult =
  | Readonly<{ status: "saved"; fileName: string; workspaceName: string }>
  | Readonly<{ status: "cancelled" }>;

export type StudioRevealResult =
  | Readonly<{ status: "revealed"; fileName: string }>
  | Readonly<{ status: "no-output" }>;

export type StudioRuntimeTestResult =
  | Readonly<{ status: "submitted"; requestId: string; fileName: string }>
  | Readonly<{ status: "no-output" | "runtime-unavailable" }>;

export type StudioProjectSaveInput = Readonly<{ fileName: string; content: string }>;
export type StudioPackageSaveInput = Readonly<{ fileName: string; bytes: Uint8Array }>;
export type StudioPackageSignInput = Readonly<{ bytes: Uint8Array }>;
export type StudioSignedPackageResult = Readonly<{ bytes: Uint8Array }>;
export type StudioSigningIdentity = Readonly<{ publisherId: string; keyId: string; publicKeyHex: string }>;
export type StudioSigningProvisionInput = Readonly<{ publisherId: string }>;

export type StudioCloudMethod = "GET" | "POST" | "DELETE";
export type StudioCloudRequestInput = Readonly<{
  url: string;
  method: StudioCloudMethod;
  accessToken: string;
  body: string | null;
}>;
export type StudioCloudResponse = Readonly<{
  status: number;
  contentType: string;
  bodyText: string;
}>;
export type StudioPresignedUploadInput = Readonly<{
  url: string;
  bytes: Uint8Array;
}>;
export type StudioPresignedUploadResult = Readonly<{
  status: number;
}>;

export type StudioOAuthBeginResult = Readonly<{ redirectUrl: string }>;
export type StudioOAuthOpenInput = Readonly<{ url: string }>;
export type StudioOAuthCallbackResult =
  | Readonly<{ status: "code"; code: string }>
  | Readonly<{ status: "error"; error: string }>;

const WINDOWS_RESERVED_NAMES = new Set([
  "con", "prn", "aux", "nul",
  "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
  "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
]);

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function exactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const keys = Object.keys(value).sort();
  const sorted = [...expected].sort();
  return keys.length === sorted.length && keys.every((key, index) => key === sorted[index]);
}

export function sanitizeStudioFileName(value: unknown, extension: ".ocp" | ".ocp-project.json"): string | null {
  if (typeof value !== "string") return null;
  const fileName = value.trim();
  const hasControlCharacter = [...fileName].some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint < 32;
  });
  if (
    fileName.length < extension.length + 1
    || fileName.length > 180
    || !fileName.toLowerCase().endsWith(extension)
    || fileName.endsWith(".")
    || fileName.endsWith(" ")
    || hasControlCharacter
    || /[\\/:*?"<>|]/.test(fileName)
    || !/^[A-Za-z0-9][A-Za-z0-9._ +()-]*$/.test(fileName)
  ) return null;

  const stem = fileName.slice(0, -extension.length).trim();
  if (!stem) return null;
  const firstSegment = stem.split(".")[0]?.toLowerCase() ?? "";
  if (WINDOWS_RESERVED_NAMES.has(firstSegment)) return null;
  return fileName;
}

export function sanitizeStudioProjectSaveInput(value: unknown): StudioProjectSaveInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["fileName", "content"])) return null;
  const fileName = sanitizeStudioFileName(source.fileName, ".ocp-project.json");
  if (
    !fileName
    || typeof source.content !== "string"
    || source.content.length < 2
    || source.content.length > MAX_STUDIO_PROJECT_CHARS
  ) return null;
  return { fileName, content: source.content };
}

function sanitizeStudioPackageBytes(value: unknown): Uint8Array | null {
  let bytes: Uint8Array;
  if (value instanceof Uint8Array) bytes = value;
  else if (value instanceof ArrayBuffer) bytes = new Uint8Array(value);
  else return null;
  if (bytes.byteLength < 1 || bytes.byteLength > MAX_STUDIO_PACKAGE_BYTES) return null;
  return bytes;
}

export function sanitizeStudioPackageSaveInput(value: unknown): StudioPackageSaveInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["fileName", "bytes"])) return null;
  const fileName = sanitizeStudioFileName(source.fileName, ".ocp");
  const bytes = sanitizeStudioPackageBytes(source.bytes);
  if (!fileName || !bytes) return null;
  return { fileName, bytes };
}

export function sanitizeStudioPackageSignInput(value: unknown): StudioPackageSignInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["bytes"])) return null;
  const bytes = sanitizeStudioPackageBytes(source.bytes);
  return bytes ? { bytes } : null;
}

export function sanitizeStudioSigningProvisionInput(value: unknown): StudioSigningProvisionInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["publisherId"])) return null;
  if (typeof source.publisherId !== "string") return null;
  const publisherId = source.publisherId.trim().toLowerCase();
  if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(publisherId) || publisherId.length > 128) return null;
  return { publisherId };
}

export function sanitizeStudioOAuthOpenInput(value: unknown): StudioOAuthOpenInput | null {
  const source = record(value);
  if (!source || !exactKeys(source, ["url"]) || typeof source.url !== "string") return null;
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
    || url.pathname !== "/auth/v1/authorize"
  ) return null;
  return { url: url.toString() };
}

export function resolveStudioIndexPath(options: Readonly<{ defaultApp: boolean; resourcesPath: string; moduleDir: string }>): string {
  return options.defaultApp
    ? path.resolve(options.moduleDir, "../../../animation-studio/app/dist/index.html")
    : path.join(options.resourcesPath, "studio", "index.html");
}

export function resolveStudioDevelopmentUrl(value: unknown): string | null {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > 2_048) return null;
  try {
    const url = new URL(value.trim());
    if (url.protocol !== "http:" || (url.hostname !== "127.0.0.1" && url.hostname !== "localhost")) return null;
    if (url.username || url.password || url.hash) return null;
    return url.toString();
  } catch {
    return null;
  }
}
