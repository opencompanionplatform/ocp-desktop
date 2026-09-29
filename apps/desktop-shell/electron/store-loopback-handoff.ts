import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { type AddressInfo } from "node:net";

import { sanitizeInstallHandoff, type InstallHandoff } from "./install-handoff";

const LOOPBACK_HOST = "127.0.0.1";
const HANDOFF_PATH = "/v1/install-handoff";
const AUTH_HANDOFF_PATH = "/v1/auth-handoff";
const RUNTIME_STATE_PATH = "/v1/runtime-state";
const AUTH_GRANT_PATTERN = /^[A-Za-z0-9_-]{32,256}$/;
const MAX_BODY_BYTES = 2_048;

export type StoreLoopbackServer = Readonly<{
  port: number;
  close: () => Promise<void>;
}>;

export type DesktopAuthHandoff = Readonly<{ grant: string }>;

export type StoreRuntimeState = Readonly<{
  runtimeAvailable: boolean;
  characters: readonly Readonly<{ packageId: string; version: string; active: boolean }>[];
  effectPacks: readonly Readonly<{ packageId: string; version: string }>[];
  download: Readonly<{ status: string; packageId: string; version: string }> | null;
}>;

export type StoreLoopbackServerOptions = Readonly<{
  port: number;
  allowedOrigins: ReadonlySet<string>;
  runtimeAvailable: () => boolean;
  runtimeState?: () => StoreRuntimeState;
  onHandoff: (handoff: InstallHandoff) => void;
  onAuthHandoff?: (handoff: DesktopAuthHandoff) => void;
}>;

function setCors(response: ServerResponse, origin: string): void {
  response.setHeader("Access-Control-Allow-Origin", origin);
  response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  response.setHeader("Access-Control-Allow-Headers", "Content-Type");
  // Keep compatibility with Chromium's local/private-network preflight model.
  // Chrome 142+ uses Local Network Access permission for public HTTPS ->
  // loopback requests; older PNA-capable clients still require this opt-in.
  response.setHeader("Access-Control-Allow-Private-Network", "true");
  response.setHeader("Access-Control-Max-Age", "600");
  response.setHeader("Vary", "Origin");
}

function respondJson(response: ServerResponse, statusCode: number, body: Readonly<Record<string, unknown>>): void {
  const payload = JSON.stringify(body);
  response.statusCode = statusCode;
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Content-Length", Buffer.byteLength(payload));
  response.end(payload);
}

function sanitizeDesktopAuthHandoff(value: unknown): DesktopAuthHandoff | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (Object.keys(record).length !== 1 || typeof record.grant !== "string" || !AUTH_GRANT_PATTERN.test(record.grant)) return null;
  return { grant: record.grant };
}

function readJsonBody(request: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let tooLarge = false;

    request.on("data", (chunk: Buffer | string) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        return;
      }
      chunks.push(buffer);
    });
    request.on("error", reject);
    request.on("end", () => {
      if (tooLarge) {
        reject(new RangeError("payload-too-large"));
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        reject(new SyntaxError("invalid-json"));
      }
    });
  });
}

export async function startStoreLoopbackHandoffServer(options: StoreLoopbackServerOptions): Promise<StoreLoopbackServer> {
  const allowedOrigins = new Set(options.allowedOrigins);
  const server = http.createServer(async (request, response) => {
    const origin = typeof request.headers.origin === "string" ? request.headers.origin : "";
    if (!allowedOrigins.has(origin)) {
      respondJson(response, 403, { ok: false });
      return;
    }
    setCors(response, origin);

    if (request.url !== HANDOFF_PATH && request.url !== AUTH_HANDOFF_PATH && request.url !== RUNTIME_STATE_PATH) {
      respondJson(response, 404, { ok: false });
      return;
    }

    if (request.method === "OPTIONS") {
      response.statusCode = 204;
      response.end();
      return;
    }

    if (request.url === RUNTIME_STATE_PATH) {
      if (request.method !== "GET") {
        respondJson(response, 405, { ok: false });
        return;
      }
      const state = options.runtimeState?.() ?? {
        runtimeAvailable: options.runtimeAvailable(),
        characters: [],
        effectPacks: [],
        download: null,
      };
      respondJson(response, 200, { ok: true, ...state });
      return;
    }

    if (request.method !== "POST") {
      respondJson(response, 405, { ok: false });
      return;
    }

    const contentType = request.headers["content-type"] ?? "";
    if (typeof contentType !== "string" || !contentType.toLowerCase().startsWith("application/json")) {
      respondJson(response, 415, { ok: false });
      return;
    }

    let candidate: unknown;
    try {
      candidate = await readJsonBody(request);
    } catch (error) {
      respondJson(response, error instanceof RangeError ? 413 : 400, { ok: false });
      return;
    }

    if (request.url === AUTH_HANDOFF_PATH) {
      const handoff = sanitizeDesktopAuthHandoff(candidate);
      if (!handoff || !options.onAuthHandoff) {
        respondJson(response, 400, { ok: false });
        return;
      }
      if (!options.runtimeAvailable()) {
        respondJson(response, 503, { ok: false });
        return;
      }
      try {
        options.onAuthHandoff(handoff);
      } catch {
        respondJson(response, 503, { ok: false });
        return;
      }
      respondJson(response, 202, { ok: true });
      return;
    }

    const handoff = sanitizeInstallHandoff(candidate);
    if (!handoff) {
      respondJson(response, 400, { ok: false });
      return;
    }
    if (!options.runtimeAvailable()) {
      respondJson(response, 503, { ok: false });
      return;
    }
    try {
      options.onHandoff(handoff);
    } catch {
      respondJson(response, 503, { ok: false });
      return;
    }

    respondJson(response, 202, { ok: true });
  });

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = (): void => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(options.port, LOOPBACK_HOST);
  });

  const address = server.address();
  if (!address || typeof address === "string") {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    throw new Error("loopback-address-unavailable");
  }
  const port = (address as AddressInfo).port;

  return {
    port,
    close: () => new Promise<void>((resolve, reject) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.close((error) => error ? reject(error) : resolve());
    }),
  };
}
