
import assert from "node:assert/strict";
import test from "node:test";
import JSZip from "jszip";

import {
  buildSpriteEffectPackDefinition,
  buildSpriteEffectPackPackageDraft,
  computeDominantAlphaBounds,
  computeSpriteSheetLayout,
  createDefaultSpriteFxPackProject,
} from "../src/features/sprite-fx/sprite-sheet-effect-model.js";

test("SPRITE-FX defaults export-safe runtime texture caps", function () {
  const project = createDefaultSpriteFxPackProject();
  assert.equal(project.slots.bodyAura.runtimeExportCap, 384);
  assert.equal(project.slots.groundRune.runtimeExportCap, 384);
  assert.equal(project.slots.levelUpBurst.runtimeExportCap, 384);
  assert.equal(project.slots.bodyAura.scale, 1.12);
  assert.equal(project.slots.bodyAura.offsetY, -6);
  assert.equal(project.slots.groundRune.scale, 1.40);
  assert.equal(project.slots.groundRune.offsetY, 0);
  assert.equal(project.slots.levelUpBurst.anchor, "character-feet-bottom");
  assert.equal(project.slots.levelUpBurst.scale, 1.10);
  assert.equal(project.slots.levelUpBurst.offsetY, 0);
});

test("SPRITE-FX 4 second source at 12 FPS maps to 48 frames in an 8x6 sheet", function () {
  const layout = computeSpriteSheetLayout(48, 512, 8);
  assert.deepEqual(layout, {
    frameCount: 48,
    frameWidth: 512,
    frameHeight: 512,
    columns: 8,
    rows: 6,
    sheetWidth: 4096,
    sheetHeight: 3072,
  });
});

test("SPRITE-FX dominant alpha bounds ignore sparse Aura particles without collapsing the core", function () {
  const width = 20;
  const height = 20;
  const rgba = new Uint8ClampedArray(width * height * 4);
  function alpha(x, y, value = 255) {
    rgba[(y * width + x) * 4 + 3] = value;
  }
  for (let y = 4; y <= 15; y += 1) {
    for (let x = 6; x <= 13; x += 1) alpha(x, y);
  }
  alpha(0, 0);
  alpha(19, 19);
  const bounds = computeDominantAlphaBounds(rgba, width, height, { x: 0, y: 0, width: 20, height: 20 });
  assert.ok(bounds.x > 0);
  assert.ok(bounds.y > 0);
  assert.ok(bounds.x + bounds.width < 20);
  assert.ok(bounds.y + bounds.height < 20);
  assert.ok(bounds.width >= 12);
  assert.ok(bounds.height >= 12);
});

test("SPRITE-FX multi-slot definition matches the approved 3-slot mock", function () {
  const project = createDefaultSpriteFxPackProject();
  const artifacts = {
    bodyAura: { frameCount: 48, frameWidth: 420, frameHeight: 480, contentBounds: { x: 0, y: 0, width: 420, height: 480 }, assetPath: "assets/bodyAura.png" },
    groundRune: { frameCount: 48, frameWidth: 470, frameHeight: 126, contentBounds: { x: 0, y: 0, width: 470, height: 126 }, assetPath: "assets/groundRune.png" },
    levelUpBurst: { frameCount: 36, frameWidth: 456, frameHeight: 470, contentBounds: { x: 0, y: 0, width: 456, height: 470 }, assetPath: "assets/levelUpBurst.png" },
  };
  project.slots.levelUpBurst.anchor = "character-feet-bottom";
  const effect = buildSpriteEffectPackDefinition(project, artifacts);
  assert.deepEqual(Object.keys(effect.slots), ["bodyAura", "groundRune", "levelUpBurst"]);
  assert.equal(effect.slots.bodyAura.looped, true);
  assert.equal(effect.slots.groundRune.anchor, "character-feet");
  assert.equal(effect.slots.groundRune.scaleMode, "character-width");
  assert.equal(effect.slots.groundRune.scale, 1.40);
  assert.equal(effect.slots.groundRune.offsetY, 0);
  assert.equal(effect.slots.groundRune.zIndex, -20);
  assert.equal(effect.slots.groundRune.maxHeightRatio, 0.32);
  assert.deepEqual(effect.slots.groundRune.contentBounds, { x: 0, y: 0, width: 470, height: 126 });
  assert.equal(effect.slots.groundRune.frameWidth, 470);
  assert.equal(effect.slots.groundRune.frameHeight, 126);
  assert.equal(effect.slots.bodyAura.scaleMode, "character-height");
  assert.equal(effect.slots.bodyAura.zIndex, -10);
  assert.equal(effect.slots.levelUpBurst.looped, false);
  assert.equal(effect.slots.levelUpBurst.anchor, "character-feet-bottom");
  assert.equal(effect.slots.levelUpBurst.zIndex, 20);
  assert.equal(effect.progression.mode, "bond-rank");
  assert.equal(effect.progression.variants.length, 5);
  assert.equal(effect.progression.variants[4].slotOverrides.bodyAura.tint, "#FACC15");
});

test("SPRITE-FX can build a partial pack while keeping independent slot assets", function () {
  const project = createDefaultSpriteFxPackProject();
  const effect = buildSpriteEffectPackDefinition(project, {
    bodyAura: { frameCount: 48, assetPath: "assets/bodyAura.png" },
  });
  assert.deepEqual(Object.keys(effect.slots), ["bodyAura"]);
  assert.equal(effect.slots.bodyAura.renderer, "sprite-sheet-2d");
});

test("SPRITE-FX package draft contains effect.json plus three generated PNG sheets", async function () {
  const project = createDefaultSpriteFxPackProject();
  const png = new Blob([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])], { type: "image/png" });
  const draft = await buildSpriteEffectPackPackageDraft(project, {
    bodyAura: { blob: png, frameCount: 48, assetPath: "assets/bodyAura.png" },
    groundRune: { blob: png, frameCount: 48, assetPath: "assets/groundRune.png" },
    levelUpBurst: { blob: png, frameCount: 24, assetPath: "assets/levelUpBurst.png" },
  }, {
    publisherId: "ocp.official",
    keyId: "ed25519:test",
  });

  const zip = await JSZip.loadAsync(draft.bytes);
  assert.ok(zip.file("assets/effect.json"));
  assert.ok(zip.file("assets/bodyAura.png"));
  assert.ok(zip.file("assets/groundRune.png"));
  assert.ok(zip.file("assets/levelUpBurst.png"));
  const manifest = JSON.parse(await zip.file("manifest.json").async("string"));
  assert.equal(manifest.type, "effect-pack");
  assert.equal(manifest.assets.length, 4);
});
