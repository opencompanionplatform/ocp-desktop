import { ChevronDown, Cloud, Library, LogOut, MonitorSmartphone, UserRound } from "lucide-react";
import { useEffect, useRef, useState, type ReactElement } from "react";

import type { RuntimeSnapshot } from "../../electron/runtime-bridge";
import type { LocaleName } from "../contracts/appearance";
import { translate } from "../i18n";

type Props = Readonly<{
  runtime: RuntimeSnapshot | null;
  locale: LocaleName;
  storeAvailable: boolean;
  compact?: boolean;
}>;

export function AccountControl({ runtime, locale, storeAvailable, compact = false }: Props): ReactElement {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const account = runtime?.account;
  const signedIn = account?.signedIn === true;
  const label = account?.email || account?.userId || translate(locale, "account.account", "Account");
  const initial = label.trim().slice(0, 1).toUpperCase() || "U";
  const cloudSyncStatus = runtime?.cloud?.sync.status;
  const cloudSyncLabel = cloudSyncStatus === "syncing"
    ? translate(locale, "library.syncing", "Syncing…")
    : cloudSyncStatus === "synced"
      ? translate(locale, "library.sync.synced", "Synced")
      : cloudSyncStatus === "error"
        ? translate(locale, "library.sync.error", "Sync error")
        : account?.deviceId
          ? translate(locale, "account.sync_ready", "Ready")
          : translate(locale, "account.device_pending", "Device registration pending");

  useEffect(() => {
    if (!open) return;
    const onPointer = (event: PointerEvent): void => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent): void => { if (event.key === "Escape") setOpen(false); };
    document.addEventListener("pointerdown", onPointer);
    document.addEventListener("keydown", onKey);
    return () => { document.removeEventListener("pointerdown", onPointer); document.removeEventListener("keydown", onKey); };
  }, [open]);

  const openAccount = (): void => {
    setOpen(false);
    void window.ocpShell.openAccount(false).catch(() => undefined);
  };
  const openSignIn = (): void => {
    setOpen(false);
    void window.ocpShell.openAccount(true).catch(() => undefined);
  };
  const signOut = (): void => {
    if (!signedIn || busy) return;
    setBusy(true);
    setOpen(false);
    void window.ocpShell.sendRuntimeCommand({ type: "account.sign-out" }).catch(() => undefined).finally(() => setBusy(false));
  };

  if (!signedIn) {
    return <button className={`account-sign-in ${compact ? "is-compact" : ""}`} disabled={!storeAvailable || busy} onClick={openSignIn} title={!storeAvailable ? translate(locale, "account.store_unavailable", "OCP Store is unavailable") : undefined} type="button">
      <UserRound size={16} />
      {!compact && translate(locale, "account.sign_in", "Sign in")}
    </button>;
  }

  return <div className={`account-control ${compact ? "is-compact" : ""}`} ref={rootRef}>
    <button aria-expanded={open} aria-haspopup="menu" className="account-trigger" onClick={() => setOpen((value) => !value)} type="button">
      <span className="account-avatar">{initial}</span>
      {!compact && <span className="account-label">{label}</span>}
      <ChevronDown className={open ? "is-open" : ""} size={14} />
    </button>
    {open && <div className="account-menu" role="menu">
      <div className="account-menu-identity"><span className="account-avatar">{initial}</span><div><strong>{label}</strong><small>{translate(locale, "account.cloud_connected", "OCP Cloud account")}</small></div></div>
      <button onClick={openAccount} role="menuitem" type="button"><UserRound size={16} />{translate(locale, "account.my_account", "My Account")}</button>
      <button onClick={() => { setOpen(false); void window.ocpShell.openView("library"); }} role="menuitem" type="button"><Library size={16} />{translate(locale, "account.my_library", "My Library")}</button>
      <div className="account-menu-status"><Cloud size={16} /><span>{translate(locale, "account.cloud_sync", "Cloud Sync")}<small>{cloudSyncLabel}</small></span></div>
      <button onClick={openAccount} role="menuitem" type="button"><MonitorSmartphone size={16} />{translate(locale, "account.devices", "Devices")}</button>
      <div className="account-menu-separator" />
      <button className="danger" disabled={busy} onClick={signOut} role="menuitem" type="button"><LogOut size={16} />{translate(locale, "account.sign_out", "Sign out")}</button>
    </div>}
  </div>;
}
