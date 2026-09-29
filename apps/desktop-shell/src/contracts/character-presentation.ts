import type { RuntimePreview } from "../../electron/runtime-bridge";
import type { RuntimeChatPresentationState } from "../../electron/runtime-bridge";

export function characterInitials(name: string): string {
  const words = name.trim().split(/\s+/u).filter(Boolean);
  if (words.length === 0) return "OC";
  const characters = words.length > 1
    ? [Array.from(words[0])[0], Array.from(words[1])[0]]
    : Array.from(words[0]).slice(0, 2);
  return characters.join("").toLocaleUpperCase();
}

export function cloudCharacterThumbnailUrl(value: string): string {
  const raw = value.trim();
  if (!raw) return "";
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.username || url.password) return "";
    return url.toString();
  } catch {
    return "";
  }
}


export function characterDisplayName(name: string, packageId: string): string {
  const normalizedName = name.trim();
  const normalizedPackageId = packageId.trim();
  const packageSuffix = normalizedPackageId.replace(/^character\./iu, "");
  const nameLooksLikeIdentity = normalizedName.length === 0
    || normalizedName.toLocaleLowerCase() === normalizedPackageId.toLocaleLowerCase()
    || normalizedName.toLocaleLowerCase() === packageSuffix.toLocaleLowerCase()
    || normalizedName.toLocaleLowerCase().startsWith("character.");
  if (!nameLooksLikeIdentity) return normalizedName;

  const words = packageSuffix.split(/[._-]+/u).filter(Boolean);
  if (words.length === 0) return normalizedName || normalizedPackageId || "Character";
  return words.map((word) => {
    const lower = word.toLocaleLowerCase();
    if (lower === "scifi") return "Sci-Fi";
    if (lower === "ai") return "AI";
    return lower.charAt(0).toLocaleUpperCase() + lower.slice(1);
  }).join(" ");
}

export function animationGlyph(name: string): string {
  const normalized = name.trim().toLocaleLowerCase().replace(/[\s-]+/gu, "_");
  if (normalized === "idle") return "●";
  if (normalized.includes("walk_left")) return "↙";
  if (normalized.includes("walk_right")) return "↘";
  if (normalized.includes("wave")) return "⌁";
  if (normalized.includes("happy")) return "✦";
  if (normalized.includes("sad")) return "◡";
  if (normalized.includes("sleep")) return "☾";
  if (normalized.includes("surpris")) return "!";
  return "◇";
}

export function previewStatusLabel(status: RuntimePreview["status"], selectedAnimation: string): string {
  if (status === "playing") return `Previewing: ${selectedAnimation || "animation"}`;
  if (status === "paused") return `Paused: ${selectedAnimation || "animation"}`;
  if (status === "ready") return `Ready: ${selectedAnimation || "animation"}`;
  if (status === "failed") return "Preview unavailable";
  return "Preparing preview";
}

export function visibleAnimationShortcuts(
  clips: readonly string[],
  selectedAnimation: string,
  limit = 6,
): readonly string[] {
  const boundedLimit = Math.max(0, Math.floor(limit));
  if (boundedLimit === 0) return [];
  const visible = clips.slice(0, boundedLimit);
  if (visible.includes(selectedAnimation) || !clips.includes(selectedAnimation)) return visible;
  return [...visible.slice(0, -1), selectedAnimation];
}

export function chatAnimationForPresentation(
  state: RuntimeChatPresentationState,
  clips: readonly string[],
  fallback = "",
): string {
  const normalized = new Map(clips.map((clip) => [clip.trim().toLocaleLowerCase().replace(/[\s-]+/gu, "_"), clip]));
  const candidates = state === "talk"
    ? ["talk", "speak", "speaking"]
    : state === "think"
      ? ["think", "thinking"]
      : ["idle"];
  for (const candidate of candidates) {
    const match = normalized.get(candidate);
    if (match) return match;
  }
  if (clips.includes(fallback)) return fallback;
  return clips[0] ?? "";
}
