import test from "node:test";
import assert from "node:assert/strict";

import {
  computeStandardizedSourcePlacement,
  measureCharacterCoreAlphaBounds,
  measurementWindowForAnimation,
  selectCharacterMeasurementBounds,
  unionSubjectBounds,
  usesCharacterCoreMeasurement,
} from "../src/features/character/subject-fit.js";

function makeImage(width, height) {
  return { width, height, data: new Uint8ClampedArray(width * height * 4) };
}

function fillRect(image, left, top, right, bottom, rgba) {
  for (let y = top; y < bottom; y += 1) {
    for (let x = left; x < right; x += 1) {
      const index = (y * image.width + x) * 4;
      image.data[index] = rgba[0];
      image.data[index + 1] = rgba[1];
      image.data[index + 2] = rgba[2];
      image.data[index + 3] = rgba[3];
    }
  }
}

test("FX character-core measurement ignores bright beam and ground-ring overflow", () => {
  const image = makeImage(40, 40);

  // Render-like FX survives cleanup and intentionally reaches the canvas edges.
  fillRect(image, 18, 0, 22, 40, [245, 250, 255, 120]);
  fillRect(image, 2, 34, 38, 36, [245, 250, 255, 150]);

  // The actual character is the dense, opaque central silhouette.
  fillRect(image, 14, 7, 26, 32, [72, 48, 36, 255]);

  const bounds = measureCharacterCoreAlphaBounds(image);
  assert.ok(bounds);
  assert.ok(bounds.x >= 12 && bounds.x <= 14, `unexpected x=${bounds.x}`);
  assert.ok(bounds.y >= 5 && bounds.y <= 7, `unexpected y=${bounds.y}`);
  assert.ok(bounds.x + bounds.width <= 28, `unexpected right=${bounds.x + bounds.width}`);
  assert.ok(bounds.y + bounds.height <= 34, `unexpected bottom=${bounds.y + bounds.height}`);
});

test("Appear and Disappear choose a representative full-character frame instead of unioning transition FX", () => {
  const samples = [
    { x: 205, y: 170, width: 102, height: 180 },
    { x: 164, y: 76, width: 188, height: 356 },
    { x: 160, y: 72, width: 194, height: 362 },
    { x: 198, y: 158, width: 116, height: 196 },
  ];

  const union = unionSubjectBounds(samples);
  assert.deepEqual(union, { x: 160, y: 72, width: 194, height: 362 });

  for (const name of ["appear", "disappear"]) {
    assert.equal(usesCharacterCoreMeasurement(name), true);
    assert.deepEqual(selectCharacterMeasurementBounds(samples, name), { x: 160, y: 72, width: 194, height: 362 });
  }
});

test("Disappear measures only the early stable portion of the transition", () => {
  assert.deepEqual(measurementWindowForAnimation("disappear"), { startRatio: 0.10, endRatio: 0.40 });
  assert.deepEqual(measurementWindowForAnimation("appear"), { startRatio: 0, endRatio: 1 });
});

test("Disappear rejects dissolved cores and prefers the Idle-height match", () => {
  const samples = [
    { x: 161, y: 74, width: 190, height: 360 },
    { x: 164, y: 78, width: 186, height: 352 },
    { x: 196, y: 156, width: 116, height: 194 },
    { x: 154, y: 96, width: 205, height: 300 },
  ];

  assert.deepEqual(
    selectCharacterMeasurementBounds(samples, "disappear", {
      sourceHeight: 512,
      referenceHeightRatio: 360 / 512,
    }),
    { x: 161, y: 74, width: 190, height: 360 },
  );
});

test("Disappear applies Idle master height correction while other air poses remain pose-aware", () => {
  const master = {
    referenceAnimation: "idle",
    referenceHeightRatio: 360 / 512,
    normalizedSourceScale: 0.8,
    baselineRatio: 0.985,
    centerXRatio: 0.5,
    standingHeightTolerance: 0.035,
    minScaleCorrection: 0.78,
    maxScaleCorrection: 1.28,
    overflowAllowanceRatio: 0.04,
  };
  const bounds = { x: 180, y: 120, width: 150, height: 300 };

  const disappear = computeStandardizedSourcePlacement(bounds, 512, 512, 512, 512, master, "disappear");
  const jump = computeStandardizedSourcePlacement(bounds, 512, 512, 512, 512, master, "jump");

  assert.ok(disappear.correction > 1, `expected disappear correction > 1, got ${disappear.correction}`);
  assert.equal(jump.correction, 1);
  assert.ok(disappear.scale > jump.scale, `expected corrected disappear scale ${disappear.scale} > jump ${jump.scale}`);
});

test("Normal character clips retain stable union measurement behavior", () => {
  const samples = [
    { x: 180, y: 130, width: 150, height: 250 },
    { x: 168, y: 118, width: 178, height: 266 },
    { x: 174, y: 124, width: 166, height: 258 },
  ];

  assert.equal(usesCharacterCoreMeasurement("idle"), false);
  assert.deepEqual(
    selectCharacterMeasurementBounds(samples, "idle"),
    { x: 168, y: 118, width: 178, height: 266 },
  );
});

test("paired drag placement can lock release scale to the hold reference", () => {
  const master = {
    referenceAnimation: "idle",
    referenceHeightRatio: 360 / 512,
    normalizedSourceScale: 0.8,
    baselineRatio: 0.985,
    centerXRatio: 0.5,
    standingHeightTolerance: 0.035,
    minScaleCorrection: 0.78,
    maxScaleCorrection: 1.28,
    overflowAllowanceRatio: 0.04,
  };
  const releaseBounds = { x: 170, y: 150, width: 172, height: 270 };
  const lockedNormalizedSourceScale = 0.72;

  const release = computeStandardizedSourcePlacement(
    releaseBounds,
    512,
    512,
    512,
    512,
    master,
    "drag_release",
    { lockedNormalizedSourceScale },
  );

  assert.equal(release.pairScaleLocked, true);
  assert.equal(release.correction, 1);
  assert.equal(release.scale, lockedNormalizedSourceScale);
  assert.equal(release.drawX + (releaseBounds.x + releaseBounds.width / 2) * release.scale, 256);
  assert.equal(release.drawY + (releaseBounds.y + releaseBounds.height) * release.scale, 512 * master.baselineRatio);
});
