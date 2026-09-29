import { describe, expect, it } from "vitest";

import { findStoreDeepLinkArg, parseStoreDeepLink, sanitizeStoreDeepLink } from "./store-deep-link";

describe("OCP Store deep links", () => {
  it("accepts only the strict store character handoff shape", () => {
    expect(parseStoreDeepLink("ocp://store/character.sabai?version=1.2.0")).toEqual({
      packageId: "character.sabai",
      version: "1.2.0",
    });
    expect(parseStoreDeepLink("ocp://store/character.sabai?version=1.2.0&token=secret")).toBeNull();
    expect(parseStoreDeepLink("ocp://store/../secret?version=1.2.0")).toBeNull();
    expect(parseStoreDeepLink("ocp://store/character.sabai?version=latest")).toBeNull();
    expect(parseStoreDeepLink("https://store.example/character.sabai?version=1.2.0")).toBeNull();
  });

  it("finds one protocol argument without trusting unrelated argv", () => {
    expect(findStoreDeepLinkArg(["electron.exe", "--flag", "ocp://store/character.sabai?version=1.2.0"])).toEqual({
      packageId: "character.sabai",
      version: "1.2.0",
    });
    expect(findStoreDeepLinkArg(["electron.exe", "--flag"])).toBeNull();
  });

  it("sanitizes structured second-instance Store data when Electron drops argv", () => {
    expect(sanitizeStoreDeepLink({ packageId: "character.sabai-sompoo", version: "1.0.1" })).toEqual({
      packageId: "character.sabai-sompoo",
      version: "1.0.1",
    });
    expect(sanitizeStoreDeepLink({ packageId: "../secret", version: "1.0.1" })).toBeNull();
    expect(sanitizeStoreDeepLink({ packageId: "character.sabai-sompoo", version: "latest" })).toBeNull();
    expect(sanitizeStoreDeepLink("ocp://store/character.sabai-sompoo?version=1.0.1")).toBeNull();
  });
});
