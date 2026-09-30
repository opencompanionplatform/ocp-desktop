import { useEffect, useState, type ReactElement } from "react";

import type { RuntimeSnapshot } from "../../electron/runtime-bridge";
import type { LocaleName } from "../contracts/appearance";
import { translate } from "../i18n";
import {
  aiControlSettingsSignature,
  aiControlSettingsValidationError,
  aiTimeoutSeconds,
  chatVoiceModes,
  controlBubbleStyles,
  controlCenterSettingsSignature,
  controlSelectableFontFamilies,
  controlTextScales,
  controlThemes,
  controlUpdateChannels,
  ttsVoiceIds,
  ttsVoiceAges,
  ttsVoiceGenders,
  ttsVoiceModes,
  thaiSpeechStyles,
  ttsModelIds,
  updateApplyCommandForDecision,
  updateMessages,
  type AIControlSettings,
  type ControlCenterPage,
  type ControlCenterSettings,
  type UpdateMessageCode,
} from "../contracts/control-center";
import type { CredentialProviderId } from "../../electron/credential-broker";

const pageCopy: Record<ControlCenterPage, Readonly<{ glyph: string; labelKey: string; detailKey: string }>> = {
  settings: { glyph: "⚙", labelKey: "page.settings", detailKey: "page.settings.detail" },
  "ai-voice": { glyph: "✦", labelKey: "page.ai_voice", detailKey: "page.ai_voice.detail" },
  updates: { glyph: "↻", labelKey: "page.updates", detailKey: "page.updates.detail" },
};

const textScaleKeys: Record<ControlCenterSettings["textScale"], string> = {
  normal: "scale.normal",
  standard: "scale.standard",
  comfortable: "scale.comfortable",
  large: "scale.large",
  extra: "scale.extra",
};

function ToggleRow({ checked, disabled, detail, label, onChange }: Readonly<{
  checked: boolean;
  disabled: boolean;
  detail: string;
  label: string;
  onChange: (value: boolean) => void;
}>): ReactElement {
  return <label className="control-toggle-row"><span><b>{label}</b><small>{detail}</small></span><input checked={checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} type="checkbox" /></label>;
}

function formatMemoryMb(value: number): string {
  if (value >= 1024) return `${(value / 1024).toFixed(value >= 10_240 ? 0 : 1)} GB`;
  return `${Math.round(value)} MB`;
}

