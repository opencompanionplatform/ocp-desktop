import { describe, expect, it } from "vitest";

import { findInstallHandoffArg, parseInstallHandoff, sanitizeInstallHandoff } from "./install-handoff";

const GRANT = "A".repeat(43);

describe("install handoff protocol", () => {
  it("accepts only strict package/version/grant handoff", () => {
    expect(parseInstallHandoff(`ocp://install/character.sabai?version=1.2.0&grant=${GRANT}`)).toEqual({
      packageId: "character.sabai",
      version: "1.2.0",
      grant: GRANT,
    });
    expect(parseInstallHandoff(`ocp://install/character.sabai?version=1.2.0&grant=${GRANT}&token=x`)).toBeNull();
    expect(parseInstallHandoff("ocp://install/character.sabai?version=latest&grant=short")).toBeNull();
    expect(parseInstallHandoff(`ocp://store/character.sabai?version=1.2.0&grant=${GRANT}`)).toBeNull();
  });

  it("finds protocol argv without trusting unrelated arguments", () => {
    expect(findInstallHandoffArg(["electron.exe", `ocp://install/character.sabai?version=1.2.0&grant=${GRANT}`])).toEqual({
      packageId: "character.sabai", version: "1.2.0", grant: GRANT,
    });
    expect(findInstallHandoffArg([`ocp://install/character.sabai?version=1.2.0&grant=${GRANT}`])).toEqual({
      packageId: "character.sabai", version: "1.2.0", grant: GRANT,
    });
    expect(findInstallHandoffArg(["electron.exe", "--flag"])).toBeNull();
  });

  it("accepts strict additionalData handoff without exposing extra fields", () => {
    expect(sanitizeInstallHandoff({ packageId: "character.sabai", version: "1.2.0", grant: GRANT })).toEqual({
      packageId: "character.sabai", version: "1.2.0", grant: GRANT,
    });
    expect(sanitizeInstallHandoff({ packageId: "character.sabai", version: "1.2.0", grant: GRANT, token: "x" })).toBeNull();
    expect(sanitizeInstallHandoff({ packageId: "../escape", version: "1.2.0", grant: GRANT })).toBeNull();
  });
});
