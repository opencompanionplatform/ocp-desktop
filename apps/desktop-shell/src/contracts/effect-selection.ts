import type { RuntimeCommandResult } from "../../electron/runtime-bridge";

export function effectSelectionOutcome(
  result: Pick<RuntimeCommandResult, "status"> | undefined,
  sameCharacter: boolean,
  previewReady: boolean,
): "wait" | "discard" | "failed" | "preview" {
  if (!sameCharacter) return "discard";
  if (result?.status === "failed") return "failed";
  return result?.status === "succeeded" && previewReady ? "preview" : "wait";
}
