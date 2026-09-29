import JSZip from "jszip";
import { EFFECT_BOND_RANKS, EFFECT_SLOT_META, EFFECT_SLOT_ORDER } from "./effect-pack-contract.js";

const PACKAGE_ID_PATTERN = /^effect\.[a-z0-9]+(?:[.-][a-z0-9]+)*$/;
const SEMVER_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const COLOR_PATTERN = /^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$/;

const RANK_STYLE_DEFAULTS = Object.freeze({
  stranger: Object.freeze({ tint: "#22D3EE", intensity: 72, speedPermille: 1000 }),
  friend: Object.freeze({ tint: "#38BDF8", intensity: 78, speedPermille: 1020 }),
  "close-friend": Object.freeze({ tint: "#818CF8", intensity: 86, speedPermille: 1040 }),
  partner: Object.freeze({ tint: "#C084FC", intensity: 94, speedPermille: 1080 }),
  "best-companion": Object.freeze({ tint: "#FACC15", intensity: 100, speedPermille: 1120 }),
});

function slotDefaults(slotName) {
  const meta = EFFECT_SLOT_META[slotName];
  const placement = slotName === "groundRune"
    ? { anchor: "character-feet", scaleMode: "character-width", scale: 1.40, offsetX: 0, offsetY: 0, zIndex: -20, maxHeightRatio: 0.32 }
    : slotName === "levelUpBurst"
      ? { anchor: "character-feet-bottom", scaleMode: "character-height", scale: 1.10, offsetX: 0, offsetY: 0, zIndex: 20, maxHeightRatio: 0 }
      : { anchor: "character-center", scaleMode: "character-height", scale: 1.12, offsetX: 0, offsetY: -6, zIndex: -10, maxHeightRatio: 0 };
  return {
    enabled: true,
    fps: 12,
    maxDuration: 4,
    frameSize: 512,
    runtimeExportCap: 384,
    columns: 8,
    keyColor: "#00FF00",
    threshold: 78,
    softness: 54,
    despill: true,
    intensity: 100,
    speedPermille: 1000,
    tint: "#FFFFFF",
    looped: slotName !== "levelUpBurst",
    layer: meta.layer,
    ...placement,
    autoCrop: true,
    cropPadding: 8,
  };
}

export function createDefaultSpriteFxPackProject() {
  return {
    id: "effect.video-neon",
    name: "Video Neon FX Pack",
    version: "1.0.0",
    license: "OCP-Creator-Sample",
    progressionMode: "bond-rank",
    rankStyles: Object.fromEntries(EFFECT_BOND_RANKS.map((rank) => [rank, { ...RANK_STYLE_DEFAULTS[rank] }])),
    slots: Object.fromEntries(EFFECT_SLOT_ORDER.map((slotName) => [slotName, slotDefaults(slotName)])),
  };
}

