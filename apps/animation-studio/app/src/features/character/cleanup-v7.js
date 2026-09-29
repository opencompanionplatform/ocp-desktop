function clampChannel(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return null;
  return Math.max(0, Math.min(255, Math.round(numeric)));
}

/** @param {{ red?: number, green?: number, blue?: number } | null | undefined} color */
export function normalizeKeyColor(color) {
  if (!color) return null;
  const red = clampChannel(color.red);
  const green = clampChannel(color.green);
  const blue = clampChannel(color.blue);
  if (red == null || green == null || blue == null) return null;
  return { red, green, blue };
}

export function keyColorToHex(color) {
  const normalized = normalizeKeyColor(color);
  if (!normalized) return "";
  return `#${[normalized.red, normalized.green, normalized.blue]
    .map((channel) => channel.toString(16).padStart(2, "0"))
    .join("")}`.toUpperCase();
}

export function hexToKeyColor(value) {
  const match = /^#?([0-9a-f]{6})$/i.exec(String(value ?? "").trim());
  if (!match) return null;
  const hex = match[1];
  return {
    red: Number.parseInt(hex.slice(0, 2), 16),
    green: Number.parseInt(hex.slice(2, 4), 16),
    blue: Number.parseInt(hex.slice(4, 6), 16),
  };
}

/**
 * Cleanup V7 never injects a fixed chroma color. A user-picked key wins;
 * otherwise the caller may provide the currently detected background key.
 * @param {{ keyColorMode?: string, keyColor?: { red?: number, green?: number, blue?: number } | null }} settings
 * @param {{ red?: number, green?: number, blue?: number } | null} detectedKey
 */
export function resolveCleanupKeyColor(settings = {}, detectedKey = null) {
  const mode = Reflect.get(settings, "keyColorMode") === "picked" ? "picked" : "auto";
  if (mode === "picked") return normalizeKeyColor(Reflect.get(settings, "keyColor"));
  return normalizeKeyColor(detectedKey);
}
