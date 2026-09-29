import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { RuntimeSnapshot } from "../electron/runtime-bridge";
import { Chat } from "./App";

const runtime: RuntimeSnapshot = {
  schemaVersion: 10,
  status: "connected",
  appearance: { theme: "solid", locale: "en", fontFamily: "inter", textScale: "standard", reduceMotion: false },
  characters: [{ packageId: "character.scifi_woman", version: "2.0.0", name: "Sabai", active: true, animations: ["idle"] }],
  chat: {
    providerId: "ollama",
    status: "ready",
    sessionId: "session-test",
    revision: 2,
    activeMessageId: "",
    presentationState: "idle",
    presentation: { owner: "chat", state: "idle", sequence: 4, turnId: "", messageId: "", speechId: "", reasonCode: "ready" },
    messages: [
      { id: "u-1", role: "user", text: "Plan this\nwith two lines", status: "complete", feedback: "none" },
      { id: "a-1", role: "assistant", text: "A complete Runtime-owned answer", status: "complete", feedback: "positive" },
    ],
  },
  preview: { status: "idle", errorCode: "", packageId: "", version: "", clips: [], selectedAnimation: "", isPlaying: false, loop: false, speed: 1, framePngBase64: "", frameWidth: 0, frameHeight: 0 },
  controlCenter: null,
  commandResults: [],
  voice: { status: "healthy", reasonCode: "", lastSuccessAtMs: 1, retryAtMs: 0 },
};