function SettingsPage({ runtime, locale, onPreviewAppearance, onRunSetup }: Readonly<{ runtime: RuntimeSnapshot | null; locale: LocaleName; onPreviewAppearance?: (settings: ControlCenterSettings) => void; onRunSetup?: () => void }>): ReactElement {
  const authoritative = runtime?.controlCenter?.settings ?? null;
  const resources = runtime?.controlCenter?.resources ?? null;
  const hasResourceBreakdown = resources?.ocpMemoryMb !== undefined;
  const authoritativeSignature = controlCenterSettingsSignature(authoritative);
  const [draft, setDraft] = useState<ControlCenterSettings | null>(authoritative);
  const [pendingId, setPendingId] = useState("");
  const [status, setStatus] = useState<"idle" | "saving" | "saved" | "failed">("idle");
  const [errorCode, setErrorCode] = useState("");
  const t = (key: string, fallback?: string, values?: Readonly<Record<string, string | number>>): string => translate(locale, key, fallback, values);

  useEffect(() => {
    if (authoritative && !pendingId) setDraft(authoritative);
  }, [authoritativeSignature, pendingId]);

  useEffect(() => {
    if (!pendingId || !runtime) return;
    const result = runtime.commandResults.find((candidate) => candidate.id === pendingId);
    if (!result) return;
    setPendingId("");
    setStatus(result.status === "succeeded" ? "saved" : "failed");
    setErrorCode(result.errorCode);
    if (result.status !== "succeeded" && authoritative) { setDraft(authoritative); onPreviewAppearance?.(authoritative); }
  }, [authoritative, pendingId, runtime]);

  useEffect(() => {
    if (!pendingId) return;
    const timeout = window.setTimeout(() => {
      setPendingId("");
      setStatus("failed");
      setErrorCode("runtime-timeout");
      if (authoritative) { setDraft(authoritative); onPreviewAppearance?.(authoritative); }
    }, 6_000);
    return () => window.clearTimeout(timeout);
  }, [authoritativeSignature, pendingId]);

  if (!draft || !authoritative) {
    return <section className="control-page control-unavailable" aria-live="polite"><span>{t("settings.eyebrow")}</span><h1>{t("settings.unavailable.title")}</h1><p>{runtime ? t("settings.unavailable.runtime") : t("settings.unavailable.start")}</p></section>;
  }

  const update = (patch: Partial<ControlCenterSettings>): void => {
    const next = { ...draft, ...patch };
    setDraft(next);
    onPreviewAppearance?.(next);
    setStatus("idle");
    setErrorCode("");
  };
  const dirty = JSON.stringify(draft) !== JSON.stringify(authoritative);
  const save = (): void => {
    setStatus("saving");
    setErrorCode("");
    void window.ocpShell.sendRuntimeCommand({ type: "control.settings.update", settings: draft })
      .then((id) => setPendingId(id))
      .catch(() => { setStatus("failed"); setErrorCode("adapter-unavailable"); });
  };

  return <section className="control-page settings-control-page">
    <div className="control-page-heading"><div><span>{t("settings.eyebrow")}</span><h1>{t("settings.title")}</h1><p>{t("settings.subtitle")}</p></div><button className="button primary" disabled={!dirty || status === "saving"} onClick={save} type="button">{status === "saving" ? t("settings.saving") : t("settings.save")}</button></div>
    <div className={`settings-result ${status}`} aria-live="polite">{status === "saved" ? t("result.saved") : status === "saving" ? t("result.waiting") : status === "failed" ? (errorCode === "adapter-unavailable" ? t("result.adapter_unavailable") : t("result.failed")) : dirty ? t("result.unsaved") : t("result.synced")}</div>
    <div className="settings-card-grid">
      <article className="control-card appearance-card"><h2>{t("settings.appearance")}</h2><p>{t("settings.appearance.detail")}</p>
        <fieldset><legend>{t("settings.theme")}</legend><div className="theme-choice-grid">{controlThemes.map((theme) => <button aria-pressed={draft.themePreset === theme} className={draft.themePreset === theme ? "selected" : ""} key={theme} onClick={() => update({ themePreset: theme })} type="button"><i className={`theme-swatch ${theme}`} />{t(`theme.${theme}`, theme)}</button>)}</div></fieldset>
        <div className="form-grid"><label>{t("settings.font")}<select onChange={(event) => update({ fontFamily: event.target.value as ControlCenterSettings["fontFamily"] })} value={draft.fontFamily}>{controlSelectableFontFamilies.map((font) => <option key={font}>{font}</option>)}</select></label><label>{t("settings.text_size")}<select onChange={(event) => update({ textScale: event.target.value as ControlCenterSettings["textScale"] })} value={draft.textScale}>{controlTextScales.map((scale) => <option key={scale} value={scale}>{t(textScaleKeys[scale], scale)}</option>)}</select></label><label>{t("settings.bubble_style")}<select onChange={(event) => update({ bubbleStyle: event.target.value as ControlCenterSettings["bubbleStyle"] })} value={draft.bubbleStyle}>{controlBubbleStyles.map((style) => <option key={style}>{style}</option>)}</select></label><label>{t("settings.language")}<select onChange={(event) => update({ language: event.target.value as ControlCenterSettings["language"] })} value={draft.language}><option value="en">{t("language.english")}</option><option value="th">{t("language.thai")}</option></select></label></div>
        <ToggleRow checked={draft.reduceMotion} disabled={false} detail={t("settings.reduce_motion.detail")} label={t("settings.reduce_motion")} onChange={(reduceMotion) => update({ reduceMotion })} />
      </article>
      <article className="control-card behaviour-card"><h2>{t("settings.behaviour")}</h2><p>{t("settings.behaviour.detail")}</p>
        <ToggleRow checked={draft.showBubbles} disabled={false} detail={t("settings.show_bubbles.detail")} label={t("settings.show_bubbles")} onChange={(showBubbles) => update({ showBubbles })} />
        <ToggleRow checked={draft.clickThroughEnabled} disabled={false} detail={t("settings.click_through.detail")} label={t("settings.click_through")} onChange={(clickThroughEnabled) => update({ clickThroughEnabled })} />
        <ToggleRow checked={draft.startWithWindows} disabled={false} detail={t("settings.start_windows.detail")} label={t("settings.start_windows")} onChange={(startWithWindows) => update({ startWithWindows })} />
        <ToggleRow checked={draft.offlinePresenceEnabled} disabled={false} detail={t("settings.offline_presence.detail")} label={t("settings.offline_presence")} onChange={(offlinePresenceEnabled) => update({ offlinePresenceEnabled })} />
        <ToggleRow checked={draft.llmCompanionModeEnabled} disabled={runtime?.controlCenter?.ai?.settings.providerId !== "ollama"} detail={t("settings.llm_companion.detail")} label={t("settings.llm_companion")} onChange={(llmCompanionModeEnabled) => update({ llmCompanionModeEnabled })} />
        <label className="channel-field">{t("settings.update_channel")}<select onChange={(event) => update({ updateChannel: event.target.value as ControlCenterSettings["updateChannel"] })} value={draft.updateChannel}>{controlUpdateChannels.map((channel) => <option key={channel} value={channel}>{channel[0].toUpperCase() + channel.slice(1)}</option>)}</select></label>
        <ToggleRow checked={draft.automaticUpdateChecks} disabled={false} detail={t("settings.automatic_updates.detail")} label={t("settings.automatic_updates")} onChange={(automaticUpdateChecks) => update({ automaticUpdateChecks })} />
      </article>
      <article className="control-card resource-card"><h2>{t("settings.resource")}</h2><p>{t("settings.resource.detail")}</p>{resources?.available ? <><div className="resource-gauges"><label>{t("settings.resource.system_cpu", "System CPU")} <b>{Math.round(resources.cpuPercent)}%</b><progress max="100" value={resources.cpuPercent} /></label><label>{t("settings.resource.system_memory", "System memory")} <b>{Math.round(resources.memoryPercent)}%</b><progress max="100" value={resources.memoryPercent} /></label><strong className={resources.pressure === "high" ? "resource-high" : ""}>{resources.pressure === "high" ? t("settings.resource.high") : t("settings.resource.normal")}</strong></div>{hasResourceBreakdown ? <div className="resource-memory-summary"><div className="resource-total"><span>{t("settings.resource.ocp_total", "OCP total")}</span><b>{formatMemoryMb(resources.ocpMemoryMb ?? 0)}</b></div><dl className="resource-breakdown"><div><dt>{t("settings.resource.runtime", "Runtime")}</dt><dd>{formatMemoryMb(resources.runtimeMemoryMb ?? 0)}</dd></div><div><dt>{t("settings.resource.desktop_shell", "Desktop Shell")}</dt><dd>{formatMemoryMb(resources.desktopShellMemoryMb ?? 0)}</dd></div><div><dt>{t("settings.resource.kernel", "Kernel")}</dt><dd>{formatMemoryMb(resources.kernelMemoryMb ?? 0)}</dd></div><div><dt>{t("settings.resource.native_host", "Native host")}</dt><dd>{formatMemoryMb(resources.nativeHostMemoryMb ?? 0)}</dd></div></dl>{(resources.aiMemoryMb ?? 0) > 0 ? <div className="resource-ai"><span>{t("settings.resource.local_ai", "Local AI (separate)")}</span><b>{formatMemoryMb(resources.aiMemoryMb ?? 0)}</b></div> : null}</div> : null}</> : <p className="resource-unavailable">{t("settings.resource.unavailable")}</p>}</article>
      <article className="control-card onboarding-card"><h2>{t("settings.guided_setup", "Guided setup")}</h2><p>{t("settings.guided_setup.detail", "Run the first-use wizard again to review your companion, AI provider and voice choices.")}</p><button className="button" disabled={!runtime || !onRunSetup} onClick={onRunSetup} type="button">{t("settings.guided_setup.run", "Run setup wizard")}</button></article>
    </div>
  </section>;
}

