import { ESLint } from "eslint";
import { describe, expect, it } from "vitest";

// T02: packaging output must not pollute source lint, and source rules must stay active.
describe("Desktop lint after packaging", () => {
  const eslint = new ESLint();

  it.each([
    "release/win-unpacked/resources/studio/assets/index.js",
    "release-arm64-rc/win-arm64-unpacked/resources/studio/assets/index.js",
    "release-x64-rc/win-unpacked/resources/studio/assets/index.js",
  ])("ignores generated Electron package files: %s", async (file) => {
    expect(await eslint.isPathIgnored(file)).toBe(true);
  });

  it("still reports real source lint errors", async () => {
    const [result] = await eslint.lintText("const unusedProductionValue = 1;", {
      filePath: "src/lint-regression-fixture.ts",
    });
    expect(result.messages.some((message) => message.ruleId === "@typescript-eslint/no-unused-vars")).toBe(true);
    expect(await eslint.isPathIgnored("electron/main.ts")).toBe(false);
  });
});
