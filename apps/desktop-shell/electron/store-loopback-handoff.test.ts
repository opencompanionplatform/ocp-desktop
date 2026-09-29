import { afterEach, describe, expect, it } from "vitest";

import { startStoreLoopbackHandoffServer, type StoreLoopbackServer } from "./store-loopback-handoff";

const GRANT = "L".repeat(43);
const ORIGIN = "http://127.0.0.1:5173";
const HANDOFF = { packageId: "character.sabai-sompoo", version: "1.0.0", grant: GRANT } as const;

let active: StoreLoopbackServer | null = null;

afterEach(async () => {
  if (active) await active.close();
  active = null;
});

async function createServer(
  onHandoff: (value: typeof HANDOFF) => void = () => undefined,
  runtimeAvailable: () => boolean = () => true,
): Promise<StoreLoopbackServer> {
  active = await startStoreLoopbackHandoffServer({
    port: 0,
    allowedOrigins: new Set([ORIGIN]),
    runtimeAvailable,
    onHandoff,
  });
  return active;
}

describe("Store loopback install handoff", () => {
  it("accepts only the allowlisted Store origin and routes a strict handoff", async () => {
    let received: typeof HANDOFF | null = null;
    const server = await createServer((value) => { received = value; });
    const response = await fetch(`http://127.0.0.1:${server.port}/v1/install-handoff`, {
      method: "POST",
      headers: { Origin: ORIGIN, "Content-Type": "application/json" },
      body: JSON.stringify(HANDOFF),
    });

    expect(response.status).toBe(202);
    expect(response.headers.get("access-control-allow-origin")).toBe(ORIGIN);
    expect(await response.json()).toEqual({ ok: true });
    expect(received).toEqual(HANDOFF);
  });

  it("returns 503 without routing when Runtime is not connected", async () => {
    let routed = false;
    const server = await createServer(() => { routed = true; }, () => false);
    const response = await fetch(`http://127.0.0.1:${server.port}/v1/install-handoff`, {
      method: "POST",
      headers: { Origin: ORIGIN, "Content-Type": "application/json" },
      body: JSON.stringify(HANDOFF),
    });

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ ok: false });
    expect(routed).toBe(false);
  });

  it("rejects an untrusted origin without routing the grant", async () => {
    let routed = false;
    const server = await createServer(() => { routed = true; });
    const response = await fetch(`http://127.0.0.1:${server.port}/v1/install-handoff`, {
      method: "POST",
      headers: { Origin: "https://evil.example", "Content-Type": "application/json" },
      body: JSON.stringify(HANDOFF),
    });

    expect(response.status).toBe(403);
    expect(routed).toBe(false);
  });

  it("routes a strict desktop auth handoff on the same exact-origin loopback", async () => {
    const authHandoff = { grant: "B".repeat(64) } as const;
    let received: typeof authHandoff | null = null;
    active = await startStoreLoopbackHandoffServer({
      port: 0,
      allowedOrigins: new Set([ORIGIN]),
      runtimeAvailable: () => true,
      onHandoff: () => undefined,
      onAuthHandoff: (value) => { received = value; },
    });
    const response = await fetch(`http://127.0.0.1:${active.port}/v1/auth-handoff`, {
      method: "POST",
      headers: { Origin: ORIGIN, "Content-Type": "application/json" },
      body: JSON.stringify(authHandoff),
    });
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ ok: true });
    expect(received).toEqual(authHandoff);
  });

  it("exposes a read-only compact Runtime state for post-install Store UX", async () => {
    active = await startStoreLoopbackHandoffServer({
      port: 0,
      allowedOrigins: new Set([ORIGIN]),
      runtimeAvailable: () => true,
      runtimeState: () => ({
        runtimeAvailable: true,
        characters: [{ packageId: "character.sabai-sompoo", version: "1.0.1", active: false }],
        download: { status: "installed", packageId: "character.sabai-sompoo", version: "1.0.1" },
      }),
      onHandoff: () => undefined,
    });
    const response = await fetch(`http://127.0.0.1:${active.port}/v1/runtime-state`, {
      headers: { Origin: ORIGIN },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("access-control-allow-origin")).toBe(ORIGIN);
    expect(await response.json()).toEqual({
      ok: true,
      runtimeAvailable: true,
      characters: [{ packageId: "character.sabai-sompoo", version: "1.0.1", active: false }],
      download: { status: "installed", packageId: "character.sabai-sompoo", version: "1.0.1" },
    });
  });

  it("rejects malformed or over-broad payloads and supports CORS preflight", async () => {
    const server = await createServer();
    const base = `http://127.0.0.1:${server.port}/v1/install-handoff`;

    const invalid = await fetch(base, {
      method: "POST",
      headers: { Origin: ORIGIN, "Content-Type": "application/json" },
      body: JSON.stringify({ ...HANDOFF, extra: "not-allowed" }),
    });
    expect(invalid.status).toBe(400);

    const options = await fetch(base, {
      method: "OPTIONS",
      headers: {
        Origin: ORIGIN,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
      },
    });
    expect(options.status).toBe(204);
    expect(options.headers.get("access-control-allow-methods")).toContain("POST");
    expect(options.headers.get("access-control-allow-private-network")).toBe("true");
  });
});
