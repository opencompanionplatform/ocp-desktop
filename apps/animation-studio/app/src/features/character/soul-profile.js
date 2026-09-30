const SOUL_SCHEMA = "soul/1";
const SOUL_MODE = "auto";
const SOUL_SOURCE = "studio-descriptions-v1";
const CUSTOM_SOUL_MAX_CHARS = 2400;

export const SOUL_TRAIT_KEYS = Object.freeze([
  "warmth",
  "humor",
  "formality",
  "initiative",
  "energy",
  "talkativeness",
  "movement",
]);

function clamp01(value) {
  return Math.max(0, Math.min(1, Number(value) || 0));
}

function round2(value) {
  return Math.round(clamp01(value) * 100) / 100;
}

function normalizeDescription(value) {
  return String(value ?? "").trim().replace(/\s+/g, " ").slice(0, 1200);
}

function normalizeSoulMode(value) {
  return ["auto", "guided", "custom"].includes(value) ? value : SOUL_MODE;
}

function includesAny(text, terms) {
  return terms.some((term) => text.includes(term));
}

function tune(base, text, positive, negative, amount = 0.18) {
  let value = base;
  if (includesAny(text, positive)) value += amount;
  if (includesAny(text, negative)) value -= amount;
  return round2(value);
}

function behaviorFromTraits(traits) {
  const maxSentences = traits.talkativeness >= 0.65 ? 4 : (traits.talkativeness <= 0.3 ? 2 : 3);
  return {
    speakingStyle: {
      concise: true,
      maxSentences,
      formality: traits.formality,
      humor: traits.humor,
      warmth: traits.warmth,
    },
    behavior: {
      initiative: traits.initiative,
      energy: traits.energy,
      movement: traits.movement,
      restSeconds: Math.round((24 - traits.initiative * 8) * 10) / 10,
      walkSeconds: Math.round((9 + traits.movement * 4) * 10) / 10,
      hangSettleSeconds: Math.round((1.2 - traits.energy * 0.35) * 100) / 100,
    },
  };
}

export function buildAutoSoulProfile(project = {}) {
  const descriptions = Object.fromEntries([
    ["en", normalizeDescription(project.descriptionEn)],
    ["th", normalizeDescription(project.descriptionTh)],
  ].filter(([, value]) => value.length > 0));
  const corpus = Object.values(descriptions).join(" ").toLowerCase();

  const traits = {
    warmth: tune(0.65, corpus,
      ["friendly", "warm", "kind", "caring", "gentle", "เป็นมิตร", "อบอุ่น", "ใจดี", "อ่อนโยน"],
      ["cold", "aloof", "distant", "เย็นชา", "ห่างเหิน"]),
    humor: tune(0.45, corpus,
      ["funny", "playful", "witty", "cheerful", "ตลก", "ขี้เล่น", "ร่าเริง", "อารมณ์ขัน"],
      ["serious", "reserved", "เคร่งขรึม", "จริงจัง"]),
    formality: tune(0.45, corpus,
      ["formal", "professional", "polite", "สุภาพ", "เป็นทางการ", "มืออาชีพ"],
      ["casual", "relaxed", "informal", "กันเอง", "สบายๆ", "สบาย ๆ"]),
    initiative: tune(0.5, corpus,
      ["proactive", "curious", "adventurous", "energetic", "กระตือรือร้น", "อยากรู้อยากเห็น", "ชอบผจญภัย"],
      ["shy", "reserved", "quiet", "ขี้อาย", "เก็บตัว", "เงียบ"]),
    energy: tune(0.5, corpus,
      ["energetic", "active", "lively", "playful", "กระฉับกระเฉง", "ร่าเริง", "ขี้เล่น", "มีพลัง"],
      ["calm", "quiet", "relaxed", "สงบ", "สุขุม", "นิ่ง"]),
    talkativeness: tune(0.45, corpus,
      ["talkative", "chatty", "outgoing", "ช่างพูด", "พูดเก่ง", "คุยเก่ง"],
      ["quiet", "concise", "reserved", "เงียบ", "พูดน้อย", "กระชับ"]),
  };
  traits.movement = round2((traits.energy * 0.65) + (traits.initiative * 0.35));
  const derived = behaviorFromTraits(traits);

  return {
    schema: SOUL_SCHEMA,
    mode: SOUL_MODE,
    source: SOUL_SOURCE,
    identity: {
      name: normalizeDescription(project.name) || "OCP Companion",
      descriptions,
    },
    traits,
    ...derived,
  };
}

