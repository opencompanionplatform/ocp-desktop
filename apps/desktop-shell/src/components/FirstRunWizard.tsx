import { Bot, Check, ChevronLeft, ChevronRight, Cloud, Download, Languages, Mic2, MonitorSpeaker, Sparkles, Volume2, WifiOff } from "lucide-react";
import { useEffect, useMemo, useState, type ReactElement } from "react";

import type { OnboardingCompletionReason } from "../../electron/onboarding-state";
import type { RuntimeSnapshot } from "../../electron/runtime-bridge";
import type { AIControlSettings, ControlLanguage } from "../contracts/control-center";
import { firstRunCompletionCommands, resolveFirstRunCommandResults, resolveFirstRunModelDiscovery, resolveFirstRunProbeResult, STARTER_CHARACTER_ID, STARTER_CHARACTER_VERSION, starterCharacterInstallCommand, starterCharacterInstalled, starterCharacterThumbnailSource } from "../contracts/first-run";

type Props = Readonly<{
  runtime: RuntimeSnapshot;
  initialLanguage: ControlLanguage;
  initialStep?: number;
  storeAvailable: boolean;
  onComplete: (reason: OnboardingCompletionReason) => Promise<void>;
}>;

type Copy = Readonly<{
  title: string;
  welcome: string;
  language: string;
  starterTitle: string;
  starterDetail: string;
  starterFree: string;
  aiTitle: string;
  aiDetail: string;
  voiceTitle: string;
  voiceDetail: string;
  readyTitle: string;
  readyDetail: string;
  back: string;
  next: string;
  skipSetup: string;
  finish: string;
  chooseLater: string;
  signIn: string;
  installSabai: string;
  installed: string;
  installing: string;
  offline: string;
  ollama: string;
  cloud: string;
  model: string;
  baseUrl: string;
  detectModels: string;
  detectingModels: string;
  detectedModels: string;
  noModels: string;
  apiKey: string;
  saveKey: string;
  test: string;
  voiceOff: string;
  systemVoice: string;
  cloudVoice: string;
  testVoice: string;
  manageGeminiKey: string;
  geminiKeyStored: string;
  startup: string;
}>;

const copies: Record<ControlLanguage, Copy> = {
  en: {
    title: "Welcome to OCP", welcome: "Set up your screen companion in a few quick steps.", language: "Language",
    starterTitle: "Add another companion", starterDetail: "Bible is already included with OCP and works offline. Sabai Sompoo is a free Cloud companion so you can try adding a new character to your library.", starterFree: "FREE COMPANION",
    aiTitle: "How should your companion think?", aiDetail: "You can stay offline, use private local Ollama, or connect an OpenAI-compatible cloud endpoint.",
    voiceTitle: "Choose a voice", voiceDetail: "Voice is optional. System voice works without an API key; cloud voice can be configured now or later.",
    readyTitle: "You're ready", readyDetail: "These choices can be changed later in Settings → AI & Voice.", back: "Back", next: "Next", skipSetup: "Skip setup", finish: "Start OCP", chooseLater: "Choose later", signIn: "Sign in to get Sabai", installSabai: "Use Sabai", installed: "Sabai installed", installing: "Installing…",
    offline: "Offline", ollama: "Ollama · Local", cloud: "OpenAI-compatible · Cloud", model: "Model", baseUrl: "Base URL", detectModels: "Detect installed models", detectingModels: "Detecting models…", detectedModels: "Installed models", noModels: "No Ollama models were found. Pull a model in Ollama, then detect again.", apiKey: "API key", saveKey: "Save securely", test: "Test connection", voiceOff: "No voice for now", systemVoice: "Windows / System voice", cloudVoice: "Cloud high-quality voice", testVoice: "Test voice", manageGeminiKey: "Create / manage Gemini API key", geminiKeyStored: "A Gemini API key is already stored securely on this PC.", startup: "Start OCP with Windows",
  },
  th: {
    title: "ยินดีต้อนรับสู่ OCP", welcome: "ตั้งค่าคู่หูบนหน้าจอให้พร้อมใช้งานในไม่กี่ขั้นตอน", language: "ภาษา",
    starterTitle: "เพิ่มคู่หูอีกตัว", starterDetail: "Bible มาพร้อม OCP และใช้งานออฟไลน์ได้ทันที ส่วน Sabai Sompoo เป็นคู่หูฟรีจาก Cloud เพื่อให้คุณลองเพิ่มตัวละครใหม่เข้าสู่คลังของคุณ", starterFree: "คู่หูฟรี",
    aiTitle: "ให้คู่หูคิดแบบไหน?", aiDetail: "เลือกออฟไลน์, Ollama ภายในเครื่อง หรือเชื่อมต่อ Cloud แบบ OpenAI-compatible ได้ และเปลี่ยนภายหลังได้เสมอ",
    voiceTitle: "เลือกเสียง", voiceDetail: "ไม่จำเป็นต้องเปิดเสียงก็ได้ System Voice ใช้ได้โดยไม่ต้องมี API key ส่วน Cloud Voice ตั้งค่าตอนนี้หรือภายหลังก็ได้",
    readyTitle: "พร้อมแล้ว", readyDetail: "แก้ไขตัวเลือกเหล่านี้ภายหลังได้ที่ Settings → AI & Voice", back: "ย้อนกลับ", next: "ถัดไป", skipSetup: "ข้ามการตั้งค่า", finish: "เริ่มใช้ OCP", chooseLater: "เลือกภายหลัง", signIn: "Sign in เพื่อรับ Sabai", installSabai: "ใช้ Sabai", installed: "ติดตั้ง Sabai แล้ว", installing: "กำลังติดตั้ง…",
    offline: "ออฟไลน์", ollama: "Ollama · ภายในเครื่อง", cloud: "OpenAI-compatible · Cloud", model: "โมเดล", baseUrl: "Base URL", detectModels: "ค้นหาโมเดลที่ติดตั้ง", detectingModels: "กำลังค้นหาโมเดล…", detectedModels: "โมเดลที่ติดตั้ง", noModels: "ยังไม่พบโมเดลใน Ollama ให้ pull โมเดลก่อน แล้วกดค้นหาอีกครั้ง", apiKey: "API key", saveKey: "บันทึกอย่างปลอดภัย", test: "ทดสอบการเชื่อมต่อ", voiceOff: "ยังไม่ใช้เสียง", systemVoice: "Windows / System Voice", cloudVoice: "Cloud Voice คุณภาพสูง", testVoice: "ทดสอบเสียง", manageGeminiKey: "สร้าง / จัดการ Gemini API key", geminiKeyStored: "มี Gemini API key เก็บไว้อย่างปลอดภัยในเครื่องนี้แล้ว", startup: "เริ่ม OCP พร้อม Windows",
  },
};

