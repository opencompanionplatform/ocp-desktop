import { StrictMode, useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import JSZip from "jszip";
import { exportStorePreview } from "./features/character/store-preview-export.js";
import { adaptiveConnectedGreenShadowCleanup } from "./features/character/cleanup-v4.js";
import { unmixConnectedScreenColor } from "./features/character/cleanup-v5.js";
import { autoSolidBackgroundMatte, estimateEdgeBackgroundKey, isClassicGreenKey } from "./features/character/cleanup-v6.js";
import { hexToKeyColor, keyColorToHex, normalizeKeyColor, resolveCleanupKeyColor } from "./features/character/cleanup-v7.js";
import StudioTopbar from "./components/StudioTopbar.jsx";
import WorkflowSidebar from "./components/WorkflowSidebar.jsx";
import { readSpriteFxAccess } from "./config/feature-flags.js";
import { installStudioDomLocalization, readStudioLocale } from "./i18n/studio-i18n.js";
import SpriteSheetEffectStudio from "./features/sprite-fx/SpriteSheetEffectStudio.jsx";
import { ANIMATION_NAMES, ANIMATION_PROFILES, BUILTIN_ANIMATION_NAMES, OPTIONAL_ANIMATION_NAMES, MAX_SPRITE_FRAMES, SUPPORTED_PLAYBACK_FPS, animationProfileFor, framesFor, inferAnimationName, labelFor, normalizeSourceName } from "./features/character/catalog.js";
import { buildWebStudioOAuthRedirect, checkCreatorCloudPackageIdentity, creatorCloudReady, creatorIdentity, creatorPortalUrl, createCreatorCloudWorkspace, findCreatorCloudProfile, findPendingCreatorCloudSubmission, getCreatorCloudProfile, linkCreatorCloudDesktopSigner, listCreatorCloudPublishers, preflightCreatorCloudVersion, readWebStudioOAuthCallback, releaseCreatorCloudPackageIdentity, reserveCreatorCloudPackageIdentity, signArchiveForCreatorCloud, submitCreatorCloudForReview, uploadSignedArchiveToCreatorCloud, validateCreatorCloudSubmission } from "./creator-cloud.js";
import {
  CHARACTER_STANDARDIZATION_DEFAULTS,
  characterScaleDeviation,
  computeSourceCropPlacement,
  computeStandardizedSourcePlacement,
  computeSubjectPlacement,
  createCharacterMasterProfile,
  measureCharacterCoreAlphaBounds,
  measurementWindowForAnimation,
  poseGroupForAnimation,
  selectCharacterMeasurementBounds,
  unionSubjectBounds,
  usesCharacterCoreMeasurement,
} from "./features/character/subject-fit.js";
import {
  beginDesktopStudioOAuth,
  chooseDesktopStudioWorkspace,
  getDesktopStudioBridge,
  openDesktopStudioOAuth,
  installDesktopStudioBuildToRuntime,
  readDesktopStudioEnvironment,
  revealDesktopStudioOutput,
  savePackageToDesktop,
  saveProjectToDesktop,
} from "./desktop-bridge.js";
import "./styles.css";

const STEPS = ["Project", "Import videos", "Timing & frames", "Clean & anchor", "Sheet composer", "Preview & QA", "Build .ocp"];
const FRAME_WIDTH = 512;
const FRAME_HEIGHT = 512;
const CLEAN_SCALE_MIN = 0.5;
const CLEAN_SCALE_MAX = 2.5;
const CLEAN_SCALE_STEP = 0.05;
const CLEAN_OFFSET_MIN = -128;
const CLEAN_OFFSET_MAX = 128;
const CLEAN_OFFSET_STEP = 1;
const CLEAN_CHROMA_MIN = 0;
const CLEAN_CHROMA_MAX = 100;
const CLEAN_CHROMA_STEP = 1;
const CLEAN_CHROMA_DEFAULT = 50;
const CLEAN_TUNING_MIN = 0;
const CLEAN_TUNING_MAX = 100;
const CLEAN_TUNING_STEP = 1;
const CLEAN_FOREGROUND_PROTECT_DEFAULT = 70;
const CLEAN_SHADOW_CUT_DEFAULT = 50;
const CLEAN_MATTE_CONTRACT_NORMAL_DEFAULT = 18;
const CLEAN_MATTE_CONTRACT_FX_DEFAULT = 0;
const CLEAN_EDGE_FEATHER_NORMAL_DEFAULT = 6;
const CLEAN_EDGE_FEATHER_FX_DEFAULT = 22;
const CLEAN_DESPILL_DEFAULT = 100;
const CLEAN_KEY_TOLERANCE_DEFAULT = 45;
const CLEAN_INTERIOR_CUT_DEFAULT = 100;
const SOURCE_ANIMATION_COUNT = ANIMATION_NAMES.length; // Standard compatibility set only.
const RUNTIME_ANIMATION_COUNT = SOURCE_ANIMATION_COUNT + 1; // + climb_ready derived from climb_up frame 0
const LOGICAL_ANIMATION_NAME_COUNT = RUNTIME_ANIMATION_COUNT + 1; // + idle_neutral fallback alias
const LOGICAL_ANIMATION_NAMES = [...ANIMATION_NAMES, "climb_ready", "idle_neutral"];
const ANIMATION_THUMBNAIL_SIZE = 112;
const ANIMATION_THUMBNAIL_PADDING = 8;
const PLACEMENT_PAIR_REFERENCES = Object.freeze({ drag_release: "drag_hold" });
const VOICE_PRESENTATIONS = ["neutral", "female", "male"];
const VOICE_AGE_GROUPS = ["child", "adult"];
const THAI_SPEECH_STYLES = ["neutral", "feminine", "masculine"];
const LOOP_SFX_NAMES = new Set([
  "walk_left", "walk_right", "climb_up", "climb_down",
  "climb_up_left", "climb_up_right", "climb_down_left", "climb_down_right",
  "hang", "hang_left", "hang_right", "drag_hold"
]);
const SOURCE_SFX_RECOMMENDED_NAMES = new Set([
  "appear", "disappear", "angry", "happy", "sad", "surprised", "wake", "sit",
  "jump", "fall", "land", "climb_up", "climb_down", "climb_top", "hang",
  "climb_up_left", "climb_up_right", "climb_down_left", "climb_down_right",
  "hang_left", "hang_right", "drag_hold", "drag_release", "walk_left", "walk_right", "wave"
]);
const SILENT_SFX_RECOMMENDED_NAMES = new Set(["idle", "think", "speak", "sleep"]);
const FX_CLEANUP_NAMES = new Set(["appear", "disappear"]);
const CLEANUP_PRESETS = {
  normal: {
    hardGreenMin: 40,
    hardDominance: 7,
    hardRatio: 1.10,
    softGreenMin: 26,
    softDominance: 2,
    softRatio: 1.01,
    softRatioRange: 0.13,
    softDominanceRange: 24,
    alphaFloor: 14,
    edgePullRadius: 2,
    edgePullStrength: 0.92,
    contractStrength: 0.18,
    featherStrength: 0.06,
    removeTinyIslands: true,
    preserveGlow: false
  },
  fx: {
    hardGreenMin: 50,
    hardDominance: 12,
    hardRatio: 1.20,
    softGreenMin: 34,
    softDominance: 5,
    softRatio: 1.035,
    softRatioRange: 0.20,
    softDominanceRange: 34,
    alphaFloor: 8,
    edgePullRadius: 1,
    edgePullStrength: 0.28,
    contractStrength: 0,
    featherStrength: 0.22,
    removeTinyIslands: false,
    preserveGlow: true
  }
};

function defaultClean(name) {
  const fx = FX_CLEANUP_NAMES.has(name);
  return {
    preset: fx ? "fx" : "normal",
    strength: 1,
    chromaSensitivity: CLEAN_CHROMA_DEFAULT,
    foregroundProtect: CLEAN_FOREGROUND_PROTECT_DEFAULT,
    shadowCut: CLEAN_SHADOW_CUT_DEFAULT,
    matteContract: fx ? CLEAN_MATTE_CONTRACT_FX_DEFAULT : CLEAN_MATTE_CONTRACT_NORMAL_DEFAULT,
    edgeFeather: fx ? CLEAN_EDGE_FEATHER_FX_DEFAULT : CLEAN_EDGE_FEATHER_NORMAL_DEFAULT,
    despill: CLEAN_DESPILL_DEFAULT,
    keyTolerance: CLEAN_KEY_TOLERANCE_DEFAULT,
    interiorCut: CLEAN_INTERIOR_CUT_DEFAULT,
    keyColorMode: "auto",
    keyColor: null,
    scale: 1,
    offsetX: 0,
    offsetY: 0
  };
}

function recommendedSfxMode(name, hasSource = true) {
  return hasSource && SOURCE_SFX_RECOMMENDED_NAMES.has(name) ? "source" : "none";
}

function defaultAudio(name) {
  return {
    mode: "none",
    externalFile: null,
    externalUrl: "",
    gainDb: LOOP_SFX_NAMES.has(name) ? -8 : -3,
    loop: LOOP_SFX_NAMES.has(name),
    fadeInSeconds: 0.02,
    fadeOutSeconds: 0.1,
    reviewed: false
  };
}

function defaultActionConfig() {
  return { priority: "presentation", interruptible: true, cooldownMs: 0 };
}

function blankClip(name) {
  const profile = animationProfileFor(name);
  return { name, sourceFile: null, sourceUrl: "", sourceDuration: 0, sourceWidth: 0, sourceHeight: 0, duration: profile.duration, targetFps: profile.fps, targetFrames: framesFor(profile), loop: profile.loop, frames: [], clean: defaultClean(name), audio: defaultAudio(name), action: isCustomAnimation(name) ? defaultActionConfig() : null, sheet: null, status: "missing", warning: "" };
}

function initialClips() {
  return Object.fromEntries(BUILTIN_ANIMATION_NAMES.map((name) => [name, blankClip(name)]));
}

function animationNamesForClips(clips) {
  return Object.keys(clips ?? {});
}

function isOptionalAnimation(name) {
  return OPTIONAL_ANIMATION_NAMES.includes(name);
}

function isCustomAnimation(name) {
  return !BUILTIN_ANIMATION_NAMES.includes(name);
}

function normalizeCustomAnimationName(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
}

function downloadBlob(blob, fileName) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url; anchor.download = fileName; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function sha256(blob) {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", await blob.arrayBuffer()));
  return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
}

function buildProfileFor(project) {
  return { ...DEFAULT_BUILD_PROFILE, ...(project?.buildProfile ?? {}) };
}

function spriteAssetExtension(project) {
  return buildProfileFor(project).spriteFormat === "png" ? ".png" : ".webp";
}

function audioAssetPath(clip, project) {
  if (!clip?.audio || clip.audio.mode === "none") return "";
  const extension = buildProfileFor(project).audioFormat === "wav" ? ".wav" : ".ogg";
  return "assets/audio/" + clip.name + extension;
}

function dataUrlToBlob(dataUrl) {
  return fetch(dataUrl).then((response) => response.blob());
}

async function convertImageBlob(blob, mimeType, quality) {
  if (!blob) throw new Error("Missing image blob for package conversion.");
  if (blob.type === mimeType) return blob;
  const bitmap = await createImageBitmap(blob);
  try {
    const canvas = document.createElement("canvas");
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const context = canvas.getContext("2d");
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(bitmap, 0, 0);
    const converted = await new Promise((resolve) => canvas.toBlob(resolve, mimeType, quality));
    if (!converted) throw new Error("Browser could not encode " + mimeType + ".");
    return converted;
  } finally {
    bitmap.close();
  }
}

async function spriteAssetBlob(clip, project) {
  const profile = buildProfileFor(project);
  if (profile.spriteFormat === "png") return clip.sheet.blob;
  return convertImageBlob(clip.sheet.blob, "image/webp", Math.max(0.5, Math.min(1, Number(profile.webpQuality) || 0.92)));
}

function writeAscii(view, offset, text) {
  for (let index = 0; index < text.length; index += 1) view.setUint8(offset + index, text.charCodeAt(index));
}

function encodePcm16Wav(audioBuffer) {
  const channels = Math.min(2, Math.max(1, audioBuffer.numberOfChannels));
  const frameCount = audioBuffer.length;
  const bytesPerSample = 2;
  const dataSize = frameCount * channels * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);
  writeAscii(view, 0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeAscii(view, 8, "WAVE");
  writeAscii(view, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, audioBuffer.sampleRate, true);
  view.setUint32(28, audioBuffer.sampleRate * channels * bytesPerSample, true);
  view.setUint16(32, channels * bytesPerSample, true);
  view.setUint16(34, 16, true);
  writeAscii(view, 36, "data");
  view.setUint32(40, dataSize, true);
  let offset = 44;
  for (let frame = 0; frame < frameCount; frame += 1) {
    for (let channel = 0; channel < channels; channel += 1) {
      const sample = Math.max(-1, Math.min(1, audioBuffer.getChannelData(channel)[frame] ?? 0));
      view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
      offset += 2;
    }
  }
  return new Blob([buffer], { type: "audio/wav" });
}

let oggEncoderFactoryPromise = null;

async function getOggEncoderFactory() {
  if (!oggEncoderFactoryPromise) {
    oggEncoderFactoryPromise = import("wasm-media-encoders").then((module) => module.createOggEncoder);
  }
  return oggEncoderFactoryPromise;
}

async function encodeOggVorbis(audioBuffer, quality) {
  const createOggEncoder = await getOggEncoderFactory();
  const encoder = await createOggEncoder();
  const channels = Math.min(2, Math.max(1, audioBuffer.numberOfChannels));
  encoder.configure({
    sampleRate: audioBuffer.sampleRate,
    channels,
    vbrQuality: Math.max(-1, Math.min(10, Number(quality) || 4))
  });
  const samples = Array.from({ length: channels }, (_, channel) => audioBuffer.getChannelData(channel));
  const chunks = [];
  const encoded = encoder.encode(samples);
  if (encoded.length) chunks.push(new Uint8Array(encoded));
  const finalBytes = encoder.finalize();
  if (finalBytes.length) chunks.push(new Uint8Array(finalBytes));
  return new Blob(chunks, { type: "audio/ogg" });
}

function trimAudioBuffer(context, audioBuffer, durationSeconds) {
  const channels = Math.min(2, Math.max(1, audioBuffer.numberOfChannels));
  const frameCount = Math.max(1, Math.min(
    audioBuffer.length,
    Math.round(Math.min(Number(durationSeconds) || audioBuffer.duration, audioBuffer.duration) * audioBuffer.sampleRate)
  ));
  const trimmed = context.createBuffer(channels, frameCount, audioBuffer.sampleRate);
  for (let channel = 0; channel < channels; channel += 1) {
    trimmed.copyToChannel(audioBuffer.getChannelData(channel).subarray(0, frameCount), channel);
  }
  return trimmed;
}

async function decodeAndEncodeAudio(blob, clip, project) {
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextClass) throw new Error("This browser does not provide Web Audio decoding.");
  const context = new AudioContextClass();
  try {
    const decoded = await context.decodeAudioData((await blob.arrayBuffer()).slice(0));
    const trimmed = trimAudioBuffer(context, decoded, clip.duration);
    const profile = buildProfileFor(project);
    if (profile.audioFormat === "wav") return encodePcm16Wav(trimmed);
    return encodeOggVorbis(trimmed, profile.vorbisQuality);
  } finally {
    await context.close();
  }
}

async function audioBlobForClip(clip, project) {
  if (!clip?.audio || clip.audio.mode === "none") return null;
  const profile = buildProfileFor(project);
  if (clip.audio.mode === "external") {
    if (!clip.audio.externalFile) throw new Error("External SFX is selected for " + clip.name + " but no WAV/OGG file is attached.");
    const lower = clip.audio.externalFile.name.toLowerCase();
    const alreadyTarget = (profile.audioFormat === "ogg" && lower.endsWith(".ogg"))
      || (profile.audioFormat === "wav" && lower.endsWith(".wav"));
    if (alreadyTarget) return clip.audio.externalFile;
    return decodeAndEncodeAudio(clip.audio.externalFile, clip, project);
  }
  if (!clip.sourceFile) throw new Error("Source audio requires the imported MP4 for " + clip.name + ".");
  try {
    return await decodeAndEncodeAudio(clip.sourceFile, clip, project);
  } catch {
    throw new Error("Unable to extract the audio track from " + clip.sourceFile.name + ". Use an external WAV/OGG file or set No sound.");
  }
}

const PROJECT_STORAGE_KEY = "ocp.animation-studio.project.v1";
const PROJECT_FILE_VERSION = 10;
const CURRENT_CHARACTER_SCHEMA = "character/3";
const CHARACTER_LICENSE_OPTIONS = [
  { value: "All-Rights-Reserved", label: "All Rights Reserved" },
  { value: "CC-BY-4.0", label: "CC BY 4.0" },
  { value: "CC-BY-SA-4.0", label: "CC BY-SA 4.0" },
  { value: "CC0-1.0", label: "CC0 1.0" },
  { value: "MIT", label: "MIT" },
];
const DEFAULT_BUILD_PROFILE = {
  spriteFormat: "webp",
  webpQuality: 0.92,
  audioFormat: "ogg",
  vorbisQuality: 4,
  archiveCompression: "deflate",
  packageBudgetMb: 80
};

function defaultCharacterStandardization() {
  return {
    enabled: CHARACTER_STANDARDIZATION_DEFAULTS.enabled,
    referenceAnimation: CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation,
    master: null,
  };
}

function standardizationWithPlacementPairReference(profile, clips, animationName) {
  const referenceName = PLACEMENT_PAIR_REFERENCES[animationName];
  if (!referenceName) return profile;
  const placement = clips?.[referenceName]?.sourcePlacement;
  if (!placement?.standardized) return profile;
  return {
    ...profile,
    placementPairReferences: {
      ...(profile?.placementPairReferences ?? {}),
      [referenceName]: placement,
    },
  };
}

function rememberPlacementPairReference(profile, animationName, placement) {
  if (!placement?.standardized) return profile;
  const isPairReference = Object.values(PLACEMENT_PAIR_REFERENCES).includes(animationName);
  if (!isPairReference) return profile;
  return {
    ...profile,
    placementPairReferences: {
      ...(profile?.placementPairReferences ?? {}),
      [animationName]: placement,
    },
  };
}

function normalizedPlacementScale(placement, targetHeight = FRAME_HEIGHT) {
  if (!placement?.standardized) return null;
  const scale = Number(placement.scale);
  const sourceHeight = Number(placement.sourceHeight);
  const target = Number(targetHeight);
  if (!Number.isFinite(scale) || scale <= 0 || !Number.isFinite(sourceHeight) || sourceHeight <= 0 || !Number.isFinite(target) || target <= 0) return null;
  return scale * sourceHeight / target;
}

function normalizeCharacterLicense(value) {
  const normalized = String(value ?? "").trim();
  if (CHARACTER_LICENSE_OPTIONS.some((option) => option.value === normalized)) return normalized;
  if (["Private", "Proprietary", "All Rights Reserved"].includes(normalized)) return "All-Rights-Reserved";
  return "All-Rights-Reserved";
}

function defaultProject() {
  return {
    id: "character.new-character",
    version: "1.0.0",
    name: "New Character",
    descriptionEn: "",
    descriptionTh: "",
    author: "",
    publisherLocked: false,
    license: "All-Rights-Reserved",
    voiceProfile: { presentation: "neutral", age: "adult", thaiSpeechStyle: "neutral" },
    buildProfile: { ...DEFAULT_BUILD_PROFILE },
    standardizationProfile: defaultCharacterStandardization()
  };
}

function normalizeProjectSnapshot(snapshot) {
  if (!snapshot?.project || ![1, 2, 3, 4, 5, 6, 7, 8, 9, PROJECT_FILE_VERSION].includes(snapshot.projectFileVersion)) return null;
  if (snapshot.projectFileVersion === PROJECT_FILE_VERSION) return snapshot;

  // v1/v2 projects predate duration-driven frame counts and voice metadata.
  // Preserve identity/authoring values, then migrate every animation to the
  // current Character/2 authoring defaults. Sources still have to be re-imported
  // after a browser restart, so stale sampled frames/sheets are never carried.
  return {
    ...snapshot,
    projectFileVersion: PROJECT_FILE_VERSION,
    project: {
      ...snapshot.project,
      descriptionEn: String(snapshot.project.descriptionEn ?? snapshot.project.description ?? ""),
      descriptionTh: String(snapshot.project.descriptionTh ?? ""),
      publisherLocked: snapshot.project.publisherLocked === true,
      license: normalizeCharacterLicense(snapshot.project.license),
      voiceProfile: snapshot.project.voiceProfile ?? { presentation: "neutral", age: "adult", thaiSpeechStyle: "neutral" },
      buildProfile: { ...DEFAULT_BUILD_PROFILE, ...(snapshot.project.buildProfile ?? {}) },
      standardizationProfile: {
        ...defaultCharacterStandardization(),
        ...(snapshot.project.standardizationProfile ?? {}),
        master: snapshot.project.standardizationProfile?.master ?? null,
      }
    },
    animations: Object.fromEntries([...new Set([...BUILTIN_ANIMATION_NAMES, ...Object.keys(snapshot.animations ?? {})])].map((name) => {
      const saved = snapshot.animations?.[name] ?? {};
      const profile = animationProfileFor(name);
      const duration = Number(saved.sourceDuration) > 0
        ? Math.min(profile.duration, Number(saved.sourceDuration))
        : profile.duration;
      return [name, {
        ...saved,
        duration,
        targetFps: profile.fps,
        targetFrames: framesFor({ duration, fps: profile.fps }),
        loop: profile.loop,
        clean: { ...defaultClean(name), ...(saved.clean ?? {}) },
        audio: saved.audio ?? defaultAudio(name),
        action: isCustomAnimation(name) ? { ...defaultActionConfig(), ...(saved.action ?? {}) } : null
      }];
    }))
  };
}

function projectSnapshot(project, clips) {
  return {
    projectFileVersion: PROJECT_FILE_VERSION,
    savedAt: new Date().toISOString(),
    project,
    animations: Object.fromEntries(Object.entries(clips).map(([name, clip]) => {
      return [name, {
        sourceFileName: clip.sourceFile?.name ?? null,
        sourceDuration: clip.sourceDuration || 0,
        duration: clip.duration,
        targetFps: clip.targetFps,
        targetFrames: clip.targetFrames,
        loop: clip.loop,
        clean: clip.clean,
        audio: {
          mode: clip.audio?.mode ?? "none",
          externalFileName: clip.audio?.externalFile?.name ?? null,
          gainDb: Number(clip.audio?.gainDb ?? -3),
          loop: Boolean(clip.audio?.loop),
          fadeInSeconds: Number(clip.audio?.fadeInSeconds ?? 0.02),
          fadeOutSeconds: Number(clip.audio?.fadeOutSeconds ?? 0.1),
          reviewed: Boolean(clip.audio?.reviewed)
        },
        action: isCustomAnimation(name) ? { ...defaultActionConfig(), ...(clip.action ?? {}) } : null
      }];
    }))
  };
}

function saveProjectLocal(project, clips) {
  const snapshot = projectSnapshot(project, clips);
  localStorage.setItem(PROJECT_STORAGE_KEY, JSON.stringify(snapshot));
  return snapshot;
}

function loadProjectLocal() {
  const raw = localStorage.getItem(PROJECT_STORAGE_KEY);
  if (!raw) return null;
  try {
    return normalizeProjectSnapshot(JSON.parse(raw));
  } catch {
    return null;
  }
}

function applyProjectSnapshot(snapshot, currentClips) {
  const nextClips = { ...currentClips };
  const names = [...new Set([...Object.keys(currentClips), ...Object.keys(snapshot.animations ?? {})])];
  for (const name of names) {
    const saved = snapshot.animations?.[name];
    if (!saved) continue;
    const base = nextClips[name] ?? blankClip(name);
    nextClips[name] = {
      ...base,
      sourceDuration: Number(saved.sourceDuration) || 0,
      duration: Number(saved.duration) || base.duration,
      targetFps: Number(saved.targetFps) || base.targetFps,
      targetFrames: Number(saved.targetFrames) || base.targetFrames,
      loop: Boolean(saved.loop),
      clean: { ...defaultClean(name), ...(saved.clean ?? {}) },
      action: isCustomAnimation(name) ? { ...defaultActionConfig(), ...(saved.action ?? {}) } : null,
      audio: {
        ...defaultAudio(name),
        ...(saved.audio ?? {}),
        // Unreviewed audio uses Studio-owned recommendations. Re-apply current
        // defaults when reopening older projects so recommendation fixes (for
        // example Hang SFX looping) migrate without overwriting an explicit
        // creator review/override.
        ...(!saved.audio?.reviewed && saved.audio?.mode !== "external" ? {
          gainDb: defaultAudio(name).gainDb,
          loop: defaultAudio(name).loop
        } : {}),
        // File objects are intentionally not persisted in localStorage/project JSON.
        // If a previous session selected External SFX, restore it as No sound
        // instead of trapping the user behind QC with a filename that no longer
        // has readable bytes. The user can re-attach WAV/OGG explicitly.
        ...((saved.audio?.mode === "external") ? { mode: "none", externalFile: null, externalUrl: "", reviewed: false } : {})
      },
      status: saved.sourceFileName ? "imported" : "missing",
      frames: [],
      sheet: null
    };
  }
  return nextClips;
}

function downloadText(text, fileName) {
  downloadBlob(new Blob([text], { type: "application/json" }), fileName);
}

function gridFor(frameCount) {
  if (frameCount <= 8) return { columns: 4, rows: 2 };
  if (frameCount <= 32) return { columns: 8, rows: 4 };
  if (frameCount <= 48) return { columns: 8, rows: 6 };
  if (frameCount <= MAX_SPRITE_FRAMES) return { columns: 8, rows: 8 };
  throw new Error("Animation exceeds the 64-frame / 4096x4096 Studio limit.");
}

function sourcePriority(fileName, animationName) {
  const normalized = normalizeSourceName(fileName);
  if (normalized === animationName) return 3;
  if (normalized.startsWith(animationName + "_")) return 2;
  return 1;
}

function inferSfxTargets(fileName, candidates = BUILTIN_ANIMATION_NAMES) {
  const normalized = normalizeSourceName(fileName);
  const sharedWalk = normalized === "walk"
    || normalized === "walking"
    || normalized.startsWith("walk_loop")
    || normalized.startsWith("walking_loop")
    || normalized.startsWith("footstep");
  if (sharedWalk) return ["walk_left", "walk_right"];

  const sharedClimb = normalized === "climb"
    || normalized === "climbing"
    || normalized.startsWith("climb_loop")
    || normalized.startsWith("climbing_loop");
  if (sharedClimb) return ["climb_up", "climb_down"];

  const animation = inferAnimationName(fileName, candidates);
  return animation ? [animation] : [];
}

function loadVideo(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata"; video.muted = true;
    video.onloadedmetadata = () => resolve({ video, url });
    video.onerror = () => reject(new Error("Unable to read video metadata: " + file.name));
    video.src = url;
  });
}

function seekVideo(video, time) {
  return new Promise((resolve, reject) => {
    const onSeeked = () => { cleanup(); resolve(); };
    const onError = () => { cleanup(); reject(new Error("Video seek failed.")); };
    const cleanup = () => { video.removeEventListener("seeked", onSeeked); video.removeEventListener("error", onError); };
    video.addEventListener("seeked", onSeeked, { once: true });
    video.addEventListener("error", onError, { once: true });
    video.currentTime = time;
  });
}

function estimateVideoBackgroundKey(video) {
  const sampleSize = 64;
  const canvas = document.createElement("canvas");
  canvas.width = sampleSize;
  canvas.height = sampleSize;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context.drawImage(video, 0, 0, sampleSize, sampleSize);
  const image = context.getImageData(0, 0, sampleSize, sampleSize);
  return estimateEdgeBackgroundKey(image.data, sampleSize, sampleSize);
}

function resolveVideoBackgroundKey(video, cleanSettings = {}, detectedKey = null) {
  const detected = detectedKey ?? estimateVideoBackgroundKey(video);
  return resolveCleanupKeyColor(cleanSettings, detected);
}

function normalizedColorDistance(red, green, blue, keyColor) {
  if (!keyColor) return 0;
  const sum = Math.max(1, red + green + blue);
  const keySum = Math.max(1, keyColor.red + keyColor.green + keyColor.blue);
  const dr = red / sum - keyColor.red / keySum;
  const dg = green / sum - keyColor.green / keySum;
  const db = blue / sum - keyColor.blue / keySum;
  return Math.sqrt(dr * dr + dg * dg + db * db);
}

function keyColorMatches(red, green, blue, preset, toleranceMultiplier = 1) {
  if (!preset.keyColor) return true;
  const normalizedTolerance = Math.max(0, Math.min(1, preset.keyTolerance / 100));
  const tolerance = (0.04 + normalizedTolerance * 0.26) * toleranceMultiplier;
  return normalizedColorDistance(red, green, blue, preset.keyColor) <= tolerance;
}

function cleanupPresetFor(settings = {}, animationName = "") {
  const presetName = ["normal", "fx"].includes(settings.preset)
    ? settings.preset
    : (FX_CLEANUP_NAMES.has(animationName) ? "fx" : "normal");
  const base = CLEANUP_PRESETS[presetName];
  const strength = Math.max(0.5, Math.min(1.5, Number(settings.strength) || 1));
  const clampTuning = (value, fallback) => {
    const numeric = Number(value);
    return Math.max(CLEAN_TUNING_MIN, Math.min(CLEAN_TUNING_MAX, Number.isFinite(numeric) ? numeric : fallback));
  };
  const chromaSensitivity = clampTuning(settings.chromaSensitivity, CLEAN_CHROMA_DEFAULT);
  const foregroundProtect = clampTuning(settings.foregroundProtect, CLEAN_FOREGROUND_PROTECT_DEFAULT);
  const shadowCut = clampTuning(settings.shadowCut, CLEAN_SHADOW_CUT_DEFAULT);
  const matteContract = clampTuning(
    settings.matteContract,
    presetName === "fx" ? CLEAN_MATTE_CONTRACT_FX_DEFAULT : CLEAN_MATTE_CONTRACT_NORMAL_DEFAULT,
  );
  const edgeFeather = clampTuning(
    settings.edgeFeather,
    presetName === "fx" ? CLEAN_EDGE_FEATHER_FX_DEFAULT : CLEAN_EDGE_FEATHER_NORMAL_DEFAULT,
  );
  const despill = clampTuning(settings.despill, CLEAN_DESPILL_DEFAULT);
  const keyTolerance = clampTuning(settings.keyTolerance, CLEAN_KEY_TOLERANCE_DEFAULT);
  const interiorCut = clampTuning(settings.interiorCut, CLEAN_INTERIOR_CUT_DEFAULT);
  const keyColorMode = settings.keyColorMode === "picked" ? "picked" : "auto";
  const keyColor = normalizeKeyColor(settings.keyColor);

  // Green screen cut controls overall key aggressiveness. Foreground protect is a
  // separate saturation gate so dark/gray character detail can be preserved without
  // forcing the backdrop/shadow key to become weak.
  const normalizedChroma = chromaSensitivity / 100;
  const chromaThresholdFactor = 1.5 - normalizedChroma;
  const minKeySaturation = 0.04 + (foregroundProtect / 100) * 0.42;
  return {
    ...base,
    presetName,
    strength,
    chromaSensitivity,
    foregroundProtect,
    shadowCut,
    matteContract,
    edgeFeather,
    despill,
    keyTolerance,
    interiorCut,
    keyColorMode,
    keyColor,
    minKeySaturation,
    hardGreenMin: Math.max(1, Math.min(255, base.hardGreenMin * chromaThresholdFactor)),
    softGreenMin: Math.max(1, Math.min(255, base.softGreenMin * chromaThresholdFactor)),
    hardDominance: (base.hardDominance / strength) * chromaThresholdFactor,
    softDominance: (base.softDominance / strength) * chromaThresholdFactor,
    hardRatio: 1 + ((base.hardRatio - 1) / strength) * chromaThresholdFactor,
    softRatio: 1 + ((base.softRatio - 1) / strength) * chromaThresholdFactor,
    edgePullStrength: Math.max(0, Math.min(1, base.edgePullStrength * strength)),
    contractStrength: Math.max(0, Math.min(0.45, matteContract / 100)),
    featherStrength: Math.max(0, Math.min(0.4, edgeFeather / 100))
  };
}

