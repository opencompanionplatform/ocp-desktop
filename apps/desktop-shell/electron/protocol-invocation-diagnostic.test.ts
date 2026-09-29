import { describe, expect, it } from "vitest";

import { summarizeProtocolInvocation } from "./protocol-invocation-diagnostic";

const GRANT = "D".repeat(43);

describe("protocol invocation diagnostic", () => {
  it("reports only safe shape metadata for a valid install URL", () => {
    const summary = summarizeProtocolInvocation([
      "electron.exe",
      "D:/ocp-platform/apps/desktop-shell",
      `ocp://install/character.sabai-sompoo?version=1.0.0&grant=${GRANT}`,
    ], null);

    expect(summary).toMatchObject({
      hasOcpArg: true,
      parsedInstall: true,
      parsedStore: false,
      argCount: 3,
      source: "argv",
    });
    expect(JSON.stringify(summary)).not.toContain(GRANT);
    expect(JSON.stringify(summary)).not.toContain("ocp://install/");
  });

  it("classifies a Runtime-launched secondary shell without exposing bridge credentials", () => {
    const summary = summarizeProtocolInvocation([
      "electron.exe",
      "D:/ocp-platform/apps/desktop-shell",
      "--ocp-open=characters",
      "--ocp-source=hover-menu",
      "--ocp-bridge-dir=C:/secret/session",
      "--ocp-bridge-token=bridge-secret",
      "--ocp-credential-pipe=credential-secret",
      "--ocp-credential-capability=capability-secret",
    ], null);

    expect(summary).toMatchObject({
      argCount: 8,
      hasOcpArg: false,
      parsedInstall: false,
      parsedStore: false,
      shellIntentParsed: true,
      openView: "characters",
      sourceKind: "hover-menu",
      warm: false,
      hasRuntimeBridgeArgs: true,
      hasCredentialBrokerArgs: true,
      source: "none",
    });
    const serialized = JSON.stringify(summary);
    expect(serialized).not.toContain("bridge-secret");
    expect(serialized).not.toContain("credential-secret");
    expect(serialized).not.toContain("C:/secret/session");
  });

  it("distinguishes malformed ocp argv from a valid additionalData handoff without leaking secrets", () => {
    const summary = summarizeProtocolInvocation(
      ["electron.exe", "ocp://install/not-valid?version=latest&grant=short"],
      { installHandoff: { packageId: "character.sabai-sompoo", version: "1.0.0", grant: GRANT } },
    );

    expect(summary).toMatchObject({
      hasOcpArg: true,
      parsedInstall: false,
      parsedStore: false,
      additionalInstallParsed: true,
      source: "additionalData",
    });
    expect(JSON.stringify(summary)).not.toContain(GRANT);
    expect(JSON.stringify(summary)).not.toContain("not-valid");
  });

  it("reports a structured Store deep link from additionalData when Electron omits the URI argv", () => {
    const summary = summarizeProtocolInvocation(
      ["electron.exe", "--ocp-open=chat", "--ocp-source=command-line"],
      { storeLink: { packageId: "character.sabai-sompoo", version: "1.0.1" } },
    );

    expect(summary).toMatchObject({
      hasOcpArg: false,
      parsedInstall: false,
      parsedStore: true,
      source: "additionalData",
    });
    expect(JSON.stringify(summary)).not.toContain("character.sabai-sompoo");
  });
});
