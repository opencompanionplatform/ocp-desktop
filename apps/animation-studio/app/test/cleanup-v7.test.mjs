import test from "node:test";
import assert from "node:assert/strict";
import {
  hexToKeyColor,
  keyColorToHex,
  normalizeKeyColor,
  resolveCleanupKeyColor,
} from "../src/features/character/cleanup-v7.js";

test("Cleanup V7 normalizes arbitrary picked RGB without forcing green or gray", () => {
  assert.deepEqual(normalizeKeyColor({ red: 18.4, green: 122.8, blue: 241.2 }), { red: 18, green: 123, blue: 241 });
  assert.equal(keyColorToHex({ red: 18, green: 123, blue: 241 }), "#127BF1");
  assert.deepEqual(hexToKeyColor("#A1B2C3"), { red: 161, green: 178, blue: 195 });
});

test("Cleanup V7 picked key wins over auto detection", () => {
  const picked = { red: 12, green: 198, blue: 77 };
  const detected = { red: 220, green: 220, blue: 220 };
  assert.deepEqual(resolveCleanupKeyColor({ keyColorMode: "picked", keyColor: picked }, detected), picked);
});

test("Cleanup V7 auto mode uses detected video color and has no fixed fallback", () => {
  const detected = { red: 31, green: 52, blue: 73 };
  assert.deepEqual(resolveCleanupKeyColor({ keyColorMode: "auto" }, detected), detected);
  assert.equal(resolveCleanupKeyColor({ keyColorMode: "auto" }, null), null);
  assert.equal(resolveCleanupKeyColor({ keyColorMode: "picked", keyColor: null }, detected), null);
});
