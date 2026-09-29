import { MIN_WINDOW_SIZE } from "./window-state";
import type { ShellView } from "../src/contracts/shell-intent";

export const nativeShellViews = ["home", "characters", "chat"] as const;
export type NativeShellView = (typeof nativeShellViews)[number];

export const windowTitles: Record<NativeShellView, string> = {
  home: "คู่หูบนหน้าจอ — OCP Desktop Shell",
  characters: "คู่หูบนหน้าจอ — OCP Desktop Shell",
  chat: "คู่หูบนหน้าจอ — OCP Desktop Shell",
};

export const windowMinimums: Record<NativeShellView, Readonly<{ width: number; height: number }>> = {
  home: { width: 840, height: 600 },
  characters: MIN_WINDOW_SIZE,
  chat: { width: 560, height: 500 },
};

export function resolveNativeShellView(view: ShellView): NativeShellView {
  if (view === "settings" || view === "updates") return "home";
  if (view === "library") return "characters";
  return view;
}

export function viewUsesRuntimePreviewMedia(view: NativeShellView): boolean {
  // Character Manager and Chat both render the authoritative Runtime preview.
  // Home/Control Center does not need multi-frame base64 media.
  return view === "characters" || view === "chat";
}

export function windowStateFileName(view: NativeShellView): string {
  return `desktop-shell-window-${view}.json`;
}
