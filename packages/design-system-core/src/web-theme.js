export const WEB_THEME_STORAGE_KEY = "ocp.web.theme.v1";
export const webThemePreferences = ["system", "light", "dark"];

export function normalizeWebTheme(value) {
  return webThemePreferences.includes(value) ? value : "system";
}

export function resolveWebTheme(preference, prefersDark = false) {
  const normalized = normalizeWebTheme(preference);
  return normalized === "system" ? (prefersDark ? "dark" : "light") : normalized;
}

export function readStoredWebTheme(storage = globalThis.localStorage) {
  try {
    return normalizeWebTheme(storage?.getItem(WEB_THEME_STORAGE_KEY));
  } catch {
    return "system";
  }
}

export function primeWebTheme(preference, options = {}) {
  const root = options.root ?? globalThis.document?.documentElement;
  const matchMedia = options.matchMedia ?? globalThis.window?.matchMedia?.bind(globalThis.window);
  const normalized = normalizeWebTheme(preference);
  const media = matchMedia ? matchMedia("(prefers-color-scheme: dark)") : null;
  const effective = resolveWebTheme(normalized, Boolean(media?.matches));
  if (root) {
    root.dataset.ocpThemePreference = normalized;
    root.dataset.ocpTheme = effective;
    root.style.colorScheme = effective;
  }
  return { preference: normalized, effective, media };
}

export function applyWebThemePreference(preference, options = {}) {
  const root = options.root ?? globalThis.document?.documentElement;
  const matchMedia = options.matchMedia ?? globalThis.window?.matchMedia?.bind(globalThis.window);
  const normalized = normalizeWebTheme(preference);
  const media = matchMedia ? matchMedia("(prefers-color-scheme: dark)") : null;

  const apply = () => {
    primeWebTheme(normalized, { root, matchMedia: media ? () => media : undefined });
  };

  apply();
  if (normalized !== "system" || !media) return () => undefined;

  const onChange = () => apply();
  if (typeof media.addEventListener === "function") media.addEventListener("change", onChange);
  else if (typeof media.addListener === "function") media.addListener(onChange);

  return () => {
    if (typeof media.removeEventListener === "function") media.removeEventListener("change", onChange);
    else if (typeof media.removeListener === "function") media.removeListener(onChange);
  };
}
