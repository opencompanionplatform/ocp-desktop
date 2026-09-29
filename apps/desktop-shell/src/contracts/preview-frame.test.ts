import { describe, expect, it } from "vitest";

import type { RuntimePreview } from "../../electron/runtime-bridge";
import { buildPreviewFrameSource, previewFallbackText } from "./preview-frame";

const SAFE_PREVIEW: RuntimePreview = {
  status: "playing",
  errorCode: "",
  packageId: "character.scifi",
  version: "2.0.0",
  clips: ["idle", "wave"],
  selectedAnimation: "wave",
  isPlaying: true,
  loop: true,
  speed: 1,
  framePngBase64: "aGVsbG8=",
  frameWidth: 96,
  frameHeight: 128,
};

describe("renderer preview frame boundary", () => {
  it("renders only a bounded PNG data URL for the selected Runtime preview", () => {
    expect(buildPreviewFrameSource(SAFE_PREVIEW, true)).toBe("data:image/png;base64,aGVsbG8=");
    expect(buildPreviewFrameSource(SAFE_PREVIEW, false)).toBe("");
    expect(buildPreviewFrameSource({ ...SAFE_PREVIEW, framePngBase64: "javascript:alert(1)" }, true)).toBe("");
    expect(buildPreviewFrameSource({ ...SAFE_PREVIEW, framePngBase64: "x".repeat(262_145) }, true)).toBe("");
    expect(buildPreviewFrameSource({ ...SAFE_PREVIEW, frameWidth: 513 }, true)).toBe("");
  });

  it("uses safe unavailable and failed presentation text without optimistic success", () => {
    expect(previewFallbackText({ ...SAFE_PREVIEW, status: "loading", framePngBase64: "", frameWidth: 0, frameHeight: 0 }, true)).toBe("Preparing Runtime preview…");
    expect(previewFallbackText({ ...SAFE_PREVIEW, status: "failed", errorCode: "package-not-installed", framePngBase64: "", frameWidth: 0, frameHeight: 0 }, true)).toBe("Preview unavailable: package-not-installed");
    expect(previewFallbackText(SAFE_PREVIEW, false)).toBe("Preparing Runtime preview…");
  });
});