const aiErrorCopy: Readonly<Record<string, string>> = Object.freeze({
  "invalid-ai-settings": "One or more AI & Voice values are invalid.",
  "provider-base-url-required": "Enter the provider Base URL before testing or saving.",
  "provider-model-required": "Enter the provider model before testing or saving.",
  "provider-base-url-invalid": "Use an http(s) Ollama URL or an https OpenAI-compatible URL.",
  "credential-required": "Save the required API key securely first.",
  "settings-service-unavailable": "Runtime Settings service is unavailable.",
  "ai-settings-save-failed": "Runtime could not persist AI & Voice settings.",
  "ai-service-unavailable": "The Runtime AI service is unavailable.",
  "ai-test-busy": "A connection test is already running.",
  "provider-test-not-required": "Offline mode does not require a connection test.",
  "provider-not-configured": "Configure the provider endpoint and model first.",
  "connection-test-failed": "The provider connection test failed.",
  "ollama-model-load-failed": "Ollama is reachable, but the selected model could not load. Free memory or choose a smaller local model.",
  "ai-test-timeout": "The provider connection test timed out.",
  "tts-disabled": "Enable spoken replies before testing the voice.",
  "tts-unavailable": "No approved voice provider is available.",
  "local-voice-not-installed": "No installed Windows voice matches this language and voice profile.",
  "dns-unreachable": "The cloud voice host cannot be resolved. Check DNS or proxy settings.",
  "provider-credential-required": "Cloud voice needs a Gemini API key. Save a Gemini credential or explicitly choose Windows system voice.",
  "provider-auth-failed": "The voice provider rejected its credential.",
  "provider-quota-exceeded": "The voice provider quota is exhausted. OCP will not switch to Windows voice unless you choose it.",
  "provider-rate-limited": "The voice provider is temporarily rate-limited. Wait for the cooldown before testing again.",
  "tts-service-unavailable": "The Runtime voice service is unavailable.",
  "voice-test-busy": "A voice test is already running.",
  "voice-test-failed": "Runtime could not play the test voice.",
  "voice-test-timeout": "The voice test timed out.",
  "runtime-timeout": "Runtime did not finish the request in time.",
});

