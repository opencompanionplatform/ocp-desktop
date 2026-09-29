import { readFile } from "node:fs/promises";

import { describe, expect, it } from "vitest";

const mainSource = await readFile(new URL("./main.ts", import.meta.url), "utf8");
const devRegistrationSource = await readFile(
  new URL("../../../register_ocp_dev_protocol.ps1", import.meta.url),
  "utf8",
).catch(() => "");
const installerSource = await readFile(
  new URL("../../../release/windows/ocp-portable.iss", import.meta.url),
  "utf8",
).catch(() => "");

describe("Windows ocp:// registration contract", () => {
  it("keeps production protocol registration installer-owned", () => {
    expect(mainSource).not.toContain('app.setAsDefaultProtocolClient("ocp")');
    expect(installerSource).toContain("Software\\Classes\\ocp\\shell\\open\\command");
    expect(installerSource).toContain("ocp-launcher.exe");
    expect(installerSource).toContain("--protocol-uri");
    expect(installerSource).not.toContain("Start-OCP.ps1\"\" -ProtocolUri");
    expect(installerSource).toContain('""%1""');
  });

  it("keeps normal shortcuts and autostart background-only while post-install opens First Run", () => {
    expect(installerSource).toContain(String.raw`Name: "{autoprograms}\{#ProductName}"; Filename: "{app}\ocp-launcher.exe"; WorkingDir: "{app}"`);
    expect(installerSource).toContain(String.raw`Name: "{autodesktop}\{#ProductName}"; Filename: "{app}\ocp-launcher.exe"; WorkingDir: "{app}"`);
    expect(installerSource).toContain(String.raw`Filename: "{app}\ocp-launcher.exe"; Parameters: "--open=home"; WorkingDir: "{app}"; Description: "Start Open Companion Platform"; Flags: nowait postinstall skipifsilent`);
    expect(installerSource).toContain(String.raw`ValueName: "OpenCompanionPlatform"; ValueData: """{app}\ocp-launcher.exe"""`);
    expect(installerSource).not.toContain(String.raw`ValueName: "OpenCompanionPlatform"; ValueData: """{app}\ocp-launcher.exe"" --open=home`);
  });

  it("provides an explicit dev registration path with Windows association metadata", () => {
    expect(devRegistrationSource).toContain("HKCU:\\Software\\Classes\\ocp");
    expect(devRegistrationSource).toContain("ApplicationName");
    expect(devRegistrationSource).toContain("OCP Desktop");
    expect(devRegistrationSource).toContain("SHCNE_ASSOCCHANGED");
    expect(devRegistrationSource).toContain('"%1"');
    expect(devRegistrationSource).toMatch(/\[switch\]\$Register/);
    expect(devRegistrationSource).toMatch(/\[switch\]\$Check/);
  });
});

