import test from "node:test";
import assert from "node:assert/strict";
import { autoSolidBackgroundMatte, estimateEdgeBackgroundKey, isClassicGreenKey } from "../src/features/character/cleanup-v6.js";

function makeImage(width, height, fill = [213, 213, 213, 255]) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let pixel = 0; pixel < width * height; pixel += 1) data.set(fill, pixel * 4);
  return { width, height, data };
}

function setPixel(image, x, y, rgba) {
  image.data.set(rgba, (y * image.width + x) * 4);
}

function getPixel(image, x, y) {
  const index = (y * image.width + x) * 4;
  return Array.from(image.data.slice(index, index + 4));
}

const GRAY = { red: 213, green: 213, blue: 213 };
const PRESET = {
  presetName: "normal",
  preserveGlow: false,
  keyColor: GRAY,
  chromaSensitivity: 60,
  keyTolerance: 55,
  interiorCut: 100,
};

test("Cleanup V6 estimates dominant neutral background from image edges", () => {
  const image = makeImage(12, 12);
  for (let y = 4; y < 8; y += 1) {
    for (let x = 4; x < 8; x += 1) setPixel(image, x, y, [20, 15, 12, 255]);
  }
  const key = estimateEdgeBackgroundKey(image.data, image.width, image.height);
  assert.ok(key);
  assert.ok(Math.abs(key.red - 213) < 1);
  assert.ok(Math.abs(key.green - 213) < 1);
  assert.ok(Math.abs(key.blue - 213) < 1);
  assert.ok(key.confidence > 0.8);
  assert.equal(isClassicGreenKey(key), false);
});

test("Cleanup V6 removes flat gray background while preserving opaque black subject", () => {
  const image = makeImage(9, 9);
  for (let y = 3; y <= 5; y += 1) {
    for (let x = 3; x <= 5; x += 1) setPixel(image, x, y, [10, 8, 7, 255]);
  }
  autoSolidBackgroundMatte(image, PRESET);
  assert.equal(getPixel(image, 0, 0)[3], 0);
  assert.equal(getPixel(image, 4, 4)[3], 255);
});

test("Cleanup V6 reconstructs semi-transparent black hair over gray", () => {
  const image = makeImage(9, 9);
  // 50% black over RGB 213 gray ~= 106.5 per channel.
  setPixel(image, 2, 4, [106, 106, 106, 255]);
  setPixel(image, 3, 4, [20, 18, 18, 255]);
  autoSolidBackgroundMatte(image, PRESET);
  const edge = getPixel(image, 2, 4);
  assert.ok(edge[3] > 80 && edge[3] < 190, `expected partial alpha, got ${edge[3]}`);
  assert.ok(edge[0] < 40 && edge[1] < 40 && edge[2] < 40, `expected recovered dark hair, got ${edge}`);
  assert.equal(getPixel(image, 3, 4)[3], 255);
});

test("Cleanup V6 floods a large connected solid background beyond the edge-refine radius", () => {
  const image = makeImage(80, 60);
  for (let y = 20; y < 40; y += 1) {
    for (let x = 30; x < 50; x += 1) setPixel(image, x, y, [15, 12, 10, 255]);
  }
  autoSolidBackgroundMatte(image, PRESET);
  assert.equal(getPixel(image, 20, 30)[3], 0, "background far from canvas edge should still be removed");
  assert.equal(getPixel(image, 40, 30)[3], 255, "opaque center subject should remain");
});

test("Cleanup V6 recognizes classic green key separately", () => {
  assert.equal(isClassicGreenKey({ red: 20, green: 237, blue: 28 }), true);
  assert.equal(isClassicGreenKey({ red: 213, green: 213, blue: 213 }), false);
  assert.equal(isClassicGreenKey({ red: 20, green: 80, blue: 220 }), false);
});

test("Cleanup V6 removes neutral FX background while preserving bright glow", () => {
  const image = makeImage(7, 7);
  setPixel(image, 3, 3, [255, 245, 255, 255]);
  setPixel(image, 2, 3, [232, 220, 240, 255]);
  const result = autoSolidBackgroundMatte(image, {
    ...PRESET,
    presetName: "fx",
    preserveGlow: true,
    interiorCut: 0,
  });

  assert.equal(getPixel(image, 0, 0)[3], 0, "sampled neutral backdrop should become transparent");
  assert.equal(getPixel(image, 3, 3)[3], 255, "bright FX core should remain opaque");
  const glowEdgeAlpha = getPixel(image, 2, 3)[3];
  assert.ok(glowEdgeAlpha > 40 && glowEdgeAlpha < 240, `expected translucent glow edge, got alpha ${glowEdgeAlpha}`);
  assert.ok(result.removedPixels > 0);
  assert.ok(result.softenedPixels > 0);
});
