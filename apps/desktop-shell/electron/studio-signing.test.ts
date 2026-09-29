import { describe, expect, it } from "vitest";

import {
  createStudioSigningConfiguration,
  sanitizeStudioSigningConfiguration,
  studioSignerExecutablePath,
  studioSigningConfiguration,
  studioSigningIdentityFromConfiguration,
} from "./studio-signing";

describe("Desktop Studio signing boundary", () => {
  it("projects public Ed25519 identity without exposing the private seed", () => {
    const configuration = studioSigningConfiguration({
      OCP_SIGNING_PUBLISHER_ID: "ocp.official",
      OCP_SIGNING_KEY_ID: "ed25519:test-1",
      OCP_SIGNING_KEY_HEX: "07".repeat(32),
    });
    expect(configuration).not.toBeNull();
    const identity = studioSigningIdentityFromConfiguration(configuration!);
    expect(identity.publisherId).toBe("ocp.official");
    expect(identity.keyId).toBe("ed25519:test-1");
    expect(identity.publicKeyHex).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(identity)).not.toContain("07".repeat(32));
    expect(Object.keys(identity).sort()).toEqual(["keyId", "publicKeyHex", "publisherId"]);
  });

  it("creates a random per-PC signing identity that round-trips through protected-storage serialization", () => {
    const configuration = createStudioSigningConfiguration("Creator.Demo");
    expect(configuration.publisherId).toBe("creator.demo");
    expect(configuration.keyId).toMatch(/^ed25519:[0-9a-f]{24}$/);
    expect(configuration.privateSeedHex).toMatch(/^[0-9a-f]{64}$/);
    const sanitized = sanitizeStudioSigningConfiguration(JSON.parse(JSON.stringify(configuration)));
    expect(sanitized).toEqual(configuration);
    const identity = studioSigningIdentityFromConfiguration(configuration);
    expect(identity.publisherId).toBe("creator.demo");
    expect(identity.publicKeyHex).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(identity)).not.toContain(configuration.privateSeedHex);
  });

  it("fails closed for malformed signing configuration", () => {
    expect(studioSigningConfiguration({})).toBeNull();
    expect(studioSigningConfiguration({
      OCP_SIGNING_PUBLISHER_ID: "bad publisher",
      OCP_SIGNING_KEY_ID: "ed25519:test",
      OCP_SIGNING_KEY_HEX: "07".repeat(32),
    })).toBeNull();
    expect(studioSigningConfiguration({
      OCP_SIGNING_PUBLISHER_ID: "ocp.official",
      OCP_SIGNING_KEY_ID: "ed25519:test",
      OCP_SIGNING_KEY_HEX: "00",
    })).toBeNull();
  });

  it("selects an architecture-matched signer resource", () => {
    expect(studioSignerExecutablePath({
      packaged: true,
      resourcesPath: "C:\\OCP\\resources",
      dirname: "ignored",
      arch: "x64",
    })).toContain("ocp-package-signer-x64.exe");
    expect(studioSignerExecutablePath({
      packaged: true,
      resourcesPath: "C:\\OCP\\resources",
      dirname: "ignored",
      arch: "arm64",
    })).toContain("ocp-package-signer-arm64.exe");
    expect(studioSignerExecutablePath({
      packaged: true,
      resourcesPath: "C:\\OCP\\resources",
      dirname: "ignored",
      arch: "ia32",
    })).toBe("");
  });
});
