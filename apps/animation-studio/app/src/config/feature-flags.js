function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function readSpriteFxAccess(env, creatorProfile) {
  const mode = text(env?.VITE_SPRITE_FX_MODE || "admin").toLowerCase();
  const normalizedMode = ["off", "admin", "public"].includes(mode) ? mode : "admin";
  const adminPublishers = new Set(
    text(env?.VITE_SPRITE_FX_ADMIN_PUBLISHERS || "ocp.official")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
  );
  const publisherId = text(creatorProfile?.publisherId).toLowerCase();
  const adminAllowed = normalizedMode === "admin" && publisherId.length > 0 && adminPublishers.has(publisherId);
  const visible = normalizedMode === "public" || adminAllowed;
  const cloudRequested = text(env?.VITE_SPRITE_FX_CLOUD).toLowerCase() === "true";
  return {
    mode: normalizedMode,
    visible,
    localBuildEnabled: visible,
    cloudPublishEnabled: cloudRequested && (normalizedMode === "public" || adminAllowed),
    label: normalizedMode === "public" ? "Sprite Sheet FX" : "Sprite Sheet FX · Beta",
  };
}