const stepIcons = [Languages, Sparkles, Bot, Volume2, Check] as const;
const stepLabels: Record<ControlLanguage, readonly string[]> = {
  en: ["Language", "Companion", "AI", "Voice", "Ready"],
  th: ["ภาษา", "คู่หู", "AI", "เสียง", "พร้อมใช้"],
};

type PendingProbe = Readonly<{ id: string; kind: "ai" | "voice" }>;

export function FirstRunWizard({ runtime, initialLanguage, initialStep = 0, storeAvailable, onComplete }: Props): ReactElement {
  const [step, setStep] = useState(Math.max(0, Math.min(4, initialStep)));
  const [language, setLanguage] = useState<ControlLanguage>(initialLanguage);
  const [draftAI, setDraftAI] = useState<AIControlSettings | null>(runtime.controlCenter?.ai?.settings ?? null);
  const [cloudKey, setCloudKey] = useState("");
  const [geminiKey, setGeminiKey] = useState("");
  const [credentialStatus, setCredentialStatus] = useState("");
  const [pendingCredentialProvider, setPendingCredentialProvider] = useState<"openai-compatible" | "gemini-cloud" | null>(null);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("");
  const [pendingFinish, setPendingFinish] = useState<{ ids: string[]; reason: OnboardingCompletionReason } | null>(null);
  const [pendingProbe, setPendingProbe] = useState<PendingProbe | null>(null);
  const [pendingDiscoveryId, setPendingDiscoveryId] = useState<string | null>(null);
  const [pendingStarterInstallId, setPendingStarterInstallId] = useState<string | null>(null);
  const [discoveredModels, setDiscoveredModels] = useState<readonly string[]>([]);
  const [startWithWindows, setStartWithWindows] = useState(runtime.controlCenter?.settings.startWithWindows ?? false);
  const copy = copies[language];
  const ai = runtime.controlCenter?.ai ?? null;
  const signedIn = runtime.account?.signedIn === true;
  const sabaiInstalled = starterCharacterInstalled(runtime);
  const sabaiThumbnail = starterCharacterThumbnailSource(runtime);
  const sabaiDownloading = runtime.cloud?.download.packageId === STARTER_CHARACTER_ID && ["authorizing", "downloading"].includes(runtime.cloud.download.status);
  const sabaiInstalling = pendingStarterInstallId !== null || sabaiDownloading;
  const interactionBusy = busy || pendingProbe !== null || sabaiInstalling;
  const aiInteractionBusy = pendingProbe !== null || pendingDiscoveryId !== null;
  const feedback = status || credentialStatus;

  useEffect(() => {
    if (!draftAI && runtime.controlCenter?.ai?.settings) setDraftAI(runtime.controlCenter.ai.settings);
  }, [draftAI, runtime.controlCenter?.ai?.settings]);

  useEffect(() => {
    if (!pendingCredentialProvider) return;
    const present = pendingCredentialProvider === "gemini-cloud"
      ? ai?.credentials.geminiPresent === true
      : ai?.credentials.openAiCompatiblePresent === true;
    if (!present) return;
    if (pendingCredentialProvider === "gemini-cloud") setGeminiKey("");
    else setCloudKey("");
    setPendingCredentialProvider(null);
    setCredentialStatus(language === "th" ? "บันทึกใน Windows secure store แล้ว" : "Stored in the Windows secure store.");
  }, [ai?.credentials.geminiPresent, ai?.credentials.openAiCompatiblePresent, language, pendingCredentialProvider]);

  useEffect(() => {
    if (!pendingCredentialProvider) return;
    const timeout = window.setTimeout(() => {
      setPendingCredentialProvider(null);
      setCredentialStatus(language === "th" ? "ยังยืนยันการบันทึก credential ไม่สำเร็จ สามารถลองใหม่ได้" : "Credential storage could not be confirmed. Please try again.");
    }, 20_000);
    return () => window.clearTimeout(timeout);
  }, [language, pendingCredentialProvider]);

  useEffect(() => {
    if (!pendingStarterInstallId) return;
    const result = runtime.commandResults.find((candidate) => candidate.id === pendingStarterInstallId && candidate.type === "cloud.library.install");
    if (!result) return;
    if (result.status === "failed") {
      setPendingStarterInstallId(null);
      setStatus(language === "th"
        ? `ติดตั้ง Sabai ไม่สำเร็จ (${result.errorCode || "runtime-error"})`
        : `Sabai installation failed (${result.errorCode || "runtime-error"}).`);
      return;
    }
    if (sabaiInstalled) {
      setPendingStarterInstallId(null);
      setStatus(language === "th" ? "ติดตั้งและเปิดใช้ Sabai สำเร็จ" : "Sabai was installed and activated.");
      return;
    }
    if (result.status === "accepted" && runtime.cloud?.download.packageId === STARTER_CHARACTER_ID && runtime.cloud.download.status === "error") {
      setPendingStarterInstallId(null);
      setStatus(language === "th" ? "ดาวน์โหลดหรือตรวจสอบแพ็กเกจ Sabai ไม่สำเร็จ กรุณาลองอีกครั้ง" : "Sabai download or package verification failed. Please try again.");
    }
  }, [language, pendingStarterInstallId, runtime.cloud?.download.packageId, runtime.cloud?.download.status, runtime.commandResults, sabaiInstalled]);

  useEffect(() => {
    if (!pendingStarterInstallId) return;
    const timeout = window.setTimeout(() => {
      setPendingStarterInstallId(null);
      setStatus(language === "th" ? "การติดตั้ง Sabai ใช้เวลานานกว่าปกติ กรุณาลองอีกครั้ง" : "Sabai installation is taking longer than expected. Please try again.");
    }, 300_000);
    return () => window.clearTimeout(timeout);
  }, [language, pendingStarterInstallId]);

  useEffect(() => {
    if (!pendingFinish) return;
    const resolution = resolveFirstRunCommandResults(pendingFinish.ids, runtime.commandResults);
    if (resolution.status === "pending") return;
    if (resolution.status === "failed") {
      setPendingFinish(null);
      setBusy(false);
      setStatus(language === "th" ? `บันทึกการตั้งค่าไม่สำเร็จ (${resolution.errorCode})` : `Setup could not be saved (${resolution.errorCode}).`);
      return;
    }
    const reason = pendingFinish.reason;
    setPendingFinish(null);
    void onComplete(reason).catch(() => {
      setBusy(false);
      setStatus(language === "th" ? "ยังบันทึกสถานะ First Run ไม่สำเร็จ กรุณาลองอีกครั้ง" : "Could not finish First Run yet. Please try again.");
    });
  }, [language, onComplete, pendingFinish, runtime.commandResults]);

  useEffect(() => {
    if (!pendingFinish) return;
    const timeout = window.setTimeout(() => {
      setPendingFinish(null);
      setBusy(false);
      setStatus(language === "th" ? "Runtime ยังไม่ยืนยันการตั้งค่า กรุณาลองอีกครั้ง" : "Runtime did not confirm the setup in time. Please try again.");
    }, 8_000);
    return () => window.clearTimeout(timeout);
  }, [language, pendingFinish]);

  useEffect(() => {
    if (!pendingProbe) return;
    const resolution = resolveFirstRunProbeResult(pendingProbe.id, runtime.commandResults);
    if (resolution.status === "pending") return;
    const kind = pendingProbe.kind;
    setPendingProbe(null);
    if (resolution.status === "succeeded") {
      setStatus(kind === "ai"
        ? (language === "th" ? "เชื่อมต่อ AI สำเร็จ" : "AI connection succeeded.")
        : (language === "th" ? "ทดสอบเสียงสำเร็จ" : "Voice test succeeded."));
      return;
    }
    const code = resolution.errorCode || "runtime-error";
    setStatus(kind === "ai"
      ? (language === "th" ? `เชื่อมต่อ AI ไม่สำเร็จ (${code})` : `AI connection failed (${code}).`)
      : (language === "th" ? `ทดสอบเสียงไม่สำเร็จ (${code})` : `Voice test failed (${code}).`));
  }, [language, pendingProbe, runtime.commandResults]);

  useEffect(() => {
    if (!pendingProbe) return;
    // Runtime intentionally gives Cloud Voice up to 35 s because generation +
    // local playback both participate in the authoritative result. The old
    // renderer-side 8 s timeout could therefore report failure while the WAV
    // was audibly playing. Keep the UI timeout outside Runtime's own deadline;
    // AI follows the configured provider timeout for the same reason.
    const timeoutMs = pendingProbe.kind === "voice"
      ? 40_000
      : Math.max(10_000, ((draftAI?.timeoutSeconds ?? 45) * 1_000) + 6_000);
    const timeout = window.setTimeout(() => {
      const kind = pendingProbe.kind;
      setPendingProbe(null);
      setStatus(kind === "ai"
        ? (language === "th" ? "Runtime ยังไม่ยืนยันผลทดสอบ AI" : "Runtime did not confirm the AI test in time.")
        : (language === "th" ? "Runtime ยังไม่ยืนยันผลทดสอบเสียง" : "Runtime did not confirm the voice test in time."));
    }, timeoutMs);
    return () => window.clearTimeout(timeout);
  }, [draftAI?.timeoutSeconds, language, pendingProbe]);

  useEffect(() => {
    if (!pendingDiscoveryId) return;
    const resolution = resolveFirstRunModelDiscovery(pendingDiscoveryId, runtime.commandResults);
    if (resolution.status === "pending") return;
    setPendingDiscoveryId(null);
    if (resolution.status === "failed") {
      if (step === 2) setStatus(language === "th" ? `ค้นหาโมเดลไม่สำเร็จ (${resolution.errorCode})` : `Model discovery failed (${resolution.errorCode}).`);
      return;
    }
    setDiscoveredModels(resolution.models);
    if (resolution.models.length > 0) {
      setDraftAI((current) => {
        if (!current || current.providerId !== "ollama" || resolution.models.includes(current.model)) return current;
        return { ...current, model: resolution.models[0] };
      });
      if (step === 2) setStatus(language === "th" ? `พบโมเดล Ollama ${resolution.models.length} รายการ` : `Found ${resolution.models.length} installed Ollama model${resolution.models.length === 1 ? "" : "s"}.`);
      return;
    }
    if (step === 2) setStatus(copies[language].noModels);
  }, [language, pendingDiscoveryId, runtime.commandResults, step]);

  useEffect(() => {
    if (!pendingDiscoveryId) return;
    const timeout = window.setTimeout(() => {
      setPendingDiscoveryId(null);
      if (step === 2) setStatus(language === "th" ? "Ollama ยังไม่ตอบกลับการค้นหาโมเดล ลองใหม่ได้อีกครั้ง" : "Ollama did not return the model list in time. You can try again.");
    }, 8_000);
    return () => window.clearTimeout(timeout);
  }, [language, pendingDiscoveryId, step]);

  const providerDetail = useMemo(() => {
    if (!draftAI) return "";
    if (draftAI.providerId === "offline") return language === "th" ? "ไม่ส่งข้อความออกจากเครื่อง" : "No provider connection required";
    if (draftAI.providerId === "ollama") return language === "th" ? "Private · ทำงานผ่าน Ollama ในเครื่องนี้" : "Private · uses Ollama on this PC";
    return language === "th" ? "ใช้ endpoint และ API key ของคุณ" : "Uses your endpoint and API key";
  }, [draftAI, language]);

  const discoverOllamaModels = (settings: AIControlSettings): void => {
    if (settings.providerId !== "ollama" || pendingDiscoveryId || pendingProbe) return;
    setCredentialStatus("");
    setDiscoveredModels([]);
    setStatus(copies[language].detectingModels);
    void window.ocpShell.sendRuntimeCommand({ type: "control.ai.discover", settings })
      .then((id) => setPendingDiscoveryId(id))
      .catch(() => setStatus(language === "th" ? "เริ่มค้นหาโมเดล Ollama ไม่ได้" : "Could not start Ollama model discovery."));
  };

  const patchProvider = (providerId: AIControlSettings["providerId"]): void => {
    if (!draftAI || pendingProbe || pendingDiscoveryId) return;
    setCredentialStatus("");
    setDiscoveredModels([]);
    setStatus("");
    if (providerId === "offline") {
      setDraftAI({ ...draftAI, providerId, baseUrl: "", model: "" });
      return;
    }
    if (providerId === "ollama") {
      const next = {
        ...draftAI,
        providerId,
        baseUrl: draftAI.providerId === "ollama" && draftAI.baseUrl ? draftAI.baseUrl : "http://127.0.0.1:11434",
        model: draftAI.providerId === "ollama" && draftAI.model ? draftAI.model : "qwen3.5:latest",
      } as AIControlSettings;
      setDraftAI(next);
      discoverOllamaModels(next);
      return;
    }
    setDraftAI({ ...draftAI, providerId, baseUrl: draftAI.providerId === "openai-compatible" ? draftAI.baseUrl : "", model: draftAI.providerId === "openai-compatible" ? draftAI.model : "" });
  };

  const installSabai = (): void => {
    const command = starterCharacterInstallCommand(runtime);
    if (!command || pendingStarterInstallId) return;
    setCredentialStatus("");
    setStatus(language === "th" ? "กำลังเตรียมอุปกรณ์และติดตั้ง Sabai…" : "Preparing this device and installing Sabai…");
    void window.ocpShell.sendRuntimeCommand(command)
      .then((id) => setPendingStarterInstallId(id))
      .catch(() => {
        setPendingStarterInstallId(null);
        setStatus(language === "th" ? "ยังเริ่มติดตั้ง Sabai ไม่ได้ ลองใหม่หรือเลือกภายหลัง" : "Could not start the Sabai install. Try again or choose later.");
      });
  };

  const saveCredential = (providerId: "openai-compatible" | "gemini-cloud", credential: string, clear: () => void): void => {
    if (!credential.trim()) return;
    setStatus("");
    setPendingCredentialProvider(providerId);
    setCredentialStatus(language === "th" ? "กำลังบันทึกอย่างปลอดภัย…" : "Saving securely…");
    void window.ocpShell.storeProviderCredential(providerId, credential).then((result) => {
      if (result.ok) {
        clear();
        setPendingCredentialProvider(null);
        setCredentialStatus(language === "th" ? "บันทึกใน Windows secure store แล้ว" : "Stored in the Windows secure store.");
        return;
      }
      if (result.code === "broker-timeout") {
        setCredentialStatus(language === "th" ? "บันทึกแล้ว กำลังยืนยันกับ Windows secure store…" : "Saved; confirming with the Windows secure store…");
        return;
      }
      setPendingCredentialProvider(null);
      setCredentialStatus(language === "th" ? `ยังบันทึก credential ไม่สำเร็จ (${result.code}) สามารถตั้งค่าภายหลังได้` : `Credential was not stored (${result.code}). You can configure it later.`);
    }).catch(() => {
      setPendingCredentialProvider(null);
      setCredentialStatus(language === "th" ? "Secure credential broker ไม่พร้อมใช้งาน" : "Secure credential broker is unavailable.");
    });
  };

  const testAI = (): void => {
    if (!draftAI || draftAI.providerId === "offline" || pendingProbe || pendingDiscoveryId) return;
    setCredentialStatus("");
    setStatus(language === "th" ? "กำลังทดสอบ AI…" : "Testing AI…");
    void window.ocpShell.sendRuntimeCommand({ type: "control.ai.test", settings: draftAI })
      .then((id) => setPendingProbe({ id, kind: "ai" }))
      .catch(() => setStatus(language === "th" ? "เริ่มการทดสอบไม่ได้" : "Could not start the connection test."));
  };

  const testVoice = (): void => {
    if (!draftAI?.ttsEnabled || pendingProbe) return;
    setCredentialStatus("");
    setStatus(language === "th" ? "กำลังทดสอบเสียง…" : "Testing voice…");
    void window.ocpShell.sendRuntimeCommand({ type: "control.voice.test", settings: draftAI })
      .then((id) => setPendingProbe({ id, kind: "voice" }))
      .catch(() => setStatus(language === "th" ? "เริ่มทดสอบเสียงไม่ได้" : "Could not start the voice test."));
  };

  const finish = async (reason: OnboardingCompletionReason): Promise<void> => {
    if (interactionBusy) return;
    setBusy(true);
    setStatus("");
    try {
      if (reason === "skipped") {
        await onComplete(reason);
        return;
      }
      const commands = firstRunCompletionCommands(runtime, language, startWithWindows, draftAI, reason);
      const ids = await Promise.all(commands.map((command) => window.ocpShell.sendRuntimeCommand(command)));
      if (ids.length === 0) {
        await onComplete(reason);
        return;
      }
      setPendingFinish({ ids, reason });
    } catch {
      setStatus(language === "th" ? "Runtime ยังบันทึกการตั้งค่าไม่สำเร็จ กรุณาลองอีกครั้ง" : "Runtime could not save the setup yet. Please try again.");
      setBusy(false);
    }
  };

  const chooseVoice = (mode: "off" | "system" | "cloud"): void => {
    if (!draftAI || pendingProbe) return;
    setCredentialStatus("");
    if (mode === "off") setDraftAI({ ...draftAI, ttsEnabled: false, chatVoiceMode: "off" });
    else if (mode === "system") setDraftAI({ ...draftAI, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "system" });
    else setDraftAI({ ...draftAI, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto" });
    setStatus("");
  };

  const moveStep = (nextStep: number): void => {
    if (interactionBusy) return;
    setCredentialStatus("");
    setStatus("");
    setStep(Math.max(0, Math.min(4, nextStep)));
  };

  const chooseLanguage = (nextLanguage: ControlLanguage): void => {
    if (interactionBusy) return;
    setCredentialStatus("");
    setStatus("");
    setLanguage(nextLanguage);
  };

  return <div className="first-run-backdrop" role="presentation">
    <section aria-busy={interactionBusy} aria-label={copy.title} aria-modal="true" className="first-run-wizard" role="dialog">
      <aside className="first-run-rail">
        <div className="first-run-brand"><Sparkles size={20} /><div><strong>OCP</strong><span>{language === "th" ? "คู่หูบนหน้าจอ" : "Screen Companion"}</span></div></div>
        <ol>{stepLabels[language].map((label, index) => { const Icon = stepIcons[index]; return <li aria-current={index === step ? "step" : undefined} className={index === step ? "active" : index < step ? "done" : ""} key={label}><span>{index < step ? <Check size={15} /> : <Icon size={15} />}</span><div><small>0{index + 1}</small><strong>{label}</strong></div></li>; })}</ol>
        <button className="first-run-skip" disabled={interactionBusy} onClick={() => void finish("skipped")} type="button">{copy.skipSetup}</button>
      </aside>
      <main className="first-run-main">
        {step === 0 && <div className="first-run-step"><div className="first-run-step-icon"><Languages size={28} /></div><span className="first-run-kicker">OCP FIRST RUN</span><h1>{copy.title}</h1><p>{copy.welcome}</p><div className="first-run-language"><button aria-pressed={language === "th"} className={language === "th" ? "selected" : ""} disabled={interactionBusy} onClick={() => chooseLanguage("th")} type="button"><strong>ไทย</strong><span>ภาษาไทย</span></button><button aria-pressed={language === "en"} className={language === "en" ? "selected" : ""} disabled={interactionBusy} onClick={() => chooseLanguage("en")} type="button"><strong>English</strong><span>English</span></button></div></div>}

        {step === 1 && <div className="first-run-step"><div className="first-run-step-icon"><Sparkles size={28} /></div><span className="first-run-kicker">{copy.starterFree}</span><h1>{copy.starterTitle}</h1><p>{copy.starterDetail}</p><div className="starter-card"><div className="starter-avatar">{sabaiThumbnail ? <img alt="Sabai Sompoo" src={sabaiThumbnail} /> : "S"}</div><div className="starter-copy"><strong>Sabai Sompoo</strong><span>{STARTER_CHARACTER_ID} · {STARTER_CHARACTER_VERSION}</span><small>24 animations · signed OCP package</small></div><div className="starter-action">{sabaiInstalled ? <span className="starter-installed"><Check size={16} /> {copy.installed}</span> : signedIn ? <button className="button primary" disabled={sabaiInstalling} onClick={installSabai} type="button"><Download size={16} /> {sabaiInstalling ? copy.installing : copy.installSabai}</button> : <button className="button primary" disabled={!storeAvailable} onClick={() => void window.ocpShell.openAccount(true)} type="button"><Cloud size={16} /> {copy.signIn}</button>}</div></div><button className="button first-run-secondary" disabled={interactionBusy} onClick={() => moveStep(2)} type="button">{copy.chooseLater}</button></div>}

        {step === 2 && <div className="first-run-step">
          <div className="first-run-step-icon"><Bot size={28} /></div>
          <span className="first-run-kicker">AI PROVIDER</span>
          <h1>{copy.aiTitle}</h1>
          <p>{copy.aiDetail}</p>
          {draftAI ? <>
            <div className="first-run-choice-grid three">
              <button aria-pressed={draftAI.providerId === "offline"} className={draftAI.providerId === "offline" ? "selected" : ""} disabled={aiInteractionBusy} onClick={() => patchProvider("offline")} type="button"><WifiOff size={20} /><strong>{copy.offline}</strong><span>{language === "th" ? "ไม่ต้องตั้งค่า" : "No setup"}</span></button>
              <button aria-pressed={draftAI.providerId === "ollama"} className={draftAI.providerId === "ollama" ? "selected" : ""} disabled={aiInteractionBusy} onClick={() => patchProvider("ollama")} type="button"><MonitorSpeaker size={20} /><strong>{copy.ollama}</strong><span>Private</span></button>
              <button aria-pressed={draftAI.providerId === "openai-compatible"} className={draftAI.providerId === "openai-compatible" ? "selected" : ""} disabled={aiInteractionBusy} onClick={() => patchProvider("openai-compatible")} type="button"><Cloud size={20} /><strong>{copy.cloud}</strong><span>API</span></button>
            </div>
            <p className="first-run-selection-detail">{providerDetail}</p>
            {draftAI.providerId !== "offline" && <div className="first-run-form">
              <label>{copy.baseUrl}<input disabled={aiInteractionBusy} maxLength={2048} onChange={(event) => { setDraftAI({ ...draftAI, baseUrl: event.target.value }); setDiscoveredModels([]); setStatus(""); }} value={draftAI.baseUrl} /></label>
              <label>{copy.model}<input disabled={aiInteractionBusy} maxLength={160} onChange={(event) => { setDraftAI({ ...draftAI, model: event.target.value }); setStatus(""); }} value={draftAI.model} /></label>
              {draftAI.providerId === "ollama" && <>
                <button className="button first-run-detect" disabled={aiInteractionBusy || !draftAI.baseUrl.trim()} onClick={() => discoverOllamaModels(draftAI)} type="button">{pendingDiscoveryId ? copy.detectingModels : copy.detectModels}</button>
                {discoveredModels.length > 0 && <div className="first-run-model-suggestions"><span>{copy.detectedModels}</span><div>{discoveredModels.map((model) => <button aria-pressed={draftAI.model === model} className={draftAI.model === model ? "selected" : ""} disabled={aiInteractionBusy} key={model} onClick={() => { setDraftAI({ ...draftAI, model }); setStatus(""); }} type="button">{model}</button>)}</div></div>}
              </>}
              {draftAI.providerId === "openai-compatible" && <div className="first-run-credential"><label>{copy.apiKey}<input autoComplete="off" disabled={aiInteractionBusy} maxLength={4096} onChange={(event) => setCloudKey(event.target.value)} type="password" value={cloudKey} /></label><button className="button" disabled={!cloudKey.trim() || !ai?.credentials.brokerAvailable || aiInteractionBusy} onClick={() => saveCredential("openai-compatible", cloudKey, () => setCloudKey(""))} type="button">{copy.saveKey}</button></div>}
              <button className="button first-run-test" disabled={aiInteractionBusy} onClick={testAI} type="button">{pendingProbe?.kind === "ai" ? (language === "th" ? "กำลังทดสอบ…" : "Testing…") : copy.test}</button>
            </div>}
          </> : <p>{language === "th" ? "Runtime AI ยังไม่พร้อม คุณสามารถข้ามและตั้งค่าภายหลังได้" : "Runtime AI is not ready yet. You can continue and configure it later."}</p>}
        </div>}

        {step === 3 && <div className="first-run-step"><div className="first-run-step-icon"><Mic2 size={28} /></div><span className="first-run-kicker">VOICE</span><h1>{copy.voiceTitle}</h1><p>{copy.voiceDetail}</p>{draftAI && <><div className="first-run-choice-grid three"><button aria-pressed={!draftAI.ttsEnabled} className={!draftAI.ttsEnabled ? "selected" : ""} disabled={pendingProbe !== null} onClick={() => chooseVoice("off")} type="button"><WifiOff size={20} /><strong>{copy.voiceOff}</strong></button><button aria-pressed={draftAI.ttsEnabled && draftAI.ttsProviderId === "system"} className={draftAI.ttsEnabled && draftAI.ttsProviderId === "system" ? "selected" : ""} disabled={pendingProbe !== null} onClick={() => chooseVoice("system")} type="button"><MonitorSpeaker size={20} /><strong>{copy.systemVoice}</strong></button><button aria-pressed={draftAI.ttsEnabled && draftAI.ttsProviderId === "auto"} className={draftAI.ttsEnabled && draftAI.ttsProviderId === "auto" ? "selected" : ""} disabled={pendingProbe !== null} onClick={() => chooseVoice("cloud")} type="button"><Cloud size={20} /><strong>{copy.cloudVoice}</strong></button></div>{draftAI.ttsEnabled && draftAI.ttsProviderId === "auto" && <><div className="first-run-credential"><label>Gemini API key<input autoComplete="off" disabled={pendingProbe !== null} maxLength={4096} onChange={(event) => setGeminiKey(event.target.value)} type="password" value={geminiKey} /></label><button className="button" disabled={!geminiKey.trim() || !ai?.credentials.brokerAvailable || pendingProbe !== null} onClick={() => saveCredential("gemini-cloud", geminiKey, () => setGeminiKey(""))} type="button">{copy.saveKey}</button></div><div className="first-run-cloud-key-help">{ai?.credentials.geminiPresent && <span><Check size={15} /> {copy.geminiKeyStored}</span>}<button className="button first-run-link" disabled={pendingProbe !== null} onClick={() => void window.ocpShell.openGeminiApiKeys().catch(() => setStatus(language === "th" ? "ยังเปิด Google AI Studio ไม่ได้" : "Could not open Google AI Studio."))} type="button"><Cloud size={15} /> {copy.manageGeminiKey}</button></div></>}<button className="button first-run-test" disabled={!draftAI.ttsEnabled || pendingProbe !== null} onClick={testVoice} type="button">{pendingProbe?.kind === "voice" ? (language === "th" ? "กำลังทดสอบ…" : "Testing…") : copy.testVoice}</button></>}</div>}

        {step === 4 && <div className="first-run-step"><div className="first-run-step-icon success"><Check size={28} /></div><span className="first-run-kicker">READY</span><h1>{copy.readyTitle}</h1><p>{copy.readyDetail}</p><div className="first-run-summary"><div><Languages size={18} /><span>{copy.language}</span><strong>{language === "th" ? "ไทย" : "English"}</strong></div><div><Sparkles size={18} /><span>{language === "th" ? "คู่หู" : "Companion"}</span><strong>{sabaiInstalled ? "Sabai Sompoo" : sabaiDownloading ? copy.installing : copy.chooseLater}</strong></div><div><Bot size={18} /><span>AI</span><strong>{draftAI?.providerId === "ollama" ? copy.ollama : draftAI?.providerId === "openai-compatible" ? copy.cloud : copy.offline}</strong></div><div><Volume2 size={18} /><span>Voice</span><strong>{!draftAI?.ttsEnabled ? copy.voiceOff : draftAI.ttsProviderId === "system" ? copy.systemVoice : copy.cloudVoice}</strong></div></div><label className="first-run-startup"><input checked={startWithWindows} disabled={interactionBusy} onChange={(event) => setStartWithWindows(event.target.checked)} type="checkbox" />{copy.startup}</label></div>}

        {feedback && <div aria-live="polite" className="first-run-status" role="status">{feedback}</div>}
        <footer className="first-run-footer"><button className="button" disabled={step === 0 || interactionBusy} onClick={() => moveStep(step - 1)} type="button"><ChevronLeft size={16} /> {copy.back}</button><span>{step + 1} / 5</span>{step < 4 ? <button className="button primary" disabled={interactionBusy} onClick={() => moveStep(step + 1)} type="button">{copy.next} <ChevronRight size={16} /></button> : <button className="button primary" disabled={interactionBusy} onClick={() => void finish("completed")} type="button"><Check size={16} /> {copy.finish}</button>}</footer>
      </main>
    </section>
  </div>;
}
