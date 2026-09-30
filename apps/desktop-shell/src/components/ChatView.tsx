import {
  ActionBarMorePrimitive,
  ActionBarPrimitive,
  AuiIf,
  ComposerPrimitive,
  MessagePrimitive,
  ThreadPrimitive,
} from "@assistant-ui/react";
import {
  ArrowUp,
  Check,
  ChevronDown,
  Copy,
  MessageSquare,
  Mic,
  MoreHorizontal,
  PanelLeftClose,
  PanelLeftOpen,
  Pencil,
  Plus,
  RefreshCw,
  Settings,
  Sparkles,
  Users,
  Volume2,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type ReactElement } from "react";

import type { RuntimeBridgeCommand, RuntimeChatPresentation, RuntimeSnapshot } from "../../electron/runtime-bridge";
import type { LocaleName } from "../contracts/appearance";
import { characterDisplayName } from "../contracts/character-presentation";
import { buildPreviewFrameSource } from "../contracts/preview-frame";
import { translate } from "../i18n";
import { OcpAssistantRuntimeProvider } from "./OcpAssistantRuntimeProvider";
import { AccountControl } from "./AccountControl";

type ChatViewProps = Readonly<{ runtime: RuntimeSnapshot | null; locale: LocaleName; storeAvailable?: boolean }>;

function IconButton({ label, children, className = "", disabled = false, onClick }: Readonly<{
  label: string;
  children: ReactElement;
  className?: string;
  disabled?: boolean;
  onClick?: () => void;
}>): ReactElement {
  return <button aria-label={label} className={`gpt-icon-button ${className}`} disabled={disabled} onClick={onClick} title={label} type="button">{children}</button>;
}

function EditComposer({ cancelLabel, saveLabel }: Readonly<{ cancelLabel: string; saveLabel: string }>): ReactElement {
  return <ComposerPrimitive.Root className="gpt-edit-composer">
    <ComposerPrimitive.Input aria-label="Edit message" rows={2} />
    <div><ComposerPrimitive.Cancel type="button">{cancelLabel}</ComposerPrimitive.Cancel><ComposerPrimitive.Send type="button">{saveLabel}</ComposerPrimitive.Send></div>
  </ComposerPrimitive.Root>;
}

function Composer({ placeholder, labels, dictationActive, dictationDisabled, onDictationToggle }: Readonly<{
  placeholder: string;
  labels: Readonly<Record<string, string>>;
  dictationActive: boolean;
  dictationDisabled: boolean;
  onDictationToggle: () => void;
}>): ReactElement {
  return <ComposerPrimitive.Root className="gpt-composer">
    <div className="gpt-composer-row">
      <IconButton disabled label={labels.attachment}><Plus size={20} /></IconButton>
      <ComposerPrimitive.Input addAttachmentOnPaste={false} aria-label={labels.write} autoFocus placeholder={placeholder} rows={1} submitMode="enter" />
      <div className="gpt-composer-actions">
        <AuiIf condition={(state) => state.thread.isRunning}>
          <ComposerPrimitive.Cancel aria-label={labels.stop} className="gpt-primary-action" title={labels.stop}><span /></ComposerPrimitive.Cancel>
        </AuiIf>
        <AuiIf condition={(state) => !state.thread.isRunning && !state.composer.isEmpty}>
          <ComposerPrimitive.Send aria-label={labels.send} className="gpt-primary-action" title={labels.send}><ArrowUp size={21} /></ComposerPrimitive.Send>
        </AuiIf>
        <AuiIf condition={(state) => !state.thread.isRunning && state.composer.isEmpty}>
          <IconButton className={dictationActive ? "is-current" : ""} disabled={dictationDisabled} label={dictationActive ? labels.dictationStop : labels.dictationStart} onClick={onDictationToggle}><Mic size={19} /></IconButton>
        </AuiIf>
      </div>
    </div>
  </ComposerPrimitive.Root>;
}

