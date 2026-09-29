import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { createStudioCreatorCloud } from "../src/creator-cloud.js";

const ACCESS = "access-token-demo";

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

test("M1 Animation Studio checks, reserves and releases Marketplace package identity", async () => {
  const calls = [];
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async (url, options = {}) => {
    const value = String(url);
    calls.push({ value, options });

    if (value.startsWith("https://api.example/cloud-api/v1/creator/identity?")) {
      const parsed = new URL(value);
      assert.equal(parsed.searchParams.get("packageId"), "character.bible");
      assert.equal(parsed.searchParams.get("displayName"), "BIBLE");
      return jsonResponse({ identity: { decision: "available", reservationExpiresAt: null } });
    }

    if (value.endsWith("/v1/creator/identity/reservations") && options.method === "POST") {
      assert.deepEqual(JSON.parse(String(options.body)), {
        packageId: "character.bible",
        displayName: "BIBLE",
      });
      return jsonResponse({
        identity: {
          decision: "reserved-by-you",
          reservationExpiresAt: "2026-09-15T12:00:00.000Z",
        },
      });
    }

    if (value.endsWith("/v1/creator/identity/reservations/character.bible") && options.method === "DELETE") {
      return jsonResponse({ identity: { status: "released" } });
    }

    throw new Error("unexpected identity URL " + value);
  });

  const checked = await client.getPackageIdentity(ACCESS, "character.bible", "BIBLE");
  assert.equal(checked.decision, "available");

  const reserved = await client.reservePackageIdentity(ACCESS, "character.bible", "BIBLE");
  assert.equal(reserved.decision, "reserved-by-you");
  assert.equal(reserved.reservationExpiresAt, "2026-09-15T12:00:00.000Z");

  assert.deepEqual(await client.releasePackageIdentity(ACCESS, "character.bible"), { status: "released" });
  assert.ok(calls.every(({ options }) => options.headers.authorization === "Bearer " + ACCESS));
});

test("M1 Animation Studio identity client is character-only and rejects invalid Cloud decisions", async () => {
  const client = createStudioCreatorCloud({
    cloudApiUrl: "https://api.example/cloud-api",
  }, async () => jsonResponse({ identity: { decision: "mystery", reservationExpiresAt: null } }));

  await assert.rejects(() => client.getPackageIdentity(ACCESS, "skill.demo", "Demo"), TypeError);
  await assert.rejects(() => client.getPackageIdentity(ACCESS, "character.demo", "Demo"), /invalid decision/);
});

test("M1 Studio UI exposes explicit Marketplace identity controls and re-checks before Cloud upload", () => {
  const source = readFileSync(new URL("../src/main.jsx", import.meta.url), "utf8");
  assert.match(source, /Package ID availability & ownership/);
  assert.match(source, /Check Marketplace/);
  assert.match(source, /Reserve for 72 hours/);
  assert.match(source, /Renew 72h reservation/);
  assert.match(source, /Release reservation/);
  assert.match(source, /assertMarketplaceIdentityReadyForPublish/);
  assert.match(source, /Re-checking Marketplace Package ID authority/);
  assert.match(source, /identity\.decision === "reserved-by-you" \|\| identity\.decision === "owned-published"/);
  assert.match(source, /owned-submission/);
  assert.match(source, /Signer \{desktopEnvironment\?\.signingAvailable \? "ready/);
  assert.match(source, /Desktop package signing is not provisioned/);
  assert.match(source, /freshUploadNeedsSigner && !desktopSignerReady/);
  assert.match(source, /\["identity", "version", "building", "signing"/);
  assert.match(source, /preflightCreatorCloudVersion/);
  assert.match(source, /Suggested next version/);
  assert.match(source, /Use \{creatorVersionConflict\.suggestedVersion\}/);
});
