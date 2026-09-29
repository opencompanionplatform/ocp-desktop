import type { AppendMessage, ThreadMessageLike } from "@assistant-ui/react";

import type { RuntimeChatMessage } from "../../electron/runtime-bridge";

const MAX_PROMPT_LENGTH = 4_000;

export function toAssistantThreadMessages(messages: readonly RuntimeChatMessage[]): readonly ThreadMessageLike[] {
  return messages.map((message): ThreadMessageLike => ({
      id: message.id,
      role: message.role,
      content: message.text,
      metadata: {
        custom: {},
        ...(message.feedback && message.feedback !== "none" ? { submittedFeedback: { type: message.feedback } } : {}),
      },
      ...(message.role === "assistant"
        ? { status: message.status === "streaming" ? { type: "running" } : message.status === "failed" ? { type: "incomplete", reason: "error" } : { type: "complete", reason: "stop" } }
        : {}),
    }));
}

export function editedRuntimeMessageId(message: AppendMessage, messages: readonly RuntimeChatMessage[]): string | null {
  if (message.role !== "user") return null;
  const parentIndex = message.parentId === null ? -1 : messages.findIndex((candidate) => candidate.id === message.parentId);
  if (message.parentId !== null && parentIndex < 0) return null;
  return messages.slice(parentIndex + 1).find((candidate) => candidate.role === "user")?.id ?? null;
}

export function assistantPromptFromAppendMessage(message: AppendMessage): string | null {
  if (message.role !== "user" || message.content.length === 0) return null;
  let rawPrompt = "";
  for (const part of message.content) {
    if (part.type !== "text") return null;
    rawPrompt += part.text;
  }
  const prompt = rawPrompt.trim();
  if (prompt.length === 0 || prompt.length > MAX_PROMPT_LENGTH) return null;
  return prompt;
}
