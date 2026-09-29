import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const mainSource = readFileSync(path.join(__dirname, "main.ts"), "utf8");

describe("Desktop Shell Store loopback integration", () => {
  it("binds the narrow loopback handoff receiver and routes only through Electron main", () => {
    expect(mainSource).toContain("startStoreLoopbackHandoffServer");
    expect(mainSource).toContain("const STORE_LOOPBACK_PORT = 47832");
    expect(mainSource).toContain("onHandoff: routeInstallHandoff");
    expect(mainSource).toContain("http://127.0.0.1:5173");
    expect(mainSource).toContain("http://localhost:5173");
  });
});
