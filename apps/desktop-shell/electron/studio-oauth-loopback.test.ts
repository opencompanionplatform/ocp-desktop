import { describe, expect, it } from "vitest";

import { startStudioOAuthLoopback } from "./studio-oauth-loopback";

describe("Studio OAuth loopback", () => {
  it("accepts a PKCE callback on the exact loopback path and returns only the code", async () => {
    const loopback = await startStudioOAuthLoopback(0);
    const callback = new URL(loopback.redirectUrl);
    callback.searchParams.set("code", "desktop-pkce-code-demo");

    const pending = loopback.waitForCallback(5_000);
    const response = await fetch(callback);
    expect(response.status).toBe(200);
    expect(response.headers.get("connection")).toBe("close");
    expect(await response.text()).toContain("OCP Studio sign-in complete");
    await expect(pending).resolves.toEqual({ status: "code", code: "desktop-pkce-code-demo" });
    await loopback.close();
  });

  it("reports provider errors without accepting unrelated paths", async () => {
    const loopback = await startStudioOAuthLoopback(0);
    const base = new URL(loopback.redirectUrl);
    const unrelated = new URL("/not-studio", base);
    expect((await fetch(unrelated)).status).toBe(404);

    const callback = new URL(loopback.redirectUrl);
    callback.searchParams.set("error", "access_denied");
    callback.searchParams.set("error_description", "User cancelled sign in");
    const pending = loopback.waitForCallback(5_000);
    expect((await fetch(callback)).status).toBe(400);
    await expect(pending).resolves.toEqual({ status: "error", error: "User cancelled sign in" });
    await loopback.close();
  });
});
