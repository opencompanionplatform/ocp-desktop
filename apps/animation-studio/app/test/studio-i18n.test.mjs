import test from "node:test";
import assert from "node:assert/strict";
import { normalizeStudioLocale, translateStudioText } from "../src/i18n/studio-i18n.js";

test("Studio i18n normalizes Thai and English locales", () => {
  assert.equal(normalizeStudioLocale("th-TH"), "th");
  assert.equal(normalizeStudioLocale("en-US"), "en");
  assert.equal(normalizeStudioLocale("ja-JP"), "en");
});

test("Studio i18n translates workflow labels without changing technical payload text", () => {
  assert.equal(translateStudioText("Import videos", "th"), "นำเข้าวิดีโอ");
  assert.equal(translateStudioText("Description (English)", "th"), "รายละเอียดตัวละคร (อังกฤษ)");
  assert.equal(translateStudioText("Description (Thai)", "th"), "รายละเอียดตัวละคร (ไทย)");
  assert.equal(translateStudioText("Entry schema (latest)", "th"), "Entry schema (ล่าสุด)");
  assert.equal(translateStudioText("Step 3 of 7", "th"), "ขั้นตอน 3 จาก 7");
  assert.equal(translateStudioText("  12 sheets ready  ", "th"), "  พร้อมแล้ว 12 ชีต  ");
  assert.equal(translateStudioText('{"schema":"character/3"}', "th"), '{"schema":"character/3"}');
  assert.equal(translateStudioText("Import videos", "en"), "Import videos");
});
