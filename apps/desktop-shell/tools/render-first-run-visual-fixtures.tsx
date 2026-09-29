import fs from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";

import type { RuntimeSnapshot } from "../electron/runtime-bridge";
import { FirstRunWizard } from "../src/components/FirstRunWizard";

const appRoot = path.resolve(import.meta.dirname, "..");
const repoRoot = path.resolve(appRoot, "..", "..");
const outputRoot = process.env.OCP_FIRST_RUN_VISUAL_OUT
  ? path.resolve(process.env.OCP_FIRST_RUN_VISUAL_OUT)
  : path.join(repoRoot, "release", "out", "first-run-visual");
const styles = fs.readFileSync(path.join(appRoot, "src", "styles.css"), "utf8");

const baseAI = {
  providerId: "offline",
  baseUrl: "",
  model: "",
  timeoutSeconds: 45,
  ttsEnabled: false,
  chatVoiceMode: "off",
  ttsProviderId: "system",
  ttsModel: "gemini-3.1-flash-tts-preview",
  ttsVoice: "auto",
  ttsVoiceMode: "character",
  ttsVoiceGender: "neutral",
  ttsVoiceAge: "adult",
  thaiSpeechStyle: "neutral",
} as const;

function runtimeFor(step: number): RuntimeSnapshot {
  const ai = step === 2
    ? { ...baseAI, providerId: "ollama", baseUrl: "http://127.0.0.1:11434", model: "qwen3.5:latest" }
    : step === 3
      ? { ...baseAI, ttsEnabled: true, chatVoiceMode: "on-demand", ttsProviderId: "auto" }
      : baseAI;

  return {
    characters: [],
    commandResults: [],
    account: { signedIn: step === 1 },
    cloud: null,
    controlCenter: {
      settings: { language: "th", startWithWindows: false },
      ai: {
        settings: ai,
        credentials: { brokerAvailable: true, openAiCompatiblePresent: false, geminiPresent: false },
      },
    },
  } as unknown as RuntimeSnapshot;
}

function documentHtml(step: number): string {
  const markup = renderToStaticMarkup(
    <FirstRunWizard
      initialLanguage="th"
      initialStep={step}
      onComplete={async () => undefined}
      runtime={runtimeFor(step)}
      storeAvailable
    />,
  );

  const layoutProbe = `
<script>
window.addEventListener('load', () => {
  const pick = (selector) => document.querySelector(selector);
  const rect = (el) => el ? el.getBoundingClientRect() : null;
  const viewport = { width: innerWidth, height: innerHeight };
  const wizard = pick('.first-run-wizard');
  const main = pick('.first-run-main');
  const stepNode = pick('.first-run-step');
  const footer = pick('.first-run-footer');
  const skip = pick('.first-run-skip');
  const report = {
    viewport,
    wizard: rect(wizard),
    main: rect(main),
    step: rect(stepNode),
    footer: rect(footer),
    skip: rect(skip),
    skipVisible: !!skip && getComputedStyle(skip).display !== 'none' && rect(skip).width > 0 && rect(skip).height > 0,
    footerVisible: !!footer && rect(footer).bottom <= innerHeight + 1 && rect(footer).top >= -1,
    wizardFitsViewport: !!wizard && rect(wizard).left >= -1 && rect(wizard).top >= -1 && rect(wizard).right <= innerWidth + 1 && rect(wizard).bottom <= innerHeight + 1,
    horizontalOverflow: document.documentElement.scrollWidth > innerWidth + 1,
    bodyOverflow: document.body.scrollHeight > innerHeight + 1,
    mainScrollable: !!main && main.scrollHeight > main.clientHeight,
    stepScrollable: !!stepNode && stepNode.scrollHeight > stepNode.clientHeight,
  };
  const pre = document.createElement('pre');
  pre.id = 'ocp-visual-report';
  pre.style.display = 'none';
  pre.textContent = JSON.stringify(report);
  document.body.appendChild(pre);
});
</script>`;

  return `<!doctype html><html lang="th"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#root{margin:0;width:100%;height:100%;overflow:hidden;background:#020812}*{box-sizing:border-box}${styles}</style></head><body><div id="root">${markup}</div>${layoutProbe}</body></html>`;
}

export function generateFirstRunVisualFixtures(): string {
  fs.rmSync(outputRoot, { recursive: true, force: true });
  fs.mkdirSync(outputRoot, { recursive: true });
  for (let step = 0; step < 5; step += 1) {
    fs.writeFileSync(path.join(outputRoot, `step-${step + 1}.html`), documentHtml(step), "utf8");
  }
  fs.writeFileSync(path.join(outputRoot, "README.txt"), "Generated from production FirstRunWizard + styles.css. Use Test-OcpFirstRunVisual.ps1 for finite Chrome layout/screenshot acceptance.\n", "utf8");
  console.log(`FIRST_RUN_VISUAL_FIXTURES=${outputRoot}`);
  return outputRoot;
}
