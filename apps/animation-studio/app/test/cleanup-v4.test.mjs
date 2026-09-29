import test from "node:test";
import assert from "node:assert/strict";
import { adaptiveConnectedGreenShadowCleanup } from "../src/features/character/cleanup-v4.js";

function image(width, height, fill = [0, 0, 0, 0]) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let pixel = 0; pixel < width * height; pixel += 1) data.set(fill, pixel * 4);
  return { width, height, data };
}

function setPixel(target, x, y, rgba) {
  target.data.set(rgba, (y * target.width + x) * 4);
}

function alphaAt(target, x, y) {
  return target.data[(y * target.width + x) * 4 + 3];
}

const preset = {
  presetName: "normal",
  preserveGlow: false,
  shadowCut: 90,
  keyTolerance: 55,
  minKeySaturation: 0.28,
  keyColor: { red: 20, green: 237, blue: 28 },
};

test("Cleanup V4 removes compressed dark-green fringe even when V3 foreground protection caught it", () => {
  const target = image(7, 7);
  // Neutral foreground block in the center.
  for (let y = 2; y <= 4; y += 1) {
    for (let x = 2; x <= 4; x += 1) setPixel(target, x, y, [28, 24, 22, 255]);
  }
  // Typical compressed screen shadow: dark, green-dominant and touching exterior transparency.
  setPixel(target, 1, 3, [3, 51, 29, 255]);
  const protectedMask = new Uint8Array(49);
  protectedMask[3 * 7 + 1] = 1;
  const result = adaptiveConnectedGreenShadowCleanup(target, preset, {
    foregroundCoreMask: protectedMask,
  });

  assert.equal(alphaAt(target, 1, 3), 0);
  assert.ok(result.removedPixels >= 1);
  assert.equal(alphaAt(target, 2, 3), 255, "neutral foreground next to the recovered shadow must remain opaque");
});

test("Cleanup V4 preserves neutral dark hair/clothing at the exterior edge", () => {
  const target = image(5, 5);
  setPixel(target, 1, 2, [24, 28, 23, 255]);
  const protectedMask = new Uint8Array(25);
  protectedMask[2 * 5 + 1] = 1;

  adaptiveConnectedGreenShadowCleanup(target, preset, { foregroundCoreMask: protectedMask });
  assert.equal(alphaAt(target, 1, 2), 255);
});

test("Cleanup V4 does not use enclosed transparent holes as growth seeds", () => {
  const target = image(9, 9, [45, 35, 30, 255]);
  // Exterior background is already transparent, but model body separates it from an enclosed hole.
  for (let x = 0; x < 9; x += 1) {
    setPixel(target, x, 0, [0, 0, 0, 0]);
    setPixel(target, x, 8, [0, 0, 0, 0]);
  }
  for (let y = 0; y < 9; y += 1) {
    setPixel(target, 0, y, [0, 0, 0, 0]);
    setPixel(target, 8, y, [0, 0, 0, 0]);
  }
  setPixel(target, 4, 4, [0, 0, 0, 0]); // enclosed transparent hole
  setPixel(target, 4, 5, [5, 70, 36, 255]); // green clothing/detail next to the hole

  adaptiveConnectedGreenShadowCleanup(target, preset);
  assert.equal(alphaAt(target, 4, 5), 255);
});

test("Cleanup V4 leaves FX preserveGlow clips unchanged", () => {
  const target = image(5, 5);
  setPixel(target, 1, 2, [3, 51, 29, 255]);
  const result = adaptiveConnectedGreenShadowCleanup(target, {
    ...preset,
    presetName: "fx",
    preserveGlow: true,
  });
  assert.equal(alphaAt(target, 1, 2), 255);
  assert.deepEqual(result, { removedPixels: 0, softenedPixels: 0, maxDistance: 0 });
});