export function spriteFxPackProjectIssues(project) {
  const issues = new Array();
  if (!PACKAGE_ID_PATTERN.test(String(project?.id ?? "").trim()) || String(project?.id ?? "").length > 128) {
    issues.push("Package ID must use effect.<slug>.");
  }
  if (String(project?.name ?? "").trim().length < 2 || String(project?.name ?? "").trim().length > 120) {
    issues.push("Display name must contain 2–120 characters.");
  }
  if (!SEMVER_PATTERN.test(String(project?.version ?? "").trim())) issues.push("Version must be semantic version format.");
  if (!["none", "bond-rank"].includes(project?.progressionMode)) issues.push("Progression must be none or bond-rank.");

  for (const slotName of EFFECT_SLOT_ORDER) {
    const slot = project?.slots?.[slotName];
    if (!slot || slot.enabled === false) continue;
    if (!Number.isInteger(Number(slot.fps)) || Number(slot.fps) < 1 || Number(slot.fps) > 30) issues.push(`${EFFECT_SLOT_META[slotName].label}: FPS must be 1–30.`);
    if (!Number.isInteger(Number(slot.frameSize)) || Number(slot.frameSize) < 128 || Number(slot.frameSize) > 1024) issues.push(`${EFFECT_SLOT_META[slotName].label}: frame size must be 128–1024.`);
    const runtimeExportCap = Number(slot.runtimeExportCap ?? 384);
    if (!Number.isInteger(runtimeExportCap) || runtimeExportCap < 128 || runtimeExportCap > 512) issues.push(`${EFFECT_SLOT_META[slotName].label}: runtime export cap must be 128–512.`);
    if (!Number.isInteger(Number(slot.columns)) || Number(slot.columns) < 1 || Number(slot.columns) > 16) issues.push(`${EFFECT_SLOT_META[slotName].label}: columns must be 1–16.`);
    if (Number(slot.maxDuration) <= 0 || Number(slot.maxDuration) > 4) issues.push(`${EFFECT_SLOT_META[slotName].label}: source duration must be 0–4 seconds.`);
    if (!COLOR_PATTERN.test(String(slot.tint ?? ""))) issues.push(`${EFFECT_SLOT_META[slotName].label}: tint is invalid.`);
    if (!["character-center", "character-feet", "character-feet-bottom", "character-above-head"].includes(String(slot.anchor))) issues.push(`${EFFECT_SLOT_META[slotName].label}: anchor is invalid.`);
    if (!["character-width", "character-height", "native-surface"].includes(String(slot.scaleMode))) issues.push(`${EFFECT_SLOT_META[slotName].label}: scale mode is invalid.`);
    if (!Number.isFinite(Number(slot.scale)) || Number(slot.scale) < 0.1 || Number(slot.scale) > 4) issues.push(`${EFFECT_SLOT_META[slotName].label}: scale must be 0.1–4.0.`);
    if (!Number.isFinite(Number(slot.offsetX)) || Math.abs(Number(slot.offsetX)) > 512 || !Number.isFinite(Number(slot.offsetY)) || Math.abs(Number(slot.offsetY)) > 512) issues.push(`${EFFECT_SLOT_META[slotName].label}: offsets must be within ±512 px.`);
    if (!Number.isInteger(Number(slot.zIndex)) || Number(slot.zIndex) < -100 || Number(slot.zIndex) > 100) issues.push(`${EFFECT_SLOT_META[slotName].label}: z-index must be -100–100.`);
    if (Number(slot.maxHeightRatio) !== 0 && (!Number.isFinite(Number(slot.maxHeightRatio)) || Number(slot.maxHeightRatio) < 0.1 || Number(slot.maxHeightRatio) > 3)) issues.push(`${EFFECT_SLOT_META[slotName].label}: max height ratio is invalid.`);
    if (!Number.isInteger(Number(slot.cropPadding)) || Number(slot.cropPadding) < 0 || Number(slot.cropPadding) > 64) issues.push(`${EFFECT_SLOT_META[slotName].label}: crop padding must be 0–64 px.`);
  }

  if (project?.progressionMode === "bond-rank") {
    for (const rank of EFFECT_BOND_RANKS) {
      const style = project?.rankStyles?.[rank];
      if (!style || !COLOR_PATTERN.test(String(style.tint ?? ""))) issues.push(`${rank}: rank tint is invalid.`);
    }
  }
  return issues;
}

export function computeSpriteSheetLayout(frameCount, frameSize, columns) {
  const safeFrames = Math.max(1, Math.min(120, Math.round(Number(frameCount) || 1)));
  const safeSize = Math.max(1, Math.round(Number(frameSize) || 512));
  const safeColumns = Math.max(1, Math.min(16, Math.round(Number(columns) || 8)));
  const usedColumns = Math.min(safeColumns, safeFrames);
  const rows = Math.ceil(safeFrames / usedColumns);
  return {
    frameCount: safeFrames,
    frameWidth: safeSize,
    frameHeight: safeSize,
    columns: usedColumns,
    rows,
    sheetWidth: usedColumns * safeSize,
    sheetHeight: rows * safeSize,
  };
}