describe("G16.26 Runtime-owned companion Chat view", () => {
  it("renders one full-window ChatGPT composition with one left Companion panel", () => {
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={runtime} />);
    expect(markup).toContain("gpt-shell");
    expect(markup).toContain("gpt-nav-rail");
    expect(markup).not.toContain("topbar");
    expect(markup).toContain("gpt-companion-panel");
    expect(markup).toContain("Sabai");
    expect(markup.match(/gpt-companion-stage/g)?.length).toBe(1);
  });

  it("uses a friendly character name when Runtime metadata repeats the package id", () => {
    const packageNamed: RuntimeSnapshot = {
      ...runtime,
      characters: [{ packageId: "character.sabai-sompoo", version: "1.0.1", name: "character.sabai-sompoo", active: true, animations: ["idle"] }],
    };
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={packageNamed} />);
    expect(markup).toContain("Sabai Sompoo");
    expect(markup).not.toContain(">character.sabai-sompoo<");
  });

  it("renders multiline Runtime text and the approved message actions", () => {
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={runtime} />);
    expect(markup).toContain("Plan this\nwith two lines");
    expect(markup).toContain("A complete Runtime-owned answer");
    for (const label of ["Copy response", "Edit message", "Read aloud", "Regenerate", "More"]) expect(markup).toContain(label);
    expect(markup).not.toContain("Good response");
    expect(markup).not.toContain("Bad response");
    expect(markup).not.toContain("Cloud sharing");
  });

  it("centers an empty composer and truthfully disables unapproved capabilities", () => {
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={{ ...runtime, chat: { ...runtime.chat, messages: [] } }} />);
    expect(markup).toContain("Where should we begin?");
    expect(markup).toContain("gpt-empty-state");
    expect(markup).toContain("File and image attachments require an approved Runtime attachment contract");
    expect(markup).toContain("Dictation is not available in this build");
    expect(markup).toContain("Voice Mode");
    expect(markup).toContain("On demand");
    expect(markup).toContain("disabled");
  });

  it("shows one provider-owned waiting state without an empty assistant message", () => {
    const waiting: RuntimeSnapshot = { ...runtime, chat: { ...runtime.chat, status: "thinking", activeMessageId: "u-2", presentationState: "think", presentation: { owner: "chat", state: "think", sequence: 5, turnId: "u-2", messageId: "u-2", speechId: "", reasonCode: "turn-active" }, messages: [runtime.chat.messages[0]!] } };
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={waiting} />);
    expect(markup).toContain("gpt-thinking");
    expect(markup).not.toContain("gpt-assistant-copy");
    expect(markup).toContain("Stop generating");
    expect(markup).toContain("gpt-companion-stage is-think");
  });

  it("renders the authoritative Runtime companion frame across idle, think, and talk presentation states", () => {
    const withFrame: RuntimeSnapshot = {
      ...runtime,
      preview: {
        status: "playing", errorCode: "", packageId: "character.scifi_woman", version: "2.0.0",
        clips: ["idle", "think", "speak"], selectedAnimation: "idle", isPlaying: true, loop: true, speed: 1,
        framePngBase64: "AAAA", frameWidth: 128, frameHeight: 128,
      },
    };
    const idleMarkup = renderToStaticMarkup(<Chat locale="en" runtime={withFrame} />);
    expect(idleMarkup).toContain("data:image/png;base64,AAAA");
    expect(idleMarkup).toContain("gpt-companion-stage is-idle");

    const thinking: RuntimeSnapshot = {
      ...withFrame,
      chat: { ...withFrame.chat, status: "thinking", presentationState: "think", presentation: { owner: "chat", state: "think", sequence: 5, turnId: "u-2", messageId: "u-2", speechId: "", reasonCode: "turn-active" } },
      preview: { ...withFrame.preview, selectedAnimation: "think" },
    };
    const thinkMarkup = renderToStaticMarkup(<Chat locale="en" runtime={thinking} />);
    expect(thinkMarkup).toContain("gpt-companion-stage is-think");
    expect(thinkMarkup).toContain("data:image/png;base64,AAAA");

    const talking: RuntimeSnapshot = {
      ...withFrame,
      chat: { ...withFrame.chat, presentationState: "talk", presentation: { owner: "chat", state: "talk", sequence: 6, turnId: "u-2", messageId: "u-2:assistant", speechId: "speech-1", reasonCode: "voice-playing" } },
      preview: { ...withFrame.preview, selectedAnimation: "speak" },
    };
    const talkMarkup = renderToStaticMarkup(<Chat locale="en" runtime={talking} />);
    expect(talkMarkup).toContain("gpt-companion-stage is-talk");
    expect(talkMarkup).toContain("data:image/png;base64,AAAA");
  });

  it("shows an explicit Preparing voice state while whole-WAV synthesis is pending", () => {
    const preparing: RuntimeSnapshot = {
      ...runtime,
      voice: { status: "synthesizing", reasonCode: "", lastSuccessAtMs: 1, retryAtMs: 0 },
      chat: {
        ...runtime.chat,
        presentationState: "think",
        presentation: { owner: "chat", state: "think", sequence: 7, turnId: "u-1", messageId: "a-1", speechId: "", reasonCode: "voice-synthesizing" },
      },
    };
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={preparing} />);
    expect(markup).toContain("Preparing voice");
    expect(markup).toContain("is-voice-progress");
    expect(markup).toContain("gpt-voice-spinner");
    expect(markup).toContain('aria-busy="true"');
    expect(markup).toContain("disabled");
    expect(markup).not.toContain("Runtime is preparing audio; playback has not started yet.");
    expect(markup).toContain("Use Read aloud on a reply. Chat will not delay text while preparing speech.");
  });

  it("surfaces provider rate-limit cooldown and disables repeated Read aloud requests", () => {
    const limited: RuntimeSnapshot = {
      ...runtime,
      voice: { status: "failed", reasonCode: "provider-rate-limited", lastSuccessAtMs: 1, retryAtMs: Date.now() + 30_000 },
      chat: {
        ...runtime.chat,
        presentation: { owner: "chat", state: "idle", sequence: 8, turnId: "u-1", messageId: "u-1", speechId: "", reasonCode: "voice-failed" },
      },
    };
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={limited} />);
    expect(markup).toContain("Voice is temporarily rate-limited. Retry in");
    expect(markup).toContain("Retry in 30s");
    expect(markup).toContain("is-cooldown");
    expect(markup).toContain("is-rate-limited");
    expect(markup).toContain("disabled");
    expect((markup.match(/Voice is temporarily rate-limited\./g) ?? []).length).toBe(1);
    expect(markup).not.toContain("gpt-read-aloud-error");
    expect(markup).not.toContain("Read aloud could not produce playable audio.");
  });

  it("labels unavailable Runtime state accurately", () => {
    const markup = renderToStaticMarkup(<Chat locale="en" runtime={null} />);
    expect(markup).toContain("Runtime adapter unavailable");
    expect(markup).toContain("Offline");
    expect(markup).not.toContain(">Online<");
  });
});
