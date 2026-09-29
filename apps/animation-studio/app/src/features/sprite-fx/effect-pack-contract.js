export const EFFECT_SLOT_ORDER = ["bodyAura", "groundRune", "levelUpBurst"];
export const EFFECT_BOND_RANKS = ["stranger", "friend", "close-friend", "partner", "best-companion"];

export const EFFECT_SLOT_META = Object.freeze({
  bodyAura: Object.freeze({
    label: "Body Aura",
    anchor: "character-center",
    layer: "back-aura",
    preset: "halo",
    looped: true,
    fps: 30,
    durationMs: 3600,
    intensity: 72,
    speedPermille: 620,
    tint: "#22D3EE",
  }),
  groundRune: Object.freeze({
    label: "Ground Rune",
    anchor: "character-feet",
    layer: "ground-rune",
    preset: "rune",
    looped: true,
    fps: 30,
    durationMs: 4800,
    intensity: 82,
    speedPermille: 520,
    tint: "#60A5FA",
  }),
  levelUpBurst: Object.freeze({
    label: "Level-Up Burst",
    anchor: "character-feet-bottom",
    layer: "front-fx",
    preset: "burst",
    looped: false,
    fps: 30,
    durationMs: 1200,
    intensity: 100,
    speedPermille: 1100,
    tint: "#FACC15",
  }),
});
