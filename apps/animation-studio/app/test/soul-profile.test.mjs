import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { buildAutoSoulProfile, buildSoulProfile, renderSoulMarkdown } from "../src/features/character/soul-profile.js";

test("Auto Soul derives bounded traits and runtime behavior from localized descriptions", () => {
  const profile = buildAutoSoulProfile({
    name: "Nene",
    descriptionEn: "A warm, playful, energetic and chatty desktop companion who is curious and friendly.",
    descriptionTh: "เพื่อนคู่ใจที่อบอุ่น ขี้เล่น ร่าเริง และช่างพูด",
  });

  assert.equal(profile.schema, "soul/1");
  assert.equal(profile.mode, "auto");
  assert.equal(profile.identity.name, "Nene");
  assert.match(profile.identity.descriptions.en, /playful/);
  assert.match(profile.identity.descriptions.th, /อบอุ่น/);
  assert.ok(profile.traits.warmth > 0.65);
  assert.ok(profile.traits.humor > 0.45);
  assert.ok(profile.traits.energy > 0.5);
  assert.ok(profile.traits.talkativeness > 0.45);
  assert.ok(profile.traits.movement >= 0 && profile.traits.movement <= 1);
  assert.ok(profile.behavior.restSeconds >= 16 && profile.behavior.restSeconds <= 24);
  assert.ok(profile.behavior.walkSeconds >= 9 && profile.behavior.walkSeconds <= 13);
});

test("Auto Soul stays deterministic and produces a canonical SOUL.md", () => {
  const project = {
    name: "Mister Zhang",
    descriptionEn: "A calm, formal, professional companion who is concise and reserved.",
    descriptionTh: "ผู้ช่วยที่สุภาพ สุขุม เงียบ และพูดน้อย",
  };
  const first = buildAutoSoulProfile(project);
  const second = buildAutoSoulProfile(project);
  assert.deepEqual(first, second);
  assert.ok(first.traits.formality > 0.45);
  assert.ok(first.traits.energy < 0.5);
  assert.ok(first.traits.talkativeness < 0.45);

  const markdown = renderSoulMarkdown(first);
  assert.match(markdown, /^# Mister Zhang — SOUL/m);
  assert.match(markdown, /## Identity/);
  assert.match(markdown, /### English/);
  assert.match(markdown, /### ไทย/);
  assert.match(markdown, /## Runtime behavior/);
  assert.match(markdown, /Runtime parses the structured profile once/);
});

test("Guided and Custom Soul modes override structured traits without changing source descriptions", () => {
  const project = {
    name: "Nene",
    descriptionEn: "A calm friendly companion.",
    descriptionTh: "เพื่อนที่สงบและเป็นมิตร",
    soulMode: "guided",
    soulTraits: { energy: 0.9, initiative: 0.8, warmth: 0.95 },
  };
  const guided = buildSoulProfile(project);
  assert.equal(guided.mode, "guided");
  assert.equal(guided.traits.energy, 0.9);
  assert.equal(guided.traits.initiative, 0.8);
  assert.equal(guided.traits.warmth, 0.95);
  assert.ok(guided.behavior.walkSeconds > 11);
  assert.ok(guided.behavior.restSeconds < 20);
  assert.equal(guided.identity.descriptions.en, "A calm friendly companion.");

  const custom = buildSoulProfile({
    ...project,
    soulMode: "custom",
    soulCustomMarkdown: "# Nene Soul\nWarm, playful, but never intrusive.",
  });
  assert.equal(custom.mode, "custom");
  assert.match(custom.customText, /never intrusive/);
  assert.equal(renderSoulMarkdown(custom), "# Nene Soul\nWarm, playful, but never intrusive.\n");
});

test("Studio package builder embeds structured Soul metadata and canonical SOUL.md", async () => {
  const source = await readFile(new URL("../src/main.jsx", import.meta.url), "utf8");
  assert.match(source, /buildSoulProfile\(project\)/);
  assert.match(source, /assets\/soul\.json/);
  assert.match(source, /assets\/SOUL\.md/);
  assert.match(source, /renderSoulMarkdown\(soulProfile\)/);
});