export function buildSoulProfile(project = {}) {
  const base = buildAutoSoulProfile(project);
  const mode = normalizeSoulMode(project.soulMode);
  if (mode === "auto") return base;

  const rawOverrides = project.soulTraits && typeof project.soulTraits === "object" ? project.soulTraits : {};
  const traits = { ...base.traits };
  for (const key of SOUL_TRAIT_KEYS) {
    const value = Number(rawOverrides[key]);
    if (Number.isFinite(value)) traits[key] = round2(value);
  }
  if (!Number.isFinite(Number(rawOverrides.movement))) {
    traits.movement = round2((traits.energy * 0.65) + (traits.initiative * 0.35));
  }

  return {
    ...base,
    mode,
    source: mode === "guided" ? "studio-guided-v1" : "studio-custom-v1",
    traits,
    ...behaviorFromTraits(traits),
    ...(mode === "custom"
      ? { customText: String(project.soulCustomMarkdown ?? "").trim().slice(0, CUSTOM_SOUL_MAX_CHARS) }
      : {}),
  };
}

export function renderSoulMarkdown(profile) {
  const customText = String(profile?.customText ?? "").trim();
  if (profile?.mode === "custom" && customText) return customText + "\n";

  const identity = profile?.identity ?? {};
  const descriptions = identity.descriptions ?? {};
  const traits = profile?.traits ?? {};
  const speaking = profile?.speakingStyle ?? {};
  const behavior = profile?.behavior ?? {};
  const lines = [
    `# ${identity.name || "OCP Companion"} — SOUL`,
    "",
    `Schema: ${profile?.schema || SOUL_SCHEMA}`,
    `Mode: ${profile?.mode || SOUL_MODE}`,
    `Source: ${profile?.source || SOUL_SOURCE}`,
    "",
    "## Identity",
  ];
  if (descriptions.en) lines.push("", "### English", descriptions.en);
  if (descriptions.th) lines.push("", "### ไทย", descriptions.th);
  lines.push(
    "",
    "## Personality traits",
    `- Warmth: ${Number(traits.warmth ?? 0.5).toFixed(2)}`,
    `- Humor: ${Number(traits.humor ?? 0.5).toFixed(2)}`,
    `- Formality: ${Number(traits.formality ?? 0.5).toFixed(2)}`,
    `- Initiative: ${Number(traits.initiative ?? 0.5).toFixed(2)}`,
    `- Energy: ${Number(traits.energy ?? 0.5).toFixed(2)}`,
    `- Talkativeness: ${Number(traits.talkativeness ?? 0.5).toFixed(2)}`,
    `- Movement: ${Number(traits.movement ?? 0.5).toFixed(2)}`,
    "",
    "## Speaking style",
    `- Concise: ${Boolean(speaking.concise)}`,
    `- Default maximum sentences: ${Number(speaking.maxSentences ?? 3)}`,
    "",
    "## Runtime behavior",
    `- Rest interval: ${Number(behavior.restSeconds ?? 18).toFixed(1)} s`,
    `- Walk duration: ${Number(behavior.walkSeconds ?? 11).toFixed(1)} s`,
    `- Hang settle: ${Number(behavior.hangSettleSeconds ?? 0.9).toFixed(2)} s`,
    "",
    "> Generated by OCP Animation Studio. Runtime parses the structured profile once and does not re-read this Markdown during animation/render loops.",
    "",
  );
  return lines.join("\n");
}
