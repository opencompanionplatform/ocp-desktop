import test from "node:test";
import assert from "node:assert/strict";
import { previewDescriptor } from "../src/features/character/store-preview-export.js";

function clip(overrides = {}) {
  return {
    frames: Array.from({ length: 18 }, (_, index) => `frame-${index}`),
    targetFps: 12,
    loop: true,
    ...overrides,
  };
}

test("S1 Studio public preview descriptor keeps Store-safe geometry", () => {
  assert.deepEqual(previewDescriptor("walking_left", clip()), {
    name: "walking_left",
    sheet: "walking_left.webp",
    thumbnail: "walking_left.png",
    columns: 16,
    rows: 2,
    frameCount: 18,
    frameWidth: 192,
    frameHeight: 192,
    fps: 12,
    loop: true,
  });
});

test("S1 Studio public preview descriptor rejects unsafe clip identity", () => {
  for (const name of ["../idle", "Idle", "walking-left", "a".repeat(49)]) {
    assert.throws(() => previewDescriptor(name, clip()), /Invalid preview clip/);
  }
});

test("S1 Studio public preview descriptor rejects invalid resource bounds", () => {
  assert.throws(() => previewDescriptor("idle", clip({ frames: [] })), /Invalid preview clip/);
  assert.throws(() => previewDescriptor("idle", clip({ frames: Array(257).fill("frame") })), /Invalid preview clip/);
  assert.throws(() => previewDescriptor("idle", clip({ targetFps: 0 })), /Invalid preview clip/);
  assert.throws(() => previewDescriptor("idle", clip({ targetFps: 121 })), /Invalid preview clip/);
});
