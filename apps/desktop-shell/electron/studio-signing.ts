/// <reference types="node" />

import { execFileSync } from "node:child_process";
import { createPrivateKey, createPublicKey, randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import { MAX_STUDIO_PACKAGE_BYTES } from "./studio-bridge";

const PACKAGE_ID_PATTERN = /^[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const KEY_ID_PATTERN = /^ed25519:[A-Za-z0-9._-]+$/;
const PRIVATE_SEED_PATTERN = /^(?:hex:)?([0-9a-fA-F]{64})$/;
const PKCS8_ED25519_SEED_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex");
const SPKI_ED25519_PUBLIC_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export type StudioSigningIdentity = Readonly<{
  publisherId: string;
  keyId: string;
  publicKeyHex: string;
}>;

export type StudioSigningConfiguration = Readonly<{
  publisherId: string;
  keyId: string;
  privateSeedHex: string;
}>;

export function sanitizeStudioSigningConfiguration(value: unknown): StudioSigningConfiguration | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const source = value as Record<string, unknown>;
  const publisherId = configuredText(source.publisherId);
  const keyId = configuredText(source.keyId);
  const privateSeedHex = configuredText(source.privateSeedHex).toLowerCase();
  if (!PACKAGE_ID_PATTERN.test(publisherId) || publisherId.length > 128) return null;
  if (!KEY_ID_PATTERN.test(keyId) || keyId.length > 256) return null;
  if (!/^[0-9a-f]{64}$/.test(privateSeedHex)) return null;
  return { publisherId, keyId, privateSeedHex };
}

export function createStudioSigningConfiguration(publisherId: string): StudioSigningConfiguration {
  const normalizedPublisherId = configuredText(publisherId).toLowerCase();
  if (!PACKAGE_ID_PATTERN.test(normalizedPublisherId) || normalizedPublisherId.length > 128) {
    throw new TypeError("Studio publisher id is invalid");
  }
  const privateSeedHex = randomBytes(32).toString("hex");
  const probe: StudioSigningConfiguration = {
    publisherId: normalizedPublisherId,
    keyId: "ed25519:pending",
    privateSeedHex,
  };
  const publicKeyHex = studioSigningIdentityFromConfiguration(probe).publicKeyHex;
  return {
    publisherId: normalizedPublisherId,
    keyId: `ed25519:${publicKeyHex.slice(0, 24)}`,
    privateSeedHex,
  };
}

function configuredText(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

export function studioSigningConfiguration(env: NodeJS.ProcessEnv): StudioSigningConfiguration | null {
  const publisherId = configuredText(env.OCP_SIGNING_PUBLISHER_ID);
  const keyId = configuredText(env.OCP_SIGNING_KEY_ID);
  const rawSeed = configuredText(env.OCP_SIGNING_KEY_HEX);
  const seedMatch = PRIVATE_SEED_PATTERN.exec(rawSeed);
  if (!PACKAGE_ID_PATTERN.test(publisherId) || publisherId.length > 128) return null;
  if (!KEY_ID_PATTERN.test(keyId) || keyId.length > 256) return null;
  if (!seedMatch) return null;
  return { publisherId, keyId, privateSeedHex: seedMatch[1].toLowerCase() };
}

export function resolveStudioSigningConfiguration(env: NodeJS.ProcessEnv, developmentEnvFile: string | null = null): StudioSigningConfiguration | null {
  const direct = studioSigningConfiguration(env);
  if (direct || !developmentEnvFile || !existsSync(developmentEnvFile)) return direct;

  const selected: NodeJS.ProcessEnv = { ...env };
  const allowed = new Set(["OCP_SIGNING_PUBLISHER_ID", "OCP_SIGNING_KEY_ID", "OCP_SIGNING_KEY_HEX"]);
  for (const line of readFileSync(developmentEnvFile, "utf8").split(/\r?\n/)) {
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line.trim());
    if (!match || !allowed.has(match[1]) || configuredText(selected[match[1]])) continue;
    selected[match[1]] = match[2].trim().replace(/^["']|["']$/g, "");
  }
  return studioSigningConfiguration(selected);
}

export function studioSigningIdentityFromConfiguration(configuration: StudioSigningConfiguration): StudioSigningIdentity {
  const seed = Buffer.from(configuration.privateSeedHex, "hex");
  const privateDer = Buffer.concat([PKCS8_ED25519_SEED_PREFIX, seed]);
  const privateKey = createPrivateKey({ key: privateDer, format: "der", type: "pkcs8" });
  const publicDer = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  if (
    !Buffer.isBuffer(publicDer)
    || publicDer.length !== SPKI_ED25519_PUBLIC_PREFIX.length + 32
    || !publicDer.subarray(0, SPKI_ED25519_PUBLIC_PREFIX.length).equals(SPKI_ED25519_PUBLIC_PREFIX)
  ) {
    throw new Error("failed to derive Studio signing public key");
  }
  return {
    publisherId: configuration.publisherId,
    keyId: configuration.keyId,
    publicKeyHex: publicDer.subarray(SPKI_ED25519_PUBLIC_PREFIX.length).toString("hex"),
  };
}

export function studioSignerExecutablePath(options: Readonly<{
  packaged: boolean;
  resourcesPath: string;
  dirname: string;
  arch: NodeJS.Architecture;
}>): string {
  const binaryName = options.arch === "arm64"
    ? "ocp-package-signer-arm64.exe"
    : options.arch === "x64"
      ? "ocp-package-signer-x64.exe"
      : "";
  if (!binaryName) return "";
  if (options.packaged) return path.join(options.resourcesPath, "tools", binaryName);
  const target = options.arch === "arm64" ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
  return path.resolve(options.dirname, "../../../../target", target, "release", "ocp-package-signer.exe");
}

export function studioSigningAvailable(configuration: StudioSigningConfiguration | null, signerPath: string): boolean {
  return Boolean(configuration && signerPath && existsSync(signerPath));
}

export function signStudioPackageDraft(
  bytes: Uint8Array,
  configuration: StudioSigningConfiguration,
  signerPath: string,
): Uint8Array {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength < 1 || bytes.byteLength > MAX_STUDIO_PACKAGE_BYTES) {
    throw new TypeError("Studio signing package is invalid");
  }
  if (!signerPath || !existsSync(signerPath)) throw new Error("OCP package signer is unavailable");

  const temporaryDirectory = mkdtempSync(path.join(os.tmpdir(), "ocp-desktop-studio-sign-"));
  const inputPath = path.join(temporaryDirectory, "unsigned.ocp");
  const outputPath = path.join(temporaryDirectory, "signed.ocp");
  try {
    writeFileSync(inputPath, Buffer.from(bytes), { mode: 0o600 });
    execFileSync(signerPath, [inputPath, outputPath], {
      env: {
        ...process.env,
        OCP_SIGNING_KEY_HEX: configuration.privateSeedHex,
        OCP_SIGNING_KEY_ID: configuration.keyId,
        OCP_SIGNING_PUBLISHER_ID: configuration.publisherId,
      },
      windowsHide: true,
      timeout: 120_000,
      stdio: ["ignore", "ignore", "pipe"],
      maxBuffer: 1024 * 1024,
    });
    const signed = readFileSync(outputPath);
    if (signed.length < 1 || signed.length > MAX_STUDIO_PACKAGE_BYTES) {
      throw new Error("OCP package signer returned an invalid package");
    }
    return new Uint8Array(signed);
  } finally {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
