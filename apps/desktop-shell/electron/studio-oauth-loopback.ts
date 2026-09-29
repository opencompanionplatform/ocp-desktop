import http, { type IncomingMessage, type ServerResponse } from "node:http";
import { type AddressInfo } from "node:net";

const LOOPBACK_HOST = "127.0.0.1";
export const STUDIO_OAUTH_CALLBACK_PATH = "/v1/studio-oauth";
const AUTH_CODE_PATTERN = /^[A-Za-z0-9._~-]{8,4096}$/;
const MAX_ERROR_CHARS = 512;

export type StudioOAuthCallbackResult =
  | Readonly<{ status: "code"; code: string }>
  | Readonly<{ status: "error"; error: string }>;

export type StudioOAuthLoopback = Readonly<{
  redirectUrl: string;
  waitForCallback: (timeoutMs?: number) => Promise<StudioOAuthCallbackResult>;
  close: () => Promise<void>;
}>;

function htmlResponse(response: ServerResponse, statusCode: number, title: string, message: string): void {
  const safe = (value: string): string => value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
  const body = `<!doctype html><html><head><meta charset="utf-8"><title>${safe(title)}</title><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0;background:#07111f;color:#e7f1ff;font:16px system-ui;display:grid;place-items:center;min-height:100vh}.card{max-width:620px;margin:24px;padding:28px;border:1px solid #284a6d;border-radius:18px;background:#0b1b2d;box-shadow:0 20px 60px rgba(0,0,0,.35)}h1{margin:0 0 12px;font-size:24px}p{margin:0;color:#a8bdd3;line-height:1.6}</style></head><body><main class="card"><h1>${safe(title)}</h1><p>${safe(message)}</p></main></body></html>`;
  response.statusCode = statusCode;
  response.setHeader("Content-Type", "text/html; charset=utf-8");
  response.setHeader("Content-Length", Buffer.byteLength(body));
  // Chrome keeps loopback HTTP sockets alive by default. Explicitly close the
  // callback connection so shutting down the one-shot OAuth server can never
  // block delivery of the authorization code back to the Studio renderer.
  response.setHeader("Connection", "close");
  response.end(body);
}

function sanitizeCallback(request: IncomingMessage): StudioOAuthCallbackResult | null {
  if (request.method !== "GET" || typeof request.url !== "string") return null;
  let url: URL;
  try {
    url = new URL(request.url, `http://${LOOPBACK_HOST}`);
  } catch {
    return null;
  }
  if (url.pathname !== STUDIO_OAUTH_CALLBACK_PATH) return null;

  const error = (url.searchParams.get("error_description") || url.searchParams.get("error") || "").trim();
  if (error) {
    return { status: "error", error: error.slice(0, MAX_ERROR_CHARS) };
  }

  const code = (url.searchParams.get("code") || "").trim();
  if (!AUTH_CODE_PATTERN.test(code)) {
    return { status: "error", error: "OAuth callback did not contain a valid authorization code" };
  }
  return { status: "code", code };
}

export async function startStudioOAuthLoopback(port: number): Promise<StudioOAuthLoopback> {
  let settle: ((result: StudioOAuthCallbackResult) => void) | null = null;
  let settledResult: StudioOAuthCallbackResult | null = null;

  const server = http.createServer((request, response) => {
    const result = sanitizeCallback(request);
    if (!result) {
      htmlResponse(response, 404, "OCP Studio", "Unknown callback.");
      return;
    }

    settledResult = result;
    if (result.status === "code") {
      htmlResponse(response, 200, "OCP Studio sign-in complete", "You can close this browser tab and return to OCP Animation Studio.");
    } else {
      htmlResponse(response, 400, "OCP Studio sign-in failed", result.error);
    }
    settle?.(result);
    settle = null;
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
    server.listen(port, LOOPBACK_HOST);
  });

  const address = server.address();
  if (!address || typeof address === "string") {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    throw new Error("studio-oauth-loopback-address-unavailable");
  }
  const actualPort = (address as AddressInfo).port;
  const redirectUrl = `http://${LOOPBACK_HOST}:${actualPort}${STUDIO_OAUTH_CALLBACK_PATH}`;

  return {
    redirectUrl,
    waitForCallback: (timeoutMs = 120_000): Promise<StudioOAuthCallbackResult> => {
      if (settledResult) return Promise.resolve(settledResult);
      return new Promise<StudioOAuthCallbackResult>((resolve) => {
        const timer = setTimeout(() => {
          if (settle) settle = null;
          resolve({ status: "error", error: "OAuth callback timed out" });
        }, Math.max(1_000, timeoutMs));
        settle = (result) => {
          clearTimeout(timer);
          resolve(result);
        };
      });
    },
    close: () => new Promise<void>((resolve, reject) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.close((error) => error ? reject(error) : resolve());
    }),
  };
}
