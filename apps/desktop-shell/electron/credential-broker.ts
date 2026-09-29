import { randomUUID } from "node:crypto";
import net from "node:net";

const TOKEN_PATTERN = /^[a-f0-9]{64}$/;
const PIPE_NAME_PATTERN = /^ocp-credential-[a-f0-9]{32}$/;
const MAX_CREDENTIAL_LENGTH = 4_096;
const MAX_RESPONSE_BYTES = 4_096;
const BROKER_TIMEOUT_MS = 15_000;

export const credentialProviderIds = ["openai-compatible", "gemini-cloud"] as const;
export type CredentialProviderId = (typeof credentialProviderIds)[number];
export type CredentialStoreResult = Readonly<{
  ok: boolean;
  code: "stored" | "broker-unavailable" | "invalid-request" | "authentication-failed" | "replayed-request" | "keystore-unavailable" | "broker-timeout" | "broker-failed";
}>;
export type CredentialBrokerLaunch = Readonly<{ pipeName: string; capability: string }>;

type BrokerResponse = Readonly<{
  version: 1;
  requestId: string;
  ok: boolean;
  code: CredentialStoreResult["code"];
}>;

function readArgument(args: readonly string[], name: string): string | undefined {
  const prefix = `--${name}=`;
  return args.find((argument) => argument.startsWith(prefix))?.slice(prefix.length);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).length === keys.length && Object.keys(value).every((key) => keys.includes(key));
}

function safeResult(code: CredentialStoreResult["code"]): CredentialStoreResult {
  return { ok: code === "stored", code };
}

export function parseCredentialBrokerLaunch(args: readonly string[]): CredentialBrokerLaunch | null {
  const pipeName = readArgument(args, "ocp-credential-pipe");
  const capability = readArgument(args, "ocp-credential-capability");
  if (!pipeName || !capability || !PIPE_NAME_PATTERN.test(pipeName) || !TOKEN_PATTERN.test(capability)) return null;
  return { pipeName, capability };
}

export function sanitizeCredentialStoreInput(value: unknown): Readonly<{ providerId: CredentialProviderId; credential: string }> | null {
  if (!isRecord(value) || !hasExactKeys(value, ["providerId", "credential"])) return null;
  if (!credentialProviderIds.includes(value.providerId as CredentialProviderId) || typeof value.credential !== "string") return null;
  const credential = value.credential.trim();
  if (!credential || credential.length > MAX_CREDENTIAL_LENGTH || [...credential].some((character) => character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127)) return null;
  return { providerId: value.providerId as CredentialProviderId, credential };
}

function sanitizeBrokerResponse(value: unknown, requestId: string): BrokerResponse | null {
  if (!isRecord(value) || !hasExactKeys(value, ["version", "requestId", "ok", "code"])) return null;
  if (value.version !== 1 || value.requestId !== requestId || typeof value.ok !== "boolean" || typeof value.code !== "string") return null;
  const codes: readonly CredentialStoreResult["code"][] = ["stored", "invalid-request", "authentication-failed", "replayed-request", "keystore-unavailable", "broker-failed"];
  if (!codes.includes(value.code as CredentialStoreResult["code"]) || value.ok !== (value.code === "stored")) return null;
  return value as BrokerResponse;
}

export class CredentialBrokerClient {
  readonly #launch: CredentialBrokerLaunch;

  constructor(launch: CredentialBrokerLaunch) {
    this.#launch = launch;
  }

  store(input: Readonly<{ providerId: CredentialProviderId; credential: string }>): Promise<CredentialStoreResult> {
    const requestId = randomUUID();
    const payload = Buffer.from(JSON.stringify({
      version: 1,
      requestId,
      capability: this.#launch.capability,
      providerId: input.providerId,
      credential: input.credential,
    }), "utf8");

    return new Promise((resolve) => {
      const socket = net.createConnection(`\\\\.\\pipe\\${this.#launch.pipeName}`);
      const responseChunks: Buffer[] = [];
      let responseBytes = 0;
      let settled = false;
      const finish = (result: CredentialStoreResult): void => {
        if (settled) return;
        settled = true;
        payload.fill(0);
        socket.destroy();
        resolve(result);
      };
      socket.setTimeout(BROKER_TIMEOUT_MS);
      socket.once("connect", () => socket.end(payload));
      socket.on("data", (chunk: Buffer) => {
        responseBytes += chunk.length;
        if (responseBytes > MAX_RESPONSE_BYTES) {
          finish(safeResult("broker-failed"));
          return;
        }
        responseChunks.push(chunk);
      });
      socket.once("timeout", () => finish(safeResult("broker-timeout")));
      socket.once("error", () => finish(safeResult("broker-unavailable")));
      socket.once("end", () => {
        if (settled) return;
        try {
          const response = sanitizeBrokerResponse(JSON.parse(Buffer.concat(responseChunks).toString("utf8")), requestId);
          finish(response ? safeResult(response.code) : safeResult("broker-failed"));
        } catch {
          finish(safeResult("broker-failed"));
        }
      });
    });
  }
}