function rgbSaturation(red, green, blue) {
  const maxChannel = Math.max(red, green, blue);
  const minChannel = Math.min(red, green, blue);
  if (maxChannel <= 0) return 0;
  return (maxChannel - minChannel) / maxChannel;
}

function chromaAlphaForPixel(red, green, blue, alpha, preset) {
  const saturation = rgbSaturation(red, green, blue);
  if (saturation < preset.minKeySaturation) return alpha;
  if (!keyColorMatches(red, green, blue, preset, 1)) return alpha;

  const maxRedBlue = Math.max(red, blue);
  const dominance = green - maxRedBlue;
  const ratio = green / Math.max(1, maxRedBlue);
  const hardGreen = green >= preset.hardGreenMin && dominance >= preset.hardDominance && ratio >= preset.hardRatio;
  if (hardGreen) return 0;
  if (green < preset.softGreenMin || dominance < preset.softDominance || ratio <= preset.softRatio) return alpha;

  const ratioWeight = Math.min(1, Math.max(0, (ratio - preset.softRatio) / preset.softRatioRange));
  const dominanceWeight = Math.min(1, Math.max(0, (dominance - preset.softDominance) / preset.softDominanceRange));
  const saturationWeight = Math.min(1, Math.max(0, (saturation - preset.minKeySaturation) / Math.max(0.08, 1 - preset.minKeySaturation)));
  const feather = ratioWeight * dominanceWeight * saturationWeight;
  const keepFactor = preset.preserveGlow ? (1 - feather * 0.72) : (1 - feather);
  const nextAlpha = Math.round(alpha * keepFactor);
  return nextAlpha < preset.alphaFloor ? 0 : nextAlpha;
}

function backgroundConnectedAlphaForPixel(red, green, blue, alpha, preset) {
  if (alpha <= 1 || preset.shadowCut <= 0) return alpha;

  const shadowStrength = Math.max(0, Math.min(1, preset.shadowCut / 100));
  const saturation = rgbSaturation(red, green, blue);
  // Foreground protection also applies to the dark-shadow classifier. This is the
  // main guard that keeps black/gray face detail from being mistaken for dark green.
  const shadowSaturationFloor = Math.max(0.03, preset.minKeySaturation * (0.72 - shadowStrength * 0.18));
  if (saturation < shadowSaturationFloor) return alpha;

  const maxRedBlue = Math.max(red, blue);
  const dominance = green - maxRedBlue;
  const sum = Math.max(1, red + green + blue);
  const greenShare = green / sum;
  // Very dark green-screen shadows drift away from the sampled bright key color after
  // video compression (for example RGB around 2/49/31). Treat these as valid screen
  // pixels when green is still clearly the dominant hue. Cyan eyes are protected
  // because blue is not lower than green; gray/black character detail is protected by
  // both the saturation and green-share gates.
  const strongDarkGreenShadow = green >= 10
    && green > red * 1.20
    && green > blue * 1.12
    && greenShare >= 0.48;
  if (!strongDarkGreenShadow && !keyColorMatches(red, green, blue, preset, 1.35)) return alpha;

  // Higher Shadow cut lowers the thresholds, allowing darker green cast shadows to
  // be removed. The connected-background flood fill still prevents isolated green
  // detail inside the character from being keyed.
  const minGreen = 26 - shadowStrength * 18;
  const minDominance = 10 - shadowStrength * 7;
  const minGreenShare = 0.47 - shadowStrength * 0.10;
  if (green < minGreen || dominance < minDominance || greenShare < minGreenShare) return alpha;

  const shareWeight = Math.min(1, Math.max(0, (greenShare - minGreenShare) / 0.16));
  const dominanceWeight = Math.min(1, Math.max(0, (dominance - minDominance) / 24));
  const saturationWeight = Math.min(1, Math.max(0, (saturation - shadowSaturationFloor) / Math.max(0.08, 1 - shadowSaturationFloor)));
  const keyWeight = Math.max(shareWeight, dominanceWeight) * saturationWeight;

  if ((greenShare >= minGreenShare + 0.08 && dominance >= Math.max(2, minDominance * 2))
    || (greenShare >= 0.58 && dominance >= minDominance)) return 0;

  const keyStrength = 0.42 + shadowStrength * 0.52;
  const nextAlpha = Math.round(alpha * (1 - keyWeight * keyStrength));
  return nextAlpha < preset.alphaFloor ? 0 : nextAlpha;
}

function measureVideoSubjectBounds(video, cleanSettings = {}, animationName = "", keyColor = null) {
  const sourceWidth = Math.max(1, Number(video.videoWidth) || FRAME_WIDTH);
  const sourceHeight = Math.max(1, Number(video.videoHeight) || FRAME_HEIGHT);
  const analysisScale = Math.min(1, 512 / Math.max(sourceWidth, sourceHeight));
  const analysisWidth = Math.max(1, Math.round(sourceWidth * analysisScale));
  const analysisHeight = Math.max(1, Math.round(sourceHeight * analysisScale));
  const canvas = document.createElement("canvas");
  canvas.width = analysisWidth;
  canvas.height = analysisHeight;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(video, 0, 0, sourceWidth, sourceHeight, 0, 0, analysisWidth, analysisHeight);

  const image = context.getImageData(0, 0, analysisWidth, analysisHeight);
  const preset = cleanupPresetFor({ ...cleanSettings, keyColor }, animationName);
  cleanCharacterImageData(image, preset);

  const fullAlphaBounds = measureSubjectAlphaBounds(image);
  if (!fullAlphaBounds) return null;
  const characterCoreBounds = usesCharacterCoreMeasurement(animationName)
    ? measureCharacterCoreAlphaBounds(image)
    : null;
  const bounds = characterCoreBounds ?? fullAlphaBounds;

  const scaleX = sourceWidth / analysisWidth;
  const scaleY = sourceHeight / analysisHeight;
  const x = Math.max(0, bounds.x * scaleX);
  const y = Math.max(0, bounds.y * scaleY);
  const right = Math.min(sourceWidth, (bounds.x + bounds.width) * scaleX);
  const bottom = Math.min(sourceHeight, (bounds.y + bounds.height) * scaleY);
  return {
    x,
    y,
    width: Math.max(1, right - x),
    height: Math.max(1, bottom - y),
    sourceWidth,
    sourceHeight,
    measuredAfterCleanup: true,
  };
}

function pullForegroundColor(image, preset) {
  const { data, width, height } = image;
  const source = new Uint8ClampedArray(data);
  const radius = preset.edgePullRadius;
  if (radius <= 0 || preset.edgePullStrength <= 0) return;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index = (y * width + x) * 4;
      const alpha = source[index + 3];
      if (alpha <= 0 || alpha >= 248) continue;

      let bestIndex = -1;
      let bestDistance = Number.POSITIVE_INFINITY;
      for (let oy = -radius; oy <= radius; oy += 1) {
        const ny = y + oy;
        if (ny < 0 || ny >= height) continue;
        for (let ox = -radius; ox <= radius; ox += 1) {
          const nx = x + ox;
          if (nx < 0 || nx >= width || (ox === 0 && oy === 0)) continue;
          const candidate = (ny * width + nx) * 4;
          if (source[candidate + 3] < 245) continue;
          const distance = ox * ox + oy * oy;
          if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = candidate;
          }
        }
      }
      if (bestIndex < 0) continue;

      const edgeWeight = 1 - alpha / 255;
      const blend = Math.max(0, Math.min(1, edgeWeight * preset.edgePullStrength));
      data[index] = Math.round(source[index] * (1 - blend) + source[bestIndex] * blend);
      data[index + 1] = Math.round(source[index + 1] * (1 - blend) + source[bestIndex + 1] * blend);
      data[index + 2] = Math.round(source[index + 2] * (1 - blend) + source[bestIndex + 2] * blend);
    }
  }
}

function contractNormalMatte(image, preset) {
  if (preset.contractStrength <= 0) return;
  const { data } = image;
  for (let index = 0; index < data.length; index += 4) {
    const alpha = data[index + 3];
    if (alpha <= 0 || alpha >= 230) continue;
    const edgeWeight = 1 - alpha / 230;
    const nextAlpha = Math.round(alpha * (1 - edgeWeight * preset.contractStrength));
    data[index + 3] = nextAlpha < preset.alphaFloor ? 0 : nextAlpha;
    if (data[index + 3] === 0) {
      data[index] = 0;
      data[index + 1] = 0;
      data[index + 2] = 0;
    }
  }
}

function featherMatte(image, preset) {
  if (preset.featherStrength <= 0) return;
  const { data, width, height } = image;
  const source = new Uint8ClampedArray(data);
  for (let y = 1; y < height - 1; y += 1) {
    for (let x = 1; x < width - 1; x += 1) {
      const index = (y * width + x) * 4;
      const alpha = source[index + 3];
      if (alpha <= 0 || alpha >= 250) continue;
      let sum = 0;
      for (let oy = -1; oy <= 1; oy += 1) {
        for (let ox = -1; ox <= 1; ox += 1) {
          sum += source[((y + oy) * width + (x + ox)) * 4 + 3];
        }
      }
      const average = sum / 9;
      const nextAlpha = Math.round(alpha * (1 - preset.featherStrength) + average * preset.featherStrength);
      data[index + 3] = nextAlpha < preset.alphaFloor ? 0 : nextAlpha;
    }
  }
}

function removeTinyMatteIslands(image, preset) {
  if (!preset.removeTinyIslands) return;
  const { data, width, height } = image;
  const source = new Uint8ClampedArray(data);
  for (let y = 1; y < height - 1; y += 1) {
    for (let x = 1; x < width - 1; x += 1) {
      const index = (y * width + x) * 4;
      const alpha = source[index + 3];
      if (alpha <= 0 || alpha > 96) continue;
      let neighbours = 0;
      for (let oy = -1; oy <= 1; oy += 1) {
        for (let ox = -1; ox <= 1; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          if (source[((y + oy) * width + (x + ox)) * 4 + 3] > 24) neighbours += 1;
        }
      }
      if (neighbours <= 1) {
        data[index] = 0;
        data[index + 1] = 0;
        data[index + 2] = 0;
        data[index + 3] = 0;
      }
    }
  }
}

function buildForegroundCoreProtectionMask(image, preset) {
  const { data, width, height } = image;
  const pixelCount = width * height;
  const protectedMask = new Uint8Array(pixelCount);
  const protectStrength = Math.max(0, Math.min(1, preset.foregroundProtect / 100));
  if (protectStrength <= 0) return protectedMask;

  // The black visor in some climb clips receives a green cast from the screen.
  // Color-only chroma keying can therefore classify it as background. Protect dark
  // foreground pixels whose green share is far below a real screen-green shadow.
  // At Foreground protect 90%, this keeps black/charcoal visor detail while still
  // allowing dark green backdrop shadows (which have a much higher green share)
  // to remain eligible for the background/shadow key.
  const darkChannelLimit = 34 + protectStrength * 68;
  const greenShareLimit = 0.50 + protectStrength * 0.16;
  const greenDominanceLimit = 5 + protectStrength * 24;

  for (let pixel = 0; pixel < pixelCount; pixel += 1) {
    const index = pixel * 4;
    const alpha = data[index + 3];
    if (alpha <= 1) continue;

    const red = data[index];
    const green = data[index + 1];
    const blue = data[index + 2];
    const maxChannel = Math.max(red, green, blue);
    if (maxChannel > darkChannelLimit) continue;

    const maxRedBlue = Math.max(red, blue);
    const dominance = green - maxRedBlue;
    const greenShare = green / Math.max(1, red + green + blue);
    if (greenShare <= greenShareLimit && dominance <= greenDominanceLimit) {
      protectedMask[pixel] = 1;
    }
  }

  // Fill tiny gaps inside the protected dark core, but only through pixels that are
  // still dark and not strongly screen-green. This is a spatial guard: it prevents a
  // one-pixel chroma bridge from leaking the outside flood fill into the visor.
  const source = new Uint8Array(protectedMask);
  const expandChannelLimit = darkChannelLimit * 1.12;
  const expandGreenShareLimit = Math.min(0.67, greenShareLimit + 0.025);
  for (let y = 1; y < height - 1; y += 1) {
    for (let x = 1; x < width - 1; x += 1) {
      const pixel = y * width + x;
      if (source[pixel]) continue;
      const index = pixel * 4;
      if (data[index + 3] <= 1) continue;

      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      if (Math.max(red, green, blue) > expandChannelLimit) continue;
      const greenShare = green / Math.max(1, red + green + blue);
      if (greenShare > expandGreenShareLimit) continue;

      let protectedNeighbours = 0;
      for (let oy = -1; oy <= 1; oy += 1) {
        for (let ox = -1; ox <= 1; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          if (source[(y + oy) * width + (x + ox)]) protectedNeighbours += 1;
        }
      }
      if (protectedNeighbours >= 2) protectedMask[pixel] = 1;
    }
  }

  return protectedMask;
}

function applyConnectedChromaKey(image, preset, foregroundCoreMask = null) {
  const { data, width, height } = image;
  const pixelCount = width * height;
  const candidateAlpha = new Uint8ClampedArray(pixelCount);
  const primaryAlphaByPixel = new Uint8ClampedArray(pixelCount);
  const passable = new Uint8Array(pixelCount);
  const connected = new Uint8Array(pixelCount);
  const strongInterior = new Uint8Array(pixelCount);
  const keyed = new Uint8Array(pixelCount);
  const queue = new Int32Array(pixelCount);

  for (let pixel = 0; pixel < pixelCount; pixel += 1) {
    const index = pixel * 4;
    const currentAlpha = data[index + 3];
    const red = data[index];
    const green = data[index + 1];
    const blue = data[index + 2];
    if (foregroundCoreMask?.[pixel]) {
      primaryAlphaByPixel[pixel] = currentAlpha;
      candidateAlpha[pixel] = currentAlpha;
      continue;
    }
    const primaryAlpha = chromaAlphaForPixel(red, green, blue, currentAlpha, preset);
    const shadowAlpha = backgroundConnectedAlphaForPixel(red, green, blue, currentAlpha, preset);
    const nextAlpha = Math.min(primaryAlpha, shadowAlpha);
    primaryAlphaByPixel[pixel] = primaryAlpha;
    candidateAlpha[pixel] = nextAlpha;

    // Weak green/shadow cleanup is still allowed only when it can be flood-filled
    // from outside the sprite. Strong pixels that closely match the sampled screen
    // color are tracked separately so enclosed background holes (between legs/arms)
    // can be removed without opening black/cyan character details.
    if (currentAlpha <= 1 || nextAlpha < currentAlpha) passable[pixel] = 1;
    const saturation = rgbSaturation(red, green, blue);
    const maxRedBlue = Math.max(red, blue);
    const greenShare = green / Math.max(1, red + green + blue);
    const sampledGreen = Math.max(1, Number(preset.keyColor?.green) || 255);
    const interiorMinGreen = Math.max(48, sampledGreen * 0.34);
    const strongScreenGreen = primaryAlpha === 0
      && green >= interiorMinGreen
      && (green - maxRedBlue) >= 8
      && greenShare >= 0.50
      && keyColorMatches(red, green, blue, preset, 0.62);
    // Enclosed-green cleanup is intentionally restricted to bright, true screen green.
    // Dark compressed green shadows must stay on the connected-background path only;
    // otherwise a green cast on a black face can be mistaken for an enclosed hole and
    // punched fully transparent when Enclosed green cut is 100%.
    if (currentAlpha > 1
      && saturation >= Math.max(0.38, preset.minKeySaturation)
      && strongScreenGreen) {
      strongInterior[pixel] = 1;
    }
  }

  let head = 0;
  let tail = 0;
  const enqueue = (pixel) => {
    if (pixel < 0 || pixel >= pixelCount || !passable[pixel] || connected[pixel]) return;
    connected[pixel] = 1;
    queue[tail] = pixel;
    tail += 1;
  };

  for (let x = 0; x < width; x += 1) {
    enqueue(x);
    enqueue((height - 1) * width + x);
  }
  for (let y = 0; y < height; y += 1) {
    enqueue(y * width);
    enqueue(y * width + width - 1);
  }

  while (head < tail) {
    const pixel = queue[head];
    head += 1;
    const x = pixel % width;
    const y = Math.floor(pixel / width);
    if (x > 0) enqueue(pixel - 1);
    if (x + 1 < width) enqueue(pixel + 1);
    if (y > 0) enqueue(pixel - width);
    if (y + 1 < height) enqueue(pixel + width);
  }

  const interiorCut = Math.max(0, Math.min(1, preset.interiorCut / 100));
  for (let pixel = 0; pixel < pixelCount; pixel += 1) {
    const connectedBackground = Boolean(connected[pixel]);
    const enclosedBackground = Boolean(strongInterior[pixel]) && interiorCut > 0;
    if (!connectedBackground && !enclosedBackground) continue;

    const index = pixel * 4;
    const currentAlpha = data[index + 3];
    let nextAlpha = candidateAlpha[pixel];
    if (!connectedBackground && enclosedBackground) {
      const interiorAlpha = Math.round(currentAlpha * (1 - interiorCut));
      nextAlpha = Math.min(interiorAlpha, primaryAlphaByPixel[pixel]);
    }
    if (nextAlpha >= currentAlpha) continue;

    data[index + 3] = nextAlpha;
    keyed[pixel] = 1;
    if (nextAlpha === 0) {
      data[index] = 0;
      data[index + 1] = 0;
      data[index + 2] = 0;
    }
  }

  return keyed;
}

function cleanupConnectedGreenFringe(image, preset, keyedMask = null, foregroundCoreMask = null) {
  if (!preset?.keyColor || preset.shadowCut <= 0) return;
  const { data, width, height } = image;
  const shadowStrength = Math.max(0, Math.min(1, preset.shadowCut / 100));
  const passes = 1 + Math.round(shadowStrength * 2);
  const toleranceMultiplier = 1.8 + shadowStrength * 1.4;
  const baseTolerance = (0.04 + Math.max(0, Math.min(1, preset.keyTolerance / 100)) * 0.26) * toleranceMultiplier;

  // A cast shadow can be too dark/desaturated for the normal chroma classifier even
  // though it is still visibly green. Recover only green-ish pixels that touch the
  // transparent matte edge, then walk inward a few pixels. This is intentionally
  // boundary-limited so black/cyan face detail in the middle of the character stays safe.
  for (let pass = 0; pass < passes; pass += 1) {
    const source = new Uint8ClampedArray(data);
    for (let y = 1; y < height - 1; y += 1) {
      for (let x = 1; x < width - 1; x += 1) {
        const pixel = y * width + x;
        const index = pixel * 4;
        const alpha = source[index + 3];
        if (alpha <= 0 || foregroundCoreMask?.[pixel]) continue;

        let transparentNeighbours = 0;
        for (let oy = -1; oy <= 1; oy += 1) {
          for (let ox = -1; ox <= 1; ox += 1) {
            if (ox === 0 && oy === 0) continue;
            if (source[((y + oy) * width + (x + ox)) * 4 + 3] <= 20) transparentNeighbours += 1;
          }
        }
        if (!transparentNeighbours) continue;

        const red = source[index];
        const green = source[index + 1];
        const blue = source[index + 2];
        const maxRedBlue = Math.max(red, blue);
        const dominance = green - maxRedBlue;
        if (dominance < 2 + (1 - shadowStrength) * 4) continue;

        const saturation = rgbSaturation(red, green, blue);
        const saturationFloor = Math.max(0.08, preset.minKeySaturation * (0.40 - shadowStrength * 0.08));
        if (saturation < saturationFloor) continue;
        if (!keyColorMatches(red, green, blue, preset, toleranceMultiplier)) continue;

        const distance = normalizedColorDistance(red, green, blue, preset.keyColor);
        const colorWeight = Math.max(0, Math.min(1, 1 - distance / Math.max(0.001, baseTolerance)));
        const edgeWeight = Math.min(1, transparentNeighbours / 3);
        const removal = Math.max(0, Math.min(1, colorWeight * edgeWeight * (0.45 + shadowStrength * 0.5)));
        let nextAlpha = Math.round(alpha * (1 - removal));

        if (transparentNeighbours >= 2 && colorWeight >= 0.52 && dominance >= 5) nextAlpha = 0;
        if (nextAlpha >= alpha) continue;

        data[index + 3] = nextAlpha;
        if (keyedMask) keyedMask[pixel] = 1;
        if (nextAlpha === 0) {
          data[index] = 0;
          data[index + 1] = 0;
          data[index + 2] = 0;
        }
      }
    }
  }
}

function removeTinyDarkKeyResidues(image, preset, keyedMask = null) {
  if (!preset || preset.presetName !== "normal") return;
  const { data, width, height } = image;
  const pixelCount = width * height;
  const candidate = new Uint8Array(pixelCount);
  const visited = new Uint8Array(pixelCount);
  const queue = new Int32Array(pixelCount);
  const shadowStrength = Math.max(0, Math.min(1, preset.shadowCut / 100));
  const maxComponentPixels = 20 + Math.round(shadowStrength * 36);

  // After the main chroma pass, video compression can leave a few fully-opaque,
  // almost-black green specks along a newly transparent edge. They are too dark for
  // normal chroma thresholds and too opaque for removeTinyMatteIslands(). Mark only
  // dark green-ish pixels that directly touch transparency; actual black visor pixels
  // are normally neutral/cyan and, more importantly, form a large continuous region.
  for (let y = 1; y < height - 1; y += 1) {
    for (let x = 1; x < width - 1; x += 1) {
      const pixel = y * width + x;
      const index = pixel * 4;
      const alpha = data[index + 3];
      if (alpha <= 20) continue;

      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      const maxChannel = Math.max(red, green, blue);
      if (maxChannel > 108) continue;

      const maxRedBlue = Math.max(red, blue);
      const dominance = green - maxRedBlue;
      const greenShare = green / Math.max(1, red + green + blue);
      const saturation = rgbSaturation(red, green, blue);
      if (dominance < 2 || greenShare < 0.40 || saturation < 0.10) continue;

      let transparentNeighbours = 0;
      for (let oy = -1; oy <= 1; oy += 1) {
        for (let ox = -1; ox <= 1; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          if (data[((y + oy) * width + (x + ox)) * 4 + 3] <= 20) transparentNeighbours += 1;
        }
      }
      if (transparentNeighbours > 0) candidate[pixel] = 1;
    }
  }

  for (let start = 0; start < pixelCount; start += 1) {
    if (!candidate[start] || visited[start]) continue;

    let head = 0;
    let tail = 0;
    queue[tail++] = start;
    visited[start] = 1;
    const component = [];

    while (head < tail) {
      const pixel = queue[head++];
      component.push(pixel);
      const x = pixel % width;
      const y = Math.floor(pixel / width);
      for (let oy = -1; oy <= 1; oy += 1) {
        for (let ox = -1; ox <= 1; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          const nx = x + ox;
          const ny = y + oy;
          if (nx <= 0 || nx >= width - 1 || ny <= 0 || ny >= height - 1) continue;
          const next = ny * width + nx;
          if (!candidate[next] || visited[next]) continue;
          visited[next] = 1;
          queue[tail++] = next;
        }
      }
    }

    if (component.length > maxComponentPixels) continue;
    for (const pixel of component) {
      const index = pixel * 4;
      data[index] = 0;
      data[index + 1] = 0;
      data[index + 2] = 0;
      data[index + 3] = 0;
      if (keyedMask) keyedMask[pixel] = 1;
    }
  }
}

function despillRetainedForegroundEdges(image, preset) {
  if (!preset || preset.despill <= 0) return;
  const { data, width, height } = image;
  const source = new Uint8ClampedArray(data);
  const strength = Math.max(0, Math.min(1, preset.despill / 100));
  const radius = 1 + Math.round(strength * 2);
  const minDominance = 1 + (1 - strength) * 5;

  // The normal keyed-mask de-spill only sees pixels that were already classified as
  // background. Green-screen compression often leaves a thin green cast on pixels we
  // intentionally kept as foreground, especially around white fur and a black visor.
  // Treat those retained boundary pixels as a color-correction problem only: RGB may
  // be neutralized, but alpha is never reduced here.
  for (let y = radius; y < height - radius; y += 1) {
    for (let x = radius; x < width - radius; x += 1) {
      const pixel = y * width + x;
      const index = pixel * 4;
      const alpha = source[index + 3];
      if (alpha <= 20) continue;

      let nearestTransparentDistance = Number.POSITIVE_INFINITY;
      for (let oy = -radius; oy <= radius; oy += 1) {
        for (let ox = -radius; ox <= radius; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          const neighbour = ((y + oy) * width + (x + ox)) * 4;
          if (source[neighbour + 3] > 20) continue;
          const distance = ox * ox + oy * oy;
          if (distance < nearestTransparentDistance) nearestTransparentDistance = distance;
        }
      }
      if (!Number.isFinite(nearestTransparentDistance)) continue;

      const red = source[index];
      const green = source[index + 1];
      const blue = source[index + 2];
      const maxRedBlue = Math.max(red, blue);
      const dominance = green - maxRedBlue;
      if (dominance <= minDominance) continue;

      // Cyan character detail is safe because blue is at least as strong as green,
      // while true green spill has green clearly above both red and blue.
      if (green <= blue + minDominance || green <= red + minDominance) continue;

      const edgeDistance = Math.sqrt(nearestTransparentDistance);
      const edgeWeight = Math.max(0, Math.min(1, (radius + 0.5 - edgeDistance) / radius));
      if (edgeWeight <= 0) continue;

      const correction = Math.max(0, Math.min(1, strength * (0.55 + edgeWeight * 0.45)));
      const neutralGreen = Math.min(green, Math.round(maxRedBlue * (preset.preserveGlow ? 1.06 : 1.005)));
      const removedGreen = Math.max(0, green - neutralGreen) * correction;

      data[index + 1] = Math.round(green - removedGreen);
      if (!preset.preserveGlow && removedGreen > 0) {
        // Redistribute a small part of the removed green energy into red/blue. This
        // avoids turning a white edge into a dark gray seam after aggressive de-spill.
        const restore = removedGreen * 0.18;
        data[index] = Math.min(255, Math.round(red + restore));
        data[index + 2] = Math.min(255, Math.round(blue + restore));
      }
    }
  }
}

function cleanCharacterImageData(image, preset) {
  // Cleanup V7 treats the selected/detected video color as the source of truth.
  // A sampled green key keeps the mature V3-V5 connected chroma/de-spill path.
  // Gray, white, blue, or other colors use the generic color-to-alpha matte,
  // including FX/Glow clips such as Appear/Disappear so their translucent light is preserved.
  // The routing is based on the sampled RGB itself; no fixed fallback key is injected.
  if (!preset.keyColor) return image;
  const useSampledKeyMatte = preset.keyColor && !isClassicGreenKey(preset.keyColor);
  if (useSampledKeyMatte) {
    autoSolidBackgroundMatte(image, preset);
    contractNormalMatte(image, preset);
    featherMatte(image, preset);
    removeTinyMatteIslands(image, preset);
    for (let index = 0; index < image.data.length; index += 4) {
      if (image.data[index + 3] === 0) {
        image.data[index] = 0;
        image.data[index + 1] = 0;
        image.data[index + 2] = 0;
      }
    }
    return image;
  }

  const foregroundCoreMask = buildForegroundCoreProtectionMask(image, preset);
  const keyedMask = applyConnectedChromaKey(image, preset, foregroundCoreMask);
  cleanupConnectedGreenFringe(image, preset, keyedMask, foregroundCoreMask);
  adaptiveConnectedGreenShadowCleanup(image, preset, { foregroundCoreMask });
  unmixConnectedScreenColor(image, preset);
  removeTinyDarkKeyResidues(image, preset, keyedMask);

  for (let pixel = 0; pixel < keyedMask.length; pixel += 1) {
    if (!keyedMask[pixel]) continue;
    const index = pixel * 4;
    if (image.data[index + 3] === 0) continue;
    const red = image.data[index];
    const green = image.data[index + 1];
    const blue = image.data[index + 2];
    const maxRedBlue = Math.max(red, blue);
    if (green > maxRedBlue && preset.despill > 0) {
      const baseSpillLimit = preset.preserveGlow ? 1.08 : 1.015;
      const targetGreen = Math.min(green, Math.round(maxRedBlue * baseSpillLimit));
      const despillAmount = Math.max(0, Math.min(1, preset.despill / 100));
      image.data[index + 1] = Math.round(green * (1 - despillAmount) + targetGreen * despillAmount);
    }
  }

  despillRetainedForegroundEdges(image, preset);
  pullForegroundColor(image, preset);
  contractNormalMatte(image, preset);
  featherMatte(image, preset);
  removeTinyMatteIslands(image, preset);
  // Color pulling can re-introduce a compressed green cast from nearby opaque pixels.
  // Run one final alpha-preserving de-spill after all matte/color reconstruction.
  despillRetainedForegroundEdges(image, preset);

  for (let index = 0; index < image.data.length; index += 4) {
    if (image.data[index + 3] === 0) {
      image.data[index] = 0;
      image.data[index + 1] = 0;
      image.data[index + 2] = 0;
    }
  }
  return image;
}

