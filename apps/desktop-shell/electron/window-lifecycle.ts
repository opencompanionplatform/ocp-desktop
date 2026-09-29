export type CharacterRuntimeState = Readonly<{ connected: boolean; characterCount: number }>;

export const CHAT_WARM_RECLAIM_MS = 60_000;

export function isWarmShellLaunch(args: readonly string[]): boolean {
  return args.includes("--ocp-warm=1");
}

/**
 * Explicit shutdown signal sent by the installed Runtime supervisor after the
 * native host has completed the user-requested shutdown handshake. This is
 * intentionally separate from transient Runtime owner loss, which remains
 * recoverable so a restarted Runtime can rebind the existing primary shell.
 */
export function isRuntimeOwnerShutdownLaunch(args: readonly string[]): boolean {
  return args.includes("--ocp-exit=runtime-owner-shutdown");
}

export function shouldKeepWindowWarmOnClose(_runtimeOwned: boolean, _appQuitting: boolean, _view: string): boolean {
  // Closing Chat must release presentation ownership immediately. Keeping the
  // BrowserWindow warm made a hidden Chat remain an ownership participant and
  // could leave the native companion hidden while Runtime commands backed up.
  return false;
}

export function shouldReclaimWarmWindow(
  runtimeOwned: boolean,
  appQuitting: boolean,
  view: string,
  warm: boolean,
  visible: boolean,
): boolean {
  return runtimeOwned && !appQuitting && view === "chat" && warm && !visible;
}

/**
 * Runtime-owned warm windows are presentation caches, not user-visible windows.
 * OS/app activation must not reveal them; only an explicit OCP menu/navigation
 * intent is allowed to promote a warm window to visible presentation.
 */
export function shouldRevealWindowOnAppActivate(runtimeOwned: boolean, warm: boolean): boolean {
  return !runtimeOwned || !warm;
}

/**
 * Characters remains available as a recovery surface while Runtime reconnects.
 * A temporary owner loss or an empty character library must never close the
 * Electron window; the renderer will show the unavailable/empty state instead.
 */
export function shouldCloseCharactersWindow(_previous: CharacterRuntimeState | null, _next: CharacterRuntimeState): boolean {
  return false;
}

/**
 * Runtime-authenticated Desktop Shell stays open across transient owner loss.
 * Explicit user/app shutdown remains the only normal process-exit authority.
 */
export function shouldQuitRuntimeOwnedShell(_runtimeOwned: boolean, _observedConnected: boolean, _ownerAvailable: boolean): boolean {
  // A Runtime restart can overlap Electron's single-instance handoff. Quitting
  // the primary on owner loss can strand the new Runtime after its secondary
  // Electron has already delivered the fresh bridge arguments and exited.
  // Keep the shell process alive in unavailable mode; an explicit user/app
  // shutdown remains the process-exit authority.
  return false;
}
