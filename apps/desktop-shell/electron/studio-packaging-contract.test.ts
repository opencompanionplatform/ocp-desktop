import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

const packageJson = JSON.parse(readFileSync(path.join(__dirname, "../package.json"), "utf8")) as {
  scripts: Record<string, string>;
  build: { extraResources: Array<{ from: string; to: string }> };
};

describe("Desktop Studio signer packaging contract", () => {
  it("builds both native signer architectures before Windows packaging", () => {
    expect(packageJson.scripts["build:signers"]).toContain("x86_64-pc-windows-msvc");
    expect(packageJson.scripts["build:signers"]).toContain("aarch64-pc-windows-msvc");
    expect(packageJson.scripts["package:win:x64"]).toContain("npm run build:signers");
    expect(packageJson.scripts["package:win:arm64"]).toContain("npm run build:signers");
    expect(packageJson.scripts["dist:win:x64"]).toContain("npm run build:signers");
    expect(packageJson.scripts["dist:win:arm64"]).toContain("npm run build:signers");
  });

  it("ships architecture-labelled signer binaries as Electron resources", () => {
    const resources = packageJson.build.extraResources;
    expect(resources).toEqual(expect.arrayContaining([
      expect.objectContaining({
        from: "../../target/x86_64-pc-windows-msvc/release/ocp-package-signer.exe",
        to: "tools/ocp-package-signer-x64.exe",
      }),
      expect.objectContaining({
        from: "../../target/aarch64-pc-windows-msvc/release/ocp-package-signer.exe",
        to: "tools/ocp-package-signer-arm64.exe",
      }),
    ]));
  });
});