function fallbackPresentation(runtime: RuntimeSnapshot | null): RuntimeChatPresentation {
  const state = runtime?.chat.presentationState ?? (runtime?.chat.status === "thinking" ? "think" : "idle");
  return {
    owner: "chat",
    state,
    sequence: 0,
    turnId: runtime?.chat.activeMessageId ?? "",
    messageId: runtime?.chat.activeMessageId ?? "",
    speechId: "",
    reasonCode: state === "think" ? "turn-active" : "ready",
  };
}

export function ChatView({ runtime, locale, storeAvailable = false }: ChatViewProps): ReactElement {
  const [panelCollapsed, setPanelCollapsed] = useState(false);
  const messages = runtime?.chat.messages ?? [];
  const isRunning = runtime?.chat.status === "thinking";
  const canSubmit = runtime?.chat.status === "ready";
  const revision = runtime?.chat.revision ?? 0;
  const presentation = runtime?.chat.presentation ?? fallbackPresentation(runtime);
  const activeCompanion = runtime?.characters.find((character) => character.active) ?? null;
  const previewMatches = Boolean(activeCompanion && runtime && runtime.preview.packageId === activeCompanion.packageId && runtime.preview.version === activeCompanion.version);
  const companionFrame = runtime ? buildPreviewFrameSource(runtime.preview, previewMatches) : "";
  const t = useCallback((key: string, fallback: string, values: Readonly<Record<string, string | number>> = {}): string => translate(locale, key, fallback, values), [locale]);
  const companionDisplayName = activeCompanion
    ? characterDisplayName(activeCompanion.name, activeCompanion.packageId)
    : t("chat.companion_name", "OCP Companion");
  const voicePreparing = presentation.reasonCode === "voice-synthesizing" || runtime?.voice?.status === "synthesizing";
  const stateLabel = useMemo(() => voicePreparing
    ? t("chat.voice_preparing", "Preparing voice…")
    : ({
      idle: t("chat.state_idle", "Idle"),
      think: t("chat.state_think", "Thinking"),
      talk: t("chat.state_talk", "Speaking"),
    }[presentation.state]), [presentation.state, t, voicePreparing]);
  const chatVoiceMode = runtime?.controlCenter?.ai?.settings.chatVoiceMode ?? "on-demand";
  const voiceModeLabel = chatVoiceMode === "off"
    ? t("chat.voice_off", "Off")
    : chatVoiceMode === "auto-speak"
      ? t("chat.voice_auto_speak", "Auto Speak")
      : chatVoiceMode === "live-voice"
        ? t("chat.voice_live", "Live Voice")
        : t("chat.voice_on_demand", "On demand");
  const voiceFailure = runtime?.voice?.status === "failed" ? runtime.voice.reasonCode : "";
  const voiceRetryAtMs = runtime?.voice?.retryAtMs ?? 0;
  const [voiceClockMs, setVoiceClockMs] = useState(() => Date.now());
  useEffect(() => {
    if (voiceFailure !== "provider-rate-limited" || voiceRetryAtMs <= Date.now()) return;
    setVoiceClockMs(Date.now());
    const timer = window.setInterval(() => setVoiceClockMs(Date.now()), 250);
    return () => window.clearInterval(timer);
  }, [voiceFailure, voiceRetryAtMs]);
  const voiceRetrySeconds = voiceFailure === "provider-rate-limited"
    ? Math.max(0, Math.ceil((voiceRetryAtMs - voiceClockMs) / 1000))
    : 0;
  const voiceRateLimited = voiceFailure === "provider-rate-limited" && voiceRetrySeconds > 0;
  const readAloudLockRef = useRef("");
  const [readAloudPendingMessageId, setReadAloudPendingMessageId] = useState("");
  const runtimeVoiceBusy = runtime?.voice?.status === "synthesizing" || runtime?.voice?.status === "playing";
  const voiceTransportBusy = runtimeVoiceBusy || Boolean(readAloudPendingMessageId);
  useEffect(() => {
    if (!readAloudPendingMessageId) return;
    if (runtimeVoiceBusy || voiceRateLimited) {
      readAloudLockRef.current = "";
      setReadAloudPendingMessageId("");
      return;
    }
    const timer = window.setTimeout(() => {
      readAloudLockRef.current = "";
      setReadAloudPendingMessageId("");
    }, 5000);
    return () => window.clearTimeout(timer);
  }, [readAloudPendingMessageId, runtimeVoiceBusy, voiceRateLimited]);
  const voiceHealthLabel = voiceFailure === "provider-credential-required"
    ? t("chat.voice_error.credential_required", "Cloud voice needs a Gemini API key. Add one in AI & Voice or explicitly choose Windows system voice.")
    : voiceFailure === "local-voice-not-installed"
      ? t("chat.voice_error.local_voice", "No matching local voice is installed. Install a Thai Windows voice or choose Gemini cloud voice.")
      : voiceFailure === "dns-unreachable"
      ? t("chat.voice_error.dns", "The cloud voice host cannot be reached. Check DNS or proxy settings.")
      : voiceFailure === "provider-auth-failed"
        ? t("chat.voice_error.auth", "The voice provider rejected its credential.")
        : voiceFailure === "provider-rate-limited"
          ? t("chat.voice_error.rate_limited", "Voice is temporarily rate-limited. Retry in {seconds}s.", { seconds: voiceRetrySeconds })
          : voiceFailure === "provider-quota-exceeded"
            ? t("chat.voice_error.quota", "The voice provider quota is exhausted.")
            : voiceFailure
            ? t("chat.voice_error.unavailable", "Read aloud could not produce playable audio.")
            : chatVoiceMode === "off"
              ? t("chat.voice_off_detail", "Voice is disabled. Text chat remains available.")
              : chatVoiceMode === "auto-speak"
                ? t("chat.voice_auto_speak_detail", "Completed replies are spoken automatically without delaying the text response.")
                : chatVoiceMode === "live-voice"
                  ? t("chat.voice_live_detail", "Live Voice uses Gemini 3.8 Live for low-latency audio-to-audio conversation with barge-in.")
                  : t("chat.voice_on_demand_detail", "Use Read aloud on a reply. Chat will not delay text while preparing speech.");
  const send = useCallback(async (command: RuntimeBridgeCommand): Promise<void> => {
    await window.ocpShell.sendRuntimeCommand(command);
  }, []);
  const [dictationActive, setDictationActive] = useState(false);
  const [dictationBusy, setDictationBusy] = useState(false);
  const toggleDictation = useCallback(async (): Promise<void> => {
    if (!runtime || dictationBusy) return;
    setDictationBusy(true);
    try {
      if (dictationActive) {
        await send({ type: "voice.input.stop" });
        setDictationActive(false);
      } else {
        await send({ type: "voice.input.start" });
        setDictationActive(true);
      }
    } catch {
      setDictationActive(false);
    } finally {
      setDictationBusy(false);
    }
  }, [dictationActive, dictationBusy, runtime, send]);
  useEffect(() => () => {
    void window.ocpShell.sendRuntimeCommand({ type: "voice.input.stop" }).catch(() => undefined);
  }, []);
  useEffect(() => {
    if (!runtime) setDictationActive(false);
  }, [runtime]);
  const onSubmit = useCallback(async (prompt: string): Promise<void> => {
    if (!canSubmit) throw new Error("OCP Runtime Chat is not ready");
    await send({ type: "chat.submit", prompt });
  }, [canSubmit, send]);
  const onCancel = useCallback(() => send({ type: "chat.turn.cancel", expectedRevision: revision }), [revision, send]);
  const onEdit = useCallback((messageId: string, prompt: string) => send({ type: "chat.message.edit", messageId, prompt, expectedRevision: revision }), [revision, send]);
  const onReload = useCallback((messageId: string) => send({ type: "chat.message.regenerate", messageId, expectedRevision: revision }), [revision, send]);
  const readAloud = useCallback((messageId: string): void => {
    if (voiceRateLimited || voiceTransportBusy || readAloudLockRef.current) return;
    readAloudLockRef.current = messageId;
    setReadAloudPendingMessageId(messageId);
    void send({ type: "chat.message.read-aloud", messageId, expectedRevision: revision }).catch(() => {
      if (readAloudLockRef.current === messageId) readAloudLockRef.current = "";
      setReadAloudPendingMessageId((current) => current === messageId ? "" : current);
    });
  }, [revision, send, voiceRateLimited, voiceTransportBusy]);
  const readAloudCooldownLabel = t("chat.voice_retry", "Retry in {seconds}s", { seconds: voiceRetrySeconds });
  const newChat = useCallback((): void => {
    if (!runtime) return;
    void send({ type: "chat.session.new", expectedRevision: revision }).catch(() => undefined);
  }, [revision, runtime, send]);
  const reconnect = useCallback((): void => {
    if (!runtime || isRunning) return;
    void send({ type: "chat.reconnect" }).catch(() => undefined);
  }, [isRunning, runtime, send]);

  const labels = {
    attachment: t("chat.attach_unavailable", "Attachments are not available in this build"),
    write: t("chat.write", "Write a message"),
    stop: t("chat.stop", "Stop generating"),
    send: t("chat.send", "Send"),
    dictationStart: t("chat.dictation_start", "Start voice input"),
    dictationStop: t("chat.dictation_stop", "Stop voice input"),
  };
  const placeholder = !runtime || runtime.chat.status === "offline" || runtime.chat.status === "failed"
    ? t("chat.connect_to_write", "Connect the Runtime AI provider to write a message")
    : t("chat.ask_anything", "Ask anything");

  return <OcpAssistantRuntimeProvider
    isRunning={isRunning}
    isSendDisabled={!canSubmit}
    messages={messages}
    onCancel={onCancel}
    onEdit={onEdit}
    onReload={onReload}
    onSubmit={onSubmit}
  >
    <main className={`gpt-shell ${panelCollapsed ? "is-panel-collapsed" : ""}`} data-presentation-owner={presentation.owner} data-presentation-state={presentation.state}>
      <aside aria-label={t("chat.navigation", "Chat navigation")} className="gpt-nav-rail">
        <IconButton className="is-current" label={t("nav.chat", "Chat")}><MessageSquare size={20} /></IconButton>
        <IconButton label={t("chat.new", "New chat")} onClick={newChat}><Plus size={21} /></IconButton>
        <div className="gpt-nav-spacer" />
        <IconButton label={t("nav.characters", "Characters")} onClick={() => void window.ocpShell.openView("characters")}><Users size={19} /></IconButton>
        <IconButton label={t("nav.settings", "Settings")} onClick={() => void window.ocpShell.openView("settings")}><Settings size={19} /></IconButton>
      </aside>

      <aside aria-label={t("chat.companion_panel", "Companion panel")} className="gpt-companion-panel">
        <header>
          <div className="gpt-companion-heading"><Sparkles size={17} /><span>{t("chat.companion", "COMPANION")}</span></div>
          <IconButton label={panelCollapsed ? t("chat.expand_companion", "Expand companion panel") : t("chat.collapse_companion", "Collapse companion panel")} onClick={() => setPanelCollapsed((value) => !value)}>
            {panelCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
          </IconButton>
        </header>
        <div className="gpt-companion-content">
          <div aria-label={`${companionDisplayName}: ${stateLabel}`} aria-live="polite" className={`gpt-companion-stage is-${presentation.state}`}>
            <div className="gpt-aura-gate" />
            {companionFrame
              ? <img alt={companionDisplayName} className="gpt-companion-character" src={companionFrame} />
              : <div aria-hidden="true" className="gpt-companion-fallback"><Sparkles size={30} /></div>}
          </div>
          <div className="gpt-companion-identity">
            <strong>{companionDisplayName}</strong>
            <span className={`gpt-live-state is-${presentation.state}`}><i />{stateLabel}</span>
          </div>
          <section className="gpt-companion-status">
            <span>{t("chat.provider", "AI provider")}</span>
            <strong>{runtime ? `${runtime.chat.providerId} · ${runtime.chat.status}` : t("chat.offline", "Offline")}</strong>
          </section>
          <section className="gpt-voice-mode-card">
            <div><Volume2 size={17} /><span>{t("chat.voice_mode", "Voice Mode")}</span></div>
            <strong>{voiceModeLabel}</strong>
            <p className={voiceFailure === "provider-rate-limited" ? "is-rate-limited" : voiceFailure ? "is-error" : ""}>{voiceHealthLabel}</p>
          </section>
        </div>
      </aside>

      <section className="gpt-chat-pane">
        <header className="gpt-chat-header">
          <button className="gpt-model-button" type="button">OCP Companion <ChevronDown size={16} /></button>
          <div className="gpt-header-actions">
            <AccountControl locale={locale} runtime={runtime} storeAvailable={storeAvailable} />
            <button className={`gpt-provider-state is-${runtime?.chat.status ?? "offline"}`} disabled={isRunning} onClick={runtime?.chat.status === "offline" || runtime?.chat.status === "failed" ? reconnect : undefined} title={runtime ? `${runtime.chat.providerId} Runtime provider status` : t("chat.offline", "Offline")} type="button"><i />{runtime ? `${runtime.chat.providerId} · ${runtime.chat.status}` : t("chat.offline", "Offline")}</button>
          </div>
        </header>
        <ThreadPrimitive.Root className="gpt-thread">
          {messages.length === 0 ? <section className="gpt-empty-state">
            <h1>{t("chat.empty_title_literal", "Where should we begin?")}</h1>
            <Composer dictationActive={dictationActive} dictationDisabled={dictationBusy || !runtime} labels={labels} onDictationToggle={() => { void toggleDictation(); }} placeholder={placeholder} />
          </section> : <ThreadPrimitive.Viewport className="gpt-viewport">
            <ThreadPrimitive.Messages>{({ message }) => {
              if (message.composer.isEditing) return <EditComposer cancelLabel={t("common.cancel", "Cancel")} saveLabel={t("common.save", "Save")} />;
              const hasVisibleText = message.content.some((part) => part.type === "text" && part.text.trim().length > 0);
              if (message.role === "assistant" && !hasVisibleText) return null;
              if (message.role === "user") return <MessagePrimitive.Root className="gpt-message gpt-user-message">
                <div className="gpt-user-bubble"><MessagePrimitive.Parts /></div>
                <ActionBarPrimitive.Root className="gpt-message-actions" hideWhenRunning>
                  <ActionBarPrimitive.Copy aria-label={t("chat.copy", "Copy")} title={t("chat.copy", "Copy")}><Copy size={18} /></ActionBarPrimitive.Copy>
                  <ActionBarPrimitive.Edit aria-label={t("chat.edit", "Edit")} title={t("chat.edit", "Edit")}><Pencil size={18} /></ActionBarPrimitive.Edit>
                </ActionBarPrimitive.Root>
              </MessagePrimitive.Root>;
              const voiceActive = presentation.messageId === message.id && presentation.reasonCode.startsWith("voice-") && presentation.reasonCode !== "voice-failed";
              const voicePendingForMessage = readAloudPendingMessageId === message.id;
              const voicePreparingForMessage = voicePendingForMessage || (voiceActive && presentation.reasonCode === "voice-synthesizing");
              return <MessagePrimitive.Root className="gpt-message gpt-assistant-message">
                <div className="gpt-assistant-copy"><MessagePrimitive.Parts>{({ part }) => part.type === "text" ? <p>{part.text}</p> : null}</MessagePrimitive.Parts></div>
                <ActionBarPrimitive.Root className="gpt-message-actions gpt-assistant-actions" hideWhenRunning>
                  <ActionBarPrimitive.Copy aria-label={t("chat.copy", "Copy")} title={t("chat.copy", "Copy")}><AuiIf condition={(state) => state.message.isCopied}><Check size={18} /></AuiIf><AuiIf condition={(state) => !state.message.isCopied}><Copy size={18} /></AuiIf></ActionBarPrimitive.Copy>
                  <button aria-busy={voicePreparingForMessage || undefined} aria-label={voiceRateLimited ? readAloudCooldownLabel : voicePreparingForMessage ? t("chat.voice_preparing", "Preparing voice…") : voiceActive ? t("chat.reading_aloud", "Reading aloud") : t("chat.read_aloud", "Read aloud")} className={voicePreparingForMessage ? "is-active is-voice-progress" : voiceActive ? "is-active" : voiceRateLimited ? "is-cooldown" : ""} disabled={voiceTransportBusy || voiceRateLimited} onClick={() => readAloud(message.id)} title={voiceRateLimited ? readAloudCooldownLabel : voicePreparingForMessage ? t("chat.voice_preparing", "Preparing voice…") : voiceActive ? t("chat.reading_aloud", "Reading aloud") : t("chat.read_aloud", "Read aloud")} type="button">{voicePreparingForMessage ? <span aria-hidden="true" className="gpt-voice-spinner" /> : <Volume2 size={18} />}</button>
                  <ActionBarPrimitive.Reload aria-label={t("chat.regenerate", "Regenerate")} title={t("chat.regenerate", "Regenerate")}><RefreshCw size={18} /></ActionBarPrimitive.Reload>
                  <ActionBarMorePrimitive.Root>
                    <ActionBarMorePrimitive.Trigger aria-label={t("chat.more", "More")} title={t("chat.more", "More")}><MoreHorizontal size={19} /></ActionBarMorePrimitive.Trigger>
                    <ActionBarMorePrimitive.Content align="end" className="gpt-more-menu" side="bottom" sideOffset={6}>
                      <ActionBarMorePrimitive.Item disabled>{t("chat.export_unavailable", "Export is not available in this build")}</ActionBarMorePrimitive.Item>
                    </ActionBarMorePrimitive.Content>
                  </ActionBarMorePrimitive.Root>
                </ActionBarPrimitive.Root>
              </MessagePrimitive.Root>;
            }}</ThreadPrimitive.Messages>
            {isRunning && !messages.some((message) => message.role === "assistant" && message.status === "streaming") && <div className="gpt-thinking" role="status"><span /><span /><span /></div>}
            <ThreadPrimitive.ViewportFooter className="gpt-viewport-footer">
              <ThreadPrimitive.ScrollToBottom aria-label={t("chat.scroll_bottom", "Scroll to bottom")} className="gpt-scroll-bottom" title={t("chat.scroll_bottom", "Scroll to bottom")}><ChevronDown size={19} /></ThreadPrimitive.ScrollToBottom>
              <Composer dictationActive={dictationActive} dictationDisabled={dictationBusy || !runtime} labels={labels} onDictationToggle={() => { void toggleDictation(); }} placeholder={placeholder} />
              <p>{t("chat.disclaimer", "OCP can make mistakes. Check important info.")}</p>
            </ThreadPrimitive.ViewportFooter>
          </ThreadPrimitive.Viewport>}
        </ThreadPrimitive.Root>
        {!runtime && <div className="gpt-runtime-alert" role="status"><MessageSquare size={18} />{t("chat.unavailable", "Runtime adapter unavailable. Start OCP Runtime to begin a conversation.")}</div>}
      </section>
    </main>
  </OcpAssistantRuntimeProvider>;
}