function commandMessage(mode: "idle" | "working" | "saved" | "succeeded" | "failed", errorCode: string, idle: string, locale: LocaleName): string {
  if (mode === "working") return translate(locale, "ai.waiting");
  if (mode === "saved") return translate(locale, "ai.saved");
  if (mode === "succeeded") return "Runtime completed the test successfully.";
  if (mode === "failed") return aiErrorCopy[errorCode] ?? "Runtime could not complete the request.";
  return idle;
}

function AIAndVoicePage({ runtime, locale }: Readonly<{ runtime: RuntimeSnapshot | null; locale: LocaleName }>): ReactElement {
  const ai = runtime?.controlCenter?.ai ?? null;
  const authoritative = ai?.settings ?? null;
  const signature = aiControlSettingsSignature(authoritative);
  const [draft, setDraft] = useState<AIControlSettings | null>(authoritative);
  const [pending, setPending] = useState<Readonly<{ id: string; type: "save" | "ai-test" | "voice-test" }> | null>(null);
  const [mode, setMode] = useState<"idle" | "working" | "saved" | "succeeded" | "failed">("idle");
  const [errorCode, setErrorCode] = useState("");
  const [cloudKey, setCloudKey] = useState("");
  const [geminiKey, setGeminiKey] = useState("");
  const [credentialStatus, setCredentialStatus] = useState("");
  const t = (key: string, fallback?: string, values?: Readonly<Record<string, string | number>>): string => translate(locale, key, fallback, values);

  useEffect(() => { if (authoritative && !pending) setDraft(authoritative); }, [signature, pending]);
  useEffect(() => {
    if (!pending || !runtime) return;
    const result = runtime.commandResults.find((candidate) => candidate.id === pending.id);
    if (!result || result.status === "accepted") return;
    setPending(null);
    setMode(result.status === "succeeded" ? (pending.type === "save" ? "saved" : "succeeded") : "failed");
    setErrorCode(result.errorCode);
    if (result.status === "failed" && authoritative && pending.type === "save") setDraft(authoritative);
  }, [authoritative, pending, runtime]);
  useEffect(() => {
    if (!pending) return;
    const timeout = window.setTimeout(() => { setPending(null); setMode("failed"); setErrorCode("runtime-timeout"); }, pending.type === "save" ? 6_000 : 130_000);
    return () => window.clearTimeout(timeout);
  }, [pending]);

  if (!ai || !draft || !authoritative) {
    return <section className="control-page control-unavailable" aria-live="polite"><span>{t("ai.eyebrow")}</span><h1>{t("ai.unavailable.title")}</h1><p>{runtime ? t("ai.unavailable.runtime") : t("ai.unavailable.start")}</p></section>;
  }

  const update = (patch: Partial<AIControlSettings>): void => { setDraft({ ...draft, ...patch }); setMode("idle"); setErrorCode(""); };
  const submit = (type: "save" | "ai-test" | "voice-test"): void => {
    if (type !== "voice-test") {
      const validationError = aiControlSettingsValidationError(draft);
      if (validationError) { setMode("failed"); setErrorCode(validationError); return; }
    }
    setMode("working"); setErrorCode("");
    const commandType = type === "save" ? "control.ai.update" : type === "ai-test" ? "control.ai.test" : "control.voice.test";
    void window.ocpShell.sendRuntimeCommand({ type: commandType, settings: draft })
      .then((id) => setPending({ id, type }))
      .catch(() => { setMode("failed"); setErrorCode("adapter-unavailable"); });
  };
  const saveCredential = (providerId: CredentialProviderId, credential: string, clear: () => void): void => {
    const transient = credential;
    clear();
    setCredentialStatus("Saving securely…");
    void window.ocpShell.storeProviderCredential(providerId, transient).then((result) => {
      setCredentialStatus(result.ok ? "Credential stored in the OS keystore." : result.code === "broker-unavailable" ? "Secure credential broker is unavailable; restart OCP Runtime and try again." : result.code === "invalid-request" ? "Credential was rejected by the secure boundary." : result.code === "keystore-unavailable" ? "Windows secure credential store rejected the write; restart OCP Runtime and try again." : result.code === "broker-timeout" ? "Secure credential broker timed out; restart OCP Runtime and try again." : "Secure credential broker failed before the key was stored.");
    }).catch(() => setCredentialStatus("Secure credential broker is unavailable."));
  };
  const cloud = draft.providerId === "openai-compatible";
  const configurable = draft.providerId !== "offline";
  const dirty = JSON.stringify(draft) !== JSON.stringify(authoritative);

  return <section className="control-page ai-control-page">
    <div className="control-page-heading"><div><span>{t("ai.eyebrow")}</span><h1>{t("ai.title")}</h1><p>{t("ai.subtitle")}</p></div><button className="button primary" disabled={!dirty || mode === "working"} onClick={() => submit("save")} type="button">{pending?.type === "save" ? t("ai.saving") : t("ai.save")}</button></div>
    <div className={`settings-result ${mode}`} aria-live="polite">{commandMessage(mode, errorCode, t("ai.sync"), locale)}</div>
    <div className="ai-card-grid">
      <article className="control-card ai-provider-card"><h2>{t("ai.provider_card")}</h2><p>{t("ai.provider_detail")}</p>
        <div className="form-grid"><label>{t("ai.provider")}<select value={draft.providerId} onChange={(event) => update({ providerId: event.target.value as AIControlSettings["providerId"] })}><option value="offline">{t("ai.provider.offline")}</option><option value="ollama">{t("ai.provider.ollama")}</option><option value="openai-compatible">{t("ai.provider.cloud")}</option></select></label><label>{t("ai.model")}<input disabled={!configurable} maxLength={160} onChange={(event) => update({ model: event.target.value })} placeholder={cloud ? t("ai.cloud_model_placeholder") : t("ai.local_model_placeholder")} value={draft.model} /></label><label>{t("ai.base_url")}<input disabled={!configurable} maxLength={2048} onChange={(event) => update({ baseUrl: event.target.value })} placeholder={cloud ? t("ai.cloud_url_placeholder") : t("ai.local_url_placeholder")} value={draft.baseUrl} /></label><label>{t("ai.timeout")}<select value={draft.timeoutSeconds} disabled={!configurable} onChange={(event) => update({ timeoutSeconds: Number(event.target.value) as AIControlSettings["timeoutSeconds"] })}>{aiTimeoutSeconds.map((seconds) => <option key={seconds} value={seconds}>{seconds} s</option>)}</select></label></div>
        {cloud ? <div className="credential-row"><label>{t("ai.key.cloud")}<input aria-label={t("ai.key.cloud")} autoComplete="off" maxLength={4096} onChange={(event) => setCloudKey(event.target.value)} placeholder={ai.credentials.openAiCompatiblePresent ? t("ai.key.replace") : t("ai.key.paste")} type="password" value={cloudKey} /></label><button className="button" disabled={!ai.credentials.brokerAvailable || !cloudKey.trim()} onClick={() => saveCredential("openai-compatible", cloudKey, () => setCloudKey(""))} type="button">{t("ai.key.save")}</button></div> : null}
        <div className="test-row"><span className={ai.provider.reachable ? "test-ready" : ""}>{ai.provider.test.status === "testing" ? t("ai.testing") : ai.provider.reachable ? t("ai.reachable") : draft.providerId === "offline" ? t("ai.offline_mode") : t("ai.not_tested")}</span><button className="button" disabled={!configurable || mode === "working"} onClick={() => submit("ai-test")} type="button">{t("ai.test")}</button></div>
      </article>
      <article className="control-card voice-card"><h2>{t("ai.voice_card")}</h2><p>{t("ai.voice_detail")}</p>
        <ToggleRow checked={draft.ttsEnabled} disabled={false} detail={t("ai.enable_tts.detail")} label={t("ai.enable_tts")} onChange={(ttsEnabled) => update({ ttsEnabled })} />
        <div className="form-grid"><label>{t("ai.voice_mode", "Voice Mode")}<select disabled={!draft.ttsEnabled} value={draft.chatVoiceMode ?? "on-demand"} onChange={(event) => update({ chatVoiceMode: event.target.value as AIControlSettings["chatVoiceMode"] })}>{chatVoiceModes.map((voiceMode) => <option disabled={voiceMode === "live-voice"} key={voiceMode} value={voiceMode}>{t(`ai.voice_mode.${voiceMode}`, voiceMode === "off" ? "Off" : voiceMode === "on-demand" ? "On demand" : voiceMode === "auto-speak" ? "Auto Speak" : "Live Voice · coming next")}</option>)}</select></label><label>{t("ai.voice_provider")}<select value={draft.ttsProviderId} onChange={(event) => update({ ttsProviderId: event.target.value as AIControlSettings["ttsProviderId"] })}><option value="auto">{t("ai.voice_auto")}</option><option value="system">{t("ai.voice_system")}</option></select></label><label>{t("ai.tts_model")}<select disabled={draft.ttsProviderId === "system"} value={draft.ttsModel} onChange={(event) => update({ ttsModel: event.target.value as AIControlSettings["ttsModel"] })}>{ttsModelIds.map((model) => <option key={model} value={model}>{model === "gemini-2.5-flash-preview-tts" ? t("ai.tts_model.economy") : t("ai.tts_model.streaming")}</option>)}</select></label><label>{t("ai.voice_source")}<select value={draft.ttsVoiceMode ?? "character"} onChange={(event) => update({ ttsVoiceMode: event.target.value as AIControlSettings["ttsVoiceMode"] })}>{ttsVoiceModes.map((mode) => <option key={mode} value={mode}>{t(`ai.voice_source.${mode}`)}</option>)}</select></label><label>{t("ai.voice_gender")}<select disabled={(draft.ttsVoiceMode ?? "character") !== "custom"} value={draft.ttsVoiceGender ?? "neutral"} onChange={(event) => update({ ttsVoiceGender: event.target.value as AIControlSettings["ttsVoiceGender"] })}>{ttsVoiceGenders.map((gender) => <option key={gender} value={gender}>{t(`ai.voice_gender.${gender}`)}</option>)}</select></label><label>{t("ai.voice_age")}<select disabled={(draft.ttsVoiceMode ?? "character") !== "custom"} value={draft.ttsVoiceAge ?? "adult"} onChange={(event) => update({ ttsVoiceAge: event.target.value as AIControlSettings["ttsVoiceAge"] })}>{ttsVoiceAges.map((age) => <option key={age} value={age}>{t(`ai.voice_age.${age}`)}</option>)}</select></label><label>{t("ai.thai_speech_style")}<select disabled={(draft.ttsVoiceMode ?? "character") !== "custom"} value={draft.thaiSpeechStyle ?? "neutral"} onChange={(event) => update({ thaiSpeechStyle: event.target.value as AIControlSettings["thaiSpeechStyle"] })}>{thaiSpeechStyles.map((style) => <option key={style} value={style}>{t(`ai.thai_speech_style.${style}`)}</option>)}</select></label><label>{t("ai.voice_advanced")}<select disabled={(draft.ttsVoiceMode ?? "character") === "character"} value={draft.ttsVoice} onChange={(event) => update({ ttsVoice: event.target.value as AIControlSettings["ttsVoice"] })}>{ttsVoiceIds.map((voice) => <option key={voice} value={voice}>{voice === "auto" ? t("ai.voice_automatic") : voice}</option>)}</select></label></div>
        <p className="voice-profile-source">{t((draft.ttsVoiceMode ?? "character") === "character" ? "ai.voice_profile.character_detail" : "ai.voice_profile.custom_detail", undefined, { gender: t(`ai.voice_gender.${draft.ttsVoiceGender ?? "neutral"}`), age: t(`ai.voice_age.${draft.ttsVoiceAge ?? "adult"}`), style: t(`ai.thai_speech_style.${draft.thaiSpeechStyle ?? "neutral"}`) })}</p>
        <div className="credential-row"><label>{t("ai.key.gemini")}<input aria-label={t("ai.key.gemini")} autoComplete="off" maxLength={4096} onChange={(event) => setGeminiKey(event.target.value)} placeholder={ai.credentials.geminiPresent ? t("ai.key.replace") : t("ai.key.paste_gemini")} type="password" value={geminiKey} /></label><button className="button" disabled={!ai.credentials.brokerAvailable || !geminiKey.trim()} onClick={() => saveCredential("gemini-cloud", geminiKey, () => setGeminiKey(""))} type="button">{t("ai.key.save")}</button></div>
        <div className="test-row"><span className={ai.voiceTest.status === "succeeded" ? "test-ready" : ""}>{ai.voiceTest.status === "testing" ? t("ai.voice.testing") : ai.voiceTest.status === "succeeded" ? t("ai.voice.success") : t("ai.voice.test_ready")}</span><button className="button" disabled={!draft.ttsEnabled || mode === "working"} onClick={() => submit("voice-test")} type="button">{t("ai.test_voice")}</button></div>
      </article>
    </div>
    <p className="credential-status" aria-live="polite">{credentialStatus || (ai.credentials.brokerAvailable ? t("ai.credentials.stored") : t("ai.credentials.unavailable"))}</p>
  </section>;
}