function renderVideoFrame(video, cleanSettings = {}, animationName = "", sourcePlacement = null, keyColor = null) {
  const canvas = document.createElement("canvas");
  canvas.width = FRAME_WIDTH; canvas.height = FRAME_HEIGHT;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  const sourceWidth = Math.max(1, Number(video.videoWidth) || FRAME_WIDTH);
  const sourceHeight = Math.max(1, Number(video.videoHeight) || FRAME_HEIGHT);
  context.clearRect(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";

  if (sourcePlacement) {
    context.drawImage(
      video,
      sourcePlacement.cropX,
      sourcePlacement.cropY,
      sourcePlacement.cropWidth,
      sourcePlacement.cropHeight,
      sourcePlacement.drawX,
      sourcePlacement.drawY,
      sourcePlacement.drawWidth,
      sourcePlacement.drawHeight,
    );
  } else {
    const fitScale = Math.min(FRAME_WIDTH / sourceWidth, FRAME_HEIGHT / sourceHeight);
    const drawWidth = Math.max(1, Math.round(sourceWidth * fitScale));
    const drawHeight = Math.max(1, Math.round(sourceHeight * fitScale));
    const drawX = Math.round((FRAME_WIDTH - drawWidth) / 2);
    const drawY = Math.round((FRAME_HEIGHT - drawHeight) / 2);
    context.drawImage(video, 0, 0, sourceWidth, sourceHeight, drawX, drawY, drawWidth, drawHeight);
  }

  const image = context.getImageData(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  const preset = cleanupPresetFor({ ...cleanSettings, keyColor }, animationName);

  // Cleanup V7 Sampled Key uses the same sampled-key, connected-background, bounded
  // dark-green shadow recovery and de-spill pipeline for both measurement and final rendering.
  cleanCharacterImageData(image, preset);
  context.putImageData(image, 0, 0);
  return canvas.toDataURL("image/png");
}

const SUBJECT_ALPHA_THRESHOLD = 20;

function measureSubjectAlphaBounds(imageData, alphaThreshold = SUBJECT_ALPHA_THRESHOLD) {
  const pixels = imageData?.data;
  const width = Number(imageData?.width) || 0;
  const height = Number(imageData?.height) || 0;
  if (!pixels || width <= 0 || height <= 0) return null;

  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (pixels[(y * width + x) * 4 + 3] <= alphaThreshold) continue;
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
    }
  }
  if (maxX < minX || maxY < minY) return null;
  return { x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1 };
}

async function normalizeSampledCharacterFrames(frames, onProgress = () => {}) {
  if (!Array.isArray(frames) || frames.length === 0) return { frames: [], subjectFit: null };
  const scratch = document.createElement("canvas");
  scratch.width = FRAME_WIDTH;
  scratch.height = FRAME_HEIGHT;
  const scratchContext = scratch.getContext("2d", { willReadFrequently: true });
  const bounds = [];

  for (let index = 0; index < frames.length; index += 1) {
    const image = await loadImage(frames[index]);
    scratchContext.clearRect(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
    scratchContext.drawImage(image, 0, 0, FRAME_WIDTH, FRAME_HEIGHT);
    bounds.push(measureSubjectAlphaBounds(scratchContext.getImageData(0, 0, FRAME_WIDTH, FRAME_HEIGHT)));
  }

  const placement = computeSubjectPlacement(unionSubjectBounds(bounds), FRAME_WIDTH, FRAME_HEIGHT);
  if (!placement || !placement.applied) {
    onProgress(91, "Character scale already fills the frame");
    return { frames, subjectFit: placement };
  }

  const normalized = [];
  const output = document.createElement("canvas");
  output.width = FRAME_WIDTH;
  output.height = FRAME_HEIGHT;
  const outputContext = output.getContext("2d");
  outputContext.imageSmoothingEnabled = true;
  outputContext.imageSmoothingQuality = "high";

  for (let index = 0; index < frames.length; index += 1) {
    const image = await loadImage(frames[index]);
    outputContext.clearRect(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
    outputContext.drawImage(
      image,
      placement.cropX,
      placement.cropY,
      placement.cropWidth,
      placement.cropHeight,
      placement.drawX,
      placement.drawY,
      placement.drawWidth,
      placement.drawHeight,
    );
    normalized.push(output.toDataURL("image/png"));
  }
  onProgress(91, `Auto-fit character ${placement.scale.toFixed(2)}×`);
  return { frames: normalized, subjectFit: placement };
}

function measurementTimesFor(duration, targetFrames, maxSamples = 12, animationName = "") {
  const count = Math.max(1, Math.min(Math.max(1, Number(targetFrames) || 1), maxSamples));
  const lastTime = Math.max(0, Number(duration) - 0.001);
  const window = measurementWindowForAnimation(animationName);
  const startTime = lastTime * Math.max(0, Math.min(1, Number(window.startRatio) || 0));
  const endTime = lastTime * Math.max(0, Math.min(1, Number(window.endRatio) || 1));
  const span = Math.max(0, endTime - startTime);
  return Array.from(
    { length: count },
    (_, index) => count === 1 ? startTime : startTime + (index / (count - 1)) * span,
  );
}

async function measureSourceCharacter(
  video,
  clip,
  keyColor,
  duration,
  onProgress = () => {},
  startPercent = 12,
  endPercent = 38,
  masterProfile = null,
) {
  const targetFrames = Math.max(1, Math.round(Number(clip.targetFrames) || framesFor(clip)));
  const times = measurementTimesFor(duration, targetFrames, 12, clip.name);
  const bounds = [];
  const characterCoreMode = usesCharacterCoreMeasurement(clip.name);
  for (let index = 0; index < times.length; index += 1) {
    await seekVideo(video, times[index]);
    bounds.push(measureVideoSubjectBounds(video, clip.clean ?? defaultClean(clip.name), clip.name, keyColor));
    const progress = startPercent + Math.round(((index + 1) / times.length) * (endPercent - startPercent));
    onProgress(progress, `${characterCoreMode ? "FX core-measure" : "Clean-measure"} ${index + 1}/${times.length}`);
  }
  return selectCharacterMeasurementBounds(bounds, clip.name, {
    sourceHeight: Math.max(1, Number(video.videoHeight) || FRAME_HEIGHT),
    referenceHeightRatio: Number(masterProfile?.referenceHeightRatio) || 0,
  });
}

async function calibrateCharacterMaster(clip, onProgress = () => {}) {
  if (!clip?.sourceFile) throw new Error("Reference animation source is not imported.");
  const loaded = await loadVideo(clip.sourceFile);
  try {
    const video = loaded.video;
    await new Promise((resolve) => video.readyState >= 2 ? resolve() : video.addEventListener("loadeddata", resolve, { once: true }));
    const duration = Math.max(0.01, Math.min(Number(clip.duration) || video.duration, video.duration));
    await seekVideo(video, 0);
    const keyColor = resolveVideoBackgroundKey(video, clip.clean ?? defaultClean(clip.name), clip.sourceKeyColor);
    const bounds = await measureSourceCharacter(video, clip, keyColor, duration, onProgress, 8, 88);
    if (!bounds) throw new Error("Unable to detect the cleaned reference character silhouette.");
    const sourceWidth = Math.max(1, Number(video.videoWidth) || FRAME_WIDTH);
    const sourceHeight = Math.max(1, Number(video.videoHeight) || FRAME_HEIGHT);
    const master = createCharacterMasterProfile(
      bounds,
      sourceWidth,
      sourceHeight,
      FRAME_WIDTH,
      FRAME_HEIGHT,
      { referenceAnimation: clip.name },
    );
    if (!master) throw new Error("Unable to create the character master scale.");
    onProgress(100, `Master scale calibrated from ${labelFor(clip.name)}`);
    return { master, sourceKeyColor: keyColor, sourceBounds: bounds };
  } finally {
    URL.revokeObjectURL(loaded.url);
  }
}

async function sampleVideo(clip, onProgress = () => {}, standardizationProfile = null) {
  onProgress(2, "Loading video");
  const loaded = await loadVideo(clip.sourceFile);
  try {
    const video = loaded.video;
    onProgress(6, `Reading ${video.videoWidth}×${video.videoHeight} source`);
    await new Promise((resolve) => video.readyState >= 2 ? resolve() : video.addEventListener("loadeddata", resolve, { once: true }));
    onProgress(10, "Video ready");
    const duration = Math.max(0.01, Math.min(clip.duration, video.duration));
    const lastTime = Math.max(0, duration - 0.001);
    const targetFrames = Math.max(1, Math.round(Number(clip.targetFrames) || framesFor(clip)));
    if (targetFrames > MAX_SPRITE_FRAMES) throw new Error("Target requires " + targetFrames + " frames; reduce duration/FPS to 64 frames or less.");

    const sampleTimes = Array.from({ length: targetFrames }, (_, index) => targetFrames === 1 ? 0 : index / (targetFrames - 1) * lastTime);
    await seekVideo(video, sampleTimes[0] ?? 0);
    const keyColor = resolveVideoBackgroundKey(video, clip.clean ?? defaultClean(clip.name), clip.sourceKeyColor);
    onProgress(12, "Cleanup V7 Sampled Key · measuring cleaned silhouette");
    const subjectBounds = await measureSourceCharacter(
      video,
      clip,
      keyColor,
      duration,
      onProgress,
      12,
      34,
      standardizationProfile?.master ?? null,
    );

    const sourceWidth = Math.max(1, Number(video.videoWidth) || FRAME_WIDTH);
    const sourceHeight = Math.max(1, Number(video.videoHeight) || FRAME_HEIGHT);
    const standardizationEnabled = standardizationProfile?.enabled !== false;
    const referenceAnimation = standardizationProfile?.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;
    let characterMaster = standardizationProfile?.master ?? null;
    if (standardizationEnabled && !characterMaster && clip.name === referenceAnimation && subjectBounds) {
      characterMaster = createCharacterMasterProfile(
        subjectBounds,
        sourceWidth,
        sourceHeight,
        FRAME_WIDTH,
        FRAME_HEIGHT,
        { referenceAnimation },
      );
    }

    const placementReferenceName = PLACEMENT_PAIR_REFERENCES[clip.name];
    const placementReference = placementReferenceName
      ? standardizationProfile?.placementPairReferences?.[placementReferenceName]
      : null;
    const lockedNormalizedSourceScale = normalizedPlacementScale(placementReference, FRAME_HEIGHT);
    const sourcePlacement = standardizationEnabled && characterMaster
      ? computeStandardizedSourcePlacement(
        subjectBounds,
        sourceWidth,
        sourceHeight,
        FRAME_WIDTH,
        FRAME_HEIGHT,
        characterMaster,
        clip.name,
        lockedNormalizedSourceScale ? { lockedNormalizedSourceScale } : {},
      )
      : computeSourceCropPlacement(
        subjectBounds,
        sourceWidth,
        sourceHeight,
        FRAME_WIDTH,
        FRAME_HEIGHT,
      );

    const sampledFrames = [];
    for (let index = 0; index < sampleTimes.length; index += 1) {
      await seekVideo(video, sampleTimes[index]);
      sampledFrames.push(renderVideoFrame(video, clip.clean ?? defaultClean(clip.name), clip.name, sourcePlacement, keyColor));
      onProgress(36 + Math.round(((index + 1) / targetFrames) * 52), `Sampling frame ${index + 1}/${targetFrames}`);
    }

    if (sourcePlacement) {
      const mode = sourcePlacement.standardized ? "Master-scale" : "Source-fit";
      onProgress(89, `${mode} ${sourcePlacement.scale.toFixed(3)}× · clean-before-measure`);
    } else {
      onProgress(89, "Source bounds unavailable · using safe contain fallback");
    }

    if (standardizationEnabled && characterMaster && sourcePlacement) {
      const deviation = characterScaleDeviation(sourcePlacement, characterMaster, sourceHeight, FRAME_HEIGHT);
      return {
        frames: sampledFrames,
        subjectFit: {
          ...sourcePlacement,
          scaleDeviation: deviation,
          poseGroup: poseGroupForAnimation(clip.name),
        },
        sourcePlacement,
        sourceKeyColor: keyColor,
        sourceBounds: subjectBounds,
        characterMaster,
        standardizationMetrics: {
          poseGroup: poseGroupForAnimation(clip.name),
          scaleDeviation: deviation,
          correction: Number(sourcePlacement.correction ?? 1),
          pairScaleLocked: Boolean(sourcePlacement.pairScaleLocked),
          placementReference: sourcePlacement.pairScaleLocked ? placementReferenceName : null,
          safetyLimited: Boolean(sourcePlacement.safetyLimited),
        },
      };
    }

    const normalized = await normalizeSampledCharacterFrames(sampledFrames, onProgress);
    return { ...normalized, sourcePlacement, sourceKeyColor: keyColor, sourceBounds: subjectBounds, characterMaster: null };
  } finally {
    URL.revokeObjectURL(loaded.url);
  }
}

async function sampleCleanupPreviewFrame(clip, frameIndex = 0) {
  if (!clip?.sourceFile) return "";
  const loaded = await loadVideo(clip.sourceFile);
  try {
    const video = loaded.video;
    await new Promise((resolve) => video.readyState >= 2 ? resolve() : video.addEventListener("loadeddata", resolve, { once: true }));

    const clean = { ...defaultClean(clip.name), ...(clip.clean ?? {}) };
    const targetFrames = Math.max(1, Math.round(Number(clip.frameCount || clip.frames?.length || clip.targetFrames) || framesFor(clip)));
    const safeFrameIndex = Math.max(0, Math.min(targetFrames - 1, Math.round(Number(frameIndex) || 0)));
    const duration = Math.max(0.01, Math.min(Number(clip.duration) || video.duration, video.duration));
    const lastTime = Math.max(0, duration - 0.001);
    const time = targetFrames === 1 ? 0 : (safeFrameIndex / (targetFrames - 1)) * lastTime;
    await seekVideo(video, time);

    const keyColor = resolveVideoBackgroundKey(video, clean, clip.sourceKeyColor);
    const sourceWidth = Math.max(1, Number(video.videoWidth) || FRAME_WIDTH);
    const sourceHeight = Math.max(1, Number(video.videoHeight) || FRAME_HEIGHT);
    const fallbackPlacement = computeSourceCropPlacement(
      measureVideoSubjectBounds(video, clean, clip.name, keyColor),
      sourceWidth,
      sourceHeight,
      FRAME_WIDTH,
      FRAME_HEIGHT,
    );
    const sourcePlacement = clip.sourcePlacement ?? fallbackPlacement;
    return renderVideoFrame(video, clean, clip.name, sourcePlacement, keyColor);
  } finally {
    URL.revokeObjectURL(loaded.url);
  }
}

async function sampleAndCompose(clip, onProgress = () => {}, standardizationProfile = null) {
  const sampled = await sampleVideo(clip, onProgress, standardizationProfile);
  onProgress(92, "Composing sprite sheet");
  const blob = await composeSheet(sampled.frames);
  if (!blob) throw new Error("Unable to compose sampled frames.");
  onProgress(100, "Ready");
  const grid = gridFor(sampled.frames.length);
  return {
    ...sampled,
    targetFrames: sampled.frames.length,
    targetFps: Number(clip.targetFps),
    loop: ANIMATION_PROFILES[clip.name]?.loop ?? clip.loop,
    sheet: { blob, sheetUrl: URL.createObjectURL(blob), columns: grid.columns, rows: grid.rows }
  };
}

function composeSheet(frames) {
  const grid = gridFor(frames.length);
  const canvas = document.createElement("canvas");
  canvas.width = grid.columns * FRAME_WIDTH; canvas.height = grid.rows * FRAME_HEIGHT;
  const context = canvas.getContext("2d");
  context.clearRect(0, 0, canvas.width, canvas.height);
  return Promise.all(frames.map((frame, index) => new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => { context.drawImage(image, index % grid.columns * FRAME_WIDTH, Math.floor(index / grid.columns) * FRAME_HEIGHT, FRAME_WIDTH, FRAME_HEIGHT); resolve(); };
    image.onerror = () => reject(new Error("Unable to compose frame " + index + "."));
    image.src = frame;
  }))).then(() => new Promise((resolve) => canvas.toBlob(resolve, "image/png")));
}

function loadImage(dataUrl) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("Unable to read sampled frame."));
    image.src = dataUrl;
  });
}

async function transformFrame(dataUrl, settings) {
  const image = await loadImage(dataUrl);
  const scale = Math.max(CLEAN_SCALE_MIN, Math.min(CLEAN_SCALE_MAX, Number(settings.scale) || 1));
  const offsetX = Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(settings.offsetX) || 0));
  const offsetY = Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(settings.offsetY) || 0));
  const canvas = document.createElement("canvas"); canvas.width = FRAME_WIDTH; canvas.height = FRAME_HEIGHT;
  const context = canvas.getContext("2d");
  const width = FRAME_WIDTH * scale; const height = FRAME_HEIGHT * scale;
  const x = (FRAME_WIDTH - width) / 2 + offsetX; const y = FRAME_HEIGHT - height + offsetY;
  context.clearRect(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  context.drawImage(image, x, y, width, height);
  return canvas.toDataURL("image/png");
}

async function findAlphaBottom(dataUrl) {
  const image = await loadImage(dataUrl);
  const canvas = document.createElement("canvas"); canvas.width = FRAME_WIDTH; canvas.height = FRAME_HEIGHT;
  const context = canvas.getContext("2d", { willReadFrequently: true }); context.drawImage(image, 0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  const pixels = context.getImageData(0, 0, FRAME_WIDTH, FRAME_HEIGHT).data;
  let bottom = -1;
  for (let y = 0; y < FRAME_HEIGHT; y += 1) for (let x = 0; x < FRAME_WIDTH; x += 1) if (pixels[(y * FRAME_WIDTH + x) * 4 + 3] > 12) bottom = Math.max(bottom, y);
  return bottom;
}

async function qaFrameDataUrl(dataUrl, mode) {
  if (!dataUrl || !["alpha", "spill"].includes(mode)) return dataUrl;
  const image = await loadImage(dataUrl);
  const canvas = document.createElement("canvas");
  canvas.width = FRAME_WIDTH; canvas.height = FRAME_HEIGHT;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  context.clearRect(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  context.drawImage(image, 0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  const frame = context.getImageData(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
  const pixels = frame.data;

  for (let index = 0; index < pixels.length; index += 4) {
    const red = pixels[index];
    const green = pixels[index + 1];
    const blue = pixels[index + 2];
    const alpha = pixels[index + 3];
    if (mode === "alpha") {
      pixels[index] = alpha;
      pixels[index + 1] = alpha;
      pixels[index + 2] = alpha;
      pixels[index + 3] = 255;
      continue;
    }

    const spill = alpha > 0 && green - Math.max(red, blue) > 4;
    if (spill) {
      pixels[index] = 255;
      pixels[index + 1] = 0;
      pixels[index + 2] = 220;
      pixels[index + 3] = 255;
    } else {
      const luminance = Math.round((red + green + blue) / 3 * 0.32);
      pixels[index] = luminance;
      pixels[index + 1] = luminance;
      pixels[index + 2] = luminance;
      pixels[index + 3] = Math.max(90, alpha);
    }
  }
  context.putImageData(frame, 0, 0);
  return canvas.toDataURL("image/png");
}

function buildCharacterJson(clips, project, audioAvailableNames = null, thumbnailAvailableNames = null) {
  const usable = Object.values(clips).filter((clip) => clip.sheet);
  const animations = Object.fromEntries(usable.map((clip) => [clip.name, {
    sprite: clip.name,
    frames: Array.from({ length: clip.frames.length }, (_, index) => index),
    loop: clip.loop,
    fps: Number(clip.targetFps)
  }]));

  if (clips.climb_up.sheet) {
    animations.climb_ready = { sprite: "climb_up", frames: [0], loop: false, fps: 1 };
  }
  if (clips.climb_up_left?.sheet) {
    animations.climb_ready_left = { sprite: "climb_up_left", frames: [0], loop: false, fps: 1 };
  }
  if (clips.climb_up_right?.sheet) {
    animations.climb_ready_right = { sprite: "climb_up_right", frames: [0], loop: false, fps: 1 };
  }

  const audioEnabled = usable.filter((clip) => {
    if (!clip.audio || clip.audio.mode === "none") return false;
    if (clip.audio.mode === "external" && !clip.audio.externalFile) return false;
    return audioAvailableNames == null || audioAvailableNames.has(clip.name);
  });
  const audioClips = audioEnabled.map((clip) => ({
    id: "sfx_" + clip.name,
    path: audioAssetPath(clip, project),
    loop: Boolean(clip.audio.loop),
    gainDb: Number(clip.audio.gainDb ?? -3),
    startSeconds: 0,
    endSeconds: Number(clip.duration),
    fadeInSeconds: Number(clip.audio.fadeInSeconds ?? 0.02),
    fadeOutSeconds: Number(clip.audio.fadeOutSeconds ?? 0.1)
  }));
  const audioBindings = Object.fromEntries(audioEnabled.map((clip) => [clip.name, {
    clip: "sfx_" + clip.name,
    start: "animation-start",
    ...(clip.audio.loop ? { stop: "animation-stop" } : {})
  }]));

  const animationFallbacks = {
    idle_neutral: "idle",
    hang_left: animations.hang_left ? "hang_left" : "hang",
    hang_right: animations.hang_right ? "hang_right" : "hang",
    drag_hold: animations.drag_hold ? "drag_hold" : "idle"
  };
  // `drag_release` deliberately has no fallback. When the optional one-shot
  // clip is absent Runtime should transition directly from Drag Hold into the
  // physics-selected Fall/Land (or grounded) animation instead of inserting
  // an artificial idle frame.
  // Directional climb slots also deliberately have no materialized fallback:
  // Runtime falls back to generic climb_up/climb_down so it can still apply
  // the package's mirror policy to legacy artwork.
  for (const [name, target] of Object.entries({ ...animationFallbacks })) {
    if (name === target) delete animationFallbacks[name];
  }
  const animationRoles = {
    "hang.neutral": "hang",
    "hang.left": "hang_left",
    "hang.right": "hang_right",
    "drag.hold": "drag_hold",
    ...(animations.drag_release ? { "drag.release": "drag_release" } : {}),
    ...(animations.climb_up_left ? { "climb.up.left": "climb_up_left" } : {}),
    ...(animations.climb_up_right ? { "climb.up.right": "climb_up_right" } : {}),
    ...(animations.climb_ready_left ? { "climb.ready.left": "climb_ready_left" } : {}),
    ...(animations.climb_ready_right ? { "climb.ready.right": "climb_ready_right" } : {}),
    ...(animations.climb_down_left ? { "climb.down.left": "climb_down_left" } : {}),
    ...(animations.climb_down_right ? { "climb.down.right": "climb_down_right" } : {})
  };
  const actions = Object.fromEntries(
    usable
      .filter((clip) => isCustomAnimation(clip.name))
      .map((clip) => {
        const config = { ...defaultActionConfig(), ...(clip.action ?? {}) };
        return [clip.name, {
          animation: clip.name,
          priority: config.priority,
          interruptible: Boolean(config.interruptible),
          cooldownMs: Math.max(0, Math.round(Number(config.cooldownMs) || 0))
        }];
      })
  );

  const visualBase = { contentBounds: [0, 0, 1, 1], hitTestBounds: [0, 0, 1, 1], scale: 1, offset: [0, 0] };
  return {
    schema: CURRENT_CHARACTER_SCHEMA,
    id: project.id,
    version: project.version,
    name: project.name,
    renderer: "sprite-sheet-2d",
    runtimeCompatibility: { minimumRuntimeVersion: "0.1.0" },
    capabilities: { basicWalk: true, jump: true, surfaceSit: true, surfaceClimb: true, topHang: true, flight: false },
    bodyProfile: { logicalSize: [128, 128], collisionHalfExtents: [42, 62], feetAnchor: [0.5, 1] },
    presentationProfile: { baseScale: 0.7, minimumUserScale: 0.5, maximumUserScale: 2 },
    presentation: {
      descriptions: Object.fromEntries([
        ["en", String(project.descriptionEn ?? "").trim()],
        ["th", String(project.descriptionTh ?? "").trim()],
      ].filter(([, value]) => value.length > 0)),
      preview: { path: "assets/preview.png" },
      animationThumbnails: Object.fromEntries(
        (thumbnailAvailableNames == null ? thumbnailNamesForClips(clips) : [...thumbnailAvailableNames])
          .filter((name) => thumbnailAvailableNames == null ? Boolean(thumbnailFrameForName(clips, name)) : thumbnailAvailableNames.has(name))
          .map((name) => [name, { path: animationThumbnailAssetPath(name) }])
      )
    },
    voiceProfile: {
      presentation: project.voiceProfile?.presentation ?? "neutral",
      age: project.voiceProfile?.age ?? "adult",
      thaiSpeechStyle: project.voiceProfile?.thaiSpeechStyle ?? "neutral"
    },
    sprites: usable.map((clip) => ({ id: clip.name, path: "assets/" + clip.name + spriteAssetExtension(project), frameSize: [FRAME_WIDTH, FRAME_HEIGHT] })),
    animations,
    animationFallbacks,
    animationRoles,
    actions,
    visualProfiles: {
      default: { ...visualBase, mirrorPolicy: "facing", mirrorSafe: true },
      sit: { ...visualBase, surfaceAnchor: [0.5, 0.625], mirrorPolicy: "facing", mirrorSafe: true },
      climb_up: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "surface-normal", mirrorSafe: true },
      climb_down: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "surface-normal", mirrorSafe: true },
      climb_up_left: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "none", mirrorSafe: false },
      climb_up_right: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "none", mirrorSafe: false },
      climb_ready_left: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "none", mirrorSafe: false },
      climb_ready_right: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "none", mirrorSafe: false },
      climb_down_left: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "none", mirrorSafe: false },
      climb_down_right: { ...visualBase, surfaceAnchor: [0.5, 0.82], mirrorPolicy: "none", mirrorSafe: false },
      walk_left: { ...visualBase, mirrorPolicy: "none", mirrorSafe: false },
      walk_right: { ...visualBase, mirrorPolicy: "none", mirrorSafe: false },
      hang: { ...visualBase, surfaceAnchor: [0.5, 0.18], mirrorPolicy: "facing", mirrorSafe: true },
      hang_left: { ...visualBase, surfaceAnchor: [0.5, 0.18], mirrorPolicy: "none", mirrorSafe: false },
      hang_right: { ...visualBase, surfaceAnchor: [0.5, 0.18], mirrorPolicy: "none", mirrorSafe: false },
      drag_hold: { ...visualBase, mirrorPolicy: "facing", mirrorSafe: true },
      drag_release: { ...visualBase, mirrorPolicy: "facing", mirrorSafe: true },
      climb_top: { ...visualBase, surfaceAnchor: [0.5, 0.76], mirrorPolicy: "surface-normal", mirrorSafe: true }
    },
    audioProfile: { clips: audioClips, bindings: audioBindings },
    effectsProfile: {
      effects: [],
      bindings: {},
      teleport: {
        mode: "runtime-default",
        effectId: "portal.blue",
        anchor: "below-feet",
        scale: 1,
        offset: [0, 0]
      }
    },
    authorship: [
      { component: "sprites", author: project.author, license: project.license },
      ...(audioClips.length ? [{ component: "audio", author: project.author, license: project.license }] : [])
    ]
  };
}

