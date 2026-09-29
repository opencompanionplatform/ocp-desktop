import { readFileSync } from "node:fs";
import path from "node:path";

import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { RuntimeSnapshot } from "../../electron/runtime-bridge";
import { FirstRunWizard } from "./FirstRunWizard";

const runtime = {
  characters: [],
  commandResults: [],
  account: { signedIn: false },
  cloud: null,
  controlCenter: {
    settings: { language: "en", startWithWindows: false },
    ai: {
      settings: {
        providerId: "offline",
        baseUrl: "",
        model: "",
        timeoutSeconds: 45,
        ttsEnabled: false,
        chatVoiceMode: "off",
        ttsProviderId: "system",
        ttsModel: "gemini-2.5-flash-preview-tts",
        ttsVoice: "auto",
        ttsVoiceMode: "character",
        ttsVoiceGender: "neutral",
        ttsVoiceAge: "adult",
        thaiSpeechStyle: "neutral",
      },
      credentials: { brokerAvailable: true, openAiCompatiblePresent: false, geminiPresent: false },
    },
  },
} as unknown as RuntimeSnapshot;

if (process.env.OCP_FIRST_RUN_VISUAL_OUT) {
  describe("First Run Wizard visual fixture generation", () => {
    it("writes production-component visual fixtures for the finite Chrome harness", async () => {
      const { generateFirstRunVisualFixtures } = await import("../../tools/render-first-run-visual-fixtures");
      const output = generateFirstRunVisualFixtures();
      expect(output).toBe(path.resolve(process.env.OCP_FIRST_RUN_VISUAL_OUT!));
    });
  });
}

describe("First Run Wizard", () => {
  it("renders the five-step guided setup without requiring an account", () => {
    const markup = renderToStaticMarkup(<FirstRunWizard initialLanguage="en" onComplete={async () => undefined} runtime={runtime} storeAvailable />);
    expect(markup).toContain("Welcome to OCP");
    expect(markup).toContain("Language");
    expect(markup).toContain("Companion");
    expect(markup).toContain("AI");
    expect(markup).toContain("Voice");
    expect(markup).toContain("Ready");
    expect(markup).toContain("Skip setup");
  });

  it("starts in Thai when the Runtime language is Thai", () => {
    const markup = renderToStaticMarkup(<FirstRunWizard initialLanguage="th" onComplete={async () => undefined} runtime={runtime} storeAvailable />);
    expect(markup).toContain("ยินดีต้อนรับสู่ OCP");
    expect(markup).toContain("ตั้งค่าคู่หูบนหน้าจอ");
    expect(markup).toContain("ข้ามการตั้งค่า");
  });

  it("renders Ollama discovery controls in the AI step", () => {
    const ollamaRuntime = {
      ...runtime,
      controlCenter: {
        ...runtime.controlCenter,
        ai: {
          ...runtime.controlCenter?.ai,
          settings: {
            ...runtime.controlCenter?.ai?.settings,
            providerId: "ollama",
            baseUrl: "http://127.0.0.1:11434",
            model: "qwen3.5:latest",
          },
        },
      },
    } as unknown as RuntimeSnapshot;
    const markup = renderToStaticMarkup(<FirstRunWizard initialLanguage="th" initialStep={2} onComplete={async () => undefined} runtime={ollamaRuntime} storeAvailable />);
    expect(markup).toContain("ค้นหาโมเดลที่ติดตั้ง");
    expect(markup).toContain("http://127.0.0.1:11434");
  });

  it("exposes explicit dialog, current-step, and selected-choice accessibility state", () => {
    const markup = renderToStaticMarkup(<FirstRunWizard initialLanguage="en" onComplete={async () => undefined} runtime={runtime} storeAvailable />);
    expect(markup).toContain('role="dialog"');
    expect(markup).toContain('aria-modal="true"');
    expect(markup).toContain('aria-busy="false"');
    expect(markup).toContain('aria-current="step"');
    expect(markup).toContain('aria-pressed="true"');
  });

  it("keeps Skip setup available and step content scrollable in the narrow-window layout", () => {
    const css = readFileSync(path.resolve(process.cwd(), "src/styles.css"), "utf8");
    expect(css).toContain("@media(max-width:820px)");
    expect(css).toContain(".first-run-rail{display:flex;flex-direction:row");
    expect(css).toContain(".first-run-skip{margin:0 0 0 auto}");
    expect(css).toContain(".first-run-step{align-self:center;max-width:700px;width:100%;max-height:100%;margin:auto;overflow:auto");
    expect(css).not.toContain("@media(max-width:820px){.first-run-wizard{grid-template-columns:1fr;height:min(720px,94vh)}.first-run-rail{display:none}");
  });
});
