import { fontFamilyStacks, textScaleValues, themes } from "@ocp/design-system-core";
import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from "react";
import { createPortal } from "react-dom";
import { ArrowDown, ArrowUp, Bell, Bot, ChevronLeft, ChevronRight, CircleDot, EllipsisVertical, Footprints, Gamepad2, Gift, Hand, Heart, Home, ImageOff, Info, ListFilter, LoaderCircle, MessageSquare, Moon, NotebookTabs, PackagePlus, Pause, Play, RefreshCw, Search, Settings as SettingsIcon, Sparkles, Square, Store, Trash2, UsersRound, X, Zap } from "lucide-react";
import { DEFAULT_SHELL_APPEARANCE, type LocaleName, type ShellAppearance } from "./contracts/appearance";
import { controlPageForShellView, type ControlCenterPage, type ControlFontFamily } from "./contracts/control-center";
import type { ShellIntent, ShellView } from "./contracts/shell-intent";
import type { StoreDeepLink } from "./contracts/store-deep-link";
import type { RuntimeSnapshot } from "../electron/runtime-bridge";
import type { OnboardingCompletionReason, OnboardingState } from "../electron/onboarding-state";
import { characterDisplayName, characterInitials, cloudCharacterThumbnailUrl, previewStatusLabel } from "./contracts/character-presentation";
import { buildPreviewFrameSource, previewFallbackText } from "./contracts/preview-frame";
import { effectSelectionOutcome } from "./contracts/effect-selection";
import { ControlCenter } from "./components/ControlCenter";
import { ChatView } from "./components/ChatView";
import { AccountControl } from "./components/AccountControl";
import { FirstRunWizard } from "./components/FirstRunWizard";
import { shouldMigrateExistingLibrary, shouldShowFirstRunWizard } from "./contracts/first-run";
export { ChatView as Chat } from "./components/ChatView";
import { localeFromSettings, translate } from "./i18n";
import ocpBrandIcon from "./assets/ocp-brand.svg";

const labelKeys: Record<ShellView, string> = { home: "view.home", characters: "view.characters", library: "view.library", chat: "view.chat", settings: "view.settings", updates: "view.settings" };
const navLabelKeys: Record<ShellView, string> = { home: "nav.home", characters: "nav.characters", library: "nav.library", chat: "nav.chat", settings: "nav.settings", updates: "nav.settings" };
const navIcons: Record<ShellView, ReactElement> = {
  home: <Home size={16} strokeWidth={1.9} />,
  characters: <UsersRound size={16} strokeWidth={1.9} />,
  library: <Store size={16} strokeWidth={1.9} />,
  chat: <MessageSquare size={16} strokeWidth={1.9} />,
  settings: <SettingsIcon size={16} strokeWidth={1.9} />,
  updates: <RefreshCw size={16} strokeWidth={1.9} />,
};

function AnimationIcon({ name, size = 18 }: Readonly<{ name: string; size?: number }>): ReactElement {
  const key = name.toLowerCase();
  if (key.includes("walk")) return <Footprints size={size} />;
  if (key.includes("climb") || key.includes("jump")) return <ArrowUp size={size} />;
  if (key.includes("fall")) return <ArrowDown size={size} />;
  if (key.includes("sleep")) return <Moon size={size} />;
  if (key.includes("wave")) return <Hand size={size} />;
  if (key.includes("appear") || key.includes("disappear") || key.includes("happy") || key.includes("surprised")) return <Sparkles size={size} />;
  return <CircleDot size={size} />;
}

function CharacterArtwork({
  name,
  remoteUrl = "",
  localPngBase64 = "",
  alt = "",
}: Readonly<{ name: string; remoteUrl?: string; localPngBase64?: string; alt?: string }>): ReactElement {
  const remoteSource = cloudCharacterThumbnailUrl(remoteUrl);
  const localSource = localPngBase64 ? `data:image/png;base64,${localPngBase64}` : "";
  const [failedSources, setFailedSources] = useState<readonly string[]>([]);

  useEffect(() => {
    setFailedSources([]);
  }, [remoteSource, localSource]);

  const source = [remoteSource, localSource].find((candidate) => candidate && !failedSources.includes(candidate)) ?? "";
  if (!source) return <span className="character-artwork-fallback">{characterInitials(name)}</span>;
  return <img alt={alt} loading="lazy" referrerPolicy="no-referrer" src={source} onError={() => setFailedSources((current) => current.includes(source) ? current : [...current, source])} />;
}
const nativeNavigation = ["characters", "chat", "settings"] as const;
const SHORTCUT_PAGE_SIZE = 6;
const controlFontStacks: Record<ControlFontFamily, string> = {
  // Noto Sans Thai is bundled with OCP and is the product baseline. System
  // families remain available as explicit user choices and fallbacks.
  "Noto Sans Thai": '"Noto Sans Thai", "Segoe UI Variable Text", "Segoe UI", "Leelawadee UI", Tahoma, sans-serif',
  Inter: 'Inter, "Leelawadee UI", Tahoma, "Segoe UI", sans-serif',
  "Segoe UI": '"Segoe UI", "Leelawadee UI", Tahoma, sans-serif',
  Tahoma: 'Tahoma, "Leelawadee UI", "Segoe UI", sans-serif',
  "Leelawadee UI": '"Leelawadee UI", Tahoma, "Segoe UI", sans-serif',
  Arial: 'Arial, Tahoma, "Leelawadee UI", "Segoe UI", sans-serif',
};

function Header({ view, locale, runtime, storeAvailable }: Readonly<{ view: ShellView; locale: LocaleName; runtime: RuntimeSnapshot | null; storeAvailable: boolean }>): ReactElement {
  // `home` remains an internal/backward-compatible alias for the Control Center
  // host window. User-facing navigation has one canonical destination: Settings.
  const visibleView: ShellView = view === "home" ? "settings" : view === "library" ? "characters" : view;
  return <header className="topbar">
    <span className="logo" aria-hidden="true"><img alt="" src={ocpBrandIcon} /></span>
    <div className="brand-copy"><strong>{translate(locale, "app.name")}</strong><span>{translate(locale, "app.subtitle")} · {translate(locale, labelKeys[visibleView], visibleView)}</span></div>
    <nav className="shell-nav" aria-label="OCP windows">{nativeNavigation.map((target) => <button aria-current={visibleView === target ? "page" : undefined} className={visibleView === target ? "active" : ""} key={target} onClick={() => void window.ocpShell.openView(target)} type="button"><i aria-hidden="true">{navIcons[target]}</i>{translate(locale, navLabelKeys[target], target)}</button>)}<button className="studio-nav-button" onClick={() => void window.ocpShell.openAnimationStudio().catch(() => undefined)} type="button"><i aria-hidden="true"><NotebookTabs size={16} strokeWidth={1.9} /></i>{locale === "th" ? "สตูดิโอแอนิเมชัน" : "Animation Studio"}</button></nav>
    <div className="topbar-actions"><AccountControl locale={locale} runtime={runtime} storeAvailable={storeAvailable} /><div className="runtime-pill"><i /> {translate(locale, "runtime.active")}</div></div>
  </header>;
}

type EffectSlotName = "bodyAura" | "groundRune" | "levelUpBurst";
type EffectPreviewTuning = Readonly<{
  fps: number;
  startFrame: number;
  endFrame: number;
  scale: number;
  offsetX: number;
  offsetY: number;
  anchor: "character-center" | "character-feet" | "character-feet-bottom" | "character-above-head";
  scaleMode: "character-width" | "character-height" | "native-surface";
}>;

function effectPreviewTuningFromConfig(slot: EffectSlotName, config: Readonly<Record<string, unknown>> | undefined): EffectPreviewTuning {
  const defaults: Record<EffectSlotName, Pick<EffectPreviewTuning, "scale" | "offsetX" | "offsetY" | "anchor" | "scaleMode">> = {
    bodyAura: { scale: 1.12, offsetX: 0, offsetY: -6, anchor: "character-center", scaleMode: "character-height" },
    groundRune: { scale: 1.40, offsetX: 0, offsetY: 0, anchor: "character-feet", scaleMode: "character-width" },
    levelUpBurst: { scale: 1.10, offsetX: 0, offsetY: 0, anchor: "character-feet-bottom", scaleMode: "character-height" },
  };
  const fallback = defaults[slot];
  const frameCount = Math.max(1, Math.min(120, Math.round(Number(config?.frameCount ?? 1))));
  const anchor = ["character-center", "character-feet", "character-feet-bottom", "character-above-head"].includes(String(config?.anchor))
    ? String(config?.anchor) as EffectPreviewTuning["anchor"] : fallback.anchor;
  const scaleMode = ["character-width", "character-height", "native-surface"].includes(String(config?.scaleMode))
    ? String(config?.scaleMode) as EffectPreviewTuning["scaleMode"] : fallback.scaleMode;
  const startFrame = Math.max(0, Math.min(frameCount - 1, Math.round(Number(config?.startFrame ?? 0))));
  const endFrame = Math.max(startFrame, Math.min(frameCount - 1, Math.round(Number(config?.endFrame ?? frameCount - 1))));
  return {
    fps: Math.max(1, Math.min(30, Math.round(Number(config?.fps ?? 12)))),
    startFrame,
    endFrame,
    scale: Math.max(0.25, Math.min(4, Number(config?.scale ?? fallback.scale))),
    offsetX: Math.max(-512, Math.min(512, Number(config?.offsetX ?? fallback.offsetX))),
    offsetY: Math.max(-512, Math.min(512, Number(config?.offsetY ?? fallback.offsetY))),
    anchor,
    scaleMode,
  };
}

