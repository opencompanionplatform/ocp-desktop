import type { NativeShellView } from "./window-configuration";

export type ChatWindowPresentationState = Readonly<{
  view: NativeShellView;
  visible: boolean;
  focused: boolean;
  minimized: boolean;
}>;

export function isCharacterPreviewActive(state: ChatWindowPresentationState): boolean {
  // Character Manager owns the shared Runtime preview only while it is the
  // foreground editing surface. If Chat is brought to the front while the
  // manager remains visible behind it, Chat must be allowed to take ownership
  // so idle/think/speak can drive the companion preview.
  return state.view === "characters" && state.visible && state.focused && !state.minimized;
}

export function isChatPresentationActive(state: ChatWindowPresentationState, characterPreviewActive = false, closing = false): boolean {
  // Runtime exposes one authenticated preview channel shared by Chat and the
  // Character Manager. Only the foreground Character Manager owns that editing
  // channel; once Chat comes to the front it owns idle/think/talk presentation.
  // A BrowserWindow remains technically visible for a short interval after its
  // close event starts. Treat that teardown interval as inactive so blur/hide
  // callbacks cannot reacquire Chat ownership after the close fast path released it.
  return !closing && !characterPreviewActive && state.view === "chat" && state.visible && !state.minimized;
}

export function shouldSynchronizeChatPresentation(
  expectedActive: boolean,
  lastSubmittedActive: boolean | null,
  runtimeOwner: "chat" | "native" | undefined,
  nowMs: number,
  lastSubmitAtMs: number,
  repairDelayMs = 150,
): boolean {
  if (lastSubmittedActive !== expectedActive) return true;
  if (runtimeOwner === undefined) return false;
  const runtimeActive = runtimeOwner === "chat";
  if (runtimeActive === expectedActive) return false;
  return nowMs - lastSubmitAtMs >= repairDelayMs;
}

export function isCompanionSuppressionActive(state: ChatWindowPresentationState): boolean {
  // Full management surfaces are safe zones for the floating native companion.
  // Character Manager already has an isolated inline preview, so keeping the
  // live desktop companion visible only causes it to cover Level/Skills/actions.
  // Activation still happens immediately in Runtime; the selected companion is
  // restored as soon as the manager closes or minimizes.
  return (state.view === "home" || state.view === "characters") && state.visible && !state.minimized;
}
