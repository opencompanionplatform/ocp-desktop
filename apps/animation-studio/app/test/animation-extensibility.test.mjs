import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  ANIMATION_NAMES,
  OPTIONAL_ANIMATION_NAMES,
  BUILTIN_ANIMATION_NAMES,
  animationProfileFor,
  inferAnimationName,
} from "../src/features/character/catalog.js";

test("Animation System V2 keeps Standard compatibility and adds optional directional/drag slots", () => {
  assert.equal(ANIMATION_NAMES.length, 21);
  assert.deepEqual(OPTIONAL_ANIMATION_NAMES, [
    "climb_top",
    "climb_up_left",
    "climb_up_right",
    "climb_down_left",
    "climb_down_right",
    "hang_left",
    "hang_right",
    "drag_hold",
    "drag_release",
  ]);
  assert.equal(BUILTIN_ANIMATION_NAMES.length, 30);
  assert.equal(animationProfileFor("climb_top").loop, false);
  assert.equal(animationProfileFor("hang_left").loop, true);
  assert.equal(animationProfileFor("drag_release").loop, false);
  assert.equal(animationProfileFor("drag_release").duration, 0.25);
});

test("Animation System V2 accepts project-scoped custom animation names", () => {
  const names = [...BUILTIN_ANIMATION_NAMES, "charge_power", "jump_scare", "bomb_drop"];
  assert.equal(inferAnimationName("charge_power.mp4", names), "charge_power");
  assert.equal(inferAnimationName("jump_scare_take01.mp4", names), "jump_scare");
  assert.equal(animationProfileFor("charge_power").fps, 12);
});

test("Studio package builder emits semantic roles, optional fallbacks and declarative actions", async () => {
  const source = await readFile(new URL("../src/main.jsx", import.meta.url), "utf8");
  assert.match(source, /"hang\.left": "hang_left"/);
  assert.match(source, /"hang\.right": "hang_right"/);
  assert.match(source, /"drag\.hold": "drag_hold"/);
  assert.match(source, /"drag\.release": "drag_release"/);
  assert.match(source, /"climb\.up\.left": "climb_up_left"/);
  assert.match(source, /"climb\.up\.right": "climb_up_right"/);
  assert.match(source, /"climb\.ready\.left": "climb_ready_left"/);
  assert.match(source, /"climb\.ready\.right": "climb_ready_right"/);
  assert.match(source, /"climb\.down\.left": "climb_down_left"/);
  assert.match(source, /"climb\.down\.right": "climb_down_right"/);
  assert.match(source, /directional artwork must provide both Left and Right slots/);
  assert.match(source, /mirrorSafe: false/);
  assert.doesNotMatch(source, /drag_release: animations\.drag_release \? "drag_release" : "idle"/);
  assert.match(source, /filter\(\(clip\) => isCustomAnimation\(clip\.name\)\)/);
  assert.match(source, /priority: "presentation"/);
  assert.match(source, /missingStandardSheets/);
});

test("Studio project metadata is localized, account-bound, licensed from an allowlist, and schema-locked", async () => {
  const source = await readFile(new URL("../src/main.jsx", import.meta.url), "utf8");
  assert.match(source, /descriptionEn/);
  assert.match(source, /descriptionTh/);
  assert.match(source, /descriptions: Object\.fromEntries/);
  assert.match(source, /creatorCloudProfile\?\.publisherId/);
  assert.match(source, /Author \/ Publisher" value=\{publisherLabel\} readOnly/);
  assert.match(source, /CHARACTER_LICENSE_OPTIONS/);
  assert.match(source, /Entry schema \(latest\).*CURRENT_CHARACTER_SCHEMA/);
  assert.match(source, /Add a character description in English or Thai before continuing/);
});
