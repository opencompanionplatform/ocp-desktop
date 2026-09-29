import assert from "node:assert/strict";
import test from "node:test";

import { readSpriteFxAccess } from "../src/config/feature-flags.js";

test("SPRITE-FX defaults to admin-only and hides from ordinary creators", () => {
  const ordinary = readSpriteFxAccess({}, { publisherId: "creator.demo" });
  assert.equal(ordinary.mode, "admin");
  assert.equal(ordinary.visible, false);
  assert.equal(ordinary.cloudPublishEnabled, false);

  const admin = readSpriteFxAccess({}, { publisherId: "ocp.official" });
  assert.equal(admin.visible, true);
  assert.equal(admin.localBuildEnabled, true);
  assert.equal(admin.cloudPublishEnabled, false);
});

test("SPRITE-FX admin Cloud publication requires both allowlist and explicit gate", () => {
  const admin = readSpriteFxAccess({
    VITE_SPRITE_FX_MODE: "admin",
    VITE_SPRITE_FX_ADMIN_PUBLISHERS: "ocp.official",
    VITE_SPRITE_FX_CLOUD: "true",
  }, { publisherId: "ocp.official" });
  assert.equal(admin.visible, true);
  assert.equal(admin.cloudPublishEnabled, true);

  const ordinary = readSpriteFxAccess({
    VITE_SPRITE_FX_MODE: "admin",
    VITE_SPRITE_FX_ADMIN_PUBLISHERS: "ocp.official",
    VITE_SPRITE_FX_CLOUD: "true",
  }, { publisherId: "creator.demo" });
  assert.equal(ordinary.visible, false);
  assert.equal(ordinary.cloudPublishEnabled, false);
});

test("SPRITE-FX public mode can explicitly enable Cloud publication", () => {
  const access = readSpriteFxAccess({
    VITE_SPRITE_FX_MODE: "public",
    VITE_SPRITE_FX_CLOUD: "true",
  }, null);
  assert.equal(access.visible, true);
  assert.equal(access.cloudPublishEnabled, true);
});

test("SPRITE-FX off mode hides feature even from admins", () => {
  const access = readSpriteFxAccess({
    VITE_SPRITE_FX_MODE: "off",
    VITE_SPRITE_FX_ADMIN_PUBLISHERS: "ocp.official",
  }, { publisherId: "ocp.official" });
  assert.equal(access.visible, false);
});