export function computeDominantAlphaBounds(rgba, width, height, visualBounds = null) {
  const safeWidth = Math.max(1, Math.round(Number(width) || 1));
  const safeHeight = Math.max(1, Math.round(Number(height) || 1));
  if (!rgba || rgba.length < safeWidth * safeHeight * 4) return visualBounds;

  const visual = visualBounds || { x: 0, y: 0, width: safeWidth, height: safeHeight };
  const left = Math.max(0, Math.min(safeWidth - 1, Math.floor(Number(visual.x) || 0)));
  const top = Math.max(0, Math.min(safeHeight - 1, Math.floor(Number(visual.y) || 0)));
  const right = Math.max(left + 1, Math.min(safeWidth, Math.ceil(left + Math.max(1, Number(visual.width) || safeWidth))));
  const bottom = Math.max(top + 1, Math.min(safeHeight, Math.ceil(top + Math.max(1, Number(visual.height) || safeHeight))));

  const rowMass = new Float64Array(safeHeight);
  const colMass = new Float64Array(safeWidth);
  let peakRow = 0;
  let peakCol = 0;
  for (let y = top; y < bottom; y += 1) {
    for (let x = left; x < right; x += 1) {
      const alpha = rgba[(y * safeWidth + x) * 4 + 3];
      if (alpha < 20) continue;
      rowMass[y] += alpha;
      colMass[x] += alpha;
    }
    peakRow = Math.max(peakRow, rowMass[y]);
  }
  for (let x = left; x < right; x += 1) peakCol = Math.max(peakCol, colMass[x]);
  if (peakRow <= 0 || peakCol <= 0) return visualBounds;

  function significantSpan(masses, start, end, peak, ratio) {
    const threshold = peak * ratio;
    let first = -1;
    let last = -1;
    for (let i = start; i < end; i += 1) {
      if (masses[i] < threshold) continue;
      if (first < 0) first = i;
      last = i;
    }
    return first >= 0 ? { start: first, end: last + 1 } : { start, end };
  }

  function enforceCoverage(span, visualStart, visualEnd, minimumRatio) {
    const visualSize = Math.max(1, visualEnd - visualStart);
    const minimum = Math.max(1, Math.ceil(visualSize * minimumRatio));
    if (span.end - span.start >= minimum) return span;
    const center = (span.start + span.end) / 2;
    let start = Math.floor(center - minimum / 2);
    let end = start + minimum;
    if (start < visualStart) { end += visualStart - start; start = visualStart; }
    if (end > visualEnd) { start -= end - visualEnd; end = visualEnd; }
    return { start: Math.max(visualStart, start), end: Math.min(visualEnd, end) };
  }

  const xSpan = enforceCoverage(significantSpan(colMass, left, right, peakCol, 0.10), left, right, 0.58);
  const ySpan = enforceCoverage(significantSpan(rowMass, top, bottom, peakRow, 0.14), top, bottom, 0.58);
  return {
    x: xSpan.start,
    y: ySpan.start,
    width: Math.max(1, xSpan.end - xSpan.start),
    height: Math.max(1, ySpan.end - ySpan.start),
  };
}

export function buildSpriteSlotContract(slotName, slot, artifact) {
  if (!EFFECT_SLOT_ORDER.includes(slotName)) throw new Error("Effect slot is invalid.");
  const meta = EFFECT_SLOT_META[slotName];
  const contract = {
    renderer: "sprite-sheet-2d",
    anchor: slot.anchor || meta.anchor,
    layer: slot.layer || meta.layer,
    looped: slotName !== "levelUpBurst",
    fps: Number(slot.fps),
    durationMs: Math.max(100, Math.round((Number(artifact.frameCount) / Number(slot.fps)) * 1000)),
    intensity: Number(slot.intensity),
    speedPermille: Number(slot.speedPermille),
    tint: String(slot.tint || "#FFFFFF").toUpperCase(),
    asset: artifact.assetPath,
    frameWidth: Number(artifact.frameWidth || slot.frameSize),
    frameHeight: Number(artifact.frameHeight || slot.frameSize),
    frameCount: Number(artifact.frameCount),
    scaleMode: slot.scaleMode,
    scale: Number(slot.scale),
    offsetX: Number(slot.offsetX),
    offsetY: Number(slot.offsetY),
    zIndex: Number(slot.zIndex),
    contentBounds: artifact.contentBounds || { x: 0, y: 0, width: Number(artifact.frameWidth || slot.frameSize), height: Number(artifact.frameHeight || slot.frameSize) },
    ...(Number(slot.maxHeightRatio) > 0 ? { maxHeightRatio: Number(slot.maxHeightRatio) } : {}),
  };
  return contract;
}

