import type { RuntimePreview } from "../../electron/runtime-bridge";

const MAX_FRAME_BASE64_LENGTH = 262_144;
const MAX_FRAME_DIMENSION = 512;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const RENDERABLE_STATUSES = new Set<RuntimePreview["status"]>(["ready", "playing", "paused"]);

export function buildPreviewFrameSource(preview: RuntimePreview, identityMatches: boolean): string {
  if (!identityMatches || !RENDERABLE_STATUSES.has(preview.status)) return "";
  if (
    preview.frameWidth < 1 || preview.frameWidth > MAX_FRAME_DIMENSION ||
    preview.frameHeight < 1 || preview.frameHeight > MAX_FRAME_DIMENSION ||
    preview.framePngBase64.length === 0 ||
    preview.framePngBase64.length > MAX_FRAME_BASE64_LENGTH ||
    !BASE64_PATTERN.test(preview.framePngBase64)
  ) return "";
  return `data:image/png;base64,${preview.framePngBase64}`;
}

export function previewFallbackText(preview: RuntimePreview, identityMatches: boolean): string {
  if (!identityMatches) return "Preparing Runtime preview…";
  if (preview.status === "failed") {
    return preview.errorCode ? `Preview unavailable: ${preview.errorCode}` : "Preview unavailable";
  }
  if (preview.status === "idle") return "Preview unavailable";
  return "Preparing Runtime preview…";
}