function updateErrorMessage(errorCode: string): string {
  if (errorCode in updateMessages) return updateMessages[errorCode as UpdateMessageCode];
  if (errorCode === "adapter-unavailable") return "The authenticated Runtime adapter is unavailable.";
  if (errorCode === "runtime-timeout") return "Runtime did not confirm the update request in time.";
  if (errorCode === "update-check-busy") return "An update check is already running.";
  return "Runtime could not complete the update request.";
}

function UpdatesPage({ runtime, locale }: Readonly<{ runtime: RuntimeSnapshot | null; locale: LocaleName }>): ReactElement {
  const updates = runtime?.controlCenter?.updates ?? null;
  const [pending, setPending] = useState<Readonly<{ id: string; type: "check" | "apply" | "restart-policy" }> | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [errorCode, setErrorCode] = useState("");
  const t = (key: string, fallback?: string, values?: Readonly<Record<string, string | number>>): string => translate(locale, key, fallback, values);

  useEffect(() => {
    if (!pending || !runtime) return;
    const result = runtime.commandResults.find((candidate) => candidate.id === pending.id);
    if (!result) return;
    if (result.status === "accepted") {
      if (pending.type === "apply" && runtime.controlCenter?.updates && ["apply-requested", "stopping", "validating", "swapping", "restarting"].includes(runtime.controlCenter.updates.state)) setPending(null);
      return;
    }
    setPending(null);
    setErrorCode(result.status === "failed" ? result.errorCode : "");
  }, [pending, runtime]);

  useEffect(() => {
    if (!pending) return;
    const timeout = window.setTimeout(() => {
      setPending(null);
      setErrorCode("runtime-timeout");
    }, pending.type === "check" ? 70_000 : 10_000);
    return () => window.clearTimeout(timeout);
  }, [pending]);

  if (!updates) {
    return <section className="control-page control-unavailable" aria-live="polite"><span>{t("updates.eyebrow")}</span><h1>{t("updates.unavailable.title")}</h1><p>{runtime ? t("updates.unavailable.runtime") : t("updates.unavailable.start")}</p></section>;
  }

  const submit = (type: "check" | "apply"): void => {
    setErrorCode("");
    const command = type === "check" ? { type: "control.update.check" } as const : updateApplyCommandForDecision("confirm", updates.canApply);
    if (!command) return;
    void window.ocpShell.sendRuntimeCommand(command)
      .then((id) => setPending({ id, type }))
      .catch(() => setErrorCode("adapter-unavailable"));
  };
  const submitInstallOnRestart = (enabled: boolean): void => {
    setErrorCode("");
    void window.ocpShell.sendRuntimeCommand({ type: "control.update.install-on-restart", enabled })
      .then((id) => setPending({ id, type: "restart-policy" }))
      .catch(() => setErrorCode("adapter-unavailable"));
  };
  const cancelApply = (): void => setConfirming(false);
  const confirmApply = (): void => {
    setConfirming(false);
    submit("apply");
  };
  const busy = pending !== null || updates.state === "checking" || ["apply-requested", "stopping", "validating", "swapping", "restarting"].includes(updates.state);
  const statusMessage = errorCode ? updateErrorMessage(errorCode) : updates.message;
  const nextCheckMinutes = Math.max(0, Math.ceil(updates.nextAutomaticCheckSeconds / 60));
  const automaticStatus = updates.automaticChecksEnabled
    ? t("updates.automatic.enabled", undefined, { minutes: nextCheckMinutes })
    : t("updates.automatic.disabled");
  const trustStatus = updates.channel === "stable"
    ? (updates.stableTrustReady ? t("updates.trust.ready") : t("updates.trust.pending"))
    : t("updates.trust.preview");

  return <section className="control-page updates-control-page">
    <div className="control-page-heading"><div><span>{t("updates.eyebrow")}</span><h1>{t("updates.title")}</h1><p>{t("updates.subtitle")}</p></div><button className="button primary" disabled={!updates.canCheck || busy} onClick={() => submit("check")} type="button">{pending?.type === "check" || updates.state === "checking" ? t("updates.checking") : t("updates.check")}</button></div>
    <div className={`settings-result ${errorCode ? "failed" : updates.state === "applied" ? "succeeded" : busy ? "working" : "idle"}`} aria-live="polite">{statusMessage}</div>
    <div className="update-card-grid">
      <article className="control-card update-status-card"><h2>{t("updates.release")}</h2><p>{t("updates.release.detail")}</p><dl className="update-facts"><div><dt>{t("updates.current")}</dt><dd>{updates.currentVersion}</dd></div><div><dt>{t("updates.channel")}</dt><dd className="update-channel-pill">{updates.channel}</dd></div><div><dt>{t("updates.target")}</dt><dd>{updates.targetVersion || t("updates.none")}</dd></div><div><dt>{t("updates.runtime_state")}</dt><dd>{updates.state.replaceAll("-", " ")}</dd></div><div><dt>{t("updates.automatic.label")}</dt><dd>{automaticStatus}</dd></div><div><dt>{t("updates.trust.label")}</dt><dd>{trustStatus}</dd></div></dl></article>
      <article className="control-card update-security-card"><h2>{t("updates.security")}</h2><p>{t("updates.security.detail")}</p><ul><li>{t("updates.security.manifest")}</li><li>{t("updates.security.signature")}</li><li>{t("updates.security.no_source")}</li><li>{t("updates.security.rollback")}</li></ul></article>
      <article className="control-card update-actions-card"><h2>{t("updates.install_card")}</h2><p>{t("updates.install_detail")}</p><button className="button primary update-apply-button" disabled={!updates.canApply || busy} onClick={() => setConfirming(true)} type="button">{t("updates.install")}</button><button className="button secondary update-apply-button" disabled={!updates.canApply || busy} onClick={() => submitInstallOnRestart(!updates.installOnRestart)} type="button">{updates.installOnRestart ? t("updates.install_restart.cancel") : t("updates.install_restart")}</button><small>{updates.installOnRestart ? t("updates.install_restart.scheduled", undefined, { version: updates.targetVersion }) : updates.canApply ? t("updates.install_ready", undefined, { version: updates.targetVersion }) : t("updates.install_check")}</small></article>
    </div>
    {confirming ? <div className="update-confirm-backdrop"><div aria-describedby="update-confirm-detail" aria-labelledby="update-confirm-title" aria-modal="true" className="update-confirm-dialog" role="alertdialog"><span>{t("updates.confirm.eyebrow")}</span><h2 id="update-confirm-title">{t("updates.confirm.title", undefined, { version: updates.targetVersion })}</h2><p id="update-confirm-detail">{t("updates.confirm.detail")}</p><div><button autoFocus className="button secondary" onClick={cancelApply} type="button">{t("common.cancel")}</button><button className="button primary" disabled={!updates.canApply} onClick={confirmApply} type="button">{t("common.confirm_install")}</button></div></div></div> : null}
  </section>;
}