export function buildSpriteEffectPackDefinition(project, artifacts) {
  const issues = spriteFxPackProjectIssues(project);
  if (issues.length) throw new Error(issues[0]);

  const slots = {};
  for (const slotName of EFFECT_SLOT_ORDER) {
    const artifact = artifacts?.[slotName];
    if (!artifact?.frameCount || !artifact?.assetPath) continue;
    slots[slotName] = buildSpriteSlotContract(slotName, project.slots[slotName], artifact);
  }
  if (Object.keys(slots).length === 0) throw new Error("Convert at least one Effect slot before building.");

  const variants = project.progressionMode === "bond-rank"
    ? EFFECT_BOND_RANKS.map((rank) => {
      const style = project.rankStyles[rank];
      const slotOverrides = {};
      for (const slotName of Object.keys(slots)) {
        slotOverrides[slotName] = {
          tint: String(style.tint).toUpperCase(),
          intensity: Number(style.intensity),
          speedPermille: Number(style.speedPermille),
        };
      }
      return { id: rank, minLevel: 1, minBondRank: rank, slotOverrides };
    })
    : [];

  return {
    schemaVersion: "1.0",
    id: project.id.trim(),
    name: project.name.trim(),
    version: project.version.trim(),
    slots,
    progression: {
      mode: project.progressionMode,
      variants,
    },
  };
}

async function sha256Hex(value) {
  const bytes = value instanceof Uint8Array ? value : new Uint8Array(await value.arrayBuffer());
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function buildSpriteEffectPackPackageDraft(project, artifacts, signingIdentity) {
  if (!signingIdentity?.publisherId || !signingIdentity?.keyId) throw new Error("Local Creator signing identity is unavailable.");
  const effectArtifacts = {};
  for (const slotName of EFFECT_SLOT_ORDER) {
    const artifact = artifacts?.[slotName];
    if (!artifact?.blob || !artifact?.frameCount) continue;
    effectArtifacts[slotName] = {
      ...artifact,
      assetPath: artifact.assetPath || `assets/${slotName}.png`,
    };
  }

  const effect = buildSpriteEffectPackDefinition(project, effectArtifacts);
  const effectText = JSON.stringify(effect, null, 2);
  const effectBytes = new TextEncoder().encode(effectText);
  const zip = new JSZip();
  zip.file("assets/effect.json", effectText);

  const assets = [{ path: "assets/effect.json", sha256: await sha256Hex(effectBytes) }];
  for (const slotName of EFFECT_SLOT_ORDER) {
    const artifact = effectArtifacts[slotName];
    if (!artifact) continue;
    const bytes = new Uint8Array(await artifact.blob.arrayBuffer());
    zip.file(artifact.assetPath, bytes);
    assets.push({ path: artifact.assetPath, sha256: await sha256Hex(bytes) });
  }

  const manifest = {
    manifestVersion: "0.1",
    id: effect.id,
    type: "effect-pack",
    version: effect.version,
    publisher: { id: signingIdentity.publisherId, keyId: signingIdentity.keyId },
    license: String(project.license || "OCP-Creator").trim() || "OCP-Creator",
    entry: "assets/effect.json",
    assets,
  };
  zip.file("manifest.json", JSON.stringify(manifest, null, 2));
  const bytes = await zip.generateAsync({
    type: "uint8array",
    compression: "DEFLATE",
    compressionOptions: { level: 6 },
  });
  return {
    blob: new Blob([Uint8Array.from(bytes).buffer], { type: "application/octet-stream" }),
    bytes,
    manifest,
    effect,
  };
}
