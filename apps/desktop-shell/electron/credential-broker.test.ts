import net from "node:net";

import { afterEach, describe, expect, it, vi } from "vitest";

import { CredentialBrokerClient, parseCredentialBrokerLaunch, sanitizeCredentialStoreInput } from "./credential-broker";

afterEach(() => vi.restoreAllMocks());

describe("credential broker boundary", () => {
  it("accepts only the bounded trusted launch arguments", () => {
    const capability = "a".repeat(64);
    expect(parseCredentialBrokerLaunch([`--ocp-credential-pipe=ocp-credential-${"b".repeat(32)}`, `--ocp-credential-capability=${capability}`])).toEqual({
      pipeName: `ocp-credential-${"b".repeat(32)}`,
      capability,
    });
    expect(parseCredentialBrokerLaunch(["--ocp-credential-pipe=\\\\.\\pipe\\anything", `--ocp-credential-capability=${capability}`])).toBeNull();
    expect(parseCredentialBrokerLaunch([`--ocp-credential-pipe=ocp-credential-${"b".repeat(32)}`])).toBeNull();
  });

  it("rejects unknown providers, unknown fields, controls and oversized credentials", () => {
    expect(sanitizeCredentialStoreInput({ providerId: "openai-compatible", credential: "  test-key  " })).toEqual({ providerId: "openai-compatible", credential: "test-key" });
    expect(sanitizeCredentialStoreInput({ providerId: "other", credential: "test-key" })).toBeNull();
    expect(sanitizeCredentialStoreInput({ providerId: "gemini-cloud", credential: "test\nkey" })).toBeNull();
    expect(sanitizeCredentialStoreInput({ providerId: "gemini-cloud", credential: "x".repeat(4_097) })).toBeNull();
    expect(sanitizeCredentialStoreInput({ providerId: "gemini-cloud", credential: "test-key", path: "C:\\secret" })).toBeNull();
  });

  it("returns only a safe result from a correlated broker response", async () => {
    const socket = {
      setTimeout: vi.fn(),
      once: vi.fn(),
      on: vi.fn(),
      end: vi.fn(),
      destroy: vi.fn(),
    };
    const onceHandlers = new Map<string, (...args: unknown[]) => void>();
    const onHandlers = new Map<string, (...args: unknown[]) => void>();
    socket.once.mockImplementation((event: string, handler: (...args: unknown[]) => void) => { onceHandlers.set(event, handler); return socket; });
    socket.on.mockImplementation((event: string, handler: (...args: unknown[]) => void) => { onHandlers.set(event, handler); return socket; });
    vi.spyOn(net, "createConnection").mockReturnValue(socket as unknown as net.Socket);
    const client = new CredentialBrokerClient({ pipeName: `ocp-credential-${"b".repeat(32)}`, capability: "a".repeat(64) });
    const pending = client.store({ providerId: "gemini-cloud", credential: "never-return-this" });
    onceHandlers.get("connect")?.();
    const request = JSON.parse((socket.end.mock.calls[0]?.[0] as Buffer).toString("utf8")) as { requestId: string };
    onHandlers.get("data")?.(Buffer.from(JSON.stringify({ version: 1, requestId: request.requestId, ok: true, code: "stored" })));
    onceHandlers.get("end")?.();
    await expect(pending).resolves.toEqual({ ok: true, code: "stored" });
  });

  it("fails closed on broker timeout without returning transport details", async () => {
    const socket = { setTimeout: vi.fn(), once: vi.fn(), on: vi.fn(), end: vi.fn(), destroy: vi.fn() };
    const onceHandlers = new Map<string, (...args: unknown[]) => void>();
    socket.once.mockImplementation((event: string, handler: (...args: unknown[]) => void) => { onceHandlers.set(event, handler); return socket; });
    socket.on.mockImplementation(() => socket);
    vi.spyOn(net, "createConnection").mockReturnValue(socket as unknown as net.Socket);
    const client = new CredentialBrokerClient({ pipeName: `ocp-credential-${"b".repeat(32)}`, capability: "a".repeat(64) });
    const pending = client.store({ providerId: "openai-compatible", credential: "never-return-this" });
    onceHandlers.get("timeout")?.();
    await expect(pending).resolves.toEqual({ ok: false, code: "broker-timeout" });
  });
});