export function ControlCenter({ page, runtime, setPage, locale = "en", onAppearancePreview, onRunSetup }: Readonly<{
  page: ControlCenterPage;
  runtime: RuntimeSnapshot | null;
  setPage: (page: ControlCenterPage) => void;
  locale?: LocaleName;
  onAppearancePreview?: (settings: ControlCenterSettings) => void;
  onRunSetup?: () => void;
}>): ReactElement {
  const t = (key: string, fallback?: string): string => translate(locale, key, fallback);
  return <main className="control-center-layout">
    <aside className="control-center-nav panel"><div><span>{t("control.eyebrow")}</span><h2>{t("control.title")}</h2><p>{t("control.subtitle")}</p></div><nav aria-label={t("control.title")}>{(Object.keys(pageCopy) as ControlCenterPage[]).map((target) => { const copy = pageCopy[target]; return <button aria-current={page === target ? "page" : undefined} className={page === target ? "selected" : ""} key={target} onClick={() => setPage(target)} type="button"><i aria-hidden="true">{copy.glyph}</i><span><b>{t(copy.labelKey)}</b><small>{t(copy.detailKey)}</small></span></button>; })}</nav><div className="control-runtime-state"><i className={runtime ? "connected" : ""} />{runtime ? t("control.runtime.connected") : t("control.runtime.unavailable")}</div></aside>
    {page === "settings" ? <SettingsPage locale={locale} onPreviewAppearance={onAppearancePreview} onRunSetup={onRunSetup} runtime={runtime} /> : page === "ai-voice" ? <AIAndVoicePage locale={locale} runtime={runtime} /> : <UpdatesPage locale={locale} runtime={runtime} />}
  </main>;
}