function App() {
  const [studioMode, setStudioMode] = useState("character");
  const [locale, setLocale] = useState(() => readStudioLocale());
  const savedSnapshot = loadProjectLocal();
  const [step, setStepState] = useState(0);
  const [project, setProject] = useState(() => savedSnapshot?.project ?? defaultProject());
  const [clips, setClips] = useState(() => savedSnapshot ? applyProjectSnapshot(savedSnapshot, initialClips()) : initialClips());
  const [activeName, setActiveName] = useState("idle");
  const [busy, setBusy] = useState(false);
  const [animationLoad, setAnimationLoad] = useState({ name: "", percent: 0, phase: "Idle", active: false });
  const [toast, setToast] = useState("");
  const [message, setMessage] = useState(() => savedSnapshot
    ? "Loaded the last local Character Project. Source videos must be re-imported after a browser restart. Timing profiles use duration-driven Character/3 framing."
    : "Create a Character Project or import the " + SOURCE_ANIMATION_COUNT + " source videos. Progress: 0/" + SOURCE_ANIMATION_COUNT + " sources, 0/" + SOURCE_ANIMATION_COUNT + " sheets.");
  const [creatorCloudSession, setCreatorCloudSession] = useState(null);
  const [creatorCloudPublishers, setCreatorCloudPublishers] = useState([]);
  const [creatorCloudProfile, setCreatorCloudProfile] = useState(null);
  const [creatorCloudState, setCreatorCloudState] = useState(() => creatorCloudReady
    ? { status: "signed-out", message: "Creator Cloud ready — sign in to upload" }
    : { status: "not-configured", message: "Creator Cloud is not configured" });
  const [creatorCloudOAuthAvailability, setCreatorCloudOAuthAvailability] = useState({ google: false, microsoft: false });
  const [marketplaceIdentity, setMarketplaceIdentity] = useState(null);
  const [marketplaceIdentityBusy, setMarketplaceIdentityBusy] = useState("");
  const [creatorVersionConflict, setCreatorVersionConflict] = useState(null);
  const desktopBridge = useMemo(() => getDesktopStudioBridge(), []);
  const [desktopEnvironment, setDesktopEnvironment] = useState(null);
  const [desktopActionBusy, setDesktopActionBusy] = useState("");
  const spriteFx = useMemo(() => readSpriteFxAccess(import.meta.env, creatorCloudProfile), [creatorCloudProfile]);
  const active = clips[activeName];
  const animationNames = useMemo(() => animationNamesForClips(clips), [clips]);
  const readyCount = useMemo(() => Object.values(clips).filter((clip) => clip.sheet).length, [clips]);
  const sourceCount = useMemo(() => Object.values(clips).filter((clip) => clip.sourceFile).length, [clips]);
  const sampledCount = useMemo(() => Object.values(clips).filter((clip) => clip.frames.length).length, [clips]);
  const standardReadyCount = useMemo(() => ANIMATION_NAMES.filter((name) => clips[name]?.sheet).length, [clips]);
  const standardSourceCount = useMemo(() => ANIMATION_NAMES.filter((name) => clips[name]?.sourceFile).length, [clips]);
  const sfxCount = useMemo(() => Object.values(clips).filter((clip) => {
    if (!clip.audio || clip.audio.mode === "none") return false;
    return clip.audio.mode !== "external" || Boolean(clip.audio.externalFile);
  }).length, [clips]);
  const buildMetrics = useMemo(() => ({
    workingSpriteBytes: Object.values(clips).reduce((sum, clip) => sum + (clip.sheet?.blob?.size ?? 0), 0),
    rawRgbaBytes: Object.values(clips).reduce((sum, clip) => sum + clip.frames.length * FRAME_WIDTH * FRAME_HEIGHT * 4, 0),
    totalFrames: Object.values(clips).reduce((sum, clip) => sum + clip.frames.length, 0)
  }), [clips]);
  const audioWarnings = useMemo(() => Object.values(clips)
    .filter((clip) => clip.audio?.mode === "external" && !clip.audio.externalFile)
    .map((clip) => labelFor(clip.name) + " SFX is set to External but no WAV/OGG file is attached."), [clips]);
  const qcIssues = useMemo(() => {
    const issues = [];
    if (standardSourceCount !== SOURCE_ANIMATION_COUNT) issues.push("Standard source videos are incomplete (" + standardSourceCount + "/" + SOURCE_ANIMATION_COUNT + ").");
    const standardization = { ...defaultCharacterStandardization(), ...(project.standardizationProfile ?? {}) };
    if (standardization.enabled !== false && sampledCount > 0 && !standardization.master) {
      issues.push("Character master scale is not calibrated. Re-sample Idle or run Apply Cleanup V7 Sampled Key to all.");
    }
    for (const name of ANIMATION_NAMES) {
      const clip = clips[name];
      if (!clip.sourceFile) issues.push(labelFor(name) + " source is missing.");
      else if (!clip.frames.length) issues.push(labelFor(name) + " has not been sampled.");
      else if (standardization.enabled !== false && !clip.sourcePlacement?.standardized) issues.push(labelFor(name) + " has not been processed with the character master scale.");
      else if (clip.frames.length !== clip.targetFrames) issues.push(labelFor(name) + " frame count does not match duration x FPS.");
      if (!SUPPORTED_PLAYBACK_FPS.includes(Number(clip.targetFps))) issues.push(labelFor(name) + " FPS must be 8, 12, or 16.");
      if (clip.targetFrames > MAX_SPRITE_FRAMES) issues.push(labelFor(name) + " exceeds the 64-frame Studio limit.");
      if (!clip.sheet) issues.push(labelFor(name) + " sheet has not been composed.");
      else {
        const expectedGrid = gridFor(clip.targetFrames);
        if (clip.sheet.columns !== expectedGrid.columns || clip.sheet.rows !== expectedGrid.rows) issues.push(labelFor(name) + " sheet grid does not match its frame count.");
      }
    }
    for (const name of animationNamesForClips(clips)) {
      if (ANIMATION_NAMES.includes(name)) continue;
      const clip = clips[name];
      const started = Boolean(clip.sourceFile || clip.frames.length || clip.sheet);
      if (!started) continue;
      if (!clip.sourceFile) issues.push(labelFor(name) + " optional/custom source is missing.");
      else if (!clip.frames.length) issues.push(labelFor(name) + " optional/custom animation has not been sampled.");
      else if (!clip.sheet) issues.push(labelFor(name) + " optional/custom sheet has not been composed.");
      if (!SUPPORTED_PLAYBACK_FPS.includes(Number(clip.targetFps))) issues.push(labelFor(name) + " FPS must be 8, 12, or 16.");
      if (clip.targetFrames > MAX_SPRITE_FRAMES) issues.push(labelFor(name) + " exceeds the 64-frame Studio limit.");
    }
    for (const [leftName, rightName] of [["climb_up_left", "climb_up_right"], ["climb_down_left", "climb_down_right"]]) {
      const left = clips[leftName];
      const right = clips[rightName];
      const leftStarted = Boolean(left?.sourceFile || left?.frames?.length || left?.sheet);
      const rightStarted = Boolean(right?.sourceFile || right?.frames?.length || right?.sheet);
      if (leftStarted !== rightStarted) {
        issues.push(labelFor(leftName.replace(/_left$/, "")) + " directional artwork must provide both Left and Right slots so Runtime never has to mirror text or asymmetric details.");
      }
    }
    return issues;
  }, [clips, standardSourceCount, sampledCount, project.standardizationProfile]);
  const jsonPreview = useMemo(() => JSON.stringify(buildCharacterJson(clips, project), null, 2), [clips, project]);

  useEffect(() => installStudioDomLocalization(document.getElementById("root"), locale), [locale]);

  useEffect(() => {
    if (studioMode === "sprite-fx" && !spriteFx.visible) setStudioMode("character");
  }, [studioMode, spriteFx.visible]);

  useEffect(() => {
    try {
      saveProjectLocal(project, clips);
    } catch {
      // Local persistence is best-effort; explicit project export remains available.
    }
  }, [project, clips]);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(""), 2800);
    return () => window.clearTimeout(timer);
  }, [toast]);

  useEffect(() => {
    setMarketplaceIdentity(null);
  }, [project.id, project.name]);

  useEffect(() => {
    setCreatorVersionConflict(null);
  }, [project.id, project.version]);

  useEffect(() => {
    const publisherId = String(creatorCloudProfile?.publisherId ?? "").trim();
    if (!publisherId) return;
    setProject((current) => current.publisherLocked || current.author === publisherId ? current : { ...current, author: publisherId });
  }, [creatorCloudProfile?.publisherId, project.author, project.publisherLocked]);

  useEffect(() => {
    if (!desktopBridge) return undefined;
    let active = true;
    readDesktopStudioEnvironment(desktopBridge)
      .then((environment) => { if (active) setDesktopEnvironment(environment); })
      .catch(() => { if (active) setDesktopEnvironment(null); });
    return () => { active = false; };
  }, [desktopBridge]);

  useEffect(() => {
    if (!creatorIdentity) return undefined;
    let active = true;
    const wait = (ms) => new Promise((resolve) => window.setTimeout(resolve, ms));
    const readWithRetry = async (label, operation) => {
      let lastError = null;
      const delays = [250, 700, 1500];
      for (let attempt = 0; attempt <= delays.length; attempt += 1) {
        try {
          return await operation();
        } catch (error) {
          lastError = error;
          const retryable = error && typeof error === "object" && (Number(error.status) >= 500 || error.code === "service_unavailable");
          if (!retryable || attempt === delays.length) throw error;
          if (active) {
            setCreatorCloudState((current) => ({
              ...current,
              status: "reconnecting",
              message: `${label} temporarily unavailable · retrying ${attempt + 1}/${delays.length}`,
            }));
          }
          await wait(delays[attempt]);
          if (!active) throw lastError;
        }
      }
      throw lastError;
    };

    const sync = async (session) => {
      if (!active) return;
      setCreatorCloudSession(session);
      if (!session?.accessToken) {
        setCreatorCloudPublishers([]);
        setCreatorCloudProfile(null);
        setMarketplaceIdentity(null);
        setCreatorCloudState({ status: "signed-out", message: "Creator Cloud ready — sign in to upload" });
        return;
      }

      if (window.name === "ocp-creator-oauth" && window.opener && !window.opener.closed) {
        window.opener.postMessage({ type: "ocp:creator-oauth-complete" }, window.location.origin);
        window.setTimeout(() => window.close(), 80);
        return;
      }

      let publishers = [];
      try {
        publishers = await readWithRetry("Creator publishers", () => readCreatorPublishers(session.accessToken));
      } catch (error) {
        if (!active) return;
        setCreatorCloudState((current) => ({
          ...current,
          status: "error",
          failedStage: "profile",
          message: error instanceof Error ? error.message : "Creator Cloud publishers unavailable",
        }));
        return;
      }
      if (!active) return;
      const profile = preferredCreatorPublisher(publishers);
      setCreatorCloudPublishers(publishers);
      setCreatorCloudProfile(profile);
      if (!profile) {
        setCreatorCloudState({ status: "needs-profile", message: "OCP Account connected · choose your creator.<name> Publisher ID" });
        return;
      }
      rememberActiveCreatorPublisher(profile);

      let pending = null;
      try {
        pending = await readWithRetry("Creator submissions", () => findPendingCreatorCloudSubmission(session.accessToken, profile.publisherId));
      } catch (error) {
        if (!active) return;
        setCreatorCloudState({
          status: "online",
          message: `Creator Cloud · ${profile.publisherId} · submission status temporarily unavailable`,
        });
        return;
      }
      if (!active) return;

      if (!pending) {
        setCreatorCloudState({ status: "online", message: `Creator Cloud · ${profile.publisherId}` });
        return;
      }

      if (pending.status === "review-ready") {
        setCreatorCloudState({
          status: "review-ready",
          stage: "review-ready",
          percent: 100,
          submissionId: pending.submissionId,
          packageId: pending.packageId,
          version: pending.version,
          message: `Waiting for C8 moderator review · ${pending.packageId} v${pending.version}`,
        });
        return;
      }

      if (pending.status === "validated") {
        const submissionId = pending.submissionId;
        const updateProgress = (progress) => {
          if (!active) return;
          setCreatorCloudState({
            status: progress.stage,
            stage: progress.stage,
            percent: progress.percent,
            message: progress.message,
            submissionId,
            packageId: pending.packageId,
            version: pending.version,
          });
        };
        try {
          const reviewSubmission = await submitCreatorCloudForReview(session.accessToken, submissionId, updateProgress);
          if (!active) return;
          setCreatorCloudState({
            status: "review-ready",
            stage: "review-ready",
            percent: 100,
            submissionId,
            packageId: reviewSubmission.packageId ?? pending.packageId,
            version: reviewSubmission.version ?? pending.version,
            message: `Waiting for C8 moderator review · ${(reviewSubmission.packageId ?? pending.packageId)} v${(reviewSubmission.version ?? pending.version)}`,
          });
        } catch (error) {
          if (!active) return;
          setCreatorCloudState({
            status: "error",
            stage: "submitting-review",
            failedStage: "submitting-review",
            percent: 97,
            submissionId,
            packageId: pending.packageId,
            version: pending.version,
            code: error && typeof error === "object" && typeof error.code === "string" ? error.code : "",
            correlationId: error && typeof error === "object" && typeof error.correlationId === "string" ? error.correlationId : "",
            message: error instanceof Error ? error.message : "Creator review submission failed",
          });
        }
        return;
      }

      setCreatorCloudState({
        status: "uploaded",
        stage: "validating",
        percent: 86,
        submissionId: pending.submissionId,
        packageId: pending.packageId,
        version: pending.version,
        message: `Upload complete · ${pending.packageId} v${pending.version} is waiting for Cloud validation`,
      });
    };

    const refreshFromOAuthPopup = (event) => {
      if (event.origin !== window.location.origin || event.data?.type !== "ocp:creator-oauth-complete") return;
      creatorIdentity.getSession().then(sync).catch((error) => {
        if (active) setCreatorCloudState({ status: "error", message: error instanceof Error ? error.message : "Creator Cloud OAuth session unavailable" });
      });
    };
    window.addEventListener("message", refreshFromOAuthPopup);
    creatorIdentity.getOAuthAvailability().then((availability) => {
      if (active) setCreatorCloudOAuthAvailability(availability);
    }).catch(() => {
      if (active) setCreatorCloudOAuthAvailability({ google: false, microsoft: false });
    });

    const initializeCreatorIdentity = async () => {
      const callback = window.name === "ocp-creator-oauth" ? readWebStudioOAuthCallback(window.location) : null;
      if (callback) {
        if (callback.error) throw new Error(callback.error);
        if (!callback.code) throw new Error("Creator Cloud OAuth callback did not include an authorization code");
        const exchanged = await creatorIdentity.exchangeOAuthCode(callback.code);
        window.history.replaceState({}, "", callback.cleanUrl);
        if (window.opener && !window.opener.closed) {
          window.opener.postMessage({ type: "ocp:creator-oauth-complete" }, window.location.origin);
          window.setTimeout(() => window.close(), 80);
        }
        return exchanged;
      }
      return creatorIdentity.getSession();
    };

    initializeCreatorIdentity().then(sync).catch((error) => {
      if (active) setCreatorCloudState({ status: "error", message: error instanceof Error ? error.message : "Creator Cloud session unavailable" });
    });
    const unsubscribe = creatorIdentity.onAuthStateChange((session) => { sync(session); });
    return () => {
      active = false;
      window.removeEventListener("message", refreshFromOAuthPopup);
      unsubscribe?.();
    };
  }, []);

  function setAnimationProgress(name, percent, phase, notifyAtComplete = false) {
    const safePercent = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)));
    setAnimationLoad({ name, percent: safePercent, phase, active: safePercent < 100 });
    if (notifyAtComplete && safePercent === 100) setToast(labelFor(name) + " animation ready · 100%");
  }

  function updateProject(field, value) { setProject((current) => ({ ...current, [field]: value })); }
  function updateVoiceProfile(field, value) {
    setProject((current) => ({
      ...current,
      voiceProfile: { ...(current.voiceProfile ?? { presentation: "neutral", age: "adult", thaiSpeechStyle: "neutral" }), [field]: value }
    }));
  }

  function updateBuildProfile(field, value) {
    setProject((current) => ({
      ...current,
      buildProfile: {
        ...DEFAULT_BUILD_PROFILE,
        ...(current.buildProfile ?? {}),
        [field]: ["webpQuality", "vorbisQuality", "packageBudgetMb"].includes(field) ? Number(value) : value
      }
    }));
  }

  function addCustomAnimation(rawName) {
    const name = normalizeCustomAnimationName(rawName);
    if (!name) {
      setMessage("Custom animation name must contain letters, numbers, or underscores.");
      return false;
    }
    if (clips[name]) {
      setActiveName(name);
      setMessage(labelFor(name) + " already exists in this Character Project.");
      return false;
    }
    setClips((current) => ({ ...current, [name]: blankClip(name) }));
    setActiveName(name);
    setMessage("Added custom animation " + name + ". Import a video, sample, clean, and compose it like any Standard animation.");
    return true;
  }

  function removeCustomAnimation(name) {
    if (!isCustomAnimation(name) || !clips[name]) return;
    const clip = clips[name];
    if ((clip.sourceFile || clip.frames.length || clip.sheet) && !window.confirm("Remove custom animation " + labelFor(name) + " and its in-memory source/sheet?")) return;
    if (clip.sourceUrl) URL.revokeObjectURL(clip.sourceUrl);
    if (clip.sheet?.sheetUrl) URL.revokeObjectURL(clip.sheet.sheetUrl);
    if (clip.audio?.externalUrl) URL.revokeObjectURL(clip.audio.externalUrl);
    setClips((current) => {
      const next = { ...current };
      delete next[name];
      return next;
    });
    if (activeName === name) setActiveName("idle");
    setMessage("Removed custom animation " + name + ".");
  }

  function newCharacter() {
    if (sourceCount > 0 || readyCount > 0) {
      const confirmed = window.confirm("Start a new Character Project? Current unsaved animation sources and sheets will be cleared.");
      if (!confirmed) return;
    }
    const nextProject = defaultProject();
    setProject(nextProject);
    setClips(initialClips());
    setActiveName("idle");
    setStepState(0);
    localStorage.removeItem(PROJECT_STORAGE_KEY);
    setMessage("New Character Project created. Define the identity, then import animation sources.");
  }

  async function refreshDesktopEnvironment() {
    if (!desktopBridge) return null;
    const environment = await readDesktopStudioEnvironment(desktopBridge);
    setDesktopEnvironment(environment);
    return environment;
  }

  async function chooseDesktopWorkspace() {
    if (!desktopBridge || desktopActionBusy) return;
    setDesktopActionBusy("workspace");
    try {
      const result = await chooseDesktopStudioWorkspace(desktopBridge);
      if (result?.status === "selected") {
        await refreshDesktopEnvironment();
        setMessage("OCP Desktop workspace selected: " + result.workspaceName + ".");
      }
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Could not choose OCP Desktop workspace.");
    } finally {
      setDesktopActionBusy("");
    }
  }

  async function revealDesktopOutput() {
    if (!desktopBridge || desktopActionBusy) return;
    setDesktopActionBusy("reveal");
    try {
      const result = await revealDesktopStudioOutput(desktopBridge);
      setMessage(result?.status === "revealed" ? "Opened " + result.fileName + " in Explorer." : "Build an .ocp package first.");
      await refreshDesktopEnvironment();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Could not open build output.");
    } finally {
      setDesktopActionBusy("");
    }
  }

  async function installDesktopBuildToRuntime() {
    if (!desktopBridge || desktopActionBusy) return;
    setDesktopActionBusy("runtime");
    try {
      const result = await installDesktopStudioBuildToRuntime(desktopBridge);
      if (result?.status === "submitted") {
        setMessage("Runtime Test install submitted for " + result.fileName + ". Character Manager is opening.");
      } else if (result?.status === "runtime-unavailable") {
        setMessage("OCP Runtime is unavailable. Start Runtime and retry the last build.");
      } else {
        setMessage("Build an .ocp package before sending it to Runtime Test.");
      }
      await refreshDesktopEnvironment();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Runtime Test handoff failed.");
    } finally {
      setDesktopActionBusy("");
    }
  }

  async function saveProject() {
    const snapshot = saveProjectLocal(project, clips);
    const projectFileName = project.id.replace(/[^a-z0-9._+-]+/gi, "-") + ".ocp-project.json";
    if (desktopBridge) {
      setDesktopActionBusy("project");
      try {
        const result = await saveProjectToDesktop(JSON.stringify(snapshot, null, 2), projectFileName, desktopBridge);
        if (result?.status === "saved") {
          await refreshDesktopEnvironment();
          setMessage("Project saved locally and to OCP Desktop workspace " + result.workspaceName + " as " + result.fileName + ". Source video files are not embedded.");
          return;
        }
        setMessage("Project remains saved in browser storage; Desktop workspace selection was cancelled.");
        return;
      } catch (error) {
        setMessage(error instanceof Error ? error.message : "Desktop project save failed.");
        return;
      } finally {
        setDesktopActionBusy("");
      }
    }
    setMessage("Project saved locally at " + new Date(snapshot.savedAt).toLocaleTimeString() + ". Source video files are not embedded.");
  }

  async function exportProjectFile() {
    const snapshot = projectSnapshot(project, clips);
    const projectFileName = project.id.replace(/[^a-z0-9._+-]+/gi, "-") + ".ocp-project.json";
    const content = JSON.stringify(snapshot, null, 2);
    if (desktopBridge) {
      setDesktopActionBusy("project");
      try {
        const result = await saveProjectToDesktop(content, projectFileName, desktopBridge);
        if (result?.status === "saved") {
          await refreshDesktopEnvironment();
          setMessage("Character Project exported to OCP Desktop workspace " + result.workspaceName + " as " + result.fileName + ".");
        } else {
          setMessage("Character Project export cancelled.");
        }
      } catch (error) {
        setMessage(error instanceof Error ? error.message : "Desktop project export failed.");
      } finally {
        setDesktopActionBusy("");
      }
      return;
    }
    downloadText(content, projectFileName);
    setMessage("Character Project file exported. Keep the source videos with the project and re-import them when needed.");
  }

  function importProjectFile(event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const snapshot = normalizeProjectSnapshot(JSON.parse(String(reader.result)));
        if (!snapshot?.project?.id || !snapshot.project?.version || !snapshot.project?.name) {
          throw new Error("Invalid OCP Character Project file.");
        }
        setProject(snapshot.project);
        setClips((current) => applyProjectSnapshot(snapshot, current));
        setActiveName("idle");
        setStepState(0);
        saveProjectLocal(snapshot.project, applyProjectSnapshot(snapshot, initialClips()));
        setMessage("Character Project imported. Re-import the source videos to continue processing.");
      } catch (error) {
        setMessage(error instanceof Error ? error.message : "Unable to import Character Project.");
      }
    };
    reader.onerror = () => setMessage("Unable to read Character Project file.");
    reader.readAsText(file);
  }

  function updateActive(field, value) {
    setClips((current) => {
      const clip = current[activeName];
      const numericValue = ["targetFps", "duration"].includes(field) ? Number(value) : value;
      const next = { ...clip, [field]: numericValue };
      if (field === "duration" || field === "targetFps") {
        const safeDuration = Math.max(0.01, Math.min(Number(next.duration) || 0.01, clip.sourceDuration || Number(next.duration) || 0.01));
        next.duration = safeDuration;
        next.targetFrames = framesFor({ duration: safeDuration, fps: Number(next.targetFps) || 8 });
        next.frames = [];
        next.sheet = null;
        next.status = clip.sourceFile ? "imported" : "missing";
        next.warning = next.targetFrames > MAX_SPRITE_FRAMES
          ? "This profile needs " + next.targetFrames + " frames. Reduce duration or FPS to stay at 64 frames or less."
          : "";
      }
      return { ...current, [activeName]: next };
    });
  }

  function updateAudio(field, value) {
    setClips((current) => {
      const clip = current[activeName];
      const numeric = ["gainDb", "fadeInSeconds", "fadeOutSeconds"].includes(field);
      const nextAudio = {
        ...(clip.audio ?? defaultAudio(activeName)),
        [field]: numeric ? Number(value) : value,
        reviewed: true
      };
      if (field === "mode" && value !== "external") {
        if (nextAudio.externalUrl) URL.revokeObjectURL(nextAudio.externalUrl);
        nextAudio.externalFile = null;
        nextAudio.externalUrl = "";
      }
      return { ...current, [activeName]: { ...clip, audio: nextAudio } };
    });
  }

  function updateAction(field, value) {
    if (!isCustomAnimation(activeName)) return;
    setClips((current) => {
      const clip = current[activeName];
      const numeric = field === "cooldownMs";
      return {
        ...current,
        [activeName]: {
          ...clip,
          action: {
            ...defaultActionConfig(),
            ...(clip.action ?? {}),
            [field]: numeric ? Math.max(0, Math.round(Number(value) || 0)) : value
          }
        }
      };
    });
  }

  function importAudioFile(event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    const lower = file.name.toLowerCase();
    if (!(lower.endsWith(".wav") || lower.endsWith(".ogg"))) {
      setMessage("SFX must be a WAV or OGG file.");
      return;
    }
    setClips((current) => {
      const clip = current[activeName];
      if (clip.audio?.externalUrl) URL.revokeObjectURL(clip.audio.externalUrl);
      return {
        ...current,
        [activeName]: {
          ...clip,
          audio: {
            ...(clip.audio ?? defaultAudio(activeName)),
            mode: "external",
            externalFile: file,
            externalUrl: URL.createObjectURL(file),
            origin: "manual",
            reviewed: true
          }
        }
      };
    });
    setMessage("Attached " + file.name + " to " + labelFor(activeName) + " SFX.");
  }

  function importSfxFiles(event) {
    const files = [...event.target.files].filter((file) => {
      const lower = file.name.toLowerCase();
      return lower.endsWith(".wav") || lower.endsWith(".ogg");
    });
    event.target.value = "";
    if (!files.length) {
      setMessage("Select one or more WAV/OGG files to import SFX.");
      return;
    }

    const chosen = {};
    const priorities = {};
    const notes = [];
    for (const file of files) {
      const targets = inferSfxTargets(file.name, animationNamesForClips(clips));
      if (!targets.length) {
        notes.push(file.name + " (unmapped filename)");
        continue;
      }
      for (const target of targets) {
        const priority = sourcePriority(file.name, target);
        if (chosen[target] && priority <= priorities[target]) {
          notes.push(file.name + " (duplicate " + target + ", skipped)");
          continue;
        }
        if (chosen[target]) notes.push(chosen[target].name + " (duplicate " + target + ", replaced by " + file.name + ")");
        chosen[target] = file;
        priorities[target] = priority;
      }
    }

    const applicable = Object.entries(chosen).filter(([name]) => !(clips[name]?.audio?.origin === "manual" && clips[name]?.audio?.externalFile));
    const mapped = applicable.length;
    const preservedManual = Object.keys(chosen).length - mapped;
    for (const name of Object.keys(chosen)) {
      if (clips[name]?.audio?.origin === "manual" && clips[name]?.audio?.externalFile) notes.push(labelFor(name) + " (manual SFX preserved)");
    }
    setClips((current) => {
      const next = { ...current };
      for (const [name, file] of Object.entries(chosen)) {
        const clip = current[name];
        const currentAudio = clip.audio ?? defaultAudio(name);
        if (currentAudio.origin === "manual" && currentAudio.externalFile) continue;
        if (currentAudio.externalUrl) URL.revokeObjectURL(currentAudio.externalUrl);
        next[name] = {
          ...clip,
          audio: {
            ...currentAudio,
            mode: "external",
            externalFile: file,
            externalUrl: URL.createObjectURL(file),
            origin: "bulk",
            reviewed: true
          }
        };
      }
      return next;
    });

    const shared = Object.entries(chosen).filter(([name, file], _index, entries) => entries.some(([otherName, otherFile]) => otherName !== name && otherFile === file)).length;
    const suffix = notes.length ? " Notes: " + notes.slice(0, 3).join(", ") + (notes.length > 3 ? "..." : "") : "";
    setMessage("Imported SFX for " + mapped + " animation mapping(s)." + (shared ? " Shared loop files can map to left/right or up/down pairs." : "") + (preservedManual ? " Preserved " + preservedManual + " manual override(s)." : "") + suffix);
  }

  function applyRecommendedSfxDefaults() {
    setClips((current) => {
      const next = { ...current };
      for (const name of Object.keys(current)) {
        const clip = current[name];
        const currentAudio = clip.audio ?? defaultAudio(name);
        if (currentAudio.externalFile) continue;
        const recommendedAudio = defaultAudio(name);
        next[name] = {
          ...clip,
          audio: {
            ...currentAudio,
            mode: recommendedSfxMode(name, Boolean(clip.sourceFile)),
            gainDb: recommendedAudio.gainDb,
            loop: recommendedAudio.loop,
            fadeInSeconds: recommendedAudio.fadeInSeconds,
            fadeOutSeconds: recommendedAudio.fadeOutSeconds,
            origin: "recommended",
            reviewed: false
          }
        };
      }
      return next;
    });
    setMessage("Applied recommended SFX defaults: action/emotion clips use source-video audio; Idle, Think, Speak, and Sleep stay silent. Existing attached WAV/OGG files were preserved.");
  }

  async function importVideos(event) {
    const files = [...event.target.files].filter((file) => file.type.startsWith("video/") || file.name.toLowerCase().endsWith(".mp4"));
    if (!files.length) {
      event.target.value = "";
      setMessage("Select one or more MP4/video files.");
      return;
    }
    const updates = {};
    const priorities = {};
    const errors = [];
    setAnimationLoad({ name: "Video import", percent: 0, phase: `Reading 0/${files.length} source(s)`, active: true });
    for (const [index, file] of files.entries()) {
      const name = inferAnimationName(file.name, animationNamesForClips(clips));
      if (!name) {
        errors.push(file.name + " (unmapped filename)");
      } else {
        const priority = sourcePriority(file.name, name);
        if (updates[name] && priority <= priorities[name]) {
          errors.push(file.name + " (duplicate " + name + ", skipped)");
        } else {
          try {
            const loaded = await loadVideo(file);
            if (updates[name]) errors.push(updates[name].sourceFile.name + " (duplicate " + name + ", replaced by " + file.name + ")");
            const profile = animationProfileFor(name);
            const duration = Math.min(profile.duration, loaded.video.duration);
            const targetFps = SUPPORTED_PLAYBACK_FPS.includes(Number(clips[name].targetFps)) ? Number(clips[name].targetFps) : profile.fps;
            const targetFrames = framesFor({ duration, fps: targetFps });
            const currentAudio = clips[name].audio ?? defaultAudio(name);
            const autoAudio = (!currentAudio.reviewed && !currentAudio.externalFile)
              ? { ...currentAudio, mode: recommendedSfxMode(name, true), origin: "recommended" }
              : currentAudio;
            updates[name] = {
              ...clips[name],
              sourceFile: file,
              sourceUrl: loaded.url,
              sourceDuration: loaded.video.duration,
              sourceWidth: loaded.video.videoWidth,
              sourceHeight: loaded.video.videoHeight,
              duration,
              targetFps,
              targetFrames,
              audio: autoAudio,
              frames: [],
              sourcePlacement: null,
              sourceKeyColor: null,
              sourceBounds: null,
              subjectFit: null,
              standardizationMetrics: null,
              clean: { ...defaultClean(name), ...(clips[name].clean ?? {}), keyColorMode: "auto", keyColor: null },
              sheet: null,
              status: "imported",
              warning: targetFrames > MAX_SPRITE_FRAMES ? "Source profile exceeds 64 frames; reduce duration or FPS." : ""
            };
            priorities[name] = priority;
          } catch (error) {
            errors.push(file.name + " (" + error.message + ")");
          }
        }
      }
      const percent = Math.round(((index + 1) / files.length) * 100);
      setAnimationLoad({
        name: name ? labelFor(name) : "Video import",
        percent,
        phase: `Reading ${index + 1}/${files.length} source(s)`,
        active: percent < 100
      });
    }
    setClips((current) => ({ ...current, ...updates }));
    const referenceName = project.standardizationProfile?.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;
    if (updates[referenceName]) {
      setProject((current) => ({
        ...current,
        standardizationProfile: { ...defaultCharacterStandardization(), ...(current.standardizationProfile ?? {}), master: null },
      }));
    }
    event.target.value = "";
    const nextSourceCount = Object.values({ ...clips, ...updates }).filter((clip) => clip.sourceFile).length;
    const suffix = errors.length ? " Failed: " + errors.slice(0, 2).join(", ") + (errors.length > 2 ? "..." : "") : "";
    setAnimationLoad({ name: "Video import", percent: 100, phase: errors.length ? "Import complete with warnings" : "Source videos ready", active: false });
    setToast("Video import complete · 100%");
    setMessage("Imported " + nextSourceCount + "/" + animationNamesForClips({ ...clips, ...updates }).length + " animation source(s). Standard set: " + SOURCE_ANIMATION_COUNT + " required." + suffix);
    if (Object.keys(updates).length) setStepState(1);
  }

  async function replaceVideoForRow(name, event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    const lower = file.name.toLowerCase();
    if (!(file.type.startsWith("video/") || lower.endsWith(".mp4"))) {
      setMessage("Select an MP4/video file for " + labelFor(name) + ".");
      return;
    }

    setBusy(true);
    try {
      const loaded = await loadVideo(file);
      const profile = animationProfileFor(name);
      setClips((current) => {
        const clip = current[name];
        if (clip.sourceUrl) URL.revokeObjectURL(clip.sourceUrl);
        if (clip.sheet?.sheetUrl) URL.revokeObjectURL(clip.sheet.sheetUrl);
        const duration = Math.min(profile.duration, loaded.video.duration);
        const targetFps = SUPPORTED_PLAYBACK_FPS.includes(Number(clip.targetFps)) ? Number(clip.targetFps) : profile.fps;
        const targetFrames = framesFor({ duration, fps: targetFps });
        const currentAudio = clip.audio ?? defaultAudio(name);
        const audio = (!currentAudio.reviewed && !currentAudio.externalFile)
          ? { ...currentAudio, mode: recommendedSfxMode(name, true), origin: "recommended" }
          : currentAudio;
        return {
          ...current,
          [name]: {
            ...clip,
            sourceFile: file,
            sourceUrl: loaded.url,
            sourceDuration: loaded.video.duration,
            sourceWidth: loaded.video.videoWidth,
            sourceHeight: loaded.video.videoHeight,
            duration,
            targetFps,
            targetFrames,
            audio,
            frames: [],
            sourcePlacement: null,
            sourceKeyColor: null,
            sourceBounds: null,
            subjectFit: null,
            standardizationMetrics: null,
            clean: { ...defaultClean(name), ...(clip.clean ?? {}), keyColorMode: "auto", keyColor: null },
            sheet: null,
            status: "imported",
            warning: targetFrames > MAX_SPRITE_FRAMES ? "Source profile exceeds 64 frames; reduce duration or FPS." : ""
          }
        };
      });
      const referenceName = project.standardizationProfile?.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;
      if (name === referenceName) {
        setProject((current) => ({
          ...current,
          standardizationProfile: { ...defaultCharacterStandardization(), ...(current.standardizationProfile ?? {}), master: null },
        }));
      }
      setActiveName(name);
      setStepState(1);
      setMessage("Changed " + labelFor(name) + " video to " + file.name + ". FPS/SFX settings were preserved; sampled frames and the old sheet were cleared and must be sampled again.");
    } catch (error) {
      setMessage("Unable to change " + labelFor(name) + " video: " + error.message);
    } finally {
      setBusy(false);
    }
  }

  async function sampleActive() {
    if (!active.sourceFile) { setMessage("Import a source video for " + activeName + " first."); return; }
    setBusy(true);
    setAnimationProgress(activeName, 0, "Preparing animation");
    setMessage("Sampling and composing " + activeName + ": " + active.targetFrames + " frames @ " + active.targetFps + " FPS from " + active.duration.toFixed(2) + "s...");
    try {
      let standardization = {
        ...defaultCharacterStandardization(),
        ...(project.standardizationProfile ?? {}),
      };
      const referenceName = standardization.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;

      if (standardization.enabled !== false && !standardization.master && activeName !== referenceName) {
        const referenceClip = clips[referenceName];
        if (referenceClip?.sourceFile) {
          setAnimationProgress(activeName, 2, "Calibrating character master scale");
          const calibrated = await calibrateCharacterMaster(referenceClip, (percent, phase) => {
            setAnimationProgress(activeName, Math.max(2, Math.min(18, Math.round(percent * 0.18))), phase);
          });
          standardization = { ...standardization, master: calibrated.master };
          setProject((current) => ({
            ...current,
            standardizationProfile: { ...standardization },
          }));
        }
      }
      standardization = standardizationWithPlacementPairReference(standardization, clips, activeName);

      const sampled = await sampleAndCompose(
        active,
        (percent, phase) => setAnimationProgress(activeName, percent, phase, true),
        standardization,
      );
      if (sampled.characterMaster && !standardization.master) {
        standardization = { ...standardization, master: sampled.characterMaster };
        setProject((current) => ({
          ...current,
          standardizationProfile: { ...standardization },
        }));
      }

      const warning = sampled.standardizationMetrics?.safetyLimited
        ? "Pose exceeds the 512px consistency envelope; a safety scale limit was applied."
        : "";
      setClips((current) => ({
        ...current,
        [activeName]: { ...current[activeName], ...sampled, status: "ready", warning },
      }));
      const grid = gridFor(sampled.frames.length);
      const standardized = sampled.sourcePlacement?.standardized ? " · master-scale standardized" : "";
      setMessage("Sampled and composed " + activeName + " as " + grid.columns + "x" + grid.rows + " / " + sampled.frames.length + " frames @ " + active.targetFps + " FPS" + standardized + ".");
      setStepState(3);
    } catch (error) {
      setAnimationLoad((current) => ({ ...current, phase: "Failed", active: false }));
      setMessage(error.message);
    } finally { setBusy(false); }
  }

  async function sampleAllImported() {
    let names = animationNamesForClips(clips).filter((name) => clips[name].sourceFile);
    if (!names.length) { setMessage("Import MP4 files before sampling the batch."); return; }
    let batchStandardization = {
      ...defaultCharacterStandardization(),
      ...(project.standardizationProfile ?? {}),
    };
    const referenceName = batchStandardization.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;
    if (names.includes(referenceName)) names = [referenceName, ...names.filter((name) => name !== referenceName)];
    if (names.includes("drag_hold") && names.includes("drag_release")) {
      names = names.filter((name) => name !== "drag_hold" && name !== "drag_release");
      names.push("drag_hold", "drag_release");
    }
    setClips((current) => {
      const next = { ...current };
      for (const name of names) {
        const clip = current[name];
        const currentAudio = clip.audio ?? defaultAudio(name);
        if (currentAudio.reviewed || currentAudio.externalFile) continue;
        next[name] = {
          ...clip,
          audio: { ...currentAudio, mode: recommendedSfxMode(name, true), origin: "recommended" }
        };
      }
      return next;
    });
    setBusy(true);
    setAnimationLoad({ name: "Batch", percent: 0, phase: "Preparing animations", active: true });
    const failures = [];
    for (const [index, name] of names.entries()) {
      const clip = clips[name];
      setActiveName(name);
      setMessage("Sampling + composing " + (index + 1) + "/" + names.length + ": " + labelFor(name) + " (" + clip.targetFrames + " frames @ " + clip.targetFps + " FPS)...");
      try {
        batchStandardization = standardizationWithPlacementPairReference(batchStandardization, clips, name);
        const sampled = await sampleAndCompose(clip, (clipPercent, phase) => {
          const overall = ((index + (clipPercent / 100)) / names.length) * 100;
          setAnimationLoad({ name: labelFor(name), percent: Math.round(overall), phase: `${phase} · ${index + 1}/${names.length}`, active: overall < 100 });
        }, batchStandardization);
        if (sampled.characterMaster && !batchStandardization.master) {
          batchStandardization = { ...batchStandardization, master: sampled.characterMaster };
          setProject((current) => ({
            ...current,
            standardizationProfile: { ...batchStandardization },
          }));
        }
        batchStandardization = rememberPlacementPairReference(batchStandardization, name, sampled.sourcePlacement);
        const warning = sampled.standardizationMetrics?.safetyLimited
          ? "Pose exceeds the 512px consistency envelope; a safety scale limit was applied."
          : "";
        setClips((current) => ({ ...current, [name]: { ...current[name], ...sampled, status: "ready", warning } }));
      } catch (error) {
        failures.push(labelFor(name) + ": " + error.message);
      }
    }
    setActiveName(names[0]);
    setBusy(false);
    const completed = names.length - failures.length;
    const finalPhase = failures.length ? `Completed with ${failures.length} error(s)` : "All animations ready";
    setAnimationLoad({ name: "Batch", percent: 100, phase: finalPhase, active: false });
    setToast("Animation load complete · 100%");
    setMessage("Sampled and composed " + completed + "/" + names.length + " animation sheet(s)." + (failures.length ? " Failed: " + failures.slice(0, 2).join(", ") : " All sampled sheets are already ready for QA/build."));
  }

  async function useDemoFrames() {
    const frames = [];
    for (let index = 0; index < active.targetFrames; index += 1) {
      const canvas = document.createElement("canvas"); canvas.width = FRAME_WIDTH; canvas.height = FRAME_HEIGHT;
      const context = canvas.getContext("2d");
      const gradient = context.createLinearGradient(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
      gradient.addColorStop(0, "#192b58"); gradient.addColorStop(1, "#6b3c88"); context.fillStyle = gradient; context.fillRect(0, 0, FRAME_WIDTH, FRAME_HEIGHT);
      context.fillStyle = "#f6c7a8"; context.beginPath(); context.arc(256, 155 + Math.sin(index / 3) * 4, 54, 0, Math.PI * 2); context.fill();
      context.fillStyle = "#6e3f7f"; context.fillRect(185, 210, 142, 200); context.fillStyle = "#f0bb9d"; context.fillRect(215, 395, 30, 80); context.fillRect(270, 395, 30, 80);
      context.fillStyle = "#f7b955"; context.font = "24px sans-serif"; context.fillText("DEMO " + String(index).padStart(2, "0"), 20, 40);
      frames.push(canvas.toDataURL("image/png"));
    }
    setClips((current) => ({ ...current, [activeName]: { ...current[activeName], frames, status: "sampled", warning: "Demo frames only." } }));
    setMessage("Loaded " + frames.length + " demo frames for " + activeName + ".");
  }

  async function composeActive() {
    if (!active.frames.length) { setMessage("Sample frames before composing a sheet."); return; }
    setBusy(true);
    try {
      const blob = await composeSheet(active.frames); const grid = gridFor(active.frames.length); const sheetUrl = URL.createObjectURL(blob);
      setClips((current) => ({ ...current, [activeName]: { ...current[activeName], sheet: { blob, sheetUrl, columns: grid.columns, rows: grid.rows }, status: "ready" } }));
      setMessage(activeName + ".png composed as " + grid.columns + "ร—" + grid.rows + ". Compose all remaining sampled animations before Preview & QA.");
    } catch (error) { setMessage(error.message); } finally { setBusy(false); }
  }

  async function composeAllSampled() {
    const names = animationNamesForClips(clips).filter((name) => clips[name].frames.length);
    if (!names.length) { setMessage("Sample frames before composing sheets."); return; }
    setBusy(true);
    const failures = [];
    for (const [index, name] of names.entries()) {
      const clip = clips[name];
      setActiveName(name);
      setMessage("Composing " + (index + 1) + "/" + names.length + ": " + labelFor(name) + "...");
      try {
        const blob = await composeSheet(clip.frames);
        const grid = gridFor(clip.frames.length);
        const sheetUrl = URL.createObjectURL(blob);
        setClips((current) => ({ ...current, [name]: { ...current[name], sheet: { blob, sheetUrl, columns: grid.columns, rows: grid.rows }, status: "ready" } }));
      } catch (error) { failures.push(labelFor(name) + ": " + error.message); }
    }
    setActiveName(names[0]);
    setBusy(false);
    setMessage("Composed " + (names.length - failures.length) + "/" + names.length + " sprite sheet(s)." + (failures.length ? " Failed: " + failures.slice(0, 2).join(", ") : ""));
    if (!failures.length) setStepState(5);
  }

  function updateClean(field, value) {
    const numeric = ["strength", "chromaSensitivity", "foregroundProtect", "shadowCut", "matteContract", "edgeFeather", "despill", "keyTolerance", "interiorCut", "scale", "offsetX", "offsetY"].includes(field);
    setClips((current) => ({
      ...current,
      [activeName]: {
        ...current[activeName],
        clean: { ...defaultClean(activeName), ...current[activeName].clean, [field]: numeric ? Number(value) : value }
      }
    }));
    const referenceName = project.standardizationProfile?.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;
    if (activeName === referenceName) {
      setProject((current) => ({
        ...current,
        standardizationProfile: { ...defaultCharacterStandardization(), ...(current.standardizationProfile ?? {}), master: null },
      }));
    }
  }

  async function applyClean() {
    if (!active.sourceFile) { setMessage("Re-import the source MP4 before applying Cleanup V7 Sampled Key."); return; }
    const currentClean = { ...defaultClean(activeName), ...(active.clean ?? {}) };
    if (currentClean.keyColorMode === "picked" && !normalizeKeyColor(currentClean.keyColor)) {
      setMessage("Pick a background color from the source video before applying Cleanup V7 Sampled Key.");
      return;
    }
    setBusy(true);
    const keyModeLabel = currentClean.keyColorMode === "picked" ? `picked ${keyColorToHex(currentClean.keyColor)}` : "auto-detected key";
    setMessage("Applying Cleanup V7 Sampled Key (" + currentClean.preset + " · " + keyModeLabel + ") to " + labelFor(activeName) + "...");
    try {
      let standardization = {
        ...defaultCharacterStandardization(),
        ...(project.standardizationProfile ?? {}),
      };
      const referenceName = standardization.referenceAnimation || CHARACTER_STANDARDIZATION_DEFAULTS.referenceAnimation;
      if (standardization.enabled !== false && !standardization.master && activeName !== referenceName) {
        const referenceClip = clips[referenceName];
        if (referenceClip?.sourceFile) {
          const calibrated = await calibrateCharacterMaster(referenceClip);
          standardization = { ...standardization, master: calibrated.master };
          setProject((current) => ({
            ...current,
            standardizationProfile: { ...standardization },
          }));
        }
      }
      standardization = standardizationWithPlacementPairReference(standardization, clips, activeName);

      const sampled = await sampleVideo(
        { ...active, clean: { ...defaultClean(activeName), ...active.clean } },
        () => {},
        standardization,
      );
      if (sampled.characterMaster && !standardization.master) {
        standardization = { ...standardization, master: sampled.characterMaster };
        setProject((current) => ({
          ...current,
          standardizationProfile: { ...standardization },
        }));
      }

      const transform = {
        scale: Number(active.clean?.scale ?? 1),
        offsetX: Number(active.clean?.offsetX ?? 0),
        offsetY: Number(active.clean?.offsetY ?? 0)
      };
      const needsTransform = Math.abs(transform.scale - 1) > 0.0001 || Math.abs(transform.offsetX) > 0.0001 || Math.abs(transform.offsetY) > 0.0001;
      const frames = needsTransform
        ? await Promise.all(sampled.frames.map((frame) => transformFrame(frame, transform)))
        : sampled.frames;
      const warning = sampled.standardizationMetrics?.safetyLimited
        ? "Pose exceeds the 512px consistency envelope; a safety scale limit was applied."
        : "";
      setClips((current) => ({
        ...current,
        [activeName]: {
          ...current[activeName],
          frames,
          sourcePlacement: sampled.sourcePlacement ?? current[activeName].sourcePlacement ?? null,
          sourceKeyColor: sampled.sourceKeyColor ?? current[activeName].sourceKeyColor ?? null,
          sourceBounds: sampled.sourceBounds ?? current[activeName].sourceBounds ?? null,
          subjectFit: sampled.subjectFit ?? current[activeName].subjectFit ?? null,
          standardizationMetrics: sampled.standardizationMetrics ?? current[activeName].standardizationMetrics ?? null,
          clean: { ...defaultClean(activeName), ...current[activeName].clean, scale: 1, offsetX: 0, offsetY: 0 },
          sheet: null,
          status: "sampled",
          warning,
        }
      }));
      setMessage("Cleanup V7 Sampled Key applied to " + labelFor(activeName) + " · clean-before-measure + master character scale. Review Black/White/Alpha/Spill modes, then compose the sheet again.");
    } catch (error) { setMessage(error.message); } finally { setBusy(false); }
  }

  async function autoAlignFeet() {
    if (!active.frames.length) { setMessage("Sample frames before auto-aligning feet."); return; }
    setBusy(true); setMessage("Aligning feet across " + active.frames.length + " frame(s)...");
    try {
      const bottoms = await Promise.all(active.frames.map((frame) => findAlphaBottom(frame)));
      const targetBottom = Math.max(...bottoms.filter((value) => value >= 0), FRAME_HEIGHT - 1);
      const cleanTransform = { ...defaultClean(activeName), ...active.clean };
      const frames = await Promise.all(active.frames.map((frame, index) => transformFrame(frame, {
        scale: cleanTransform.scale,
        offsetX: cleanTransform.offsetX,
        offsetY: (targetBottom - bottoms[index]) + cleanTransform.offsetY
      })));
      setClips((current) => ({ ...current, [activeName]: { ...current[activeName], frames, clean: { ...defaultClean(activeName), ...current[activeName].clean, scale: 1, offsetX: 0, offsetY: 0 }, sheet: null, status: "sampled" } }));
      setMessage("Feet aligned for " + activeName + ". Compose the sheet again.");
    } catch (error) { setMessage(error.message); } finally { setBusy(false); }
  }

  async function buildArchive() {
    if (qcIssues.length) throw new Error("QC must pass all " + SOURCE_ANIMATION_COUNT + " source animations first. " + qcIssues.slice(0, 2).join(" "));

    const profile = buildProfileFor(project);
    const audioAssets = [];
    const audioBuildWarnings = [];
    const audioAvailableNames = new Set();
    for (const [name, clip] of Object.entries(clips)) {
      if (!clip.audio || clip.audio.mode === "none") continue;
      if (clip.audio.mode === "external" && !clip.audio.externalFile) {
        audioBuildWarnings.push(labelFor(name) + " external SFX was not attached and was omitted.");
        continue;
      }
      try {
        const path = audioAssetPath(clip, project);
        const blob = await audioBlobForClip(clip, project);
        if (path && blob) {
          audioAssets.push({ path, blob });
          audioAvailableNames.add(name);
        }
      } catch (error) {
        audioBuildWarnings.push(labelFor(name) + " source SFX was omitted: " + error.message);
      }
    }

    const thumbnailAssets = [];
    const thumbnailAvailableNames = new Set();
    const thumbnailNames = thumbnailNamesForClips(clips);
    for (const name of thumbnailNames) {
      const frame = thumbnailFrameForName(clips, name);
      if (!frame) throw new Error("Export blocked: missing representative frame for " + labelFor(name) + " thumbnail.");
      const blob = await animationThumbnailBlob(frame);
      thumbnailAssets.push({ path: animationThumbnailAssetPath(name), blob });
      thumbnailAvailableNames.add(name);
    }
    if (thumbnailAvailableNames.size !== thumbnailNames.length) {
      throw new Error("Export blocked: all generated animation thumbnails are required.");
    }

    // Build character.json only after optional audio conversion and required
    // thumbnail generation so it can never reference an omitted package asset.
    // Unsigned/local drafts must never claim a verified Publisher merely because
    // the project remembers one from a previous signed-in editing session.
    const packagePublisherId = creatorCloudProfile?.publisherId || "ocp.local";
    const characterJson = buildCharacterJson(
      clips,
      { ...project, author: packagePublisherId },
      audioAvailableNames,
      thumbnailAvailableNames,
    );
    const entryBlob = new Blob([JSON.stringify(characterJson, null, 2)], { type: "application/json" });
    const zip = new JSZip();
    const assets = [{ path: "assets/character.json", blob: entryBlob }];

    const missingStandardSheets = ANIMATION_NAMES.filter((name) => !clips[name]?.sheet);
    if (missingStandardSheets.length) {
      throw new Error("Export blocked: missing Standard animation sheets: " + missingStandardSheets.map(labelFor).join(", ") + ".");
    }
    const spriteClips = Object.values(clips).filter((clip) => clip.sheet);
    let spriteInputBytes = 0;
    let spriteOutputBytes = 0;
    for (const clip of spriteClips) {
      spriteInputBytes += clip.sheet.blob.size;
      const blob = await spriteAssetBlob(clip, project);
      spriteOutputBytes += blob.size;
      assets.push({ path: "assets/" + clip.name + spriteAssetExtension(project), blob });
    }

    const previewFrame = clips.idle.frames[0];
    if (!previewFrame) throw new Error("Export blocked: idle frame 1 is required to generate assets/preview.png.");
    assets.push({ path: "assets/preview.png", blob: await dataUrlToBlob(previewFrame) });
    assets.push(...thumbnailAssets);
    assets.push(...audioAssets);

    const assetEntries = [];
    for (const asset of assets) {
      zip.file(asset.path, asset.blob);
      assetEntries.push({ path: asset.path, sha256: await sha256(asset.blob) });
    }
    const manifest = {
      manifestVersion: "0.1",
      id: project.id,
      type: "character",
      version: project.version,
      publisher: { id: packagePublisherId, keyId: "local-poc" },
      license: project.license,
      entry: "assets/character.json",
      assets: assetEntries
    };
    if (new Set(manifest.assets.map((asset) => asset.path)).size !== manifest.assets.length) throw new Error("Export blocked: manifest contains duplicate asset paths.");
    zip.file("manifest.json", JSON.stringify(manifest, null, 2));

    const compression = profile.archiveCompression === "store" ? "STORE" : "DEFLATE";
    const blob = await zip.generateAsync({
      type: "blob",
      compression,
      ...(compression === "DEFLATE" ? { compressionOptions: { level: 6 } } : {})
    });
    const audioBytes = audioAssets.reduce((sum, asset) => sum + asset.blob.size, 0);
    const thumbnailBytes = thumbnailAssets.reduce((sum, asset) => sum + asset.blob.size, 0);
    const rawRgbaBytes = Object.values(clips).reduce((sum, clip) => sum + clip.frames.length * FRAME_WIDTH * FRAME_HEIGHT * 4, 0);
    const budgetBytes = Math.max(1, Number(profile.packageBudgetMb) || 80) * 1024 * 1024;
    const stats = {
      packageBytes: blob.size,
      spriteInputBytes,
      spriteOutputBytes,
      audioBytes,
      thumbnailBytes,
      thumbnailCount: thumbnailAssets.length,
      spriteCount: spriteClips.length,
      rawRgbaBytes,
      budgetBytes,
      overBudget: blob.size > budgetBytes,
      spriteFormat: profile.spriteFormat,
      audioFormat: profile.audioFormat,
      compression
    };
    return { blob, manifest, audioBuildWarnings, stats };
  }

  async function exportDraft() {
    if (desktopBridge) setDesktopActionBusy("package");
    try {
      const { blob, manifest, audioBuildWarnings, stats } = await buildArchive();
      const packageFileName = project.id.replaceAll(".", "-") + "-v" + project.version + ".draft.ocp";
      let desktopSave = null;
      if (desktopBridge) {
        desktopSave = await savePackageToDesktop(blob, packageFileName, desktopBridge);
        if (desktopSave?.status === "saved") {
          await refreshDesktopEnvironment();
          await revealDesktopStudioOutput(desktopBridge);
        }
      } else {
        downloadBlob(blob, packageFileName);
      }
      if (desktopBridge && desktopSave?.status !== "saved") {
        setMessage("Package build completed, but Desktop workspace save was cancelled.");
        return;
      }
      const mb = (bytes) => (bytes / (1024 * 1024)).toFixed(1) + " MB";
      const spriteSaving = stats.spriteInputBytes > 0
        ? Math.max(0, (1 - stats.spriteOutputBytes / stats.spriteInputBytes) * 100).toFixed(0)
        : "0";
      setMessage(
        "Exported " + manifest.id + " v" + manifest.version
        + " · package " + mb(stats.packageBytes)
        + " · sprites " + mb(stats.spriteOutputBytes) + " (" + stats.spriteFormat.toUpperCase() + ", " + spriteSaving + "% smaller than working PNG sheets)"
        + " · thumbnails " + stats.thumbnailCount + " × " + ANIMATION_THUMBNAIL_SIZE + "px (" + mb(stats.thumbnailBytes) + ")"
        + " · SFX " + mb(stats.audioBytes) + " (" + stats.audioFormat.toUpperCase() + ")"
        + (stats.overBudget ? " · WARNING: package exceeds the configured size budget." : " · size budget passed.")
        + (desktopSave?.status === "saved" ? " · saved as " + desktopSave.fileName + " in Desktop workspace " + desktopSave.workspaceName + ". Explorer opened at the saved file." : "")
        + (audioBuildWarnings.length ? " SFX warnings: " + audioBuildWarnings.slice(0, 2).join(" ") : "")
      );
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Package export failed.");
    } finally {
      if (desktopBridge) setDesktopActionBusy("");
    }
  }

  async function readCreatorPublishers(accessToken) {
    try {
      return await listCreatorCloudPublishers(accessToken);
    } catch (error) {
      // Backward-compatible fallback while an older Cloud deployment is still active.
      if (error && typeof error === "object" && Number(error.status) === 404) {
        const legacyProfile = await findCreatorCloudProfile(accessToken);
        return legacyProfile ? [legacyProfile] : [];
      }
      throw error;
    }
  }

  function preferredCreatorPublisher(publishers) {
    if (!Array.isArray(publishers) || publishers.length === 0) return null;
    const projectPublisher = String(project.author || "").trim();
    if (projectPublisher) {
      const projectMatch = publishers.find((item) => item?.publisherId === projectPublisher);
      if (projectMatch) return projectMatch;
    }
    const remembered = window.localStorage.getItem("ocp.studio.activePublisher") || "";
    return publishers.find((item) => item?.publisherId === remembered) || publishers[0] || null;
  }

  function rememberActiveCreatorPublisher(profile) {
    if (profile?.publisherId) window.localStorage.setItem("ocp.studio.activePublisher", profile.publisherId);
  }

  async function finalizeCreatorDesktopSigner(session, profile, providerLabel = "OCP Account", publishers = null) {
    setCreatorCloudSession(session);
    const availablePublishers = Array.isArray(publishers) ? publishers : (profile ? [profile] : []);
    setCreatorCloudPublishers(availablePublishers);
    setCreatorCloudProfile(profile);
    if (!profile) {
      setCreatorCloudState({ status: "needs-profile", message: `${providerLabel} connected · create your Creator publisher` });
      return null;
    }
    rememberActiveCreatorPublisher(profile);
    if (!desktopBridge) {
      setCreatorCloudState({ status: "online", message: `Creator Cloud · ${profile.publisherId}` });
      return profile;
    }
    try {
      setCreatorCloudState({ status: "linking", message: `${providerLabel} connected · preparing protected signing key for ${profile.publisherId}…` });
      const linked = await linkCreatorCloudDesktopSigner(session.accessToken, profile);
      setCreatorCloudProfile(linked.profile);
      setCreatorCloudPublishers((current) => current.map((item) => item.publisherId === linked.profile.publisherId ? linked.profile : item));
      rememberActiveCreatorPublisher(linked.profile);
      await refreshDesktopEnvironment().catch(() => null);
      setCreatorCloudState({ status: "online", message: `Creator Cloud · ${linked.profile.publisherId} · this PC is ready to sign` });
      return linked.profile;
    } catch (error) {
      setCreatorCloudState({
        status: "needs-signer",
        message: `${providerLabel} connected · signing setup needs attention: ${error instanceof Error ? error.message : "unknown error"}`,
      });
      return profile;
    }
  }

  async function switchCreatorCloudPublisher(publisherId) {
    if (!creatorCloudSession?.accessToken) throw new Error("Sign in to Creator Cloud first.");
    if (project.publisherLocked && project.author && project.author !== publisherId) {
      const error = new Error(`This project is locked to ${project.author} after Marketplace reservation. Release the reservation or open a different project before switching Publisher.`);
      setCreatorCloudState((current) => ({ ...current, status: "error", message: error.message }));
      throw error;
    }
    const profile = creatorCloudPublishers.find((item) => item.publisherId === publisherId);
    if (!profile) throw new Error("This Publisher is not available to the signed-in account.");
    setMarketplaceIdentity(null);
    return await finalizeCreatorDesktopSigner(creatorCloudSession, profile, "Publisher switch", creatorCloudPublishers);
  }

  async function signInCreatorCloud(email, password) {
    if (!creatorIdentity) throw new Error("Creator Cloud is not configured. Add the public Supabase and Cloud API settings first.");
    setCreatorCloudState({ status: "signing-in", message: "Signing in to Creator Cloud..." });
    try {
      await creatorIdentity.signIn(email, password);
      const session = await creatorIdentity.getSession();
      if (!session?.accessToken) throw new Error("Creator Cloud did not return a usable session");
      const publishers = await readCreatorPublishers(session.accessToken);
      const profile = preferredCreatorPublisher(publishers);
      return await finalizeCreatorDesktopSigner(session, profile, "OCP Account", publishers);
    } catch (error) {
      setCreatorCloudState({ status: "error", message: error instanceof Error ? error.message : "Creator Cloud sign in failed" });
      throw error;
    }
  }

  async function signInCreatorCloudOAuth(provider) {
    if (!creatorIdentity) throw new Error("Creator Cloud is not configured. Add the public Supabase and Cloud API settings first.");
    const providerLabel = provider === "microsoft" ? "Microsoft" : "Google";
    const packagedDesktop = window.location.protocol === "file:" && Boolean(desktopBridge);
    setCreatorCloudState({ status: "signing-in", message: `Waiting for ${providerLabel} sign in… Studio work stays open.` });

    if (packagedDesktop) {
      try {
        const callback = await beginDesktopStudioOAuth(desktopBridge);
        if (!callback?.redirectUrl) throw new Error("Desktop OAuth callback is unavailable");
        const result = await creatorIdentity.signInWithOAuth(provider, callback.redirectUrl);
        if (!result?.url) throw new Error(`${providerLabel} sign in did not return an authorization URL`);
        const oauthResult = await openDesktopStudioOAuth(result.url, desktopBridge);
        if (!oauthResult || oauthResult.status !== "code") {
          throw new Error(oauthResult?.error || `${providerLabel} sign in did not return an authorization code`);
        }
        const exchangedSession = await creatorIdentity.exchangeOAuthCode(oauthResult.code);
        const persistedSession = await creatorIdentity.getSession().catch(() => null);
        const session = persistedSession?.accessToken ? persistedSession : exchangedSession;
        if (!session?.accessToken) throw new Error("Creator Cloud did not return a usable session");

        // Authentication and creator-profile lookup are separate gates. Reflect
        // the signed-in OCP Account immediately; a transient Creator Cloud
        // profile error must never make a successful Google sign-in look like
        // it failed.
        setCreatorCloudSession(session);
        setCreatorCloudState({ status: "reconnecting", message: `${providerLabel} signed in · loading Creator profile…` });
        setToast(`${providerLabel} sign-in complete`);

        let publishers = [];
        try {
          publishers = await readCreatorPublishers(session.accessToken);
        } catch (profileError) {
          setCreatorCloudPublishers([]);
          setCreatorCloudProfile(null);
          setCreatorCloudState({
            status: "needs-profile",
            failedStage: "profile",
            message: `${providerLabel} signed in · Creator publishers temporarily unavailable`,
          });
          return null;
        }
        const profile = preferredCreatorPublisher(publishers);
        return await finalizeCreatorDesktopSigner(session, profile, providerLabel, publishers);
      } catch (error) {
        setCreatorCloudState({ status: "error", message: error instanceof Error ? error.message : "Creator Cloud OAuth sign in failed" });
        throw error;
      }
    }

    const popup = window.open("about:blank", "ocp-creator-oauth", "popup=yes,width=520,height=720,resizable=yes,scrollbars=yes");
    if (!popup) {
      const error = new Error(`Allow pop-ups for ${window.location.origin} to sign in with ${providerLabel} without losing Studio work.`);
      setCreatorCloudState({ status: "error", message: error.message });
      throw error;
    }
    popup.document.title = `OCP ${providerLabel} sign in`;
    popup.document.body.innerHTML = `<p style="font-family:system-ui;padding:24px;color:#dbeafe;background:#07111f;min-height:100vh;margin:0">Opening ${providerLabel} sign in…</p>`;
    try {
      const result = await creatorIdentity.signInWithOAuth(provider, buildWebStudioOAuthRedirect(window.location));
      if (!result?.url) throw new Error(`${providerLabel} sign in did not return an authorization URL`);
      popup.location.replace(result.url);
    } catch (error) {
      if (!popup.closed) popup.close();
      setCreatorCloudState({ status: "error", message: error instanceof Error ? error.message : "Creator Cloud OAuth sign in failed" });
      throw error;
    }
  }

  async function onboardCreatorCloudFromSigner(input = {}) {
    if (!creatorCloudSession?.accessToken) throw new Error("Sign in to Creator Cloud first.");
    const requestedPublisherId = String(input.publisherId ?? "").trim().toLowerCase();
    setCreatorCloudState({ status: "linking", message: "Preparing Creator signing identity for this PC..." });
    try {
      if (!requestedPublisherId && creatorCloudProfile) {
        const linked = await linkCreatorCloudDesktopSigner(creatorCloudSession.accessToken, creatorCloudProfile);
        setCreatorCloudProfile(linked.profile);
        setCreatorCloudPublishers((current) => current.map((item) => item.publisherId === linked.profile.publisherId ? linked.profile : item));
        rememberActiveCreatorPublisher(linked.profile);
        await refreshDesktopEnvironment().catch(() => null);
        setCreatorCloudState({ status: "online", message: `Creator Cloud · ${linked.profile.publisherId} · this PC is ready to sign` });
        return linked.profile;
      }

      if (!/^creator\.[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(requestedPublisherId)) {
        throw new Error("Choose a Publisher ID such as creator.yourname before Creator setup.");
      }
      if (requestedPublisherId === "creator.ocp") {
        throw new Error("creator.ocp is reserved for the verified OCP Official publisher.");
      }

      const existing = creatorCloudPublishers.find((item) => item.publisherId === requestedPublisherId);
      if (existing) return await switchCreatorCloudPublisher(existing.publisherId);

      const displayName = String(input.displayName ?? "").trim()
        || creatorCloudSession.user?.displayName
        || creatorCloudSession.user?.email
        || "OCP Creator";
      const profile = await createCreatorCloudWorkspace(
        creatorCloudSession.accessToken,
        requestedPublisherId,
        displayName,
      );
      const publishers = [...creatorCloudPublishers.filter((item) => item.publisherId !== profile.publisherId), profile];
      setCreatorCloudPublishers(publishers);
      setCreatorCloudProfile(profile);
      rememberActiveCreatorPublisher(profile);
      await refreshDesktopEnvironment().catch(() => null);
      setCreatorCloudState({ status: "online", message: `Creator Cloud · ${profile.publisherId} · signer ready` });
      setMarketplaceIdentity(null);
      return profile;
    } catch (error) {
      setCreatorCloudState({ status: "error", message: error instanceof Error ? error.message : "Creator workspace creation failed" });
      throw error;
    }
  }

  async function signOutCreatorCloud() {
    if (!creatorIdentity) return;
    await creatorIdentity.signOut();
    setCreatorCloudSession(null);
    setCreatorCloudPublishers([]);
    setCreatorCloudProfile(null);
    setMarketplaceIdentity(null);
    setCreatorCloudState({ status: "signed-out", message: "Creator Cloud ready — sign in to upload" });
  }

  function currentMarketplaceIdentityInput() {
    const packageId = project.id.trim().toLowerCase();
    const displayName = project.name.trim().replace(/\s+/g, " ");
    if (!/^character\.[a-z0-9]+(?:-[a-z0-9]+)*$/.test(packageId)) {
      throw new Error("Character Package ID must use character.<slug> before Marketplace check.");
    }
    if (displayName.length < 2 || displayName.length > 80) {
      throw new Error("Display name must contain 2-80 characters before Marketplace check.");
    }
    return { packageId, displayName };
  }

  async function checkMarketplaceIdentity({ quiet = false } = {}) {
    if (!creatorCloudSession?.accessToken || !creatorCloudProfile) {
      throw new Error("Sign in and complete Creator setup before checking Marketplace identity.");
    }
    const input = currentMarketplaceIdentityInput();
    if (!quiet) setMarketplaceIdentityBusy("check");
    try {
      const result = await checkCreatorCloudPackageIdentity(
        creatorCloudSession.accessToken,
        input.packageId,
        input.displayName,
        creatorCloudProfile.publisherId,
      );
      const next = { ...result, packageId: input.packageId, displayName: input.displayName };
      setMarketplaceIdentity(next);
      if (!quiet) setMessage("Marketplace identity: " + result.decision + ".");
      return next;
    } finally {
      if (!quiet) setMarketplaceIdentityBusy("");
    }
  }

  async function reserveMarketplaceIdentity() {
    if (!creatorCloudSession?.accessToken || !creatorCloudProfile) {
      setMessage("Sign in and complete Creator setup before reserving a Package ID.");
      return;
    }
    setMarketplaceIdentityBusy("reserve");
    try {
      const input = currentMarketplaceIdentityInput();
      const result = await reserveCreatorCloudPackageIdentity(
        creatorCloudSession.accessToken,
        input.packageId,
        input.displayName,
        creatorCloudProfile.publisherId,
      );
      const next = { ...result, packageId: input.packageId, displayName: input.displayName };
      setMarketplaceIdentity(next);
      if (result.decision === "reserved-by-you") {
        setProject((current) => ({ ...current, author: creatorCloudProfile.publisherId, publisherLocked: true }));
        setMessage("Marketplace Package ID reserved for 72 hours" + (result.reservationExpiresAt ? " until " + new Date(result.reservationExpiresAt).toLocaleString() : "") + `. Publisher locked to ${creatorCloudProfile.publisherId}.`);
      } else {
        setMessage("Package ID could not be reserved: " + result.decision + ".");
      }
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Marketplace Package ID reservation failed.");
    } finally {
      setMarketplaceIdentityBusy("");
    }
  }

  async function releaseMarketplaceIdentity() {
    if (!creatorCloudSession?.accessToken) {
      setMessage("Sign in before releasing a Package ID reservation.");
      return;
    }
    setMarketplaceIdentityBusy("release");
    try {
      const input = currentMarketplaceIdentityInput();
      await releaseCreatorCloudPackageIdentity(creatorCloudSession.accessToken, input.packageId, creatorCloudProfile?.publisherId || "");
      setMarketplaceIdentity({ decision: "available", reservationExpiresAt: null, packageId: input.packageId, displayName: input.displayName });
      setProject((current) => ({ ...current, publisherLocked: false }));
      setMessage("Marketplace Package ID reservation released. Publisher can be changed again for this project.");
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Marketplace Package ID release failed.");
    } finally {
      setMarketplaceIdentityBusy("");
    }
  }

  async function assertMarketplaceIdentityReadyForPublish() {
    const identity = await checkMarketplaceIdentity({ quiet: true });
    if (identity.decision === "reserved-by-you" || identity.decision === "owned-published") return identity;
    const message = identity.decision === "available"
      ? "Reserve this Package ID before the first Creator Cloud upload."
      : identity.decision === "owned-submission"
        ? "This Package ID belongs to your existing submission, but its reservation is no longer active. Renew the 72-hour reservation before uploading again."
        : "Marketplace Package ID is not publishable: " + identity.decision + ".";
    const error = new Error(message);
    error.stage = "identity";
    throw error;
  }

  function useSuggestedCreatorVersion() {
    const suggestedVersion = creatorVersionConflict?.suggestedVersion;
    if (!suggestedVersion) return;
    setProject((current) => ({ ...current, version: suggestedVersion }));
    setCreatorVersionConflict(null);
    setCreatorCloudState((current) => ({
      ...current,
      status: "online",
      stage: "version",
      failedStage: null,
      percent: 0,
      code: "",
      correlationId: "",
      message: `Version updated to ${suggestedVersion}. Ready for Creator Cloud upload.`,
    }));
    setMessage(`Package version updated to ${suggestedVersion}. Build or upload again when ready.`);
  }

  async function publishCreatorCloud() {
    if (!creatorCloudSession?.accessToken || !creatorCloudProfile) {
      setCreatorCloudState({ status: "signed-out", message: "Sign in and complete Creator Portal onboarding before Cloud upload" });
      return;
    }
    let lastProgress = { stage: "identity", percent: 1, message: "Checking Marketplace identity...", submissionId: null };
    const updateProgress = (progress) => {
      lastProgress = { ...lastProgress, ...progress };
      setCreatorCloudState({
        status: progress.stage,
        stage: progress.stage,
        percent: progress.percent,
        message: progress.message,
        submissionId: progress.submissionId ?? lastProgress.submissionId ?? null,
      });
    };
    try {
      updateProgress({ stage: "identity", percent: 1, message: "Re-checking Marketplace Package ID authority..." });
      await assertMarketplaceIdentityReadyForPublish();
      updateProgress({ stage: "version", percent: 2, message: `Checking whether ${project.id} v${project.version} is already used...` });
      const versionConflict = await preflightCreatorCloudVersion(
        creatorCloudSession.accessToken,
        project.id,
        project.version,
        creatorCloudProfile.publisherId,
      );
      if (versionConflict) {
        setCreatorVersionConflict(versionConflict);
        const error = new Error(`${versionConflict.packageId} v${versionConflict.version} is already ${versionConflict.status}. Suggested next version: ${versionConflict.suggestedVersion}.`);
        error.stage = "version";
        error.code = "version_conflict";
        throw error;
      }
      setCreatorVersionConflict(null);
      updateProgress({ stage: "building", percent: 3, message: "Marketplace identity and package version accepted. Building .ocp package..." });
      const { blob, manifest } = await buildArchive();
      updateProgress({ stage: "signing", percent: 5, message: `Signing ${manifest.id} v${manifest.version} locally...` });
      const signedBlob = await signArchiveForCreatorCloud(blob);
      const signedZip = await JSZip.loadAsync(signedBlob);
      const manifestFile = signedZip.file("manifest.json");
      if (!manifestFile) throw new Error("Signed package has no manifest.json");
      const signedManifest = JSON.parse(await manifestFile.async("string"));
      const signedPublisherId = signedManifest?.publisher?.id;
      const signedKeyId = signedManifest?.publisher?.keyId;
      if (signedManifest?.id !== manifest.id || signedManifest?.version !== manifest.version) throw new Error("Local signer changed package identity unexpectedly");
      if (signedPublisherId !== creatorCloudProfile.publisherId) throw new Error(`Local signing publisher ${signedPublisherId || "unknown"} does not match Creator Cloud profile ${creatorCloudProfile.publisherId}`);
      if (!creatorCloudProfile.keys.some((key) => key.status === "active" && key.keyId === signedKeyId)) throw new Error(`Signing key ${signedKeyId || "unknown"} is not active in Creator Cloud`);
      const submission = await uploadSignedArchiveToCreatorCloud(creatorCloudSession.accessToken, {
        blob: signedBlob,
        packageId: manifest.id,
        version: manifest.version,
        publisherId: creatorCloudProfile.publisherId,
        onProgress: updateProgress,
      });
      const reviewSubmission = await submitCreatorCloudForReview(
        creatorCloudSession.accessToken,
        submission.submissionId,
        updateProgress,
      );
      setCreatorCloudState({
        status: "review-ready",
        stage: "review-ready",
        percent: 100,
        submissionId: reviewSubmission.submissionId,
        packageId: reviewSubmission.packageId,
        version: reviewSubmission.version,
        message: `Submitted for C8 moderation · ${reviewSubmission.packageId} v${reviewSubmission.version}`,
      });
      setMessage(`Creator Cloud pipeline SUCCESS. Submission ${reviewSubmission.submissionId} is waiting for marketplace moderator review.`);
    } catch (error) {
      const failedStage = error && typeof error === "object" && typeof error.stage === "string" ? error.stage : lastProgress.stage;
      const submissionId = error && typeof error === "object" && typeof error.submissionId === "string" ? error.submissionId : lastProgress.submissionId;
      const code = error && typeof error === "object" && typeof error.code === "string" ? error.code : "";
      const correlationId = error && typeof error === "object" && typeof error.correlationId === "string" ? error.correlationId : "";
      const failureMessage = error instanceof Error ? error.message : "Creator Cloud operation failed";
      setCreatorCloudState({
        status: "error",
        stage: failedStage,
        failedStage,
        percent: Number(lastProgress.percent) || 0,
        submissionId: submissionId || null,
        code,
        correlationId,
        message: failureMessage,
      });
      const operation = failedStage === "validating" ? "validation FAILED" : failedStage === "submitting-review" ? "Submit for Review FAILED" : "upload pipeline FAILED";
      setMessage(`Creator Cloud ${operation}: ${failureMessage}`);
    }
  }

  async function retryCreatorCloudValidation() {
    const submissionId = creatorCloudState.submissionId;
    if (!creatorCloudSession?.accessToken || !submissionId) {
      setCreatorCloudState((current) => ({ ...current, status: "error", message: "No uploaded Creator Cloud submission is available to retry." }));
      return;
    }
    let lastProgress = { stage: "validating", percent: 86, message: "Retrying Cloud validation...", submissionId };
    const updateProgress = (progress) => {
      lastProgress = { ...lastProgress, ...progress };
      setCreatorCloudState({ status: progress.stage, stage: progress.stage, percent: progress.percent, message: progress.message, submissionId });
    };
    try {
      const submission = await validateCreatorCloudSubmission(creatorCloudSession.accessToken, submissionId, updateProgress);
      const reviewSubmission = await submitCreatorCloudForReview(
        creatorCloudSession.accessToken,
        submissionId,
        updateProgress,
      );
      setCreatorCloudState({
        status: "review-ready",
        stage: "review-ready",
        percent: 100,
        submissionId,
        packageId: reviewSubmission.packageId ?? submission.packageId,
        version: reviewSubmission.version ?? submission.version,
        message: `Submitted for C8 moderation · ${(reviewSubmission.packageId ?? submission.packageId)} v${(reviewSubmission.version ?? submission.version)}`,
      });
      setMessage(`Creator Cloud pipeline SUCCESS. Submission ${submissionId} is waiting for marketplace moderator review.`);
    } catch (error) {
      const failureMessage = error instanceof Error ? error.message : "Creator Cloud validation failed";
      setCreatorCloudState({
        status: "error",
        stage: "validating",
        failedStage: "validating",
        percent: Number(lastProgress.percent) || 86,
        submissionId,
        code: error && typeof error === "object" && typeof error.code === "string" ? error.code : "",
        correlationId: error && typeof error === "object" && typeof error.correlationId === "string" ? error.correlationId : "",
        message: failureMessage,
      });
      setMessage(`Creator Cloud validation FAILED: ${failureMessage}`);
    }
  }

  async function retryCreatorCloudReview() {
    const submissionId = creatorCloudState.submissionId;
    if (!creatorCloudSession?.accessToken || !submissionId) {
      setCreatorCloudState((current) => ({ ...current, status: "error", message: "No validated Creator Cloud submission is available to submit for review." }));
      return;
    }
    const updateProgress = (progress) => {
      setCreatorCloudState((current) => ({
        ...current,
        status: progress.stage,
        stage: progress.stage,
        percent: progress.percent,
        message: progress.message,
        submissionId,
      }));
    };
    try {
      const submission = await submitCreatorCloudForReview(creatorCloudSession.accessToken, submissionId, updateProgress);
      setCreatorCloudState({
        status: "review-ready",
        stage: "review-ready",
        percent: 100,
        submissionId,
        packageId: submission.packageId,
        version: submission.version,
        message: `Waiting for C8 moderator review · ${submission.packageId} v${submission.version}`,
      });
      setMessage(`Creator Cloud submission ${submissionId} is waiting for marketplace moderator review.`);
    } catch (error) {
      setCreatorCloudState((current) => ({
        ...current,
        status: "error",
        stage: "submitting-review",
        failedStage: "submitting-review",
        percent: 97,
        submissionId,
        code: error && typeof error === "object" && typeof error.code === "string" ? error.code : "",
        correlationId: error && typeof error === "object" && typeof error.correlationId === "string" ? error.correlationId : "",
        message: error instanceof Error ? error.message : "Creator review submission failed",
      }));
      setMessage(`Creator Cloud Submit for Review FAILED: ${error instanceof Error ? error.message : "unknown error"}`);
    }
  }

  function stepError(targetStep) {
    if (targetStep === 0 && (!project.id.trim() || !project.version.trim() || !project.name.trim())) return "Complete package ID, version, and display name first.";
    if (targetStep === 0 && !String(project.descriptionEn ?? "").trim() && !String(project.descriptionTh ?? "").trim()) return "Add a character description in English or Thai before continuing.";
    if (targetStep === 0 && !/^character\.[a-z0-9]+(?:-[a-z0-9]+)*$/.test(project.id.trim())) return "Character Package ID must use the locked character.<slug> format, for example character.sabai-sompoo.";
    if (targetStep === 0 && !/^\d+\.\d+\.\d+$/.test(project.version.trim())) return "Package version must use semantic versioning such as 1.0.0.";
    if (targetStep === 1 && sourceCount === 0) return "Import at least one MP4 before continuing.";
    if (targetStep === 2 && active.targetFrames > MAX_SPRITE_FRAMES) return "Reduce End time or FPS: this animation needs " + active.targetFrames + " frames, but Studio supports up to 64.";
    if (targetStep === 2 && !active.frames.length) return "Sample frames for the selected animation first.";
    if (targetStep === 3 && !active.frames.length) return "Clean & anchor requires sampled frames.";
    if (targetStep === 4 && sampledCount !== readyCount) return "Compose every sampled animation before Preview & QA (" + readyCount + "/" + sampledCount + " ready). Use Compose all sampled.";
    if (targetStep === 5 && qcIssues.length) return "QC is not complete yet: " + qcIssues.slice(0, 2).join(" ") + " Return to the earlier step and fix the remaining items.";
    if (targetStep === 6 && standardReadyCount < SOURCE_ANIMATION_COUNT) return "All " + SOURCE_ANIMATION_COUNT + " Standard sprite sheets are required before export (" + standardReadyCount + "/" + SOURCE_ANIMATION_COUNT + " ready). Optional/custom sheets are included only when authored.";
    return "";
  }

  function setStep(nextStep) {
    const targetStep = typeof nextStep === "function" ? nextStep(step) : nextStep;
    const firstInvalidStep = targetStep > step ? Array.from({ length: targetStep - step }, (_, index) => step + index).find((candidate) => stepError(candidate)) : undefined;
    const error = firstInvalidStep === undefined ? "" : stepError(firstInvalidStep);
    if (error) { setMessage(error); return; }
    setStepState(targetStep);
  }

  function navigateTo(targetStep) {
    if (targetStep <= step) { setStep(targetStep); return; }
    const error = stepError(step);
    if (error) { setMessage(error); return; }
    setStep(targetStep);
  }

  function goNext() { navigateTo(Math.min(STEPS.length - 1, step + 1)); }

  function renderStep() {
    if (step === 0) return <ProjectStepV2 project={project} updateProject={updateProject} updateVoiceProfile={updateVoiceProfile} updateBuildProfile={updateBuildProfile} onImport={importVideos} sourceCount={sourceCount} readyCount={readyCount} standardSourceCount={standardSourceCount} standardReadyCount={standardReadyCount} onNew={newCharacter} onSave={saveProject} onExportProject={exportProjectFile} onImportProject={importProjectFile} creatorCloudSession={creatorCloudSession} creatorCloudProfile={creatorCloudProfile} marketplaceIdentity={marketplaceIdentity} marketplaceIdentityBusy={marketplaceIdentityBusy} onCheckMarketplaceIdentity={checkMarketplaceIdentity} onReserveMarketplaceIdentity={reserveMarketplaceIdentity} onReleaseMarketplaceIdentity={releaseMarketplaceIdentity} />;
    if (step === 1) return <ImportStepV2 clips={clips} animationNames={animationNames} activeName={activeName} onSelect={setActiveName} onImport={importVideos} onReplaceVideo={replaceVideoForRow} onImportSfx={importSfxFiles} onApplyRecommendedSfx={applyRecommendedSfxDefaults} onAddCustom={addCustomAnimation} onRemoveCustom={removeCustomAnimation} sourceCount={sourceCount} sfxCount={sfxCount} />;
    if (step === 2) return <TimingStepV2 clip={active} animationNames={animationNames} activeName={activeName} onSelect={setActiveName} updateActive={updateActive} updateAudio={updateAudio} updateAction={updateAction} onImportAudio={importAudioFile} onApplyRecommendedSfx={applyRecommendedSfxDefaults} onSample={sampleActive} onSampleAll={sampleAllImported} onDemo={useDemoFrames} busy={busy} sourceCount={sourceCount} />;
    if (step === 3) return <CleanStepV2 clip={active} animationNames={animationNames} activeName={activeName} onSelect={setActiveName} updateClean={updateClean} onApply={applyClean} onApplyAll={sampleAllImported} onAutoAlign={autoAlignFeet} busy={busy} standardizationProfile={project.standardizationProfile} />;
    if (step === 4) return <SheetStepV2 clip={active} animationNames={animationNames} activeName={activeName} onSelect={setActiveName} onCompose={composeActive} onComposeAll={composeAllSampled} busy={busy} sampledCount={sampledCount} readyCount={readyCount} />;
    if (step === 5) return <PreviewStepInteractive project={project} clips={clips} clip={active} animationNames={animationNames} activeName={activeName} onSelect={setActiveName} readyCount={readyCount} audioWarnings={audioWarnings} locale={locale} />;
    return <BuildStepV2 jsonPreview={jsonPreview} project={project} buildMetrics={buildMetrics} sourceCount={sourceCount} readyCount={readyCount} standardSourceCount={standardSourceCount} standardReadyCount={standardReadyCount} thumbnailCount={thumbnailNamesForClips(clips).length} sfxCount={sfxCount} qcIssues={qcIssues} audioWarnings={audioWarnings} onExport={exportDraft} creatorCloudReady={creatorCloudReady} creatorCloudSession={creatorCloudSession} creatorCloudProfile={creatorCloudProfile} creatorCloudState={creatorCloudState} creatorVersionConflict={creatorVersionConflict} creatorPortalUrl={creatorPortalUrl} onCreatorCloudSignIn={signInCreatorCloud} onCreatorCloudOAuth={signInCreatorCloudOAuth} onCreatorCloudOnboard={onboardCreatorCloudFromSigner} onCreatorCloudSignOut={signOutCreatorCloud} onCreatorCloudPublish={publishCreatorCloud} onCreatorCloudRetryValidation={retryCreatorCloudValidation} onCreatorCloudRetryReview={retryCreatorCloudReview} onUseSuggestedCreatorVersion={useSuggestedCreatorVersion} desktopBridgeAvailable={Boolean(desktopBridge)} desktopEnvironment={desktopEnvironment} desktopActionBusy={desktopActionBusy} onRevealDesktopOutput={revealDesktopOutput} onInstallDesktopBuild={installDesktopBuildToRuntime} />;
  }

  if (studioMode === "sprite-fx" && spriteFx.visible) return <SpriteSheetEffectStudio onCharacter={() => setStudioMode("character")} access={spriteFx} creatorSession={creatorCloudSession} creatorProfile={creatorCloudProfile} locale={locale} onLocaleChange={setLocale} />;

  return <div className="studio-shell">
    <StudioTopbar
      activeMode="character"
      spriteFx={spriteFx}
      onCharacter={() => setStudioMode("character")}
      onSpriteFx={() => setStudioMode("sprite-fx")}
      creatorPortalUrl={creatorPortalUrl}
      desktopBridge={desktopBridge}
      desktopEnvironment={desktopEnvironment}
      desktopActionBusy={desktopActionBusy}
      onChooseWorkspace={() => void chooseDesktopWorkspace()}
      project={project}
      cloudReady={creatorCloudReady}
      session={creatorCloudSession}
      publishers={creatorCloudPublishers}
      profile={creatorCloudProfile}
      cloudState={creatorCloudState}
      oauthAvailability={creatorCloudOAuthAvailability}
      onOAuth={signInCreatorCloudOAuth}
      onPasswordSignIn={signInCreatorCloud}
      onSetup={onboardCreatorCloudFromSigner}
      onPublisherSelect={switchCreatorCloudPublisher}
      onSignOut={signOutCreatorCloud}
      locale={locale}
      onLocaleChange={setLocale}
    />
    <div className="studio-layout">
      <WorkflowSidebar steps={STEPS} step={step} onStep={setStep} desktop={Boolean(desktopBridge)} />
      <main className="studio-main">
        <div className="studio-heading">
          <div><h1>{STEPS[step]}</h1><p>{message}</p></div>
          <span className="studio-badge">{readyCount} sheets ready</span>
        </div>
        {(animationLoad.active || animationLoad.percent > 0) && <section className={"studio-load-progress " + (animationLoad.percent === 100 ? "is-complete" : "")} aria-live="polite">
          <div><span><b>{animationLoad.name || labelFor(activeName)}</b> · {animationLoad.phase}</span><strong>{animationLoad.percent}%</strong></div>
          <div className="studio-load-progress-track" role="progressbar" aria-label="Animation load progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={animationLoad.percent}>
            <i style={{ width: animationLoad.percent + "%" }} />
          </div>
        </section>}
        {renderStep()}
        <div className="studio-footer">
          <span>Step {step + 1} of {STEPS.length}</span>
          <div>
            <button type="button" className="studio-button" disabled={step === 0} onClick={() => setStep((current) => Math.max(0, current - 1))}>Back</button>
            <button type="button" className="studio-button studio-primary" onClick={() => setStep((current) => Math.min(STEPS.length - 1, current + 1))}>{step === STEPS.length - 1 ? "Finish" : "Next step"}</button>
          </div>
        </div>
      </main>
    </div>
    {toast && <div className="studio-toast" role="status"><span>✓</span><div><b>Animation ready</b><small>{toast}</small></div></div>}
  </div>;
}

function MarketplaceIdentityCard({ project, session, profile, identity, busy, onCheck, onReserve, onRelease }) {
  const localReady = /^character\.[a-z0-9]+(?:-[a-z0-9]+)*$/.test(project.id.trim()) && project.name.trim().replace(/\s+/g, " ").length >= 2;
  const cloudReady = Boolean(session?.accessToken && profile);
  const decision = identity?.decision ?? "unverified";
  const reserveAllowed = ["available", "reserved-by-you", "owned-submission"].includes(decision);
  const renew = decision === "reserved-by-you" || decision === "owned-submission";
  const tone = ["reserved-by-you", "owned-published"].includes(decision)
    ? "is-ok"
    : ["unavailable", "reserved-name", "invalid-display-name"].includes(decision)
      ? "is-error"
      : decision === "owned-submission"
        ? "is-warning"
        : "is-neutral";
  const statusText = decision === "available"
    ? "Available — reserve before first publish"
    : decision === "reserved-by-you"
      ? "Reserved by your creator account"
      : decision === "owned-published"
        ? "Published identity owned by your publisher"
        : decision === "owned-submission"
          ? "Owned submission found — renew reservation before another upload"
          : decision === "unverified"
            ? "Not checked against Marketplace yet"
            : decision;

  return <section className="studio-marketplace-identity">
    <div className="studio-marketplace-identity-head">
      <div>
        <span>MARKETPLACE IDENTITY</span>
        <strong>Package ID availability & ownership</strong>
      </div>
      <em className={tone}>{decision}</em>
    </div>
    <div className="studio-marketplace-checks">
      <div className={localReady ? "is-ok" : "is-error"}><b>{localReady ? "✓" : "×"}</b><span>Local format<strong>{localReady ? project.id : "Use character.<slug>"}</strong></span></div>
      <div className={cloudReady ? "is-ok" : "is-warning"}><b>{cloudReady ? "✓" : "○"}</b><span>Creator authority<strong>{cloudReady ? profile.publisherId : "Sign in + complete creator setup"}</strong></span></div>
      <div className={tone}><b>{["reserved-by-you", "owned-published"].includes(decision) ? "✓" : decision === "unverified" ? "○" : "!"}</b><span>Marketplace<strong>{statusText}</strong></span></div>
    </div>
    {identity?.reservationExpiresAt && <p className="studio-identity-expiry">Reservation expires {new Date(identity.reservationExpiresAt).toLocaleString()} · reserve again to renew another 72 hours.</p>}
    <div className="studio-actions studio-identity-actions">
      <button type="button" className="studio-button" disabled={!localReady || !cloudReady || Boolean(busy)} onClick={() => void onCheck()}>{busy === "check" ? "Checking…" : "Check Marketplace"}</button>
      {reserveAllowed && <button type="button" className="studio-button studio-primary" disabled={!localReady || !cloudReady || Boolean(busy)} onClick={() => void onReserve()}>{busy === "reserve" ? "Reserving…" : renew ? "Renew 72h reservation" : "Reserve for 72 hours"}</button>}
      {decision === "reserved-by-you" && <button type="button" className="studio-button" disabled={Boolean(busy)} onClick={() => void onRelease()}>{busy === "release" ? "Releasing…" : "Release reservation"}</button>}
    </div>
    <p className="studio-note">Local validation does not guarantee Marketplace availability. Creator Cloud is authoritative, and publish re-checks this identity immediately before build/upload.</p>
  </section>;
}

function ProjectStepV2({ project, updateProject, updateVoiceProfile, updateBuildProfile, onImport, sourceCount, readyCount, standardSourceCount, standardReadyCount, onNew, onSave, onExportProject, onImportProject, creatorCloudSession, creatorCloudProfile, marketplaceIdentity, marketplaceIdentityBusy, onCheckMarketplaceIdentity, onReserveMarketplaceIdentity, onReleaseMarketplaceIdentity }) {
  const buildProfile = buildProfileFor(project);
  const publisherLabel = project.publisherLocked && project.author
    ? `Locked · ${project.author}`
    : creatorCloudProfile?.publisherId
      ? `${creatorCloudProfile.displayName || "OCP Creator"} · ${creatorCloudProfile.publisherId}`
      : (creatorCloudSession?.user ? "Complete Creator setup to assign Publisher ID" : "Local / Unverified · ocp.local");
  return <section className="studio-grid">
    <div className="studio-panel studio-span-7">
      <div className="studio-panel-heading"><h2>Character Project</h2><span>Local-first</span></div>
      <div className="studio-actions">
        <button type="button" className="studio-button studio-primary" onClick={onNew}>New Character</button>
        <button type="button" className="studio-button" onClick={onSave}>Save Project</button>
        <button type="button" className="studio-button" onClick={onExportProject}>Export Project</button>
        <label className="studio-button">Open Project<input type="file" accept="application/json,.json" onChange={onImportProject} hidden /></label>
      </div>
      <h2>Character package</h2>
      <div className="studio-fields">
        <PackageIdField value={project.id} onChange={(value) => updateProject("id", value)} />
        <Field label="Package version" value={project.version} onChange={(value) => updateProject("version", value)} />
        <Field label="Display name" value={project.name} onChange={(value) => updateProject("name", value)} />
        <label className="studio-field studio-field-wide">Description (English)<textarea value={project.descriptionEn ?? ""} maxLength={1200} rows={4} placeholder="Describe the character, personality, theme, costume, or notable details." onChange={(event) => updateProject("descriptionEn", event.target.value)} /></label>
        <label className="studio-field studio-field-wide">Description (Thai)<textarea value={project.descriptionTh ?? ""} maxLength={1200} rows={4} placeholder="อธิบายตัวละคร บุคลิก ธีม เครื่องแต่งกาย หรือรายละเอียดสำคัญ" onChange={(event) => updateProject("descriptionTh", event.target.value)} /></label>
        <Field label="Author / Publisher" value={publisherLabel} readOnly />
        <label className="studio-field">License<select value={normalizeCharacterLicense(project.license)} onChange={(event) => updateProject("license", event.target.value)}>{CHARACTER_LICENSE_OPTIONS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
        <Field label="Entry schema (latest)" value={CURRENT_CHARACTER_SCHEMA} readOnly />
        <label className="studio-field">TTS voice presentation<select value={project.voiceProfile?.presentation ?? "neutral"} onChange={(event) => updateVoiceProfile("presentation", event.target.value)}>{VOICE_PRESENTATIONS.map((value) => <option key={value} value={value}>{labelFor(value)}</option>)}</select></label>
        <label className="studio-field">TTS age<select value={project.voiceProfile?.age ?? "adult"} onChange={(event) => updateVoiceProfile("age", event.target.value)}>{VOICE_AGE_GROUPS.map((value) => <option key={value} value={value}>{labelFor(value)}</option>)}</select></label>
        <label className="studio-field">Thai speech style<select value={project.voiceProfile?.thaiSpeechStyle ?? "neutral"} onChange={(event) => updateVoiceProfile("thaiSpeechStyle", event.target.value)}>{THAI_SPEECH_STYLES.map((value) => <option key={value} value={value}>{labelFor(value)}</option>)}</select></label>
      </div>
      <MarketplaceIdentityCard project={project} session={creatorCloudSession} profile={creatorCloudProfile} identity={marketplaceIdentity} busy={marketplaceIdentityBusy} onCheck={onCheckMarketplaceIdentity} onReserve={onReserveMarketplaceIdentity} onRelease={onReleaseMarketplaceIdentity} />
      <p className="studio-note">voiceProfile is semantic metadata (for example presentation=female, age=adult). It does not embed audio or credentials; an explicit user-selected TTS voice still overrides the character hint.</p>
      <h2>Build optimization</h2>
      <div className="studio-fields">
        <label className="studio-field">Sprite package format<select value={buildProfile.spriteFormat} onChange={(event) => updateBuildProfile("spriteFormat", event.target.value)}><option value="webp">WebP — Recommended</option><option value="png">PNG — Lossless</option></select></label>
        <Field label="WebP quality" value={String(buildProfile.webpQuality)} onChange={(value) => updateBuildProfile("webpQuality", value)} />
        <label className="studio-field">SFX package format<select value={buildProfile.audioFormat} onChange={(event) => updateBuildProfile("audioFormat", event.target.value)}><option value="ogg">OGG Vorbis — Recommended</option><option value="wav">WAV — Lossless</option></select></label>
        <Field label="Vorbis quality" value={String(buildProfile.vorbisQuality)} onChange={(value) => updateBuildProfile("vorbisQuality", value)} />
        <label className="studio-field">Archive compression<select value={buildProfile.archiveCompression} onChange={(event) => updateBuildProfile("archiveCompression", event.target.value)}><option value="deflate">DEFLATE — Recommended</option><option value="store">Store only</option></select></label>
        <Field label="Package budget" value={String(buildProfile.packageBudgetMb)} suffix="MB" onChange={(value) => updateBuildProfile("packageBudgetMb", value)} />
      </div>
      <p className="studio-note">Production default keeps 32/48 animation frames but converts package sprite sheets to transparent WebP and SFX to OGG Vorbis at Build time. Working sheets stay PNG inside Studio so editing quality is not degraded. Runtime still receives 512x512 frame cells.</p>
      <div className="studio-actions"><label className="studio-button studio-primary">Import MP4 files<input type="file" accept="video/*,.mp4" multiple onChange={onImport} hidden /></label><label className="studio-button">Import folder<input type="file" accept="video/*,.mp4" multiple webkitdirectory="" directory="" onChange={onImport} hidden /></label></div>
      <div className="studio-progress-strip">
        <div><strong>{standardSourceCount}/{SOURCE_ANIMATION_COUNT}</strong><span>Standard sources</span></div>
        <div><strong>{standardReadyCount}/{SOURCE_ANIMATION_COUNT}</strong><span>Standard sheets</span></div>
        {(sourceCount > standardSourceCount || readyCount > standardReadyCount) && <div><strong>{sourceCount - standardSourceCount}/{readyCount - standardReadyCount}</strong><span>optional/custom source / sheet</span></div>}
        <div><strong>Local</strong><span>browser processing</span></div>
      </div>
    </div>
    <div className="studio-panel studio-span-5">
      <h2>Canvas profile</h2>
      <div className="studio-fields">
        <Field label="Frame width" value="512 px" readOnly />
        <Field label="Frame height" value="512 px" readOnly />
        <Field label="Feet anchor X" value="0.50" readOnly />
        <Field label="Feet anchor Y" value="1.00" readOnly />
        <Field label="Sheet grids" value="4x2 / 8x4 / 8x6 / 8x8" readOnly />
        <Field label="Playback FPS" value="8 / 12 / 16" readOnly />
      </div>
      <p className="studio-note">Runtime target: 128x128 logical pixels. Each frame remains 512x512; sheet size grows with duration x FPS up to 64 frames / 4096x4096.</p>
    </div>
  </section>;
}

function ImportStepV2({ clips, animationNames, activeName, onSelect, onImport, onReplaceVideo, onImportSfx, onApplyRecommendedSfx, onAddCustom, onRemoveCustom, sourceCount, sfxCount }) {
  const [customName, setCustomName] = useState("");
  const addCustom = () => {
    if (onAddCustom(customName)) setCustomName("");
  };
  return <section className="studio-grid">
    <div className="studio-panel studio-span-7">
      <div className="studio-panel-heading">
        <h2>Animation sources <span>{sourceCount}/{animationNames.length} imported</span></h2>
        <div className="studio-actions">
          <label className="studio-button">Add videos<input type="file" accept="video/*,.mp4" multiple onChange={onImport} hidden /></label>
          <label className="studio-button">Import folder<input type="file" accept="video/*,.mp4" multiple webkitdirectory="" directory="" onChange={onImport} hidden /></label>
        </div>
      </div>
      <div className="studio-check">✓ Standard 22 animations remain the compatibility set. Directional/interaction and custom animations are optional.</div>
      <div className="studio-fields">
        <label className="studio-field">Custom animation
          <input value={customName} placeholder="charge_power / jump_scare / bomb_drop" onChange={(event) => setCustomName(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); addCustom(); } }} />
        </label>
      </div>
      <div className="studio-actions">
        <button type="button" className="studio-button studio-primary" disabled={!customName.trim()} onClick={addCustom}>+ Add Custom Animation</button>
      </div>
      <p className="studio-note">Built-in optional slots: Climb Top, directional Climb Up/Down Left/Right, Hang Left/Right, Drag Hold, and Drag Release. Use directional climb slots for text, logos, or asymmetric artwork that must never be mirrored. Custom names become generic package actions automatically and do not require a Runtime code change.</p>
      <div className="studio-list">{animationNames.map((name) => {
        const clip = clips[name];
        const audio = clip.audio ?? defaultAudio(name);
        const sfxLabel = audio.mode === "source"
          ? "Source video audio"
          : audio.mode === "external"
            ? (audio.externalFile?.name ?? "External file missing")
            : "No sound";
        const kind = ANIMATION_NAMES.includes(name) ? "Standard" : (isOptionalAnimation(name) ? "Optional" : "Custom");
        return <div className={"studio-row studio-row-editable " + (activeName === name ? "is-selected" : "")} key={name}>
          <button type="button" className="studio-row-select" onClick={() => onSelect(name)}>
            <span><i className={"studio-dot " + (clip.sourceFile ? "is-ready" : "")} />{labelFor(name)} <small>{kind}</small></span>
            <span>{clip.sourceFile?.name ?? "Not imported"}{clip.sourceFile && <small>Source: {clip.sourceWidth || "?"}×{clip.sourceHeight || "?"} · fit to {FRAME_WIDTH}×{FRAME_HEIGHT}</small>}<small>SFX: {sfxLabel}</small></span>
            <strong>{clip.sourceFile ? (clip.sourceDuration || clip.duration).toFixed(1) + "s" : "-"}</strong>
          </button>
          <label className="studio-row-change">{clip.sourceFile ? "Change video" : "Add video"}<input type="file" accept="video/*,.mp4" onChange={(event) => onReplaceVideo(name, event)} hidden /></label>
          {isCustomAnimation(name) && <button type="button" className="studio-row-change" onClick={() => onRemoveCustom(name)}>Remove</button>}
        </div>;
      })}</div>
    </div>
    <div className="studio-panel studio-span-5">
      <h2>Animation SFX <span>{sfxCount}/{animationNames.length} configured</span></h2>
      <div className="studio-actions">
        <label className="studio-button studio-primary">Add WAV / OGG<input type="file" accept="audio/wav,audio/ogg,.wav,.ogg" multiple onChange={onImportSfx} hidden /></label>
        <label className="studio-button">Import SFX folder<input type="file" accept="audio/wav,audio/ogg,.wav,.ogg" multiple webkitdirectory="" directory="" onChange={onImportSfx} hidden /></label>
        <button type="button" className="studio-button" onClick={onApplyRecommendedSfx}>Apply recommended SFX defaults</button>
      </div>
      <p className="studio-note">Bulk SFX uses the same filename mapping as video import, including custom animation names already added to this project.</p>
      <div className="studio-check">✓ SFX is optional and never required for every animation</div>
      <div className="studio-check">✓ Optional/custom clips are packaged only when authored</div>
      <div className="studio-check">✓ Standard 22 remain the release compatibility requirement</div>
    </div>
  </section>;
}

