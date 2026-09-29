import { describe, expect, it } from "vitest";

import { localeFromSettings, translate } from "./i18n";

describe("desktop shell localization", () => {
  it("normalizes supported locale variants and falls back to English", () => {
    expect(localeFromSettings("th-TH")).toBe("th");
    expect(localeFromSettings("en_US")).toBe("en");
    expect(localeFromSettings("ja-JP")).toBe("en");
  });

  it("translates shared control-center copy with named placeholders", () => {
    expect(translate("th", "settings.title")).toBe("ปรับ OCP ให้เป็นแบบของคุณ");
    expect(translate("th", "updates.confirm.title", "", { version: "2.0.0" })).toContain("2.0.0");
    expect(translate("en", "missing.key", "Fallback")).toBe("Fallback");
  });
});