function Characters({ runtime, storeAvailable, locale, storeLink, initialTab = "installed", onRetryRuntime }: Readonly<{ runtime: RuntimeSnapshot | null; storeAvailable: boolean; locale: LocaleName; storeLink?: StoreDeepLink | null; initialTab?: "installed" | "library"; onRetryRuntime: () => Promise<boolean> }>): ReactElement {
  const t = useCallback((key: string, fallback?: string, values?: Readonly<Record<string, string | number>>): string => translate(locale, key, fallback, values), [locale]);
  const [tab, setTab] = useState<"installed" | "library">(initialTab);
  const [selectedId, setSelectedId] = useState("");
  const [selectedCloudId, setSelectedCloudId] = useState("");
  const [animationSearch, setAnimationSearch] = useState("");
  const [installNotice, setInstallNotice] = useState("");
  const [installBusy, setInstallBusy] = useState(false);
  const [activationTarget, setActivationTarget] = useState("");
  const [runtimeRetryBusy, setRuntimeRetryBusy] = useState(false);
  const [moreOpen, setMoreOpen] = useState(false);
  const [moreMenuPosition, setMoreMenuPosition] = useState<{ top: number; left: number } | null>(null);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [shortcutPage, setShortcutPage] = useState(0);
  const [previewRequest, setPreviewRequest] = useState<{ animation: string; kind: "select" | "play" } | null>(null);
  const [previewLoadingVisible, setPreviewLoadingVisible] = useState(false);
  const [effectPreviewMode, setEffectPreviewMode] = useState<"" | "all" | "bodyAura" | "groundRune" | "levelUpBurst">("");
  const [previewSidebarTab, setPreviewSidebarTab] = useState<"animations" | "effects">("animations");
  const [effectTuneSlot, setEffectTuneSlot] = useState<EffectSlotName>("bodyAura");
  const [effectTuneDraft, setEffectTuneDraft] = useState<EffectPreviewTuning>(() => effectPreviewTuningFromConfig("bodyAura", undefined));
  const [effectInstallBusy, setEffectInstallBusy] = useState(false);
  const [effectInstallNotice, setEffectInstallNotice] = useState("");
  const [effectProfileNotice, setEffectProfileNotice] = useState("");
  const [uninstallBusy, setUninstallBusy] = useState(false);
  const [pendingUninstall, setPendingUninstall] = useState<{ id: string; packageId: string; version: string; name: string } | null>(null);
  const [lastAnimationByCharacter, setLastAnimationByCharacter] = useState<Record<string, string>>({});
  const requestedPreview = useRef("");
  const moreButtonRef = useRef<HTMLButtonElement | null>(null);
  const requestedRememberedAnimation = useRef("");
  const requestedThumbnailPage = useRef("");
  const previewMediaRecovery = useRef("");
  const appliedStoreLink = useRef("");
  const submit = useCallback((command: Parameters<typeof window.ocpShell.sendRuntimeCommand>[0]): void => { void window.ocpShell.sendRuntimeCommand(command).catch(() => undefined); }, []);
  const characters = runtime?.characters ?? [];
  const cloud = runtime?.cloud;
  const cloudItems = cloud?.library.items.filter((item) => item.productType === "character" && item.entitled && !item.revokedAt) ?? [];
  const selectedCloud = cloudItems.find((item) => item.productId === selectedCloudId) ?? cloudItems[0];
  const selectedCloudInstalled = selectedCloud ? characters.find((character) => character.packageId === selectedCloud.productId) : undefined;
  const cloudDownloadBusy = cloud?.download.status === "authorizing" || cloud?.download.status === "downloading";
  const selected = characters.find((character) => character.packageId === selectedId) ?? characters.find((character) => character.active) ?? characters[0];
  const selectedDisplayName = selected ? characterDisplayName(selected.name, selected.packageId) : "";
  const selectedPackageId = selected?.packageId ?? "";
  const selectedVersion = selected?.version ?? "";
  const selectedIdentity = selectedPackageId && selectedVersion ? `${selectedPackageId}@${selectedVersion}` : "";
  const [pendingEffectSelection, setPendingEffectSelection] = useState<{ id: string; slot: EffectSlotName; character: string } | null>(null);
  const effectSelectionSequence = useRef(0);
  const selectedActivationBusy = activationTarget === selectedIdentity;
  const progressionCompanion = runtime?.progression?.companions.find((companion) => companion.characterId === selectedPackageId);
  const relationshipLevel = Math.max(1, progressionCompanion?.relationship.level ?? 1);
  const relationshipXp = Math.max(0, progressionCompanion?.relationship.xp ?? 0);
  const relationshipCap = runtime?.progression?.levelCap ?? 200;
  const relationshipName = progressionCompanion?.relationship.bondRank?.replaceAll("-", " ") ?? "";
  const canonicalProgress = progressionCompanion?.relationship.progressPermille;
  const relationshipProgress = canonicalProgress === undefined ? 0 : Math.max(0, Math.min(100, canonicalProgress / 10));
  const progressionEffects = runtime?.progression?.effects ?? { levelUpEnabled: true, auraEnabled: false };
  const effectPacks = runtime?.effectPacks;
  const effectTuneConfig = effectPacks?.resolved[effectTuneSlot]?.config;
  const effectTuneUsesFrames = effectTuneConfig?.renderer === "sprite-sheet-2d";
  const effectTuneConfigKey = JSON.stringify(effectTuneConfig ?? {});
  const effectTuneFrameCount = Math.max(1, Math.min(120, Math.round(Number(effectTuneConfig?.frameCount ?? 1))));
  const effectSlots = [
    { id: "bodyAura" as const, labelKey: "characters.body_aura", label: "Body Aura", hintKey: "characters.body_aura_hint", hint: "Animated aura behind the companion" },
    { id: "groundRune" as const, labelKey: "characters.ground_rune", label: "Ground Rune", hintKey: "characters.ground_rune_hint", hint: "Animated rune circle under the companion" },
    { id: "levelUpBurst" as const, labelKey: "characters.level_up_burst", label: "Level-Up Burst", hintKey: "characters.level_up_burst_hint", hint: "One-shot effect when the relationship level increases" },
  ];
  const hasResolvedEffects = effectSlots.some((slot) => Boolean(effectPacks?.resolved[slot.id]));
  const skillLevels = new Map((progressionCompanion?.skills ?? []).map((skill) => [skill.skillId.toLocaleLowerCase(), skill.level]));
  const dashboardSkills = [
    { id: "assistant", label: "Assistant", level: skillLevels.get("assistant") ?? 0, icon: Bot },
    { id: "notes", label: "Notes", level: skillLevels.get("notes") ?? 0, icon: NotebookTabs },
    { id: "reminder", label: "Reminder", level: skillLevels.get("reminder") ?? 0, icon: Bell },
    { id: "entertainment", label: "Entertainment", level: skillLevels.get("entertainment") ?? 0, icon: Gamepad2 },
  ];

  useEffect(() => { setTab(initialTab); }, [initialTab]);
  useEffect(() => { setEffectTuneDraft(effectPreviewTuningFromConfig(effectTuneSlot, effectTuneConfig)); }, [effectTuneSlot, effectTuneConfigKey]);
  useEffect(() => {
    if (!pendingEffectSelection) return;
    const result = runtime?.commandResults.find((item) => item.id === pendingEffectSelection.id);
    const preview = runtime?.preview;
    const ready = Boolean(preview && `${preview.packageId}@${preview.version}` === selectedIdentity && ["ready", "playing", "paused"].includes(preview.status));
    const outcome = effectSelectionOutcome(result, pendingEffectSelection.character === selectedIdentity, ready);
    if (outcome === "wait") return;
    setPendingEffectSelection(null);
    if (outcome === "failed") {
      setEffectProfileNotice(t("characters.effect_selection_failed", "Could not select this pack. Please try again."));
    } else if (outcome === "preview") {
      setEffectTuneSlot(pendingEffectSelection.slot);
      setEffectPreviewMode(pendingEffectSelection.slot);
      void window.ocpShell.sendRuntimeCommand({ type: "effect-pack.preview", mode: pendingEffectSelection.slot }).catch(() => {
        setEffectProfileNotice(t("characters.effect_selection_failed", "Could not select this pack. Please try again."));
      });
    }
  }, [pendingEffectSelection, runtime?.commandResults, runtime?.preview, selectedIdentity, t]);
  useEffect(() => {
    if (!pendingEffectSelection) return;
    const timer = window.setTimeout(() => {
      setPendingEffectSelection(null);
      setEffectProfileNotice(t("characters.effect_selection_failed", "Could not select this pack. Please try again."));
    }, 15000);
    return () => window.clearTimeout(timer);
  }, [pendingEffectSelection, t]);
  useEffect(() => {
    if (!activationTarget) return;
    const active = characters.find((character) => character.active);
    if (active && `${active.packageId}@${active.version}` === activationTarget) setActivationTarget("");
  }, [activationTarget, characters]);
  useEffect(() => {
    if (!activationTarget) return;
    const target = activationTarget;
    const timer = window.setTimeout(() => {
      setActivationTarget((current) => current === target ? "" : current);
    }, 15_000);
    return () => window.clearTimeout(timer);
  }, [activationTarget]);
  useEffect(() => {
    if (!pendingUninstall) return;
    const stillInstalled = characters.some((character) => character.packageId === pendingUninstall.packageId && character.version === pendingUninstall.version);
    const result = runtime?.commandResults.find((item) => item.id === pendingUninstall.id && item.type === "character.uninstall");
    if (!stillInstalled || result?.status === "succeeded") {
      if (selectedId === pendingUninstall.packageId) setSelectedId("");
      setInstallNotice(t("characters.uninstall_succeeded", "Removed {name} from this computer.", { name: pendingUninstall.name }));
      setPendingUninstall(null);
      return;
    }
    if (result?.status === "failed") {
      setInstallNotice(t("characters.uninstall_failed", "Unable to uninstall {name}. Please try again.", { name: pendingUninstall.name }) + (result.errorCode ? ` (${result.errorCode})` : ""));
      setPendingUninstall(null);
    }
  }, [characters, pendingUninstall, runtime?.commandResults, selectedId, t]);
  useEffect(() => {
    if (!pendingUninstall) return;
    const pending = pendingUninstall;
    const timer = window.setTimeout(() => {
      setPendingUninstall(null);
      setInstallNotice(t("characters.uninstall_failed", "Unable to uninstall {name}. Please try again.", { name: pending.name }) + " (timeout)");
    }, 15_000);
    return () => window.clearTimeout(timer);
  }, [pendingUninstall, t]);
  useEffect(() => {
    if (!storeLink) return;
    const identity = `${storeLink.packageId}@${storeLink.version}`;
    if (appliedStoreLink.current === identity) return;
    const installedMatch = characters.find((character) => character.packageId === storeLink.packageId && character.version === storeLink.version);
    if (installedMatch) {
      appliedStoreLink.current = identity;
      setTab("installed");
      setSelectedId(installedMatch.packageId);
      return;
    }
    const cloudMatch = cloudItems.find((item) => item.productId === storeLink.packageId && (!item.latestVersion || item.latestVersion === storeLink.version));
    if (cloudMatch) {
      appliedStoreLink.current = identity;
      setTab("library");
      setSelectedCloudId(cloudMatch.productId);
    }
  }, [characters, cloudItems, storeLink]);
  useEffect(() => {
    if (selectedCloud?.productId && selectedCloud.productId !== selectedCloudId) setSelectedCloudId(selectedCloud.productId);
  }, [selectedCloud, selectedCloudId]);
  useEffect(() => {
    if (selectedPackageId && selectedPackageId !== selectedId) setSelectedId(selectedPackageId);
  }, [selectedId, selectedPackageId]);
  useEffect(() => {
    if (tab !== "installed" || !selectedPackageId || !selectedVersion) return;
    const identity = `${selectedPackageId}@${selectedVersion}`;
    requestedPreview.current = identity;
    requestedThumbnailPage.current = "";
    setPreviewRequest(null);
    setEffectPreviewMode("");
    setShortcutPage(0);
    submit({ type: "character.preview.open", packageId: selectedPackageId, version: selectedVersion });
    return () => {
      // Character-card selection clears requestedPreview before React runs this
      // cleanup. In that case the next character's open command owns replacing
      // the old Runtime preview; do not enqueue a stale close that can race it.
      if (requestedPreview.current !== identity) return;
      requestedPreview.current = "";
      submit({ type: "character.preview.close", packageId: selectedPackageId, version: selectedVersion });
    };
  }, [selectedPackageId, selectedVersion, submit, tab]);
  useEffect(() => {
    if (!runtime || !selected) return;
    const previewState = runtime.preview;
    const identity = `${selected.packageId}@${selected.version}`;
    const remembered = lastAnimationByCharacter[identity];
    const canRestore = previewState.packageId === selected.packageId
      && previewState.version === selected.version
      && ["ready", "playing", "paused"].includes(previewState.status)
      && Boolean(remembered)
      && previewState.clips.includes(remembered);
    if (!canRestore || previewState.selectedAnimation === remembered) {
      requestedRememberedAnimation.current = "";
      return;
    }
    const requestKey = `${identity}:${remembered}`;
    if (requestedRememberedAnimation.current === requestKey) return;
    requestedRememberedAnimation.current = requestKey;
    submit({ type: "character.preview.select", packageId: selected.packageId, version: selected.version, animation: remembered });
  }, [lastAnimationByCharacter, runtime, selected, submit]);
  useEffect(() => {
    if (!runtime || !selectedPackageId || !selectedVersion) return;
    const previewState = runtime.preview;
    if (previewState.packageId !== selectedPackageId || previewState.version !== selectedVersion || !["ready", "playing", "paused"].includes(previewState.status)) return;
    const pageCount = Math.max(1, Math.ceil(previewState.clips.length / SHORTCUT_PAGE_SIZE));
    const normalizedPage = Math.min(shortcutPage, pageCount - 1);
    if (normalizedPage !== shortcutPage) {
      setShortcutPage(normalizedPage);
      return;
    }
    const requestKey = `${selectedPackageId}@${selectedVersion}:${normalizedPage}`;
    if (requestedThumbnailPage.current === requestKey) return;
    requestedThumbnailPage.current = requestKey;
    submit({ type: "character.preview.thumbnail-page", packageId: selectedPackageId, version: selectedVersion, offset: normalizedPage * SHORTCUT_PAGE_SIZE });
  }, [runtime, selectedPackageId, selectedVersion, shortcutPage, submit]);
  useEffect(() => {
    if (!previewRequest) {
      setPreviewLoadingVisible(false);
      return;
    }
    const timer = window.setTimeout(() => setPreviewLoadingVisible(true), 120);
    return () => window.clearTimeout(timer);
  }, [previewRequest]);
  useEffect(() => {
    if (!previewRequest || !runtime || !selected) return;
    const previewState = runtime.preview;
    if (previewState.packageId !== selected.packageId || previewState.version !== selected.version) return;
    if (previewState.status === "failed") {
      setPreviewRequest(null);
      return;
    }
    // Selection/status and preview media travel through separate atomic files.
    // Do not expose a low-resolution thumbnail as a completed Ready state: the
    // request owns Loading until the renderer has the bounded full preview frame.
    const selectionReady = previewState.selectedAnimation === previewRequest.animation
      && ["ready", "playing", "paused"].includes(previewState.status);
    if (!selectionReady) return;
    const mediaReady = buildPreviewFrameSource(previewState, true).length > 0;
    if (!mediaReady) return;
    if (previewRequest.kind === "play" && !previewState.isPlaying) return;
    previewMediaRecovery.current = "";
    setPreviewRequest(null);
  }, [previewRequest, runtime, selected]);
  useEffect(() => {
    if (!runtime || !selected || tab !== "installed") return;
    const previewState = runtime.preview;
    const identityMatches = previewState.packageId === selected.packageId && previewState.version === selected.version;
    const stateReady = ["ready", "playing", "paused"].includes(previewState.status);
    if (!identityMatches || !stateReady || !previewState.selectedAnimation) return;
    if (buildPreviewFrameSource(previewState, true)) {
      previewMediaRecovery.current = "";
      return;
    }
    // Playing rewrites media continuously. Recovery is needed only for the
    // non-playing Ready state where state.json can win the race with media.
    if (previewState.isPlaying) return;
    const recoveryKey = `${selected.packageId}@${selected.version}:${previewState.selectedAnimation}`;
    if (previewMediaRecovery.current === recoveryKey) return;
    previewMediaRecovery.current = recoveryKey;
    setPreviewRequest({ animation: previewState.selectedAnimation, kind: "select" });
    submit({
      type: "character.preview.select",
      packageId: selected.packageId,
      version: selected.version,
      animation: previewState.selectedAnimation,
    });
  }, [runtime, selected, submit, tab]);
  useEffect(() => {
    if (!previewRequest) return;
    // UI fail-safe only. Runtime remains authoritative; this prevents a lost or
    // rejected bridge acknowledgement from pinning Character Manager controls
    // in a disabled loading state forever.
    const timer = window.setTimeout(() => setPreviewRequest(null), 10_000);
    return () => window.clearTimeout(timer);
  }, [previewRequest]);

  const closeMoreMenu = (): void => {
    setMoreOpen(false);
    setMoreMenuPosition(null);
  };
  const openStore = (): void => {
    closeMoreMenu();
    void window.ocpShell.openStore().catch(() => {
      setInstallNotice(t("characters.store_open_failed", "Unable to open the OCP Store right now."));
    });
  };
  const toggleMoreMenu = (): void => {
    if (moreOpen) {
      closeMoreMenu();
      return;
    }
    const rect = moreButtonRef.current?.getBoundingClientRect();
    if (!rect) return;
    const menuWidth = 220;
    const viewportPadding = 12;
    const left = Math.min(window.innerWidth - menuWidth - viewportPadding, Math.max(viewportPadding, rect.right - menuWidth));
    setMoreMenuPosition({ top: rect.bottom + 8, left });
    setMoreOpen(true);
  };
  const activateCharacter = (packageId: string, version: string): void => {
    const identity = `${packageId}@${version}`;
    if (!packageId || !version || activationTarget) return;
    setActivationTarget(identity);
    submit({ type: "character.activate", packageId, version });
  };
  const installLocal = async (): Promise<void> => {
    if (installBusy) return;
    setMoreOpen(false);
    setInstallBusy(true);
    setInstallNotice(translate(locale, "characters.install_selecting", "Choose an .ocp package to install…"));
    try {
      const result = await window.ocpShell.installLocalCharacter();
      if (result.status === "cancelled") {
        setInstallNotice("");
        return;
      }
      if (result.status === "submitted") {
        setInstallNotice(translate(locale, "characters.install_submitted", "Installing {file}…", { file: result.fileName }));
        return;
      }
      setInstallNotice(translate(locale, `characters.install_error.${result.errorCode}`, "Unable to install this local package."));
    } catch {
      setInstallNotice(translate(locale, "characters.install_failed", "Unable to install this local package."));
    } finally {
      setInstallBusy(false);
    }
  };
  const installLocalEffect = async (): Promise<void> => {
    if (effectInstallBusy) return;
    setEffectInstallBusy(true);
    setEffectInstallNotice(translate(locale, "characters.effect_install_selecting", "Choose an Effect .ocp package…"));
    try {
      const result = await window.ocpShell.installLocalEffect();
      if (result.status === "cancelled") { setEffectInstallNotice(""); return; }
      if (result.status === "submitted") {
        setEffectInstallNotice(translate(locale, "characters.effect_install_submitted", "Uploading {file}…", { file: result.fileName }));
        return;
      }
      setEffectInstallNotice(translate(locale, `characters.install_error.${result.errorCode}`, "Unable to install this Effect Pack."));
    } catch {
      setEffectInstallNotice(translate(locale, "characters.effect_install_failed", "Unable to install this Effect Pack."));
    } finally {
      setEffectInstallBusy(false);
    }
  };
  const beginUninstall = async (target: { packageId: string; version: string; name: string }): Promise<void> => {
    if (uninstallBusy || pendingUninstall) return;
    requestedPreview.current = "";
    requestedThumbnailPage.current = "";
    setUninstallBusy(true);
    setInstallNotice(t("characters.uninstall_pending", "Removing {name}…", { name: target.name }));
    try {
      const id = await window.ocpShell.sendRuntimeCommand({ type: "character.uninstall", packageId: target.packageId, version: target.version });
      setPendingUninstall({ id, packageId: target.packageId, version: target.version, name: target.name });
    } catch {
      setInstallNotice(t("characters.uninstall_failed", "Unable to uninstall {name}. Please try again.", { name: target.name }) + " (command-not-sent)");
    } finally {
      setUninstallBusy(false);
    }
  };
  const requestUninstall = async (): Promise<void> => {
    if (!selected || pendingUninstall || uninstallBusy) return;
    setMoreOpen(false);
    setInstallNotice("");
    const target = { packageId: selected.packageId, version: selected.version, name: selectedDisplayName };
    let confirmed = false;
    try {
      confirmed = await window.ocpShell.confirmCharacterUninstall(target.name, selected.active, locale);
    } catch {
      setInstallNotice(t("characters.uninstall_failed", "Unable to uninstall {name}. Please try again.", { name: target.name }) + " (confirm-unavailable)");
      return;
    }
    if (!confirmed) return;
    await beginUninstall(target);
  };
  const retryRuntime = async (): Promise<void> => {
    if (runtimeRetryBusy) return;
    setRuntimeRetryBusy(true);
    try { await onRetryRuntime(); } finally { setRuntimeRetryBusy(false); }
  };
  if (!runtime) return <main className="characters-layout character-empty-layout">
    <aside className="character-list panel"><div className="character-list-heading"><h2>{t("characters.my")}</h2><button className="store-link" disabled={!storeAvailable} onClick={openStore} type="button">{t("characters.explore")}</button></div><div className="tabs"><button className="selected" type="button">{t("characters.installed")}</button><button onClick={() => setTab("library")} type="button">{t("characters.library")}</button></div><p className="empty-state">{t("characters.empty")}</p><div className="character-library-actions"><button className="library-store-button" disabled={!storeAvailable} onClick={openStore} type="button"><Store size={16} />{t("characters.add")}</button><button className="library-local-button" disabled={!runtime || installBusy} onClick={() => void installLocal()} type="button"><PackagePlus size={16} />{installBusy ? t("characters.installing") : t("characters.install_local")}</button></div>{installNotice && <p className="install-notice">{installNotice}</p>}</aside>
    <section className="character-stage panel runtime-offline"><span>{t("characters.eyebrow")}</span><h1>{t("characters.runtime_unavailable")}</h1><p>{t("characters.runtime_start")}</p><button className="button primary" disabled={runtimeRetryBusy} onClick={() => void retryRuntime()} type="button">{runtimeRetryBusy ? t("characters.runtime_retrying") : t("characters.runtime_retry")}</button></section>
    <aside className="preview-panel panel"><h2>{t("characters.preview")}</h2><input aria-label={t("characters.search")} disabled placeholder={t("characters.search")} /><p>{t("characters.library_count", undefined, { count: "unavailable" })}</p><div className="animation-empty">{t("characters.runtime_unavailable")}</div></aside>
  </main>;

  if (tab === "library") {
    const signedIn = runtime.account?.signedIn === true;
    const libraryStatus = cloud?.library.status ?? (signedIn ? "idle" : "signed-out");
    const syncStatus = cloud?.sync.status ?? (signedIn ? "idle" : "signed-out");
    const selectedInstalledCurrent = Boolean(selectedCloud && selectedCloudInstalled && selectedCloud.latestVersion && selectedCloudInstalled.version === selectedCloud.latestVersion);
    const selectedInstalledActive = selectedInstalledCurrent && selectedCloudInstalled?.active === true;
    const selectedDownloadBusy = Boolean(selectedCloud && cloudDownloadBusy && cloud?.download.packageId === selectedCloud.productId);
    const refreshLibrary = (): void => submit({ type: "cloud.library.refresh" });
    const syncNow = (): void => submit({ type: "cloud.sync.now" });
    const installSelectedCloud = (): void => {
      if (!selectedCloud?.latestVersion) return;
      submit({ type: "cloud.library.install", packageId: selectedCloud.productId, version: selectedCloud.latestVersion });
    };
    return <main className="characters-layout cloud-library-layout">
      <aside className="character-list panel">
        <div className="character-list-heading"><h2>{t("characters.my")}</h2><button className="store-link" disabled={!storeAvailable} onClick={openStore} type="button">{t("characters.explore")}</button></div>
        <div className="tabs"><button onClick={() => setTab("installed")} type="button">{t("characters.installed")}</button><button className="selected" type="button">{t("characters.library")}</button></div>
        {!signedIn ? <div className="cloud-library-empty"><Store size={24} /><b>{t("library.sign_in_title", "Sign in to My Library")}</b><p>{t("library.sign_in_detail", "Your OCP Cloud entitlements appear here while installed characters remain available offline.")}</p><button className="button primary" disabled={!storeAvailable} onClick={() => void window.ocpShell.openAccount(true)} type="button">{t("account.sign_in", "Sign in")}</button></div> : <>
          <div className="cloud-library-toolbar"><span className={`cloud-state state-${libraryStatus}`}>{t(`library.status.${libraryStatus}`, libraryStatus)}</span><button aria-label={t("library.refresh", "Refresh Library")} disabled={libraryStatus === "loading"} onClick={refreshLibrary} type="button"><RefreshCw className={libraryStatus === "loading" ? "spin" : ""} size={15} /></button></div>
          <div className="character-cards cloud-library-cards">{cloudItems.map((item, index) => {
            const installed = characters.find((character) => character.packageId === item.productId);
            const current = Boolean(installed && item.latestVersion && installed.version === item.latestVersion);
            return <button className={item.productId === selectedCloud?.productId ? "character-card selected" : "character-card"} key={item.productId} onClick={() => setSelectedCloudId(item.productId)} type="button"><i className={`character-avatar avatar-${index % 3}`} aria-hidden="true"><CharacterArtwork name={item.name || item.productId} remoteUrl={item.thumbnailUrl} localPngBase64={installed?.thumbnailPngBase64 ?? ""} /></i><span className="character-card-copy"><b>{item.name || item.productId}</b><small>{item.latestVersion ? `v${item.latestVersion}` : item.productId}</small><em className={current ? "active" : ""}>{current ? t("library.installed", "Installed") : installed ? t("library.update_available", "Update available") : t("library.cloud_ready", "Ready from Cloud")}</em></span>{item.productId === selectedCloud?.productId && <span className="selected-check" aria-label="Selected">✓</span>}</button>;
          })}{cloudItems.length === 0 && <div className="cloud-library-empty compact"><Store size={22} /><b>{libraryStatus === "loading" ? t("library.loading", "Loading My Library…") : t("library.empty", "Your Library is empty")}</b><p>{t("library.empty_detail", "Add a free or purchased character from OCP Store and refresh this list.")}</p></div>}</div>
        </>}
        <div className="character-library-actions"><button className="library-store-button" disabled={!storeAvailable} onClick={openStore} type="button"><Store size={16} />{t("characters.explore")}</button>{signedIn && <button className="library-local-button" disabled={libraryStatus === "loading"} onClick={refreshLibrary} type="button"><RefreshCw size={16} />{t("library.refresh", "Refresh Library")}</button>}</div>
      </aside>
      <section className="character-stage panel cloud-library-stage">
        {!signedIn ? <div className="cloud-library-hero"><Store size={40} /><span>{t("characters.library", "My Library")}</span><h1>{t("library.sign_in_title", "Sign in to My Library")}</h1><p>{t("library.sign_in_detail", "Your OCP Cloud entitlements appear here while installed characters remain available offline.")}</p></div> : !selectedCloud ? <div className="cloud-library-hero"><Store size={40} /><span>{t("characters.library", "My Library")}</span><h1>{libraryStatus === "loading" ? t("library.loading", "Loading My Library…") : t("library.empty", "Your Library is empty")}</h1><p>{t("library.empty_detail", "Add a free or purchased character from OCP Store and refresh this list.")}</p></div> : <>
          <div className="stage-heading"><div><span>{t("library.cloud_character", "CLOUD CHARACTER")}</span><h1>{selectedCloud.name || selectedCloud.productId}</h1><p><i className="status-dot" /> {t("library.entitled", "Entitled")} · {t(`library.source.${selectedCloud.source}`, selectedCloud.source)}</p><small className="version-chip">⌁ {selectedCloud.latestVersion ? `v${selectedCloud.latestVersion}` : t("library.metadata_loading", "metadata loading")}</small></div><div className="stage-heading-actions">{selectedInstalledCurrent ? <button className="button primary" disabled={selectedInstalledActive || Boolean(activationTarget)} onClick={() => selectedCloudInstalled && activateCharacter(selectedCloudInstalled.packageId, selectedCloudInstalled.version)} type="button">{selectedCloudInstalled && activationTarget === `${selectedCloudInstalled.packageId}@${selectedCloudInstalled.version}` ? <><LoaderCircle className="spin" size={16} />{t("characters.activating", "Switching…")}</> : selectedInstalledActive ? t("characters.active_button") : t("characters.use")}</button> : <button className="button primary" disabled={!selectedCloud.latestVersion || cloudDownloadBusy} onClick={installSelectedCloud} type="button">{selectedDownloadBusy ? <><LoaderCircle className="spin" size={16} />{cloud?.download.status === "downloading" ? t("library.downloading", "Downloading…") : t("library.authorizing", "Authorizing…")}</> : selectedCloudInstalled ? t("library.update", "Update") : t("library.install", "Install")}</button>}<button className="button secondary" disabled={!storeAvailable} onClick={openStore} type="button"><Store size={16} />{t("library.view_store", "View Store")}</button></div></div>
          <div className="cloud-library-visual"><CharacterArtwork name={selectedCloud.name || selectedCloud.productId} remoteUrl={selectedCloud.thumbnailUrl} localPngBase64={selectedCloudInstalled?.thumbnailPngBase64 ?? ""} alt={`${selectedCloud.name || selectedCloud.productId} thumbnail`} /></div>
          <div className="cloud-library-meta"><div><span>{t("characters.package", "Package")}</span><b>{selectedCloud.productId}</b></div><div><span>{t("characters.version", "Version")}</span><b>{selectedCloud.latestVersion || "—"}</b></div><div><span>{t("library.entitlement", "Entitlement")}</span><b>{t(`library.source.${selectedCloud.source}`, selectedCloud.source)}</b></div><div><span>{t("characters.status", "Status")}</span><b>{selectedInstalledCurrent ? t("library.installed", "Installed") : selectedCloudInstalled ? t("library.update_available", "Update available") : t("library.cloud_ready", "Ready from Cloud")}</b></div></div>
        </>}
      </section>
      <aside className="preview-panel panel cloud-sync-panel">
        <div className="cloud-sync-heading"><h2>{t("account.cloud_sync", "Cloud Sync")}</h2><button aria-label={t("library.sync_now", "Sync now")} disabled={!signedIn || syncStatus === "syncing" || !cloud?.sync.deviceRegistered} onClick={syncNow} type="button"><RefreshCw className={syncStatus === "syncing" ? "spin" : ""} size={16} /></button></div>
        <p>{t("library.sync_detail", "Runtime synchronizes Cloud-owned progression and keeps local activity queued when offline.")}</p>
        <div className="cloud-sync-facts"><div><span>{t("library.account", "Account")}</span><b>{runtime.account?.email || "—"}</b></div><div><span>{t("library.device", "Device")}</span><b>{cloud?.sync.deviceRegistered ? t("library.registered", "Registered") : t("account.device_pending", "Device registration pending")}</b></div><div><span>{t("library.sync_status", "Sync status")}</span><b>{t(`library.sync.${syncStatus}`, syncStatus)}</b></div><div><span>{t("library.cloud_revision", "Cloud revision")}</span><b>{cloud?.sync.progressionRevision ?? runtime.progression?.revision ?? 0}</b></div></div>
        <button className="button secondary cloud-sync-button" disabled={!signedIn || syncStatus === "syncing" || !cloud?.sync.deviceRegistered} onClick={syncNow} type="button"><RefreshCw className={syncStatus === "syncing" ? "spin" : ""} size={16} />{syncStatus === "syncing" ? t("library.syncing", "Syncing…") : t("library.sync_now", "Sync now")}</button>
        <section className="about"><h3>{t("library.security", "Cloud security")}</h3><div><p>{t("library.security.session", "Session")}<b>{signedIn ? t("library.secure_session", "Secure OS credential") : t("library.signed_out", "Signed out")}</b></p><p>{t("library.security.install", "Install authority")}<b>{t("library.runtime_verified", "Runtime + signed package")}</b></p><p>{t("library.security.trust", "Package trust")}<b>{cloud?.download.trust?.mode === "marketplace-release" ? `${t("library.marketplace_verified", "Marketplace verified")} · seq ${cloud.download.trust.sequence}` : cloud?.download.trust?.mode === "local-beta" ? `${t("library.local_beta_verified", "Local Beta verified")} · seq ${cloud.download.trust.sequence}` : t("library.trust_pending", "Verified on install")}</b></p><p>{t("library.security.offline", "Offline") }<b>{t("library.queue_local", "Local activity queue")}</b></p></div></section>
      </aside>
    </main>;
  }

  if (!selected) return <main className="characters-layout character-empty-layout">
    <aside className="character-list panel"><div className="character-list-heading"><h2>{t("characters.my")}</h2><button className="store-link" disabled={!storeAvailable} onClick={openStore} type="button">{t("characters.explore")}</button></div><div className="tabs"><button className="selected" type="button">{t("characters.installed")}</button><button onClick={() => setTab("library")} type="button">{t("characters.library")}</button></div><p className="empty-state">{t("characters.none_installed")}</p><div className="character-library-actions"><button className="library-store-button" disabled={!storeAvailable} onClick={openStore} type="button"><Store size={16} />{t("characters.add")}</button><button className="library-local-button" disabled={installBusy} onClick={() => void installLocal()} type="button"><PackagePlus size={16} />{installBusy ? t("characters.installing") : t("characters.install_local")}</button></div>{installNotice && <p className="install-notice">{installNotice}</p>}</aside>
    <section className="character-stage panel runtime-offline"><span>{t("characters.eyebrow")}</span><h1>{t("characters.none_title")}</h1><p>{t("characters.none_detail")}</p></section>
    <aside className="preview-panel panel"><h2>{t("characters.preview")}</h2><input aria-label={t("characters.search")} disabled placeholder={t("characters.search")} /><p>{t("characters.library_count", undefined, { count: 0 })}</p><div className="animation-empty">{t("characters.none_preview")}</div></aside>
  </main>;

  const preview = runtime.preview;
  const previewMatches = preview.packageId === selected.packageId && preview.version === selected.version;
  const previewAvailable = previewMatches && ["ready", "playing", "paused"].includes(preview.status);
  const previewPlaying = previewMatches && preview.isPlaying;
  const previewLoop = previewMatches ? preview.loop : false;
  const previewSpeed = previewMatches ? preview.speed : 1;
  const clips = previewMatches ? preview.clips.filter((clip) => clip.toLocaleLowerCase().includes(animationSearch.toLocaleLowerCase())) : [];
  const frameSource = buildPreviewFrameSource(preview, previewMatches);
  const previewDisplayLoading = previewLoadingVisible
    || (previewMatches && preview.status === "loading")
    || (previewAvailable && !frameSource);
  const staticPreviewSource = selected.thumbnailPngBase64 ? `data:image/png;base64,${selected.thumbnailPngBase64}` : "";
  const loadingAnimation = previewRequest?.animation ?? preview.selectedAnimation;
  const loadingThumbnailBase64 = previewMatches ? (preview.clipThumbnailPngBase64?.[loadingAnimation] ?? "") : "";
  const loadingThumbnailSource = loadingThumbnailBase64 ? `data:image/png;base64,${loadingThumbnailBase64}` : "";
  const stagePlaceholderSource = loadingThumbnailSource || staticPreviewSource;
  const shortcutPageCount = previewMatches ? Math.max(1, Math.ceil(preview.clips.length / SHORTCUT_PAGE_SIZE)) : 1;
  const shortcutStart = Math.min(shortcutPage, shortcutPageCount - 1) * SHORTCUT_PAGE_SIZE;
  const shortcuts = previewMatches ? preview.clips.slice(shortcutStart, shortcutStart + SHORTCUT_PAGE_SIZE) : [];
  const statusLabel = previewMatches && frameSource
    ? previewStatusLabel(preview.status, preview.selectedAnimation)
    : "Preparing preview";
  const openPreview = (): void => {
    requestedPreview.current = `${selected.packageId}@${selected.version}`;
    submit({ type: "character.preview.open", packageId: selected.packageId, version: selected.version });
  };
  const selectPreviewAnimation = (name: string): void => {
    const identity = `${selected.packageId}@${selected.version}`;
    const clipIndex = preview.clips.indexOf(name);
    if (clipIndex >= 0) {
      const nextPage = Math.floor(clipIndex / SHORTCUT_PAGE_SIZE);
      requestedThumbnailPage.current = "";
      setShortcutPage(nextPage);
    }
    setLastAnimationByCharacter((current) => ({ ...current, [identity]: name }));
    requestedRememberedAnimation.current = `${identity}:${name}`;
    if (name !== preview.selectedAnimation || !frameSource) setPreviewRequest({ animation: name, kind: "select" });
    submit({ type: "character.preview.select", packageId: selected.packageId, version: selected.version, animation: name });
    // An explicit tile click previews the clip immediately. Keep select/play as
    // two ordered commands so programmatic selection (restore/chat) retains its
    // existing semantics and Runtime remains the playback authority.
    submit({ type: "character.preview.play", packageId: selected.packageId, version: selected.version });
  };
  const togglePreviewPlayback = (): void => {
    if (preview.isPlaying) {
      setPreviewRequest(null);
      submit({ type: "character.preview.pause", packageId: selected.packageId, version: selected.version });
      return;
    }
    if (!frameSource) setPreviewRequest({ animation: preview.selectedAnimation, kind: "play" });
    submit({ type: "character.preview.play", packageId: selected.packageId, version: selected.version });
  };
  const previewEffect = (mode: "all" | "bodyAura" | "groundRune" | "levelUpBurst" | "off"): void => {
    setEffectPreviewMode(mode === "off" ? "" : mode);
    submit({ type: "effect-pack.preview", mode });
  };
  const selectEffectPack = async (slot: EffectSlotName, value: string): Promise<void> => {
    const sequence = ++effectSelectionSequence.current;
    setPendingEffectSelection(null);
    setEffectProfileNotice("");
    if (!value) {
      submit({ type: "effect-pack.unequip", slot });
      if (effectPreviewMode === slot || effectPreviewMode === "all") previewEffect("off");
      return;
    }
    const pack = effectPacks?.installed.find((item) => `${item.packageId}@${item.version}` === value && item.slots.includes(slot));
    if (!pack) return;
    try {
      const id = await window.ocpShell.sendRuntimeCommand({ type: "effect-pack.equip", packageId: pack.packageId, version: pack.version, slot });
      if (sequence === effectSelectionSequence.current) setPendingEffectSelection({ id, slot, character: selectedIdentity });
    } catch {
      if (sequence === effectSelectionSequence.current) setEffectProfileNotice(t("characters.effect_selection_failed", "Could not select this pack. Please try again."));
    }
  };
  const applyEffectTune = (next: EffectPreviewTuning): void => {
    setEffectTuneDraft(next);
    submit({ type: "effect-pack.preview-tune", slot: effectTuneSlot, tuning: next });
    if (effectPreviewMode !== effectTuneSlot) {
      setEffectPreviewMode(effectTuneSlot);
      submit({ type: "effect-pack.preview", mode: effectTuneSlot });
    }
  };
  const resetEffectTune = (): void => {
    applyEffectTune(effectPreviewTuningFromConfig(effectTuneSlot, effectTuneConfig));
  };
  const saveEffectProfile = (): void => {
    if (!selectedPackageId || !effectTuneConfig) return;
    submit({ type: "effect-pack.character-profile.save", characterId: selectedPackageId, slot: effectTuneSlot, tuning: effectTuneDraft });
    setEffectProfileNotice(t("characters.effect_profile_saved", "Saved {slot} tuning for {character}.", { slot: effectTuneSlot, character: selectedDisplayName || selectedPackageId }));
  };
  const resetSavedEffectProfile = (): void => {
    if (!selectedPackageId) return;
    submit({ type: "effect-pack.character-profile.reset", characterId: selectedPackageId, slot: effectTuneSlot });
    setEffectProfileNotice(t("characters.effect_profile_reset", "Reset saved {slot} tuning for {character}.", { slot: effectTuneSlot, character: selectedDisplayName || selectedPackageId }));
  };

  const effectPanel = <div className="progression-effects effect-sidebar-content">
    <div className="progression-effects-heading">
      <Sparkles size={16} />
      <span>{t("characters.effects", "Character Effects")}</span>
      <button className="effect-upload-button" disabled={effectInstallBusy} onClick={() => void installLocalEffect()} type="button"><PackagePlus size={14} />{effectInstallBusy ? t("characters.installing", "Installing…") : t("characters.upload_effect", "Upload Effect")}</button>
      <button className={`preview-level-up-button${effectPreviewMode === "all" ? " active" : ""}`} disabled={!hasResolvedEffects || !previewAvailable} onClick={() => previewEffect("all")} type="button">
        <Play size={15} />{t("characters.preview_effects", "Play All")}
      </button>
    </div>
    {effectInstallNotice ? <p className="effect-install-notice">{effectInstallNotice}</p> : null}
    {effectPacks && !hasResolvedEffects ? <p className="effect-install-notice is-warning">{t("characters.effect_none_resolved", "No Effect Pack is equipped yet. Upload or select a pack below.")}</p> : null}
    <p className="effect-install-notice">{t("characters.effect_selection_hint", "Choose a pack for each effect to preview it here. The checkbox controls whether it is enabled on your desktop companion.")}</p>
    <div className="effect-slot-grid">
      {effectSlots.map((slot) => {
        const resolved = effectPacks?.resolved[slot.id];
        const current = effectPacks?.loadout[slot.id];
        const enabled = effectPacks?.enabled[slot.id] ?? true;
        const options = (effectPacks?.installed ?? []).filter((pack) => pack.slots.includes(slot.id));
        const value = current ? `${current.packageId}@${current.version}` : "";
        const variant = typeof resolved?.config._variantId === "string" ? resolved.config._variantId : "";
        return <section className={`effect-slot-card effect-slot-${slot.id}`} key={slot.id}>
          <div className="effect-slot-title">
            <span className="effect-slot-glyph"><Sparkles size={16} /></span>
            <span><b>{t(slot.labelKey, slot.label)}</b><small>{t(slot.hintKey, slot.hint)}</small></span>
            <input aria-label={`${t(slot.labelKey, slot.label)} enabled`} checked={enabled} disabled={!effectPacks} onChange={(event) => {
              const nextEnabled = event.target.checked;
              submit({ type: "effect-pack.slot-enabled", slot: slot.id, enabled: nextEnabled });
            }} type="checkbox" />
          </div>
          <select
            aria-label={`${t(slot.labelKey, slot.label)} pack`}
            disabled={!effectPacks}
            onChange={(event) => void selectEffectPack(slot.id, event.target.value)}
            value={value}
          >
            <option value="">{t("characters.effect_none", "None")}</option>
            {options.map((pack) => <option key={`${pack.packageId}@${pack.version}`} value={`${pack.packageId}@${pack.version}`}>{pack.name}</option>)}
          </select>
          <div className="effect-slot-meta">
            <span>{resolved?.name ?? t("characters.effect_not_equipped", "Not equipped")}</span>
            {variant ? <em>{t("characters.effect_variant", "Variant")}: {variant.replaceAll("-", " ")}</em> : null}
          </div>
        </section>;
      })}
    </div>
    {pendingEffectSelection ? <p className="effect-install-notice" role="status">{t("characters.effect_selection_pending", "Selecting pack and preparing preview…")}</p> : null}
    {effectProfileNotice ? <p className="effect-install-notice" role="status">{effectProfileNotice}</p> : null}
    <div className="effect-preview-toolbar" aria-label={t("characters.preview_effects", "Effect preview controls")}>
      <button className={effectPreviewMode === "bodyAura" ? "active" : ""} disabled={!effectPacks?.resolved.bodyAura || !previewAvailable} onClick={() => { setEffectTuneSlot("bodyAura"); previewEffect("bodyAura"); }} type="button"><Sparkles size={14} />{t("characters.body_aura", "Aura")}</button>
      <button className={effectPreviewMode === "groundRune" ? "active" : ""} disabled={!effectPacks?.resolved.groundRune || !previewAvailable} onClick={() => { setEffectTuneSlot("groundRune"); previewEffect("groundRune"); }} type="button"><CircleDot size={14} />{t("characters.ground_rune", "Rune")}</button>
      <button className={effectPreviewMode === "levelUpBurst" ? "active" : ""} disabled={!effectPacks?.resolved.levelUpBurst || !previewAvailable} onClick={() => { setEffectTuneSlot("levelUpBurst"); previewEffect("levelUpBurst"); }} type="button"><Zap size={14} />{t("characters.level_up_burst", "Burst")}</button>
      <button className="stop" disabled={!effectPreviewMode} onClick={() => previewEffect("off")} type="button"><Square size={13} />{t("common.stop", "Stop")}</button>
    </div>
    <section className="effect-tuning-panel" aria-label={t("characters.effect_tuning", "Effect preview tuning")}>
      {effectTuneConfig && !effectTuneUsesFrames ? <p className="effect-install-notice">{t("characters.effect_procedural_hint", "This pack draws rings procedurally. Choose a video pack above for animated video effects; frame controls do not apply to this pack.")}</p> : null}
      <div className="effect-tuning-heading"><div><b>{t("characters.effect_tuning", "Effect Tuning")}</b><small>{t("characters.effect_tuning_hint", "Preview live, then save placement/timing for this character")}</small></div><div className="effect-tuning-actions"><button disabled={!effectTuneConfig} onClick={resetEffectTune} type="button"><RefreshCw size={13} />{t("characters.effect_reset_preview", "Reset Preview")}</button><button disabled={!effectTuneConfig || !selectedPackageId} onClick={resetSavedEffectProfile} type="button">{t("characters.effect_reset_saved", "Reset Saved")}</button><button className="primary" disabled={!effectTuneConfig || !selectedPackageId} onClick={saveEffectProfile} type="button">{t("characters.effect_save_character", "Save for this Character")}</button></div></div>

      <div className="effect-tuning-grid">
        <label><span>{t("characters.effect_tuning_slot", "Slot")}</span><select value={effectTuneSlot} onChange={(event) => { const slot = event.target.value as EffectSlotName; setEffectTuneSlot(slot); setEffectPreviewMode(slot); submit({ type: "effect-pack.preview", mode: slot }); }}><option value="bodyAura">Aura</option><option value="groundRune">Rune</option><option value="levelUpBurst">Burst</option></select></label>
        <label><span>FPS</span><select disabled={!effectTuneConfig || !effectTuneUsesFrames} value={effectTuneDraft.fps} onChange={(event) => applyEffectTune({ ...effectTuneDraft, fps: Number(event.target.value) })}><option>8</option><option>10</option><option>12</option><option>15</option><option>20</option><option>24</option></select></label>
        <label><span>{t("characters.effect_start_frame", "Start frame")}</span><input disabled={!effectTuneConfig || !effectTuneUsesFrames} max={Math.max(0, effectTuneDraft.endFrame)} min={0} type="number" value={effectTuneDraft.startFrame} onChange={(event) => { const startFrame = Math.max(0, Math.min(effectTuneDraft.endFrame, Number(event.target.value))); applyEffectTune({ ...effectTuneDraft, startFrame }); }} /></label>
        <label><span>{t("characters.effect_end_frame", "End frame")}</span><input disabled={!effectTuneConfig || !effectTuneUsesFrames} max={effectTuneFrameCount - 1} min={effectTuneDraft.startFrame} type="number" value={effectTuneDraft.endFrame} onChange={(event) => { const endFrame = Math.max(effectTuneDraft.startFrame, Math.min(effectTuneFrameCount - 1, Number(event.target.value))); applyEffectTune({ ...effectTuneDraft, endFrame }); }} /></label>
        <label><span>{t("characters.effect_anchor", "Anchor")}</span><select disabled={!effectTuneConfig} value={effectTuneDraft.anchor} onChange={(event) => applyEffectTune({ ...effectTuneDraft, anchor: event.target.value as EffectPreviewTuning["anchor"] })}><option value="character-center">Body center</option><option value="character-feet">Feet center</option><option value="character-feet-bottom">Feet / ground</option><option value="character-above-head">Above head</option></select></label>
        <label><span>{t("characters.effect_scale_mode", "Scale mode")}</span><select disabled={!effectTuneConfig} value={effectTuneDraft.scaleMode} onChange={(event) => applyEffectTune({ ...effectTuneDraft, scaleMode: event.target.value as EffectPreviewTuning["scaleMode"] })}><option value="character-width">Character width</option><option value="character-height">Character height</option><option value="native-surface">Native surface</option></select></label>
        <label className="effect-tuning-range"><span>{t("characters.effect_scale", "Scale")} {effectTuneDraft.scale.toFixed(2)}×</span><input disabled={!effectTuneConfig} max="2.5" min="0.5" step="0.05" type="range" value={effectTuneDraft.scale} onChange={(event) => applyEffectTune({ ...effectTuneDraft, scale: Number(event.target.value) })} /></label>
        <label><span>Offset X</span><input disabled={!effectTuneConfig} max="256" min="-256" type="number" value={effectTuneDraft.offsetX} onChange={(event) => applyEffectTune({ ...effectTuneDraft, offsetX: Number(event.target.value) })} /></label>
        <label className="effect-offset-y-control"><span>Offset Y <em>{effectTuneDraft.offsetY}px</em></span><input disabled={!effectTuneConfig} max="256" min="-256" type="number" value={effectTuneDraft.offsetY} onChange={(event) => applyEffectTune({ ...effectTuneDraft, offsetY: Number(event.target.value) })} /><input aria-label="Effect vertical offset" disabled={!effectTuneConfig} max="128" min="-128" step="1" type="range" value={Math.max(-128, Math.min(128, effectTuneDraft.offsetY))} onChange={(event) => applyEffectTune({ ...effectTuneDraft, offsetY: Number(event.target.value) })} /></label>
      </div>
    </section>
    <label className="progression-effect-toggle level-up-master">
      <span><b>{t("characters.level_up_effect", "Level-Up Celebration")}</b><small>{t("characters.level_up_effect_hint", "Floating level badge and equipped Level-Up Burst")}</small></span>
      <input checked={progressionEffects.levelUpEnabled} onChange={(event) => submit({ type: "character.effects.update", levelUpEnabled: event.target.checked, auraEnabled: progressionEffects.auraEnabled })} type="checkbox" />
    </label>
    <label className="effect-rank-preview-control">
      <span><b>{t("characters.preview_bond_rank", "Preview Bond Rank")}</b><small>{t("characters.preview_bond_rank_hint", "Temporary visual preview only — EXP and cloud progression are not changed")}</small></span>
      <select
        disabled={!effectPacks || !previewAvailable}
        value={effectPacks?.previewRank ?? ""}
        onChange={(event) => submit({ type: "effect-pack.preview-rank", rank: event.target.value as "" | "stranger" | "friend" | "close-friend" | "partner" | "best-companion" })}
      >
        <option value="">{t("characters.preview_live_rank", "Live / Canonical")}</option>
        <option value="stranger">Stranger · Calm Cyan</option>
        <option value="friend">Friend · Friendly Blue</option>
        <option value="close-friend">Close Friend · Bond Violet</option>
        <option value="partner">Partner · Partner Bloom</option>
        <option value="best-companion">Best Companion · Golden Companion</option>
      </select>
    </label>
  </div>;

  const moreMenu = moreOpen && moreMenuPosition ? createPortal(
    <div
      className="character-more-menu character-more-menu-portal"
      onPointerDown={(event) => event.stopPropagation()}
      style={{ top: moreMenuPosition.top, left: moreMenuPosition.left }}
    >
      <button onClick={(event) => { if (event.detail === 0) void installLocal(); }} onPointerDown={(event) => { if (event.button !== 0) return; event.preventDefault(); event.stopPropagation(); void installLocal(); }} type="button"><PackagePlus size={15} />{t("characters.install_local")}</button>
      <button onClick={(event) => { if (event.detail !== 0) return; closeMoreMenu(); openPreview(); }} onPointerDown={(event) => { if (event.button !== 0) return; event.preventDefault(); event.stopPropagation(); closeMoreMenu(); openPreview(); }} type="button"><RefreshCw size={15} />{t("characters.refresh_preview")}</button>
      <button onClick={(event) => { if (event.detail !== 0) return; openStore(); }} onPointerDown={(event) => { if (event.button !== 0) return; event.preventDefault(); event.stopPropagation(); openStore(); }} type="button"><Store size={15} />{t("characters.explore")}</button>
      <button className="danger" disabled={Boolean(pendingUninstall)} onClick={(event) => { if (event.detail === 0) void requestUninstall(); }} onPointerDown={(event) => { if (event.button !== 0 || pendingUninstall) return; event.preventDefault(); event.stopPropagation(); void requestUninstall(); }} type="button"><Trash2 size={15} />{pendingUninstall ? t("characters.uninstalling", "Removing…") : t("characters.uninstall", "Uninstall")}</button>
    </div>,
    document.body,
  ) : null;

  return <main className="characters-layout">
    <aside className="character-list panel">
      <div className="character-list-heading"><h2>{t("characters.my")}</h2><button className="store-link" disabled={!storeAvailable} onClick={openStore} type="button">{t("characters.explore")}</button></div>
      <div className="tabs"><button className="selected" type="button">{t("characters.installed")}</button><button onClick={() => setTab("library")} type="button">{t("characters.library")}</button></div>
      <div className="character-cards">{characters.map((character, index) => <button className={character.packageId === selected.packageId ? "character-card selected" : "character-card"} key={`${character.packageId}@${character.version}`} onClick={() => { requestedPreview.current = ""; requestedRememberedAnimation.current = ""; requestedThumbnailPage.current = ""; setShortcutPage(0); setAnimationSearch(""); setDetailsOpen(false); setMoreOpen(false); setSelectedId(character.packageId); }} type="button"><i className={`character-avatar avatar-${index % 3}`} aria-hidden="true">{character.thumbnailPngBase64 ? <img alt="" src={`data:image/png;base64,${character.thumbnailPngBase64}`} /> : characterInitials(characterDisplayName(character.name, character.packageId))}</i><span className="character-card-copy"><b>{characterDisplayName(character.name, character.packageId)}</b><small>{character.packageId} · v{character.version}</small><em className={character.active ? "active" : ""}>{t("characters.installed")} · {character.active ? t("characters.active") : t("characters.ready")}</em></span>{character.packageId === selected.packageId && <span className="selected-check" aria-label="Selected">✓</span>}</button>)}</div>
      <div className="character-library-actions">
        <button className="library-store-button" disabled={!storeAvailable} onClick={openStore} type="button"><Store size={16} />{t("characters.add")}</button>
        <button className="library-local-button" disabled={installBusy} onClick={() => void installLocal()} type="button"><PackagePlus size={16} />{installBusy ? t("characters.installing") : t("characters.install_local")}</button>
      </div>
      {installNotice && <p className="install-notice">{installNotice}</p>}
    </aside>
    <section className="character-stage panel">
      <div className="stage-heading"><div><span>{t("characters.selected")}</span><h1>{selectedDisplayName}</h1><p><i className="status-dot" /> {t("characters.installed")} · {selected.active ? t("characters.active") : t("characters.ready")}</p><small className="version-chip">{selected.packageId} · v{selected.version}</small></div><div className="stage-heading-actions"><button className="button primary" disabled={selected.active || Boolean(activationTarget)} onClick={() => activateCharacter(selected.packageId, selected.version)} type="button">{selectedActivationBusy ? <><LoaderCircle className="spin" size={16} />{t("characters.activating", "Switching…")}</> : selected.active ? t("characters.active_button") : t("characters.use")}</button><button className="button secondary" onClick={() => setDetailsOpen((value) => !value)} type="button"><Info size={16} />{t("characters.details")}</button><div className="character-more-wrap"><button ref={moreButtonRef} className="icon-button" aria-expanded={moreOpen} aria-label={t("characters.more")} onClick={toggleMoreMenu} type="button"><EllipsisVertical size={18} /></button>{moreMenu}</div></div></div>
      {detailsOpen && <section className="character-details-sheet"><div><span>{t("characters.details_eyebrow")}</span><h3>{selectedDisplayName}</h3><button aria-label={t("common.cancel")} onClick={() => setDetailsOpen(false)} type="button"><X size={16} /></button></div><dl><div><dt>{t("characters.package")}</dt><dd>{selected.packageId}</dd></div><div><dt>{t("characters.version")}</dt><dd>{selected.version}</dd></div><div><dt>{t("characters.status")}</dt><dd>{selected.active ? t("characters.active") : t("characters.ready")}</dd></div><div><dt>{t("characters.library_count_short")}</dt><dd>{previewMatches ? preview.clips.length : selected.animations.length}</dd></div></dl><p>{t("characters.details_note")}</p><button className="details-uninstall" disabled={Boolean(pendingUninstall)} onClick={() => void requestUninstall()} type="button"><Trash2 size={15} />{pendingUninstall ? t("characters.uninstalling", "Removing…") : t("characters.uninstall", "Uninstall")}</button></section>}
      <div className="stage-canvas"><div className={`runtime-preview-stage${effectPreviewMode ? " is-effect-preview" : ""}`} aria-busy={previewDisplayLoading} aria-live="polite">{previewDisplayLoading && stagePlaceholderSource ? <img className="static-preview-image preview-loading-placeholder" alt={`${selectedDisplayName} ${loadingAnimation} loading preview`} src={stagePlaceholderSource} /> : frameSource ? <img className="live-preview-image" alt={`${selectedDisplayName} ${preview.selectedAnimation} preview`} height={preview.frameHeight} src={frameSource} width={preview.frameWidth} /> : stagePlaceholderSource ? <img className="static-preview-image" alt={`${selectedDisplayName} static preview`} src={stagePlaceholderSource} /> : <p>{previewFallbackText(preview, previewMatches)}</p>}{effectPreviewMode && <span className="effect-preview-badge"><Sparkles size={13} />FX Preview · {effectPreviewMode === "all" ? "All" : effectPreviewMode === "bodyAura" ? "Aura" : effectPreviewMode === "groundRune" ? "Ground Rune" : "Burst"}</span>}{previewDisplayLoading && <div className="preview-loading-overlay"><span aria-hidden="true" className="preview-spinner" /><span>{t("characters.preview_loading", "Loading animation…")}</span></div>}</div></div>
      <button className="stage-preview-status" onClick={openPreview} type="button">{statusLabel}<i className={previewAvailable ? "ready" : ""} /></button>
      <div className="animation-shortcut-carousel">
        <button className="shortcut-nav" aria-label="Previous animations" disabled={!previewAvailable || shortcutPage <= 0} onClick={() => { requestedThumbnailPage.current = ""; setShortcutPage((page) => Math.max(0, page - 1)); }} type="button"><ChevronLeft size={20} /></button>
        <div className="animation-shortcuts">{shortcuts.map((name) => {
          const thumbnailBase64 = preview.clipThumbnailPngBase64?.[name] ?? "";
          const thumbnailSource = thumbnailBase64 ? `data:image/png;base64,${thumbnailBase64}` : "";
          return <button className={name === preview.selectedAnimation ? "selected" : ""} disabled={!previewAvailable} key={name} onClick={() => selectPreviewAnimation(name)} type="button"><span className="shortcut-visual">{thumbnailSource ? <img alt={`${name} animation thumbnail`} src={thumbnailSource} /> : <i className="shortcut-no-preview"><ImageOff size={18} /><small>{t("characters.no_preview", "No preview")}</small></i>}</span><span className="shortcut-name">{name}</span></button>;
        })}</div>
        <button className="shortcut-nav" aria-label="Next animations" disabled={!previewAvailable || shortcutPage >= shortcutPageCount - 1} onClick={() => { requestedThumbnailPage.current = ""; setShortcutPage((page) => Math.min(shortcutPageCount - 1, page + 1)); }} type="button"><ChevronRight size={20} /></button>
        <span className="shortcut-page-indicator">{Math.min(shortcutPage + 1, shortcutPageCount)} / {shortcutPageCount}</span>
      </div>
    </section>
    <aside className="preview-panel panel">
      <div className="preview-sidebar-tabs" role="tablist" aria-label={t("characters.preview", "Preview")}>
        <button className={previewSidebarTab === "animations" ? "active" : ""} onClick={() => setPreviewSidebarTab("animations")} role="tab" aria-selected={previewSidebarTab === "animations"} type="button"><Play size={14} />{t("characters.preview", "Animation Preview")}</button>
        <button className={previewSidebarTab === "effects" ? "active" : ""} onClick={() => setPreviewSidebarTab("effects")} role="tab" aria-selected={previewSidebarTab === "effects"} type="button"><Sparkles size={14} />{t("characters.effects", "Character Effects")}</button>
      </div>
      {previewSidebarTab === "animations" ? <>
        <div className="preview-sidebar-section-heading"><h2>{t("characters.preview")}</h2><span>{t("characters.library_count", undefined, { count: previewMatches ? preview.clips.length : 0 })}</span></div>
        <div className="animation-search"><span className="search-icon"><Search size={16} /></span><input aria-label={t("characters.search")} disabled={!previewAvailable} onChange={(event) => setAnimationSearch(event.target.value)} placeholder={t("characters.search")} value={animationSearch} /><button disabled aria-label={t("characters.filter")} title={t("characters.filter")} type="button"><ListFilter size={17} /></button></div>
        <div className="animation-list">{clips.map((name) => <button className={name === preview.selectedAnimation ? "selected" : ""} disabled={!previewAvailable} key={name} onClick={() => selectPreviewAnimation(name)} type="button"><i><AnimationIcon name={name} size={16} /></i><span>{name}</span><em aria-label="Available" /></button>)}{clips.length === 0 && <div className="animation-empty">{previewAvailable ? t("characters.no_match") : statusLabel}</div>}</div>
        <div className="preview-controls"><button className="button primary" disabled={!previewAvailable || previewDisplayLoading} onClick={togglePreviewPlayback} type="button">{previewDisplayLoading ? <span aria-hidden="true" className="preview-spinner preview-spinner-small" /> : previewPlaying ? <Pause size={16} /> : <Play size={16} />}{previewDisplayLoading ? t("characters.preview_loading_short", "Loading…") : previewPlaying ? t("characters.pause") : t("characters.play")}</button><label className="toggle"><input checked={previewLoop} disabled={!previewAvailable || previewDisplayLoading} onChange={(event) => submit({ type: "character.preview.set-loop", packageId: selected.packageId, version: selected.version, enabled: event.target.checked })} type="checkbox" /> {t("characters.loop")}</label><select aria-label="Preview speed" disabled={!previewAvailable || previewDisplayLoading} onChange={(event) => submit({ type: "character.preview.set-speed", packageId: selected.packageId, version: selected.version, speed: Number(event.target.value) as 0.5 | 1 | 1.5 | 2 })} value={previewSpeed}><option value={0.5}>0.5×</option><option value={1}>1×</option><option value={1.5}>1.5×</option><option value={2}>2×</option></select></div>
        <section className="about"><h3>{t("characters.about")}</h3><div><p>{t("characters.package")}<b>{selected.packageId}</b></p><p>{t("characters.version")}<b>{selected.version}</b></p><p>{t("characters.authority")}<b>{t("characters.godot")}</b></p><p>{t("characters.status")}<b>{selected.active ? t("characters.active") : t("characters.ready")}</b></p></div></section>
      </> : <div className="effect-sidebar-scroll">{effectPanel}</div>}
    </aside>
    <section className="character-dashboard" aria-label={t("characters.progression_dashboard", "Character progression")}>
      <article className="progress-card">
        <h3>{t("characters.level_progress", "Level & Progress")}</h3>
        <div className="relationship-heading">
          <Heart aria-hidden="true" fill="currentColor" size={26} />
          <div>
            <strong>Lv. {relationshipLevel} {relationshipName}</strong>
            <small>{t("characters.relationship_level", "Relationship level")}</small>
          </div>
        </div>
        <div className="relationship-progress" aria-label={`${relationshipProgress}%`}>
          <span style={{ width: `${relationshipProgress}%` }} />
        </div>
        <div className="relationship-meta">
          <b>{relationshipXp.toLocaleString()} XP</b>
          <span>{relationshipLevel} / {relationshipCap}</span>
        </div>
        <div className="relationship-next">
          <span>{canonicalProgress === undefined ? t("characters.progress_pending", "Waiting for canonical EXP progress") : relationshipLevel < relationshipCap ? `${t("characters.next_level", "Next")}: Lv. ${relationshipLevel + 1}` : t("characters.max_relationship", "Maximum relationship reached")}</span>
          <button aria-label={t("characters.rewards", "Rewards")} disabled type="button"><Gift size={20} /></button>
        </div>
      </article>
      <article className="skills-card">
        <h3>{t("characters.skills", "Skills")}</h3>
        <div className="skills-grid">
          {dashboardSkills.map((skill) => {
            const SkillIcon = skill.icon;
            return <div className={`skill-row skill-${skill.id}`} key={skill.id}>
              <span className="skill-icon"><SkillIcon size={17} /></span>
              <b>{skill.label}</b>
              <em>Lv. {skill.level}</em>
            </div>;
          })}
        </div>
        <button className="view-skills-button" disabled type="button">{t("characters.view_all_skills", "View All Skills")}</button>
      </article>
    </section>
  </main>;
}
/*
 * Pre-ADR-0053 chat implementation retained only as migration history. It is
 * excluded from the bundle so Electron cannot infer presentation state or
 * issue animation commands outside Runtime ownership.
export function LegacyChat({ runtime, locale }: Readonly<{ runtime: RuntimeSnapshot | null; locale: LocaleName }>): ReactElement {
  const [chatAction, setChatAction] = useState<"reconnect" | "clear" | null>(null);
  const requestedAvatar = useRef("");
  const requestedAnimation = useRef("");
  const canSubmit = runtime?.chat.status === "ready";
  const messages = runtime?.chat.messages ?? [];
  const companion = runtime?.characters.find((character) => character.active) ?? runtime?.characters[0];
  const companionIdentity = companion ? `${companion.packageId}@${companion.version}` : "";
  const companionPreviewMatches = Boolean(companion && runtime?.preview.packageId === companion.packageId && runtime.preview.version === companion.version);
  const companionImage = runtime && companion ? buildPreviewFrameSource(runtime.preview, companionPreviewMatches) : "";
  const currentTurnCount = messages.filter((item) => item.role === "user").length;
  const hasStreamingMessage = messages.some((item) => item.role === "assistant" && item.status === "streaming");
  const isTurnRunning = runtime?.chat.status === "thinking";
  const isWaitingForFirstDelta = Boolean(isTurnRunning && !hasStreamingMessage);
  const lastAssistantId = [...messages].reverse().find((item) => item.role === "assistant")?.id ?? "";
  const presence = !runtime || runtime.chat.status === "offline" ? "offline" : runtime.chat.status === "failed" ? "attention" : runtime.chat.status === "thinking" ? "thinking" : "online";
  const t = (key: string, fallback?: string, values?: Readonly<Record<string, string | number>>): string => translate(locale, key, fallback, values);
  const submitChat = useCallback(async (prompt: string): Promise<void> => {
    if (!canSubmit) throw new Error("OCP Runtime Chat is not ready");
    await window.ocpShell.sendRuntimeCommand({ type: "chat.submit", prompt });
  }, [canSubmit]);
  useEffect(() => {
    if (!companion || !runtime) return;
    // Runtime owns the package and provides a bounded PNG frame. Electron asks
    // only for the active character's preview and never reads package files.
    if (requestedAvatar.current === companionIdentity) return;
    requestedAvatar.current = companionIdentity;
    void window.ocpShell.sendRuntimeCommand({ type: "character.preview.open", packageId: companion.packageId, version: companion.version }).catch(() => undefined);
  }, [companion, companionIdentity, companionPreviewMatches, runtime]);
  useEffect(() => {
    if (chatAction === "reconnect" && runtime?.chat.status === "ready") setChatAction(null);
    if (chatAction === "clear" && messages.length === 0) setChatAction(null);
  }, [chatAction, messages.length, runtime?.chat.status]);
  const runChatAction = (type: "chat.reconnect" | "chat.session.clear"): void => {
    if (!runtime || isTurnRunning || chatAction) return;
    setChatAction(type === "chat.reconnect" ? "reconnect" : "clear");
    void window.ocpShell.sendRuntimeCommand({ type }).catch(() => setChatAction(null));
  };
  const ttsEnabled = runtime?.controlCenter?.ai?.settings.ttsEnabled ?? false;
  const voiceTestStatus = runtime?.controlCenter?.ai?.voiceTest.status ?? "idle";
  const voiceHealth = !ttsEnabled ? "disabled" : runtime?.voice?.status ?? (voiceTestStatus === "testing" ? "synthesizing" : voiceTestStatus === "succeeded" ? "healthy" : voiceTestStatus === "failed" ? "failed" : "idle");
  const voiceHealthLabel = voiceHealth === "disabled" ? t("chat.voice_off") : voiceHealth === "synthesizing" ? t("chat.voice_preparing") : voiceHealth === "playing" ? t("chat.voice_speaking") : voiceHealth === "healthy" ? t("chat.voice_ready") : voiceHealth === "failed" || voiceHealth === "degraded" ? t("chat.voice_attention") : t("chat.voice_waiting");
  const voiceHealthDetail = voiceHealth === "disabled" ? t("chat.voice_detail_off") : voiceHealth === "synthesizing" ? t("chat.voice_detail_preparing") : voiceHealth === "playing" ? t("chat.voice_detail_speaking") : voiceHealth === "healthy" ? t("chat.voice_detail_ready") : voiceHealth === "failed" || voiceHealth === "degraded" ? t("chat.voice_detail_playback_failed") : t("chat.voice_detail_waiting");
  const presentationState = runtime?.chat.presentationState ?? (voiceHealth === "playing" ? "talk" : isTurnRunning || voiceHealth === "synthesizing" ? "think" : "idle");
  const desiredAnimation = runtime ? chatAnimationForPresentation(presentationState, runtime.preview.clips, runtime.preview.selectedAnimation) : "";
  const isSpeaking = presentationState === "talk";
  const isThinking = presentationState === "think";
  const companionPortrait = companionImage
    ? <img alt={`${companion?.name ?? "OCP companion"} portrait`} src={companionImage} />
    : "◌";
  const presenceLabel = isSpeaking ? t("chat.voice_speaking") : presence === "thinking" ? t("chat.composing") : presence === "online" ? t("chat.online") : presence === "attention" ? t("chat.needs_attention") : t("chat.offline");
  const presentationLabel = presentationState === "talk" ? t("chat.state_talk") : presentationState === "think" ? t("chat.state_think") : t("chat.state_idle");
  const composerPlaceholder = !runtime || presence === "offline" || presence === "attention"
    ? t("chat.connect_to_write")
    : isTurnRunning
      ? t("chat.replying")
      : t("chat.ask_anything");
  useEffect(() => {
    if (!runtime || !companion || !companionPreviewMatches || !desiredAnimation) return;
    const requestKey = `${companionIdentity}:${presentationState}:${desiredAnimation}`;
    if (requestedAnimation.current === requestKey) return;
    requestedAnimation.current = requestKey;
    void (async () => {
      if (runtime.preview.selectedAnimation !== desiredAnimation) {
        await window.ocpShell.sendRuntimeCommand({ type: "character.preview.select", packageId: companion.packageId, version: companion.version, animation: desiredAnimation });
      }
      if (!runtime.preview.loop) {
        await window.ocpShell.sendRuntimeCommand({ type: "character.preview.set-loop", packageId: companion.packageId, version: companion.version, enabled: true });
      }
      if (!runtime.preview.isPlaying) {
        await window.ocpShell.sendRuntimeCommand({ type: "character.preview.play", packageId: companion.packageId, version: companion.version });
      }
    })().catch(() => { requestedAnimation.current = ""; });
  }, [companion, companionIdentity, companionPreviewMatches, desiredAnimation, presentationState, runtime]);
  return <OcpAssistantRuntimeProvider isRunning={Boolean(isTurnRunning)} isSendDisabled={!canSubmit} messages={messages} onSubmit={submitChat}>
  <main className="chat-layout">
    <ThreadPrimitive.Root className="chat-thread chatgpt-thread">
      <header className="chat-thread-header"><div><h1>{t("chat.title")}</h1><p>{t("chat.transcript_summary", undefined, { messages: messages.length, turns: currentTurnCount })}</p></div><div className="chat-header-actions"><div className="chat-live-status"><i className={runtime?.chat.status === "ready" ? "online" : ""} />{runtime ? `${runtime.chat.providerId} · ${runtime.chat.status}` : t("chat.unavailable")}</div><button className="chat-icon-action" disabled={!runtime || messages.length === 0 || isTurnRunning || chatAction !== null} onClick={() => runChatAction("chat.session.clear")} title={t("chat.new")} type="button">＋</button></div></header>
      <ThreadPrimitive.Viewport aria-live="polite" className="messages chat-transcript">
        {messages.length === 0 && runtime && <section className="chat-empty"><i aria-hidden="true">✦</i><h2>{t("chat.empty_title")}</h2><p>{t("chat.empty_detail")}</p></section>}
        <ThreadPrimitive.Messages>{({ message }) => {
          const hasVisibleText = message.content.some((part) => part.type === "text" && part.text.trim().length > 0);
          if (message.role === "assistant" && !hasVisibleText) return null;
          return <MessagePrimitive.Root className={`message ${message.role === "user" ? "local" : "assistant"} ${message.status?.type === "incomplete" ? "failed" : ""}`}>
            {message.role === "assistant" && <i aria-hidden="true" className={`message-avatar ${companionImage ? "has-character" : ""} ${message.id === lastAssistantId ? isSpeaking ? "is-speaking" : isThinking ? "is-thinking" : "" : ""}`}>{companionPortrait}</i>}
            <div className="message-content"><MessagePrimitive.Parts>{({ part }) => part.type === "text" ? <p>{message.status?.type === "incomplete" ? t("chat.response_failed") : part.text}</p> : null}</MessagePrimitive.Parts><ActionBarPrimitive.Root className="message-actions"><ActionBarPrimitive.Copy aria-label={t("chat.copy")} title={t("chat.copy")}>▣</ActionBarPrimitive.Copy></ActionBarPrimitive.Root></div>
          </MessagePrimitive.Root>;
        }}</ThreadPrimitive.Messages>
        {isWaitingForFirstDelta && <div className="typing-indicator" role="status"><i aria-hidden="true" /><i aria-hidden="true" /><i aria-hidden="true" /><span>{t("chat.composing")}</span></div>}
        {!runtime && <p className="message assistant">{t("chat.unavailable")}</p>}
      </ThreadPrimitive.Viewport>
      <ThreadPrimitive.ViewportFooter className="chat-footer"><ComposerPrimitive.Root className="chat-composer"><div className="composer-row"><button aria-disabled="true" className="composer-icon" disabled title={t("chat.attach_unavailable")} type="button">＋</button><ComposerPrimitive.Input addAttachmentOnPaste={false} aria-label={t("chat.write")} placeholder={composerPlaceholder} rows={1} submitMode="enter" /><ComposerPrimitive.Send aria-label={t("chat.send")} className="composer-send">{isTurnRunning ? "…" : "↑"}</ComposerPrimitive.Send></div><span className="composer-hint">{t("chat.multiline_hint")}</span></ComposerPrimitive.Root></ThreadPrimitive.ViewportFooter>
    </ThreadPrimitive.Root>
    <aside className="chat-side panel"><div className="companion-rail-heading"><span>{t("chat.companion")}</span><h2>{companion?.name ?? "OCP Companion"}</h2></div><div className={`chat-character-stage is-${presentationState}`} data-state={presentationState}><div className={companionImage ? "has-character" : ""}>{companionPortrait}</div><small>{presentationLabel}</small></div><div className="companion-presence"><i className={`${companionImage ? "has-character" : ""} ${isSpeaking ? "is-speaking" : isThinking ? "is-thinking" : ""}`}>{companionPortrait}</i><div><b>{presenceLabel}</b><small>{runtime ? t("chat.connected", undefined, { provider: runtime.chat.providerId }) : t("chat.start")}</small></div></div>{runtime && (presence === "offline" || presence === "attention") ? <button className="button primary" disabled={chatAction !== null || isTurnRunning} onClick={() => runChatAction("chat.reconnect")} type="button">{chatAction === "reconnect" ? t("chat.connecting") : t("chat.connect")}</button> : null}<div className="voice-state"><div><small>{t("chat.voice")}</small><b>{voiceHealthLabel}</b></div><i className={voiceHealth === "healthy" ? "enabled" : voiceHealth === "failed" || voiceHealth === "degraded" ? "attention" : voiceHealth === "synthesizing" || voiceHealth === "playing" ? "testing" : ""} aria-label={voiceHealthLabel} /></div><p>{voiceHealthDetail}</p><OpenWindow locale={locale} view="settings" /></aside>
  </main>
  </OcpAssistantRuntimeProvider>;
}
*/
export function LegacyChat({ runtime, locale }: Readonly<{ runtime: RuntimeSnapshot | null; locale: LocaleName }>): ReactElement {
  return <ChatView locale={locale} runtime={runtime} storeAvailable={false} />;
}
export function App(): ReactElement {
  const [view, setView] = useState<ShellView>("home");
  const [controlPage, setControlPage] = useState<ControlCenterPage>("settings");
  const [appearance, setAppearance] = useState<ShellAppearance>(DEFAULT_SHELL_APPEARANCE);
  const [appearancePreview, setAppearancePreview] = useState<ShellAppearance | null>(null);
  const [controlFontPreview, setControlFontPreview] = useState<ControlFontFamily | null>(null);
  const [runtime, setRuntime] = useState<RuntimeSnapshot | null>(null);
  const [storeLink, setStoreLink] = useState<StoreDeepLink | null>(null);
  const [storeAvailable, setStoreAvailable] = useState(false);
  const [onboarding, setOnboarding] = useState<OnboardingState | null>(null);
  const [manualFirstRun, setManualFirstRun] = useState(false);
  // Existing-library migration is a bootstrap-only compatibility decision.
  // Once a clean First Run session starts, installing Sabai must not later
  // satisfy this migration path and silently complete onboarding mid-Wizard.
  const initialLibraryMigrationChecked = useRef(false);
  const applyIntent = (intent: ShellIntent): void => {
    const page = controlPageForShellView(intent.view);
    if (page) {
      setView("home");
      setControlPage(page);
      return;
    }
    setView(intent.view);
  };
  useEffect(() => {
    let offIntent = (): void => undefined;
    let offAppearance = (): void => undefined;
    let offRuntime = (): void => undefined;
    let offStoreLink = (): void => undefined;
    let runtimeConnected = false;
    const applyRuntimeState = (state: RuntimeSnapshot | null): void => {
      runtimeConnected = state !== null;
      setRuntime(state);
      if (state) { setAppearance(state.appearance); setAppearancePreview(null); setControlFontPreview(null); }
    };
    void window.ocpShell.getBootstrap().then((bootstrap) => {
      applyIntent(bootstrap.intent); setAppearance(bootstrap.appearance); setAppearancePreview(null); setControlFontPreview(null); setStoreLink(bootstrap.storeLink); setStoreAvailable(Boolean(bootstrap.storeUrl)); setOnboarding(bootstrap.onboarding); document.documentElement.dataset.platform = bootstrap.platform;
      return window.ocpShell.getRuntimeState();
    }).then(applyRuntimeState).catch(() => undefined);
    offIntent = window.ocpShell.onIntent(applyIntent);
    offStoreLink = window.ocpShell.onStoreLink((link) => { setStoreLink(link); setView("characters"); });
    offAppearance = window.ocpShell.onAppearance((next) => { setAppearance(next); setAppearancePreview(null); setControlFontPreview(null); });
    offRuntime = window.ocpShell.onRuntimeState(applyRuntimeState);
    // Push events are authoritative. Poll only while disconnected so the Shell
    // can recover after a Runtime crash/restart without requiring a window
    // reload. Null poll results never overwrite an already-connected snapshot.
    const runtimeRecoveryTimer = window.setInterval(() => {
      if (runtimeConnected) return;
      void window.ocpShell.getRuntimeState().then((state) => { if (state) applyRuntimeState(state); }).catch(() => undefined);
    }, 500);
    return () => { window.clearInterval(runtimeRecoveryTimer); offIntent(); offStoreLink(); offAppearance(); offRuntime(); };
  }, []);
  const retryRuntimeConnection = useCallback(async (): Promise<boolean> => {
    try {
      const state = await window.ocpShell.getRuntimeState();
      if (!state) return false;
      setRuntime(state);
      setAppearance(state.appearance);
      setAppearancePreview(null);
      setControlFontPreview(null);
      return true;
    } catch {
      return false;
    }
  }, []);
  useEffect(() => {
    if (initialLibraryMigrationChecked.current || !onboarding || !runtime) return;
    initialLibraryMigrationChecked.current = true;
    if (!shouldMigrateExistingLibrary(onboarding, runtime)) return;
    void window.ocpShell.completeOnboarding("existing-library").then(setOnboarding).catch(() => undefined);
  }, [onboarding, runtime]);
  const completeFirstRun = useCallback(async (reason: OnboardingCompletionReason): Promise<void> => {
    const next = await window.ocpShell.completeOnboarding(reason);
    setOnboarding(next);
    setManualFirstRun(false);
  }, []);
  const firstRunVisible = view === "home" && (manualFirstRun || shouldShowFirstRunWizard(onboarding, runtime));
  const controlSettings = runtime?.controlCenter?.settings;
  const runtimeAppearance: ShellAppearance = {
    ...appearance,
    theme: controlSettings?.themePreset ?? appearance.theme,
    locale: localeFromSettings(controlSettings?.language ?? appearance.locale),
    fontFamily: appearance.fontFamily,
    textScale: controlSettings?.textScale ?? appearance.textScale,
    reduceMotion: controlSettings?.reduceMotion ?? appearance.reduceMotion,
  };
  const effectiveAppearance = appearancePreview ?? runtimeAppearance;
  const effectiveTheme = effectiveAppearance.theme;
  const locale = localeFromSettings(effectiveAppearance.locale);
  const effectiveFont = controlFontPreview
    ? controlFontStacks[controlFontPreview]
    : appearancePreview
      ? fontFamilyStacks[appearancePreview.fontFamily]
      : controlSettings
        ? controlFontStacks[controlSettings.fontFamily]
        : fontFamilyStacks[appearance.fontFamily];
  const effectiveScale = textScaleValues[effectiveAppearance.textScale];
  const previewSettings = useCallback((settings: NonNullable<RuntimeSnapshot["controlCenter"]>["settings"]): void => {
    // Theme/locale/scale continue through the portable appearance contract,
    // while the Windows Control Center font is previewed by its exact stack.
    setControlFontPreview(settings.fontFamily);
    setAppearancePreview({ ...appearance, theme: settings.themePreset, locale: settings.language, textScale: settings.textScale, reduceMotion: settings.reduceMotion });
  }, [appearance]);
  const variables = useMemo(() => { const token = themes[effectiveTheme]; return { "--canvas": token.canvas, "--canvas-raised": token.canvasRaised, "--panel": token.panel, "--panel-strong": token.panelStrong, "--border": token.border, "--border-bright": token.borderBright, "--text": token.text, "--text-muted": token.textMuted, "--cyan": token.cyan, "--blue": token.blue, "--violet": token.violet, "--danger": token.danger, "--success": token.success, "--shadow": token.shadow, "--blur": token.blur, "--font-stack": effectiveFont, "--text-scale": String(effectiveScale) } as React.CSSProperties; }, [effectiveTheme, effectiveFont, effectiveScale]);
  const reduceMotion = effectiveAppearance.reduceMotion;
  return <div className={reduceMotion ? "shell reduce-motion" : "shell"} data-theme={effectiveTheme} style={variables}>
    {view !== "chat" && <Header locale={locale} runtime={runtime} storeAvailable={storeAvailable} view={view} />}
    {view === "home" && <ControlCenter locale={locale} onAppearancePreview={previewSettings} onRunSetup={() => setManualFirstRun(true)} page={controlPage} runtime={runtime} setPage={setControlPage} />}
    {(view === "characters" || view === "library") && <Characters initialTab={view === "library" ? "library" : "installed"} locale={locale} onRetryRuntime={retryRuntimeConnection} runtime={runtime} storeAvailable={storeAvailable} storeLink={storeLink} />}
    {view === "chat" && <ChatView locale={locale} runtime={runtime} storeAvailable={storeAvailable} />}
    {firstRunVisible && runtime && <FirstRunWizard initialLanguage={runtime.controlCenter?.settings.language ?? "en"} onComplete={completeFirstRun} runtime={runtime} storeAvailable={storeAvailable} />}
  </div>;
}
