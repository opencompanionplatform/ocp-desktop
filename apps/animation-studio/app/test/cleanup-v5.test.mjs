import test from "node:test";
import assert from "node:assert/strict";
import { estimateColorToAlpha, unmixConnectedScreenColor } from "../src/features/character/cleanup-v5.js";

function makeImage(width, height, fill = [0, 0, 0, 0]) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let pixel = 0; pixel < width * height; pixel += 1) {
    data.set(fill, pixel * 4);
  }
  return { width, height, data };
}

function setPixel(image, x, y, rgba) {
  image.data.set(rgba, (y * image.width + x) * 4);
}

function getPixel(image, x, y) {
  return Array.from(image.data.slice((y * image.width + x) * 4, (y * image.width + x) * 4 + 4));
}

const KEY = { red: 20, green: 237, blue: 28 };
const PRESET = {
  presetName: "normal",
  preserveGlow: false,
  keyColor: KEY,
  shadowCut: 90,
};

test("Cleanup V5 color-to-alpha estimates pure key as transparent", () => {
  assert.equal(estimateColorToAlpha(KEY.red, KEY.green, KEY.blue, KEY), 0);
});

test("Cleanup V5 reconstructs a black semi-transparent hair edge composited over green", () => {
  const image = makeImage(5, 5);
  // Approximation of 50% black hair over the sampled green screen.
  setPixel(image, 1, 2, [10, 119, 14, 255]);
  setPixel(image, 2, 2, [5, 59, 7, 255]);

  const result = unmixConnectedScreenColor(image, PRESET, { maxDistance: 4 });
  const first = getPixel(image, 1, 2);
  assert.ok(result.unmixedPixels >= 1);
  assert.ok(first[3] < 220, `expected reconstructed alpha, got ${first[3]}`);
  assert.ok(first[1] < 90, `expected green screen energy to be removed, got ${first[1]}`);
});

test("Cleanup V5 leaves genuine opaque green detail unchanged when channels differ from the key", () => {
  const image = makeImage(5, 5);
  setPixel(image, 1, 2, [0, 120, 0, 255]);
  const before = getPixel(image, 1, 2);
  unmixConnectedScreenColor(image, PRESET, { maxDistance: 4 });
  assert.deepEqual(getPixel(image, 1, 2), before);
});

test("Cleanup V5 leaves neutral opaque black detail unchanged", () => {
  const image = makeImage(5, 5);
  setPixel(image, 1, 2, [0, 0, 0, 255]);
  const before = getPixel(image, 1, 2);
  unmixConnectedScreenColor(image, PRESET, { maxDistance: 4 });
  assert.deepEqual(getPixel(image, 1, 2), before);
});

test("Cleanup V5 skips FX preserveGlow clips", () => {
  const image = makeImage(5, 5);
  setPixel(image, 1, 2, [10, 119, 14, 255]);
  const before = getPixel(image, 1, 2);
  const result = unmixConnectedScreenColor(image, { ...PRESET, presetName: "fx", preserveGlow: true });
  assert.deepEqual(getPixel(image, 1, 2), before);
  assert.equal(result.unmixedPixels, 0);
});
