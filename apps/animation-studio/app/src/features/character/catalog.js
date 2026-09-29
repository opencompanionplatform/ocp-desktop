export const SUPPORTED_PLAYBACK_FPS = [8, 12, 16];
export const DEFAULT_SOURCE_DURATION = 4;
export const MAX_SPRITE_FRAMES = 64;

// Character/2 does not require every animation to have the same physical frame
// count. The authoring defaults below preserve up to the first 4 seconds of a
// source clip and choose a playback rate by motion complexity. Frame count is
// always derived from duration * FPS and is capped by Studio QC at 64 frames
// (8x8 at 512x512 = 4096x4096).
export const STANDARD_ANIMATION_PROFILES = {
  idle: { duration: 4, fps: 8, loop: true },
  appear: { duration: 4, fps: 12, loop: false },
  disappear: { duration: 4, fps: 12, loop: false },
  angry: { duration: 4, fps: 8, loop: true },
  happy: { duration: 4, fps: 8, loop: true },
  sad: { duration: 4, fps: 8, loop: true },
  surprised: { duration: 4, fps: 8, loop: true },
  speak: { duration: 4, fps: 8, loop: true },
  think: { duration: 4, fps: 8, loop: true },
  wake: { duration: 4, fps: 12, loop: false },
  sleep: { duration: 4, fps: 8, loop: true },
  sit: { duration: 4, fps: 12, loop: false },
  jump: { duration: 4, fps: 12, loop: true },
  fall: { duration: 4, fps: 12, loop: true },
  land: { duration: 4, fps: 12, loop: false },
  climb_up: { duration: 4, fps: 12, loop: true },
  climb_down: { duration: 4, fps: 12, loop: true },
  hang: { duration: 4, fps: 8, loop: true },
  walk_left: { duration: 4, fps: 12, loop: true },
  walk_right: { duration: 4, fps: 12, loop: true },
  wave: { duration: 4, fps: 12, loop: true }
};

// Optional semantic/interaction clips are understood by Runtime but are never
// required for backward compatibility. Older Bible/Sabai packages can keep
// generic climb/hang artwork and no drag-release transition. New characters
// may add authored left/right climb clips when mirroring would reverse text,
// logos, asymmetric costumes, equipment, or vehicle markings.
export const OPTIONAL_ANIMATION_PROFILES = {
  climb_top: { duration: 4, fps: 12, loop: false },
  climb_up_left: { duration: 4, fps: 12, loop: true },
  climb_up_right: { duration: 4, fps: 12, loop: true },
  climb_down_left: { duration: 4, fps: 12, loop: true },
  climb_down_right: { duration: 4, fps: 12, loop: true },
  hang_left: { duration: 4, fps: 8, loop: true },
  hang_right: { duration: 4, fps: 8, loop: true },
  drag_hold: { duration: 4, fps: 8, loop: true },
  drag_release: { duration: 0.25, fps: 12, loop: false }
};

export const CUSTOM_ANIMATION_PROFILE = { duration: 4, fps: 12, loop: false };
export const ANIMATION_PROFILES = { ...STANDARD_ANIMATION_PROFILES, ...OPTIONAL_ANIMATION_PROFILES };
export const ANIMATION_NAMES = Object.keys(STANDARD_ANIMATION_PROFILES);
export const OPTIONAL_ANIMATION_NAMES = Object.keys(OPTIONAL_ANIMATION_PROFILES);
export const BUILTIN_ANIMATION_NAMES = [...ANIMATION_NAMES, ...OPTIONAL_ANIMATION_NAMES];

export function animationProfileFor(name) {
  return ANIMATION_PROFILES[name] ?? CUSTOM_ANIMATION_PROFILE;
}

export function framesFor(profile) {
  return Math.max(1, Math.round(Number(profile.duration) * Number(profile.fps)));
}

export function labelFor(name) {
  return name.replace(/[_-]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function normalizeSourceName(name) {
  return name.toLowerCase().replace(/\.[^.]+$/, "").replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

export function inferAnimationName(fileName, candidates = BUILTIN_ANIMATION_NAMES) {
  const normalized = normalizeSourceName(fileName);
  const aliases = [
    ["walking_left", "walk_left"],
    ["walking_right", "walk_right"],
    ["waving_greeting", "wave"],
    ["speaking", "speak"],
    ["peaking_2", "speak"],
    ["sitting", "sit"],
    ["sleeping", "sleep"],
    ["waking_up", "wake"],
    ["hanging", "hang"],
    ["climbing_down", "climb_down"],
    ["climbing", "climb_up"],
    ["idle_2", "idle"],
    ["idle", "idle"]
  ];
  for (const [prefix, animation] of aliases) if (normalized.startsWith(prefix)) return animation;
  return [...candidates]
    .sort((left, right) => right.length - left.length)
    .find((animation) => normalized === animation || normalized.startsWith(animation + "_")) ?? null;
}
