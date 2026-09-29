import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../src/features/sprite-fx/SpriteSheetEffectStudio.jsx", import.meta.url), "utf8");
const main = await readFile(new URL("../src/main.jsx", import.meta.url), "utf8");

test("SPRITE-FX Cloud publish reuses Creator identity, upload, validation, and review pipeline", () => {
  assert.match(source, /checkCreatorCloudPackageIdentity/);
  assert.match(source, /reserveCreatorCloudPackageIdentity/);
  assert.match(source, /"owned-submission"/);
  assert.match(source, /uploadSignedArchiveToCreatorCloud/);
  assert.match(source, /submitCreatorCloudForReview/);
  assert.match(source, /signPackageWithDesktop/);
  assert.match(source, /creatorProfile\.keys/);
  assert.match(source, /Publish to Creator Cloud/);
  assert.match(source, /Submitted for C8 moderation/);
});

test("SPRITE-FX receives the same authenticated Creator session/profile as Character Studio", () => {
  assert.match(main, /<SpriteSheetEffectStudio/);
  assert.match(main, /creatorSession=\{creatorCloudSession\}/);
  assert.match(main, /creatorProfile=\{creatorCloudProfile\}/);
});

test("SPRITE-FX local signed build remains available independently from Cloud publish", () => {
  assert.match(source, /Build signed \.ocp/);
  assert.match(source, /savePackageToDesktop/);
  assert.match(source, /Cloud publish remains closed for this account/);
});