function TimingStepV2({ clip, animationNames, activeName, onSelect, updateActive, updateAudio, updateAction, onImportAudio, onApplyRecommendedSfx, onSample, onSampleAll, onDemo, busy, sourceCount }) {
  const sourceDuration = clip.sourceDuration || clip.duration;
  const audio = clip.audio ?? defaultAudio(activeName);
  const recommendedAudioText = SILENT_SFX_RECOMMENDED_NAMES.has(activeName)
    ? "Recommended: No sound - keep this animation quiet so TTS/ambient use stays clean."
    : "Recommended: Use source video audio - replace with WAV/OGG later if you want a curated SFX.";
  return <section className="studio-grid">
    <div className="studio-panel studio-span-5">
      <div className="studio-panel-heading"><h2>Output profile</h2><span>{sourceCount}/{animationNames.length} imported</span></div>
      <label className="studio-field">Animation<select value={activeName} onChange={(event) => onSelect(event.target.value)}>{animationNames.map((name) => <option key={name} value={name}>{labelFor(name)}</option>)}</select></label>
      <div className="studio-fields">
        <Field label="Start time" value="0.00" suffix="s" readOnly />
        <Field label="End time" value={clip.duration.toFixed(2)} suffix="s" onChange={(value) => updateActive("duration", value)} />
        <label className="studio-field">Target FPS<select value={String(clip.targetFps)} onChange={(event) => updateActive("targetFps", event.target.value)}>{SUPPORTED_PLAYBACK_FPS.map((fps) => <option key={fps} value={fps}>{fps} FPS</option>)}</select></label>
        <Field label="Target frames" value={String(clip.targetFrames)} readOnly />
      </div>
      <label className="studio-check"><input type="checkbox" checked={Boolean(clip.loop)} onChange={(event) => updateActive("loop", event.target.checked)} /> Loop animation</label>
      {isCustomAnimation(activeName) && <div className="studio-panel studio-action-config">
        <h3>Custom Action</h3>
        <div className="studio-fields">
          <label className="studio-field">Priority<select value={clip.action?.priority ?? "presentation"} onChange={(event) => updateAction("priority", event.target.value)}><option value="ambient">Ambient</option><option value="presentation">Presentation</option><option value="reaction">Reaction</option><option value="lifecycle">Lifecycle</option></select></label>
          <Field label="Cooldown" value={String(clip.action?.cooldownMs ?? 0)} suffix="ms" onChange={(value) => updateAction("cooldownMs", value)} />
        </div>
        <label className="studio-check"><input type="checkbox" checked={clip.action?.interruptible !== false} onChange={(event) => updateAction("interruptible", event.target.checked)} /> Allow other presentation actions to interrupt (Physics always wins)</label>
      </div>}
      <div className="studio-actions">
        <button type="button" className="studio-button studio-primary" disabled={busy || !clip.sourceFile} onClick={onSample}>Sample selected</button>
        <button type="button" className="studio-button" disabled={busy || !sourceCount} onClick={onSampleAll}>Sample all imported</button>
        <button type="button" className="studio-button" disabled={busy} onClick={onDemo}>Demo frames (test)</button>
      </div>
      <p className="studio-note">Frame count is automatic: End time ร— FPS. 4 seconds gives 32 frames @ 8 FPS, 48 @ 12 FPS, or 64 @ 16 FPS. Studio caps a sheet at 64 frames / 4096x4096.</p>
    </div>
    <div className="studio-panel studio-span-7">
      <h2>Candidate timeline + SFX</h2>
      <div className="studio-timeline">{Array.from({ length: Math.min(MAX_SPRITE_FRAMES, clip.targetFrames) }, (_, index) => <span className={index === 8 ? "is-focus" : ""} key={index} />)}</div>
      <div className="studio-stats"><div>Source <strong>{clip.sourceFile ? sourceDuration.toFixed(2) + "s" : "not imported"}</strong></div><div>Output <strong>{clip.duration.toFixed(2) + "s"}</strong></div><div>Target <strong>{clip.targetFrames} frames @ {clip.targetFps} FPS</strong></div><div>Loop <strong>{clip.loop ? "on" : "off"}</strong></div></div>
      {clip.warning && <div className="studio-warning">{clip.warning}</div>}
      <div className="studio-note">{recommendedAudioText}</div>
      <div className="studio-fields">
        <label className="studio-field">SFX source<select value={audio.mode} onChange={(event) => updateAudio("mode", event.target.value)}><option value="none">No sound</option><option value="source" disabled={!clip.sourceFile}>Use source video audio</option><option value="external">External WAV / OGG</option></select></label>
        <Field label="SFX gain" value={String(audio.gainDb)} suffix="dB" onChange={(value) => updateAudio("gainDb", value)} />
        <Field label="Fade in" value={String(audio.fadeInSeconds)} suffix="s" onChange={(value) => updateAudio("fadeInSeconds", value)} />
        <Field label="Fade out" value={String(audio.fadeOutSeconds)} suffix="s" onChange={(value) => updateAudio("fadeOutSeconds", value)} />
      </div>
      <label className="studio-check"><input type="checkbox" checked={Boolean(audio.loop)} onChange={(event) => updateAudio("loop", event.target.checked)} /> Loop SFX while animation is active</label>
      <div className="studio-actions"><label className="studio-button">Attach WAV / OGG<input type="file" accept="audio/wav,audio/ogg,.wav,.ogg" onChange={onImportAudio} hidden /></label><button type="button" className="studio-button" onClick={onApplyRecommendedSfx}>Apply recommended SFX defaults</button></div>
      <p className="studio-note">Source audio is extracted to WAV only when building the .ocp. External WAV/OGG is packaged as-is. Preview & QA plays the selected SFX together with the animation.</p>
    </div>
  </section>;
}

