import { describe, expect, it } from "vitest";

import {
  MAX_STUDIO_PACKAGE_BYTES,
  resolveStudioDevelopmentUrl,
  resolveStudioIndexPath,
  sanitizeStudioFileName,
  sanitizeStudioOAuthOpenInput,
  sanitizeStudioPackageSaveInput,
  sanitizeStudioPackageSignInput,
  sanitizeStudioProjectSaveInput,
} from "./studio-bridge";

describe("studio desktop bridge contract", () => {
  it("accepts only safe project/package basenames", () => {
    expect(sanitizeStudioFileName("character-bible-v1.draft.ocp", ".ocp")).toBe("character-bible-v1.draft.ocp");
    expect(sanitizeStudioFileName("character.bible.ocp-project.json", ".ocp-project.json")).toBe("character.bible.ocp-project.json");
    expect(sanitizeStudioFileName("../escape.ocp", ".ocp")).toBeNull();
    expect(sanitizeStudioFileName("C:\\escape.ocp", ".ocp")).toBeNull();
    expect(sanitizeStudioFileName("CON.ocp", ".ocp")).toBeNull();
  });

  it("rejects unknown save fields and oversized payloads", () => {
    expect(sanitizeStudioProjectSaveInput({ fileName: "demo.ocp-project.json", content: "{}", path: "D:\\escape" })).toBeNull();
    expect(sanitizeStudioProjectSaveInput({ fileName: "demo.ocp-project.json", content: "{}" })).toEqual({
      fileName: "demo.ocp-project.json",
      content: "{}",
    });
    expect(sanitizeStudioPackageSaveInput({ fileName: "demo.ocp", bytes: new Uint8Array([1, 2, 3]) })?.bytes.byteLength).toBe(3);
    expect(sanitizeStudioPackageSaveInput({ fileName: "demo.ocp", bytes: new Uint8Array(MAX_STUDIO_PACKAGE_BYTES + 1) })).toBeNull();
    expect(sanitizeStudioPackageSignInput({ bytes: new Uint8Array([1, 2, 3]) })?.bytes.byteLength).toBe(3);
    expect(sanitizeStudioPackageSignInput({ bytes: new Uint8Array([1]), path: "D:\\escape.ocp" })).toBeNull();
  });

  it("resolves Studio from source when the branded Electron executable is still a default app", () => {
    expect(resolveStudioIndexPath({
      defaultApp: true,
      resourcesPath: "D:\\ocp\\electron\\resources",
      moduleDir: "D:\\ocp\\apps\\desktop-shell\\dist-electron\\electron",
    })).toBe("D:\\ocp\\apps\\animation-studio\\app\\dist\\index.html");
    expect(resolveStudioIndexPath({
      defaultApp: false,
      resourcesPath: "D:\\ocp\\release\\resources",
      moduleDir: "D:\\ocp\\release\\resources\\app.asar\\dist-electron\\electron",
    })).toBe("D:\\ocp\\release\\resources\\studio\\index.html");
  });

  it("accepts only Supabase-style HTTPS authorize URLs for Desktop OAuth", () => {
    expect(sanitizeStudioOAuthOpenInput({ url: "https://example.supabase.co/auth/v1/authorize?provider=google" })?.url)
      .toBe("https://example.supabase.co/auth/v1/authorize?provider=google");
    expect(sanitizeStudioOAuthOpenInput({ url: "http://example.supabase.co/auth/v1/authorize?provider=google" })).toBeNull();
    expect(sanitizeStudioOAuthOpenInput({ url: "https://evil.example/login" })).toBeNull();
    expect(sanitizeStudioOAuthOpenInput({ url: "https://user:pass@example.supabase.co/auth/v1/authorize" })).toBeNull();
  });

  it("accepts a Studio dev URL only on local HTTP", () => {
    expect(resolveStudioDevelopmentUrl("http://127.0.0.1:5174/")).toBe("http://127.0.0.1:5174/");
    expect(resolveStudioDevelopmentUrl("http://localhost:5174/")).toBe("http://localhost:5174/");
    expect(resolveStudioDevelopmentUrl("https://studio.example/")).toBeNull();
    expect(resolveStudioDevelopmentUrl("http://192.168.1.10:5174/")).toBeNull();
  });
});
