// Kept dependency-free because this same contract is compiled into Electron's
// CommonJS main/preload process.  Renderer tokens mirror these allowlists.
export const appearanceThemes = ["solid", "glass", "liquid"] as const;
export const appearanceLocales = ["en", "th"] as const;
export const appearanceFontFamilies = ["system", "inter", "noto-sans-thai", "atkinson"] as const;
export const appearanceTextScales = ["normal", "standard", "comfortable", "large", "extra"] as const;
export type ThemeName = (typeof appearanceThemes)[number];
export type LocaleName = (typeof appearanceLocales)[number];
export type FontFamilyName = (typeof appearanceFontFamilies)[number];
export type TextScaleName = (typeof appearanceTextScales)[number];

export type ShellAppearance = Readonly<{
  theme: ThemeName;
  locale: LocaleName;
  fontFamily: FontFamilyName;
  textScale: TextScaleName;
  reduceMotion: boolean;
}>;

export const DEFAULT_SHELL_APPEARANCE: ShellAppearance = Object.freeze({
  theme: "liquid",
  locale: "en",
  fontFamily: "noto-sans-thai",
  textScale: "standard",
  reduceMotion: false,
});

const KEYS = new Set(["theme", "locale", "fontFamily", "textScale", "reduceMotion"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function sanitizeShellAppearance(value: unknown): ShellAppearance | null {
  if (!isRecord(value) || !Object.keys(value).every((key) => KEYS.has(key))) return null;
  if (!appearanceThemes.includes(value.theme as ThemeName)) return null;
  if (!appearanceLocales.includes(value.locale as LocaleName)) return null;
  if (!appearanceFontFamilies.includes(value.fontFamily as FontFamilyName)) return null;
  if (!appearanceTextScales.includes(value.textScale as TextScaleName)) return null;
  if (typeof value.reduceMotion !== "boolean") return null;
  return {
    theme: value.theme as ThemeName,
    locale: value.locale as LocaleName,
    fontFamily: value.fontFamily as FontFamilyName,
    textScale: value.textScale as TextScaleName,
    reduceMotion: value.reduceMotion,
  };
}