function CleanStepV2({ clip, animationNames, activeName, onSelect, updateClean, onApply, onApplyAll, onAutoAlign, busy, standardizationProfile }) {
  const clean = { ...defaultClean(activeName), ...(clip.clean ?? {}) };
  const masterReady = Boolean(standardizationProfile?.master);
  const metrics = clip.standardizationMetrics ?? null;
  const deviationPercent = metrics?.scaleDeviation == null ? null : Math.round(Number(metrics.scaleDeviation) * 100);
  const [qaMode, setQaMode] = useState("checker");
  const [previewView, setPreviewView] = useState("qa");
  const [zoom, setZoom] = useState(100);
  const [frameIndex, setFrameIndex] = useState(Math.min(8, Math.max(0, clip.frames.length - 1)));
  const [liveFrame, setLiveFrame] = useState("");
  const [livePreviewState, setLivePreviewState] = useState("idle");
  const [pickingKeyColor, setPickingKeyColor] = useState(false);
  const videoRef = useRef(null);

  useEffect(() => {
    setFrameIndex(Math.min(8, Math.max(0, clip.frames.length - 1)));
    setQaMode("checker");
    setPreviewView("qa");
    setZoom(100);
    setPickingKeyColor(false);
  }, [activeName, clip.frames.length]);

  const frame = clip.frames[Math.min(frameIndex, Math.max(0, clip.frames.length - 1))] ?? clip.frames[0];
  const requestedChroma = Number(clean.chromaSensitivity);
  const chromaSensitivity = Math.max(
    CLEAN_CHROMA_MIN,
    Math.min(CLEAN_CHROMA_MAX, Number.isFinite(requestedChroma) ? requestedChroma : CLEAN_CHROMA_DEFAULT),
  );
  const pickedKeyColor = normalizeKeyColor(clean.keyColor);
  const keyColorMode = clean.keyColorMode === "picked" ? "picked" : "auto";
  const effectiveKeyColor = keyColorMode === "picked" ? pickedKeyColor : normalizeKeyColor(clip.sourceKeyColor);
  const backgroundCutLabel = keyColorMode === "picked" ? "Sampled color cut" : (effectiveKeyColor && isClassicGreenKey(effectiveKeyColor) ? "Green screen cut" : "Background cut");
  const backgroundKeyLabel = effectiveKeyColor
    ? `${keyColorToHex(effectiveKeyColor)} · RGB ${effectiveKeyColor.red} / ${effectiveKeyColor.green} / ${effectiveKeyColor.blue}`
    : "pending";
  const cleanupPreviewKey = [
    clean.preset,
    clean.strength,
    clean.chromaSensitivity,
    clean.foregroundProtect,
    clean.shadowCut,
    clean.matteContract,
    clean.edgeFeather,
    clean.despill,
    clean.keyTolerance,
    clean.interiorCut,
    clean.keyColorMode,
    keyColorToHex(clean.keyColor),
  ].join("|");

  function beginKeyColorPick() {
    if (!videoRef.current) return;
    videoRef.current.pause();
    setPickingKeyColor(true);
  }

  function chooseAutoKeyColor() {
    setPickingKeyColor(false);
    updateClean("keyColorMode", "auto");
  }

  function chooseKeyColor(color) {
    const normalized = normalizeKeyColor(color);
    if (!normalized) return;
    updateClean("keyColor", normalized);
    updateClean("keyColorMode", "picked");
    setPickingKeyColor(false);
  }

  function pickKeyColorFromVideo(event) {
    if (!pickingKeyColor) return;
    const video = videoRef.current;
    if (!video || video.readyState < 2 || !video.videoWidth || !video.videoHeight) return;

    const rect = video.getBoundingClientRect();
    const sourceAspect = video.videoWidth / video.videoHeight;
    const boxAspect = rect.width / Math.max(1, rect.height);
    let displayWidth = rect.width;
    let displayHeight = rect.height;
    let offsetX = 0;
    let offsetY = 0;
    if (sourceAspect > boxAspect) {
      displayHeight = rect.width / sourceAspect;
      offsetY = (rect.height - displayHeight) / 2;
    } else {
      displayWidth = rect.height * sourceAspect;
      offsetX = (rect.width - displayWidth) / 2;
    }

    const localX = event.clientX - rect.left - offsetX;
    const localY = event.clientY - rect.top - offsetY;
    if (localX < 0 || localY < 0 || localX >= displayWidth || localY >= displayHeight) return;

    const sourceX = Math.max(0, Math.min(video.videoWidth - 1, Math.round((localX / displayWidth) * video.videoWidth)));
    const sourceY = Math.max(0, Math.min(video.videoHeight - 1, Math.round((localY / displayHeight) * video.videoHeight)));
    const radius = 3;
    const sx = Math.max(0, sourceX - radius);
    const sy = Math.max(0, sourceY - radius);
    const sw = Math.max(1, Math.min(radius * 2 + 1, video.videoWidth - sx));
    const sh = Math.max(1, Math.min(radius * 2 + 1, video.videoHeight - sy));
    const canvas = document.createElement("canvas");
    canvas.width = sw;
    canvas.height = sh;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    context.drawImage(video, sx, sy, sw, sh, 0, 0, sw, sh);
    const pixels = context.getImageData(0, 0, sw, sh).data;
    let red = 0;
    let green = 0;
    let blue = 0;
    let count = 0;
    for (let index = 0; index < pixels.length; index += 4) {
      if (pixels[index + 3] < 128) continue;
      red += pixels[index];
      green += pixels[index + 1];
      blue += pixels[index + 2];
      count += 1;
    }
    if (!count) return;
    chooseKeyColor({ red: red / count, green: green / count, blue: blue / count });
  }

  useEffect(() => {
    let cancelled = false;
    let timer = 0;
    setLiveFrame(frame || "");

    if (!clip.sourceFile || busy) {
      setLivePreviewState(clip.sourceFile ? "applied" : "unavailable");
      return undefined;
    }

    setLivePreviewState("updating");
    timer = window.setTimeout(() => {
      sampleCleanupPreviewFrame({
        name: activeName,
        sourceFile: clip.sourceFile,
        frameCount: clip.frames.length,
        targetFrames: clip.targetFrames,
        duration: clip.duration,
        sourcePlacement: clip.sourcePlacement,
        sourceKeyColor: clip.sourceKeyColor,
        clean,
      }, frameIndex).then((value) => {
        if (cancelled) return;
        setLiveFrame(value || frame || "");
        setLivePreviewState("live");
      }).catch(() => {
        if (cancelled) return;
        setLiveFrame(frame || "");
        setLivePreviewState("error");
      });
    }, 180);

    return () => {
      cancelled = true;
      if (timer) window.clearTimeout(timer);
    };
  }, [activeName, frameIndex, frame, cleanupPreviewKey, busy, clip.sourceFile, clip.frames.length, clip.targetFrames, clip.duration, clip.sourcePlacement, clip.sourceKeyColor]);

  return <section className="studio-grid">
    <div className="studio-panel studio-span-5">
      <div className="studio-panel-heading"><h2>Original source</h2><select value={activeName} onChange={(event) => onSelect(event.target.value)}>{animationNames.map((name) => <option key={name} value={name}>{labelFor(name)}</option>)}</select></div>
      <div className={"studio-video-preview " + (pickingKeyColor ? "is-picking-key" : "")}>{clip.sourceUrl ? <video ref={videoRef} src={clip.sourceUrl} controls={!pickingKeyColor} muted onClick={pickKeyColorFromVideo} aria-label={pickingKeyColor ? "Click the video background to sample the cleanup key color" : "Original source video"} /> : <div className="studio-placeholder">Import {labelFor(activeName)}.mp4</div>}{pickingKeyColor ? <div className="studio-key-pick-hint">Click the background color in this paused frame</div> : null}</div>
      <div className="studio-stats"><div>Frames <strong>{clip.frames.length || "-"}</strong></div><div>Cleanup V7 Sampled Key <strong>{clean.preset === "fx" ? "FX / Glow" : "Normal character"}</strong></div><div>Master scale <strong>{masterReady ? "LOCKED" : "pending"}</strong></div>{metrics && <div>Pose <strong>{metrics.poseGroup}{deviationPercent == null ? "" : " · " + (deviationPercent >= 0 ? "+" : "") + deviationPercent + "%"}</strong></div>}</div>
      <div className="studio-fields">
        <label className="studio-field">Cleanup preset<select value={clean.preset} onChange={(event) => updateClean("preset", event.target.value)}><option value="normal">Normal character</option><option value="fx">FX / Glow</option></select></label>
        <Field label="Cleanup strength" value={String(clean.strength)} suffix="x" onChange={(value) => updateClean("strength", value)} />
        <div className="studio-field studio-key-color-field">
          <span>Key color <b>{keyColorMode === "picked" ? "Picked from video" : "Auto detect"}</b></span>
          <div className="studio-key-color-toolbar">
            <button type="button" className={"studio-button " + (pickingKeyColor ? "studio-primary" : "")} disabled={busy || !clip.sourceFile} onClick={beginKeyColorPick}>{pickingKeyColor ? "Pick background now" : "Pick from video"}</button>
            <button type="button" className={"studio-button " + (keyColorMode === "auto" ? "studio-primary" : "")} disabled={busy} onClick={chooseAutoKeyColor}>Auto detect</button>
            {effectiveKeyColor ? <input type="color" value={keyColorToHex(effectiveKeyColor)} disabled={busy} onChange={(event) => chooseKeyColor(hexToKeyColor(event.target.value))} aria-label="Cleanup key color" /> : null}
            <span className="studio-key-color-value">{effectiveKeyColor ? <i className="studio-key-color-swatch" style={{ background: keyColorToHex(effectiveKeyColor) }} /> : null}{backgroundKeyLabel}</span>
          </div>
          <small className="studio-note">Pause on a representative frame, choose <strong>Pick from video</strong>, then click the actual backdrop. V7 samples a small pixel neighborhood from that frame; it does not force #00FF00, gray, white, or any other preset color.</small>
        </div>
        <label className="studio-field studio-chroma-field">
          <span>{backgroundCutLabel} <b>{Math.round(chromaSensitivity)}%</b></span>
          <div className="studio-chroma-control">
            <input
              type="range"
              min={CLEAN_CHROMA_MIN}
              max={CLEAN_CHROMA_MAX}
              step={CLEAN_CHROMA_STEP}
              value={chromaSensitivity}
              disabled={busy}
              onChange={(event) => updateClean("chromaSensitivity", event.target.value)}
              aria-label={`${backgroundCutLabel} sensitivity`}
            />
            <input
              type="number"
              min={CLEAN_CHROMA_MIN}
              max={CLEAN_CHROMA_MAX}
              step={CLEAN_CHROMA_STEP}
              value={Math.round(chromaSensitivity)}
              disabled={busy}
              onChange={(event) => updateClean("chromaSensitivity", event.target.value)}
              aria-label={`${backgroundCutLabel} sensitivity value`}
            />
          </div>
          {busy ? <small className="studio-chroma-busy">Batch sampling is using the settings captured when it started. Wait for 100%, then adjust {backgroundCutLabel} and click Apply Cleanup V7 Sampled Key.</small> : null}
        </label>
        <details className="studio-advanced-cleanup" open>
          <summary>{keyColorMode === "picked" ? "Advanced sampled key tuning" : (effectiveKeyColor && isClassicGreenKey(effectiveKeyColor) ? "Advanced green screen tuning" : "Advanced auto matte tuning")}</summary>
          {effectiveKeyColor ? <small className="studio-note">Active key: {backgroundKeyLabel}{keyColorMode === "picked" ? " · sampled from the selected video frame" : " · detected from the video edge"}</small> : <small className="studio-note">No background key has been detected yet. Use Pick from video for deterministic cleanup.</small>}
          <div className="studio-advanced-cleanup-grid">
            <CleanupTuningField label="Foreground protect" value={clean.foregroundProtect} busy={busy} onChange={(value) => updateClean("foregroundProtect", value)} help="Increase when dark, light, or low-saturation character detail is being cut." />
            <CleanupTuningField label="Key color tolerance" value={clean.keyTolerance} busy={busy} onChange={(value) => updateClean("keyTolerance", value)} help="How far a pixel may drift from the selected or detected key color. Lower protects the character; higher removes a wider range around the backdrop color." />
            <CleanupTuningField label="Dark shadow cut" value={clean.shadowCut} busy={busy} onChange={(value) => updateClean("shadowCut", value)} help="Used mainly by automatic classic-green cleanup to recover dark compressed screen shadows. Sampled-key mode relies primarily on the selected color and tolerance." />
            <CleanupTuningField label="Enclosed key cut" value={clean.interiorCut} busy={busy} onChange={(value) => updateClean("interiorCut", value)} help="Removes near-key background trapped inside closed gaps such as between legs, arms, hair, or props while protecting colors farther from the selected key." />
            <CleanupTuningField label="Matte contract" value={clean.matteContract} busy={busy} onChange={(value) => updateClean("matteContract", value)} help="Shrinks semi-transparent edges. Set near 0% if the character outline or face is being eaten." />
            <CleanupTuningField label="Edge feather" value={clean.edgeFeather} busy={busy} onChange={(value) => updateClean("edgeFeather", value)} help="Softens the alpha edge. Keep low for crisp characters; raise slightly for jagged edges." />
            <CleanupTuningField label="De-spill" value={clean.despill} busy={busy} onChange={(value) => updateClean("despill", value)} help="Neutralizes green spill on retained 1–3 px character edges without changing alpha. Raise this after the silhouette is already correct." />
          </div>
        </details>
        <label className="studio-field studio-transform-field">
          <span>Scale <b>{Number(clean.scale).toFixed(2)}×</b></span>
          <input
            type="range"
            min={CLEAN_SCALE_MIN}
            max={CLEAN_SCALE_MAX}
            step={CLEAN_SCALE_STEP}
            value={Math.max(CLEAN_SCALE_MIN, Math.min(CLEAN_SCALE_MAX, Number(clean.scale) || 1))}
            onChange={(event) => updateClean("scale", event.target.value)}
            aria-label="Character scale"
          />
        </label>
        <label className="studio-field studio-transform-field">
          <span>Offset X <b>{Math.round(Number(clean.offsetX) || 0)} px</b></span>
          <input
            type="range"
            min={CLEAN_OFFSET_MIN}
            max={CLEAN_OFFSET_MAX}
            step={CLEAN_OFFSET_STEP}
            value={Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(clean.offsetX) || 0))}
            onChange={(event) => updateClean("offsetX", event.target.value)}
            aria-label="Character horizontal offset"
          />
        </label>
        <label className="studio-field studio-transform-field">
          <span>Offset Y <b>{Math.round(Number(clean.offsetY) || 0)} px</b></span>
          <input
            type="range"
            min={CLEAN_OFFSET_MIN}
            max={CLEAN_OFFSET_MAX}
            step={CLEAN_OFFSET_STEP}
            value={Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(clean.offsetY) || 0))}
            onChange={(event) => updateClean("offsetY", event.target.value)}
            aria-label="Character vertical offset"
          />
        </label>
      </div>
      <div className="studio-actions"><button type="button" className="studio-button studio-primary" disabled={busy || !clip.sourceFile} onClick={onApply}>Apply Cleanup V7 Sampled Key</button><button type="button" className="studio-button" disabled={busy} onClick={onApplyAll}>Apply Cleanup V7 Sampled Key to all</button><button type="button" className="studio-button" disabled={busy || !clip.frames.length} onClick={onAutoAlign}>Auto-align feet</button></div>
      <p className="studio-note">Cleanup V7 supports two key sources: <strong>Pick from video</strong> samples the backdrop color directly from the paused source frame, while <strong>Auto detect</strong> estimates the dominant edge color. No fixed #00FF00 or #E0E0E0 fallback is used. Green sampled keys use the connected chroma/de-spill path with the actual selected RGB; gray, white, blue, or other flat colors use the generic sampled-key color-to-alpha matte. Recommended order: Pick key → Sampled color cut → Key color tolerance → Matte contract → Edge feather.</p>
    </div>

    <div className="studio-panel studio-span-7">
      <div className="studio-panel-heading"><h2>{previewView === "qa" ? "Cleanup QA" : "Final Anchor Preview"}</h2><span>{previewView === "qa" ? (livePreviewState === "updating" ? "Updating live source preview…" : livePreviewState === "live" ? "Live source preview · Apply to bake all frames" : livePreviewState === "error" ? "Live preview failed · showing last applied frame" : "Inspect edge matte before compose") : "Exact 512×512 placement used by the sprite pipeline"}</span></div>
      <div className="studio-actions studio-preview-mode-actions">
        <button type="button" className={"studio-button " + (previewView === "qa" ? "studio-primary" : "")} onClick={() => setPreviewView("qa")}>Cleanup QA</button>
        <button type="button" className={"studio-button " + (previewView === "anchor" ? "studio-primary" : "")} onClick={() => setPreviewView("anchor")}>Final Anchor Preview</button>
      </div>
      {previewView === "qa"
        ? <CleanupFramePreview frame={liveFrame || frame} mode={qaMode} zoom={zoom} scale={clean.scale} offsetX={clean.offsetX} offsetY={clean.offsetY} />
        : <FinalAnchorPreview frame={liveFrame || frame} scale={clean.scale} offsetX={clean.offsetX} offsetY={clean.offsetY} />}
      {previewView === "qa" ? <div className="studio-actions">
        {["checker", "black", "white", "gray", "alpha", "spill"].map((mode) => <button type="button" key={mode} className={"studio-button " + (qaMode === mode ? "studio-primary" : "")} onClick={() => setQaMode(mode)}>{mode === "spill" ? "Spill detector" : mode === "alpha" ? "Alpha mask" : mode[0].toUpperCase() + mode.slice(1)}</button>)}
      </div> : null}
      <div className="studio-fields">
        <label className="studio-field">Frame<input type="range" min="0" max={Math.max(0, clip.frames.length - 1)} value={Math.min(frameIndex, Math.max(0, clip.frames.length - 1))} disabled={!clip.frames.length} onChange={(event) => setFrameIndex(Number(event.target.value))} /></label>
        {previewView === "qa" ? <label className="studio-field">QA zoom<select value={String(zoom)} onChange={(event) => setZoom(Number(event.target.value))}><option value="100">100%</option><option value="200">200%</option><option value="400">400%</option><option value="800">800%</option></select></label> : null}
      </div>
      <div className="studio-stats"><div>Frame <strong>{clip.frames.length ? (frameIndex + 1) + " / " + clip.frames.length : "-"}</strong></div>{previewView === "qa" ? <><div>Mode <strong>{qaMode}</strong></div><div>Zoom <strong>{zoom}%</strong></div></> : <><div>Canvas <strong>512×512</strong></div><div>Placement <strong>{metrics?.pairScaleLocked ? "PAIR LOCK" : clip.sourcePlacement?.standardized ? "MASTER" : "SOURCE FIT"}</strong></div></>}</div>
      <p className="studio-note">{previewView === "qa" ? "Spill detector marks residual green-dominant pixels in magenta. Alpha mask should show a clean silhouette without floating gray islands. Black/White are the fastest way to catch pale matte halos." : metrics?.pairScaleLocked ? `Scale is locked to ${labelFor(metrics.placementReference)} while center and feet baseline are measured from this animation.` : "This is the final anchored 512×512 frame used before sprite-sheet composition. Use it to judge character size and feet alignment; QA zoom does not affect this view."}</p>
    </div>
  </section>;
}

