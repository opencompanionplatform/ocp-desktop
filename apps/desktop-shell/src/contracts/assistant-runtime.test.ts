import type { AppendMessage } from "@assistant-ui/react";
import { describe, expect, it } from "vitest";

import type { RuntimeChatMessage } from "../../electron/runtime-bridge";
import { assistantPromptFromAppendMessage, editedRuntimeMessageId, toAssistantThreadMessages } from "./assistant-runtime";

const runtimeMessages: readonly RuntimeChatMessage[] = [
  { id: "u-1", role: "user", text: "สรุปเอกสารนี้", status: "complete" },
  { id: "a-1", role: "assistant", text: "กำลัง stream และต้องแสดงทันที", status: "streaming" },
  { id: "a-2", role: "assistant", text: "สรุปเสร็จแล้ว <script>unsafe()</script>", status: "complete", feedback: "positive" },
  { id: "a-3", role: "assistant", text: "ตอบไม่สำเร็จ", status: "failed" },
];

describe("OCP assistant-ui external-store contract", () => {
  it("projects one Runtime-owned running message and preserves text as data", () => {
    const projected = toAssistantThreadMessages(runtimeMessages);

    expect(projected).toHaveLength(4);
    expect(projected.map((message) => message.id)).toEqual(["u-1", "a-1", "a-2", "a-3"]);
    expect(projected[1]?.content).toBe("กำลัง stream และต้องแสดงทันที");
    expect(projected[1]?.status).toEqual({ type: "running" });
    expect(projected[2]?.content).toBe("สรุปเสร็จแล้ว <script>unsafe()</script>");
    expect(projected[2]?.status).toEqual({ type: "complete", reason: "stop" });
    expect(projected[2]?.metadata?.submittedFeedback).toEqual({ type: "positive" });
    expect(projected[3]?.status).toEqual({ type: "incomplete", reason: "error" });
  });

  it("resolves an edited user message from assistant-ui's parent id", () => {
    const firstEdit = { role: "user", parentId: null, content: [{ type: "text", text: "first revised" }] } as unknown as AppendMessage;
    const laterEdit = { role: "user", parentId: "a-1", content: [{ type: "text", text: "later revised" }] } as unknown as AppendMessage;
    const conversation: readonly RuntimeChatMessage[] = [
      { id: "u-1", role: "user", text: "first", status: "complete" },
      { id: "a-1", role: "assistant", text: "answer", status: "complete" },
      { id: "u-2", role: "user", text: "later", status: "complete" },
    ];
    expect(editedRuntimeMessageId(firstEdit, conversation)).toBe("u-1");
    expect(editedRuntimeMessageId(laterEdit, conversation)).toBe("u-2");
  });

  it("accepts a bounded text-only user message and rejects attachment/tool content", () => {
    const textMessage = {
      role: "user",
      content: [{ type: "text", text: "ตั้งปลุก 07:00" }],
    } as unknown as AppendMessage;
    const imageMessage = {
      role: "user",
      content: [{ type: "image", image: "data:image/png;base64,AAAA" }],
    } as unknown as AppendMessage;

    expect(assistantPromptFromAppendMessage(textMessage)).toBe("ตั้งปลุก 07:00");
    expect(assistantPromptFromAppendMessage(imageMessage)).toBeNull();
  });
});