function SheetStepV2({ clip, animationNames, activeName, onSelect, onCompose, onComposeAll, busy, sampledCount, readyCount }) {
  const grid = gridFor(clip.frames.length || clip.targetFrames);
  return <section className="studio-grid">
    <div className="studio-panel studio-span-7">
      <div className="studio-panel-heading"><h2>Sheet composer <span>{readyCount}/{animationNames.length} ready</span></h2><select value={activeName} onChange={(event) => onSelect(event.target.value)}>{animationNames.map((name) => <option key={name} value={name}>{labelFor(name)}</option>)}</select></div>
      <div className="studio-sheet-meta"><strong>{activeName}.png</strong><span>{grid.columns}x{grid.rows} grid ยท {clip.frames.length} sampled frames</span></div>
      {clip.sheet ? <img className="studio-sheet-image" src={clip.sheet.sheetUrl} alt={activeName + " sprite sheet"} /> : <div className="studio-sheet-grid">{Array.from({ length: grid.columns * grid.rows }, (_, index) => <span className={index < clip.frames.length ? "is-highlight" : ""} key={index}>{index < clip.frames.length ? String(index).padStart(2, "0") : "-"}</span>)}</div>}
      <div className="studio-stats"><div>Sampled <strong>{sampledCount}/{animationNames.length}</strong></div><div>Used <strong>{clip.frames.length} cells</strong></div><div>Output <strong>{grid.columns * FRAME_WIDTH}x{grid.rows * FRAME_HEIGHT}</strong></div></div>
    </div>
    <div className="studio-panel studio-span-5">
      <h2>Compose sheets</h2>
      <div className="studio-check">โ“ Frame sizes match</div>
      <div className="studio-check">โ“ Row-major indexing</div>
      <div className="studio-check">โ“ PNG transparency</div>
      <div className="studio-actions"><button type="button" className="studio-button studio-primary" disabled={busy || !clip.frames.length} onClick={onCompose}>Compose selected</button><button type="button" className="studio-button" disabled={busy || !sampledCount} onClick={onComposeAll}>Compose all sampled</button></div>
      <p className="studio-note">The final package requires the {SOURCE_ANIMATION_COUNT}-animation Standard compatibility set. Climb Top, Drag Release, directional climb/hang, and custom sheets are optional. Studio derives climb_ready from climb_up frame 0; when directional Climb Up Left/Right are authored it also derives non-mirrored climb_ready_left/right poses. idle_neutral is derived from idle.</p>
    </div>
  </section>;
}

function runtimeThumbnailFrame(clip) {
  if (!clip?.frames?.length) return "";
  const representativeIndex = Math.min(clip.frames.length - 1, Math.floor(clip.frames.length * 0.5));
  return clip.frames[representativeIndex] ?? clip.frames[0] ?? "";
}

function thumbnailFrameForName(clips, name) {
  if (name === "climb_ready") return clips.climb_up?.frames?.[0] ?? "";
  if (name === "idle_neutral") return runtimeThumbnailFrame(clips.idle);
  return runtimeThumbnailFrame(clips[name]);
}

function thumbnailNamesForClips(clips) {
  const names = [...LOGICAL_ANIMATION_NAMES];
  for (const name of animationNamesForClips(clips)) {
    if (!names.includes(name) && thumbnailFrameForName(clips, name)) names.push(name);
  }
  return names;
}

function animationThumbnailAssetPath(name) {
  return "assets/thumbnails/" + name + ".png";
}

async function animationThumbnailBlob(frameDataUrl) {
  if (!frameDataUrl) throw new Error("Missing representative frame for animation thumbnail.");
  const image = await loadImage(frameDataUrl);
  const scratch = document.createElement("canvas");
  scratch.width = image.naturalWidth || image.width || FRAME_WIDTH;
  scratch.height = image.naturalHeight || image.height || FRAME_HEIGHT;
  const scratchContext = scratch.getContext("2d", { willReadFrequently: true });
  scratchContext.clearRect(0, 0, scratch.width, scratch.height);
  scratchContext.drawImage(image, 0, 0, scratch.width, scratch.height);
  const pixels = scratchContext.getImageData(0, 0, scratch.width, scratch.height).data;
  let minX = scratch.width;
  let minY = scratch.height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < scratch.height; y += 1) {
    for (let x = 0; x < scratch.width; x += 1) {
      const alpha = pixels[(y * scratch.width + x) * 4 + 3];
      if (alpha < 16) continue;
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
    }
  }
  if (maxX < minX || maxY < minY) {
    minX = 0;
    minY = 0;
    maxX = scratch.width - 1;
    maxY = scratch.height - 1;
  }
  const sourceWidth = Math.max(1, maxX - minX + 1);
  const sourceHeight = Math.max(1, maxY - minY + 1);
  const contentSize = ANIMATION_THUMBNAIL_SIZE - ANIMATION_THUMBNAIL_PADDING * 2;
  const scale = Math.min(contentSize / sourceWidth, contentSize / sourceHeight);
  const drawWidth = Math.max(1, Math.round(sourceWidth * scale));
  const drawHeight = Math.max(1, Math.round(sourceHeight * scale));
  const drawX = Math.round((ANIMATION_THUMBNAIL_SIZE - drawWidth) / 2);
  const drawY = ANIMATION_THUMBNAIL_SIZE - ANIMATION_THUMBNAIL_PADDING - drawHeight;
  const canvas = document.createElement("canvas");
  canvas.width = ANIMATION_THUMBNAIL_SIZE;
  canvas.height = ANIMATION_THUMBNAIL_SIZE;
  const context = canvas.getContext("2d");
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.drawImage(image, minX, minY, sourceWidth, sourceHeight, drawX, drawY, drawWidth, drawHeight);
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
  if (!blob) throw new Error("Browser could not encode animation thumbnail PNG.");
  return blob;
}

function PreviewStepInteractive({ project, clips, clip, animationNames, activeName, onSelect, readyCount, audioWarnings, locale }) {
  const [exportingPreview, setExportingPreview] = useState(false);
  const [exportNotice, setExportNotice] = useState("");
  async function exportPublicPreview() {
    setExportingPreview(true); setExportNotice("");
    try { const count = await exportStorePreview(clips, project); setExportNotice("Exported " + count + " silent public previews. Review the ZIP before publishing to Store."); }
    catch(error) { setExportNotice(error.message); }
    finally { setExportingPreview(false); }
  }
  const [frameIndex, setFrameIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [loop, setLoop] = useState(Boolean(clip.loop));
  const audioRef = useRef(null);
  const audio = clip.audio ?? defaultAudio(activeName);
  const audioUrl = audio.mode === "source" ? clip.sourceUrl : (audio.mode === "external" ? audio.externalUrl : "");

  useEffect(() => {
    setFrameIndex(0);
    setPlaying(false);
    setLoop(Boolean(clip.loop));
  }, [activeName, clip.loop, clip.frames.length]);

  useEffect(() => {
    if (audioRef.current) {
      audioRef.current.pause();
      audioRef.current = null;
    }
    if (!audioUrl) return undefined;
    const player = new Audio(audioUrl);
    player.preload = "auto";
    player.loop = Boolean(audio.loop);
    player.volume = Math.max(0, Math.min(1, Math.pow(10, Number(audio.gainDb ?? -3) / 20)));
    audioRef.current = player;
    return () => {
      player.pause();
      audioRef.current = null;
    };
  }, [activeName, audioUrl, audio.loop, audio.gainDb]);

  useEffect(() => {
    const player = audioRef.current;
    if (!player) return;
    if (playing) {
      if (frameIndex === 0) player.currentTime = 0;
      player.play().catch(() => undefined);
    } else {
      player.pause();
    }
  }, [playing, frameIndex]);

  useEffect(() => {
    if (!playing || !clip.frames.length) return undefined;
    const interval = window.setInterval(() => {
      setFrameIndex((current) => {
        const next = current + 1;
        if (next < clip.frames.length) return next;
        if (loop) {
          if (audioRef.current && audio.loop) audioRef.current.currentTime = 0;
          return 0;
        }
        setPlaying(false);
        return current;
      });
    }, 1000 / Math.max(1, clip.targetFps));
    return () => window.clearInterval(interval);
  }, [clip.frames.length, clip.targetFps, loop, playing, audio.loop]);

  function togglePlayback() {
    if (!playing && frameIndex >= Math.max(0, clip.frames.length - 1)) setFrameIndex(0);
    setPlaying((current) => !current);
  }

  const standardizedCount = Object.values(clips).filter((item) => item.sourcePlacement?.standardized).length;
  const safetyLimited = Object.values(clips).filter((item) => item.standardizationMetrics?.safetyLimited).map((item) => labelFor(item.name));
  const masterReady = Boolean(project.standardizationProfile?.master);
  const previewDescription = String(locale === "th" ? (project.descriptionTh || project.descriptionEn || "") : (project.descriptionEn || project.descriptionTh || "")).trim();

  return <section className="studio-grid"><div className="studio-panel studio-span-5"><h2>Runtime preview</h2><div className="studio-preview-metadata"><strong>{project.name}</strong><p>{previewDescription || "No character description"}</p><small>{project.author || "Local preview"} · {normalizeCharacterLicense(project.license)} · {CURRENT_CHARACTER_SCHEMA}</small></div><button className="studio-button" type="button" disabled={exportingPreview || !readyCount} onClick={exportPublicPreview}>{exportingPreview ? "Exporting…" : "Export Store preview (public)"}</button><p className="studio-note">Separate low-resolution public images. No private package or audio. Review before publishing.</p>{exportNotice && <p role="status">{exportNotice}</p>}<FramePreview frame={clip.frames[frameIndex] ?? clip.frames[0]} /><div className="studio-actions"><button type="button" className="studio-button studio-primary" disabled={!clip.frames.length} onClick={togglePlayback}>{playing ? "Pause" : "Play"} Animation + Sound</button><button type="button" className="studio-button" disabled={!clip.frames.length} onClick={() => setLoop((current) => !current)}>{loop ? "Loop on" : "Loop off"}</button></div><div className="studio-stats">Frame <strong>{clip.frames.length ? String(frameIndex + 1).padStart(2, "0") + " / " + clip.frames.length : "-"}</strong> / FPS <strong>{clip.targetFps}</strong> / Duration <strong>{(clip.frames.length / clip.targetFps).toFixed(2)}s</strong></div><div className="studio-note">SFX: {audio.mode === "none" ? "None" : (audio.mode === "source" ? "Source video audio" : (audio.externalFile?.name ?? "External audio not attached"))}</div></div><div className="studio-panel studio-span-7"><h2>Quality report</h2><div className="studio-check">✓ {readyCount} animation sheet(s) composed</div><div className="studio-check">✓ Character master scale {masterReady ? "calibrated from " + labelFor(project.standardizationProfile?.referenceAnimation || "idle") : "pending"}</div><div className="studio-check">✓ {standardizedCount}/{animationNames.length} sampled animations use master-scale placement</div>{safetyLimited.length > 0 && <div className="studio-warning">Consistency warning: safety scaling was required for {safetyLimited.slice(0, 4).join(", ")}{safetyLimited.length > 4 ? "…" : ""}. Review these extreme poses for clipping.</div>}<div className="studio-check">✓ character/3 entry can be generated</div><div className="studio-check">✓ assets/preview.png is generated from Idle frame 1</div><div className="studio-check">✓ Reviewed SFX is packaged as Character/3 audioProfile</div>{audioWarnings.length > 0 && <div className="studio-warning">SFX warning (non-blocking): {audioWarnings.slice(0, 2).join(" ")} Missing external files are treated as No sound until re-attached.</div>}<div className="studio-check">โ“ Runtime-default teleport uses portal.blue / below-feet</div><div className="studio-check">✓ Packaged Desktop signing is handled by the Electron bridge + bundled OCP signer; browser mode is preview/development only</div><div className="studio-check">✓ {thumbnailNamesForClips(clips).length} embedded animation thumbnails will be packaged at {ANIMATION_THUMBNAIL_SIZE}×{ANIMATION_THUMBNAIL_SIZE}</div><p className="studio-note">Thumbnail preview uses the representative frame that Studio will embed into assets/thumbnails/*.png. climb_ready is derived from climb_up frame 1 and idle_neutral is derived from idle. Runtime/Electron can consume these package assets directly in the next integration phase.</p><div className="studio-thumbnail-grid">{thumbnailNamesForClips(clips).map((name) => { const thumbnail = thumbnailFrameForName(clips, name); return <button type="button" className={name === activeName ? "is-selected" : ""} key={name} onClick={() => { if (animationNames.includes(name)) onSelect(name); else onSelect(name === "climb_ready" ? "climb_up" : "idle"); }}><span>{thumbnail ? <img src={thumbnail} alt={labelFor(name) + " embedded thumbnail preview"} /> : <i>No preview</i>}</span><b>{labelFor(name)}</b></button>; })}</div><select value={activeName} onChange={(event) => onSelect(event.target.value)}>{animationNames.map((name) => <option key={name} value={name}>{labelFor(name)}</option>)}</select></div></section>;
}

function BuildStepV2({ jsonPreview, project, buildMetrics, sourceCount, readyCount, standardSourceCount, standardReadyCount, thumbnailCount, sfxCount, qcIssues, audioWarnings, onExport, creatorCloudReady: cloudReady, creatorCloudProfile, creatorCloudState, creatorVersionConflict, creatorPortalUrl: portalUrl, onCreatorCloudPublish, onCreatorCloudRetryValidation, onCreatorCloudRetryReview, onUseSuggestedCreatorVersion, desktopBridgeAvailable, desktopEnvironment, desktopActionBusy, onRevealDesktopOutput, onInstallDesktopBuild }) {
  const complete = qcIssues.length === 0;
  const cloudBusy = ["identity", "version", "building", "signing", "hashing", "authorizing", "uploading", "completing", "validating", "submitting-review"].includes(creatorCloudState.status);
  const cloudPercent = Math.max(0, Math.min(100, Number(creatorCloudState.percent) || 0));
  const canRetryValidation = Boolean(creatorCloudState.submissionId) && (creatorCloudState.status === "uploaded" || (creatorCloudState.status === "error" && creatorCloudState.failedStage === "validating"));
  const canRetryReview = Boolean(creatorCloudState.submissionId) && (creatorCloudState.status === "validated" || (creatorCloudState.status === "error" && creatorCloudState.failedStage === "submitting-review"));
  const desktopSignerReady = !desktopBridgeAvailable || desktopEnvironment?.signingAvailable === true;
  const freshUploadNeedsSigner = !canRetryValidation && !canRetryReview;
  const hasPipelineFailure = creatorCloudState.status === "error" && Boolean(creatorCloudState.failedStage) && creatorCloudState.failedStage !== "profile";
  const showCloudProgress = cloudBusy || hasPipelineFailure || ["uploaded", "validated", "review-ready"].includes(creatorCloudState.status) || Boolean(creatorCloudState.submissionId);
  const cloudOutcome = creatorCloudState.status === "review-ready" ? "WAITING MODERATOR" : creatorCloudState.status === "validated" ? "VALIDATED" : hasPipelineFailure ? "FAILED" : creatorCloudState.status === "uploaded" ? "VALIDATION PENDING" : cloudBusy ? "IN PROGRESS" : "READY";
  const validationPassed = ["validated", "submitting-review", "review-ready"].includes(creatorCloudState.status) || (creatorCloudState.status === "error" && creatorCloudState.failedStage === "submitting-review");
  const cloudPipeline = [
    { key: "identity", label: "Marketplace identity", done: cloudPercent >= 2 },
    { key: "version", label: "Package version", done: cloudPercent >= 3 },
    { key: "signing", label: "Build + local sign", done: cloudPercent >= 8 },
    { key: "authorizing", label: "Create private submission", done: cloudPercent >= 35 },
    { key: "uploading", label: "Upload to R2 quarantine", done: cloudPercent >= 72 },
    { key: "completing", label: "Finalize upload", done: cloudPercent >= 86 },
    { key: "validating", label: "Cloud validation", done: validationPassed },
    { key: "security-gate", label: "Security Gate", done: validationPassed },
    { key: "submitting-review", label: "Submit for C8 review", done: creatorCloudState.status === "review-ready" },
  ];
  const profile = buildProfileFor(project);
  const mb = (bytes) => (bytes / (1024 * 1024)).toFixed(1) + " MB";

  return <section className="studio-grid">
    <div className="studio-panel studio-span-5">
      <h2>Package summary</h2>
      <div className="studio-check">✓ character/3 JSON generated</div>
      <div className="studio-check">✓ Standard sources {standardSourceCount}/{SOURCE_ANIMATION_COUNT} · total authored {sourceCount}</div>
      <div className="studio-check">✓ Standard sheets {standardReadyCount}/{SOURCE_ANIMATION_COUNT} · total packaged {readyCount}</div>
      <div className="studio-check">✓ assets/preview.png generated from Idle frame 1</div>
      <div className="studio-check">✓ {thumbnailCount} animation thumbnails embedded in assets/thumbnails/*.png ({ANIMATION_THUMBNAIL_SIZE}×{ANIMATION_THUMBNAIL_SIZE})</div>
      <div className="studio-check">✓ {sfxCount} animation SFX binding(s) included</div>
      <div className="studio-check">✓ Build sprites: {profile.spriteFormat.toUpperCase()} · SFX: {profile.audioFormat.toUpperCase()} · archive: {profile.archiveCompression.toUpperCase()}</div>
      <div className="studio-check">✓ Working PNG sheets: {mb(buildMetrics.workingSpriteBytes)} · {buildMetrics.totalFrames} frames</div>
      <div className="studio-check">✓ Full-load RGBA estimate: {mb(buildMetrics.rawRgbaBytes)}; Runtime V3 uses lazy animation cache instead</div>
      <div className="studio-check">✓ Store package budget: {profile.packageBudgetMb} MB</div>
      <div className="studio-check">✓ Runtime-default teleport portal profile included</div>
      <div className="studio-check">✓ Standard runtime baseline {RUNTIME_ANIMATION_COUNT} entries including climb_ready; optional/custom entries are additive</div>
      <div className="studio-check">✓ Standard logical baseline {LOGICAL_ANIMATION_NAME_COUNT} names including idle_neutral fallback</div>
      <div className="studio-check">✓ SHA-256 asset hashes calculated</div>
      {complete
        ? <div className="studio-check">✓ QC passed: duration-driven Character/3 package</div>
        : <div className="studio-warning">! QC needs attention: {qcIssues.length} issue(s). {qcIssues.slice(0, 2).join(" ")}</div>}
      {audioWarnings.length > 0 && <div className="studio-warning">SFX warning (non-blocking): {audioWarnings.length} External SFX selection(s) have no attached WAV/OGG. They will be omitted from this build and treated as No sound.</div>}
      <div className="studio-check">✓ Publish signs the draft locally; private key never enters the browser</div>
      <div className="studio-actions">
        <button type="button" className="studio-button studio-primary" disabled={!complete || Boolean(desktopActionBusy)} onClick={onExport}>{desktopActionBusy === "package" ? (desktopBridgeAvailable ? "Building + saving .ocp…" : "Exporting .ocp…") : desktopBridgeAvailable ? "Build + Save .ocp" : "Export .ocp draft"}</button>
        {desktopBridgeAvailable && <button type="button" className="studio-button" disabled={!desktopEnvironment?.hasLastOutput || Boolean(desktopActionBusy)} onClick={onRevealDesktopOutput}>Open build in Explorer</button>}
        {desktopBridgeAvailable && <button type="button" className="studio-button studio-runtime-test" disabled={!desktopEnvironment?.hasLastOutput || !desktopEnvironment?.runtimeAvailable || Boolean(desktopActionBusy)} onClick={onInstallDesktopBuild}>{desktopActionBusy === "runtime" ? "Sending to Runtime…" : "Install build to Runtime Test"}</button>}
      </div>
      {desktopBridgeAvailable && <div className={"studio-desktop-build-state " + (desktopEnvironment?.signingAvailable ? "is-ready" : "is-offline")}><strong>OCP Desktop workspace</strong><span>{desktopEnvironment?.workspaceName || "Choose a workspace when saving"} · {desktopEnvironment?.hasLastOutput ? "build ready" : "no saved build"} · Runtime {desktopEnvironment?.runtimeAvailable ? "connected" : "offline"} · Signer {desktopEnvironment?.signingAvailable ? "ready · " + (desktopEnvironment.signingPublisherId || "publisher configured") : "not provisioned"}</span></div>}
      <div className="studio-cloud-card">
        <div className="studio-cloud-heading"><div><strong>Creator Cloud · C6 → C8</strong><small>Private quarantine · validation · Security Gate · auto submit for review</small></div><span className={["validated", "review-ready", "online"].includes(creatorCloudState.status) ? "studio-cloud-dot online" : "studio-cloud-dot"} /></div>
        {!cloudReady
          ? <div className="studio-note">Creator Cloud not configured. Cloud account settings are shown globally in the top bar.</div>
          : !creatorCloudProfile
            ? <div className="studio-note">OCP Account is managed globally in the top bar. Sign in and complete creator setup there before uploading.</div>
            : <div className="studio-cloud-account"><div><strong>{creatorCloudProfile.displayName || "OCP Creator"}</strong><small>{creatorCloudProfile.publisherId} · global OCP Account</small></div></div>}
        {showCloudProgress && <div className={`studio-cloud-progress ${creatorCloudState.status === "error" ? "is-error" : ["validated", "review-ready"].includes(creatorCloudState.status) ? "is-success" : ""}`}>
          <div className="studio-cloud-progress-head"><strong>{cloudOutcome}</strong><span>{cloudPercent}%</span></div>
          <div className="studio-cloud-progress-track" role="progressbar" aria-label="Creator Cloud publish progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={cloudPercent}><i style={{ width: cloudPercent + "%" }} /></div>
          <div className="studio-cloud-pipeline">
            {cloudPipeline.map((item) => {
              const failed = creatorCloudState.status === "error" && creatorCloudState.failedStage === item.key;
              const active = !failed && !item.done && creatorCloudState.stage === item.key;
              return <div key={item.key} className={failed ? "is-failed" : item.done ? "is-done" : active ? "is-active" : ""}><span>{failed ? "×" : item.done ? "✓" : active ? "…" : "○"}</span>{item.label}</div>;
            })}
          </div>
          {creatorCloudState.submissionId && <small className="studio-cloud-submission">Submission · {creatorCloudState.submissionId}</small>}
        </div>}
        <div className={creatorCloudState.status === "error" ? "studio-cloud-error" : ["validated", "review-ready"].includes(creatorCloudState.status) ? "studio-cloud-success" : "studio-note"}>{creatorCloudState.message}</div>
        {creatorVersionConflict && <div className="studio-version-conflict">
          <div>
            <strong>{creatorVersionConflict.packageId} v{creatorVersionConflict.version} is already {creatorVersionConflict.status}.</strong>
            <small>Suggested next version: {creatorVersionConflict.suggestedVersion}</small>
          </div>
          <button type="button" className="studio-button" onClick={onUseSuggestedCreatorVersion}>Use {creatorVersionConflict.suggestedVersion}</button>
        </div>}
        <div className="studio-actions">
          <button
            type="button"
            className="studio-button studio-primary"
            disabled={(!canRetryValidation && !canRetryReview && !complete) || !creatorCloudProfile || cloudBusy || creatorCloudState.status === "review-ready" || (freshUploadNeedsSigner && !desktopSignerReady)}
            onClick={canRetryValidation ? onCreatorCloudRetryValidation : canRetryReview ? onCreatorCloudRetryReview : onCreatorCloudPublish}
          >{cloudBusy ? "Creator Cloud working..." : creatorCloudState.status === "review-ready" ? "Waiting for moderator" : canRetryValidation ? "Retry Cloud validation" : canRetryReview ? "Retry Submit for Review" : creatorCloudState.status === "error" ? "Retry Upload + Validate" : "Upload + Validate + Submit for Review"}</button>
          {portalUrl && <button type="button" className="studio-button" onClick={() => window.open(portalUrl, "_blank", "noopener,noreferrer")}>Open Creator Portal</button>}
        </div>
        {desktopBridgeAvailable && !desktopEnvironment?.signingAvailable && <div className="studio-warning">Desktop package signing is not provisioned. Build/Runtime Test still work, but a new Creator Cloud upload is blocked until a creator signing identity is configured.</div>}
        <div className="studio-note">Animation Studio automatically submits a successfully validated package for C8 review. Manual uploads in Creator Portal still require the creator to press Submit for Review.</div>
      </div>
    </div>
    <div className="studio-panel studio-span-7"><h2>character.json preview</h2><pre className="studio-json">{jsonPreview}</pre></div>
  </section>;
}

const CHARACTER_PACKAGE_PREFIX = "character.";

function normalizeCharacterPackageSlug(value) {
  return String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/^character\./, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96);
}

function characterPackageSlug(packageId) {
  const raw = String(packageId ?? "").trim().toLowerCase();
  return normalizeCharacterPackageSlug(raw.startsWith(CHARACTER_PACKAGE_PREFIX) ? raw.slice(CHARACTER_PACKAGE_PREFIX.length) : raw);
}

function PackageIdField({ value, onChange }) {
  const slug = characterPackageSlug(value);
  const fullId = `${CHARACTER_PACKAGE_PREFIX}${slug}`;
  return <label className="studio-field">Package ID<div className="studio-package-id"><span className="studio-package-prefix" aria-label="Locked package namespace">{CHARACTER_PACKAGE_PREFIX}</span><input aria-label="Character package slug" value={slug} placeholder="sabai-sompoo" onChange={(event) => onChange?.(`${CHARACTER_PACKAGE_PREFIX}${normalizeCharacterPackageSlug(event.target.value)}`)} /></div><small className="studio-package-id-full">{fullId}</small></label>;
}

function Field({ label, value, onChange, readOnly = false, suffix = "" }) {
  return <label className="studio-field">{label}<div className="studio-input-wrap"><input value={value} readOnly={readOnly} onChange={(event) => onChange?.(event.target.value)} />{suffix && <span>{suffix}</span>}</div></label>;
}

function CleanupTuningField({ label, value, onChange, busy = false, help = "" }) {
  const normalized = Math.max(CLEAN_TUNING_MIN, Math.min(CLEAN_TUNING_MAX, Number(value) || 0));
  return <label className="studio-field studio-chroma-field studio-cleanup-tuning-field">
    <span>{label} <b>{Math.round(normalized)}%</b></span>
    <div className="studio-chroma-control">
      <input type="range" min={CLEAN_TUNING_MIN} max={CLEAN_TUNING_MAX} step={CLEAN_TUNING_STEP} value={normalized} disabled={busy} onChange={(event) => onChange?.(event.target.value)} aria-label={label} />
      <input type="number" min={CLEAN_TUNING_MIN} max={CLEAN_TUNING_MAX} step={CLEAN_TUNING_STEP} value={Math.round(normalized)} disabled={busy} onChange={(event) => onChange?.(event.target.value)} aria-label={label + " value"} />
    </div>
    {help ? <small className="studio-cleanup-help">{help}</small> : null}
  </label>;
}

function CleanupFramePreview({ frame, mode, zoom, scale = 1, offsetX = 0, offsetY = 0 }) {
  const [previewFrame, setPreviewFrame] = useState(frame);
  useEffect(() => {
    let cancelled = false;
    if (!frame) { setPreviewFrame(""); return undefined; }

    const normalizedScale = Math.max(CLEAN_SCALE_MIN, Math.min(CLEAN_SCALE_MAX, Number(scale) || 1));
    const normalizedOffsetX = Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(offsetX) || 0));
    const normalizedOffsetY = Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(offsetY) || 0));
    const needsTransform = Math.abs(normalizedScale - 1) > 0.0001 || Math.abs(normalizedOffsetX) > 0.0001 || Math.abs(normalizedOffsetY) > 0.0001;

    (async () => {
      const transformed = needsTransform
        ? await transformFrame(frame, { scale: normalizedScale, offsetX: normalizedOffsetX, offsetY: normalizedOffsetY })
        : frame;
      const value = await qaFrameDataUrl(transformed, mode);
      if (!cancelled) setPreviewFrame(value);
    })().catch(() => {
      if (!cancelled) setPreviewFrame(frame);
    });

    return () => { cancelled = true; };
  }, [frame, mode, scale, offsetX, offsetY]);

  const background = mode === "black" ? "#000"
    : mode === "white" ? "#fff"
      : mode === "gray" ? "#777"
        : mode === "checker"
          ? "conic-gradient(#d6d6d6 25%, #8c8c8c 0 50%, #d6d6d6 0 75%, #8c8c8c 0) 0 / 22px 22px"
          : "#101010";
  return <div className="studio-frame-preview studio-cleanup-preview" style={{ background, overflow: "auto" }}>
    {previewFrame
      ? <img src={previewFrame} alt={mode + " cleanup preview"} style={{ width: zoom + "%", maxHeight: "none", flex: "0 0 auto" }} />
      : <span>No sampled frame</span>}
  </div>;
}

function FinalAnchorPreview({ frame, scale = 1, offsetX = 0, offsetY = 0 }) {
  const [previewFrame, setPreviewFrame] = useState(frame);
  useEffect(() => {
    let cancelled = false;
    if (!frame) { setPreviewFrame(""); return undefined; }

    const normalizedScale = Math.max(CLEAN_SCALE_MIN, Math.min(CLEAN_SCALE_MAX, Number(scale) || 1));
    const normalizedOffsetX = Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(offsetX) || 0));
    const normalizedOffsetY = Math.max(CLEAN_OFFSET_MIN, Math.min(CLEAN_OFFSET_MAX, Number(offsetY) || 0));
    const needsTransform = Math.abs(normalizedScale - 1) > 0.0001 || Math.abs(normalizedOffsetX) > 0.0001 || Math.abs(normalizedOffsetY) > 0.0001;

    (async () => {
      const transformed = needsTransform
        ? await transformFrame(frame, { scale: normalizedScale, offsetX: normalizedOffsetX, offsetY: normalizedOffsetY })
        : frame;
      if (!cancelled) setPreviewFrame(transformed);
    })().catch(() => {
      if (!cancelled) setPreviewFrame(frame);
    });

    return () => { cancelled = true; };
  }, [frame, scale, offsetX, offsetY]);

  return <div className="studio-frame-preview studio-final-anchor-preview">
    {previewFrame ? <img src={previewFrame} alt="Final anchored 512 by 512 animation preview" /> : <span>No sampled frame</span>}
    <i className="studio-anchor-guide studio-anchor-guide-x" aria-hidden="true" />
    <i className="studio-anchor-guide studio-anchor-guide-y" aria-hidden="true" />
    <i className="studio-anchor-guide studio-anchor-guide-baseline" aria-hidden="true" />
  </div>;
}

function FramePreview({ frame }) {
  return <div className="studio-frame-preview">{frame ? <img src={frame} alt="Animation frame preview" /> : <span>No sampled frame</span>}<div className="studio-baseline" /></div>;
}

createRoot(document.getElementById("root")).render(<StrictMode><App /></StrictMode>);


