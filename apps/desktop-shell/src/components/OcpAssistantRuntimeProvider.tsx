import {
  AssistantRuntimeProvider,
  useExternalStoreRuntime,
  type AppendMessage,
  type ThreadMessageLike,
} from "@assistant-ui/react";
import { useCallback, useMemo, type ReactNode } from "react";

import type { RuntimeChatMessage } from "../../electron/runtime-bridge";
import { assistantPromptFromAppendMessage, editedRuntimeMessageId, toAssistantThreadMessages } from "../contracts/assistant-runtime";

type OcpAssistantRuntimeProviderProps = Readonly<{
  children: ReactNode;
  isRunning: boolean;
  isSendDisabled: boolean;
  messages: readonly RuntimeChatMessage[];
  onSubmit: (prompt: string) => Promise<void>;
  onCancel?: () => Promise<void>;
  onEdit?: (messageId: string, prompt: string) => Promise<void>;
  onFeedback?: (messageId: string, feedback: "positive" | "negative") => void;
  onReload?: (messageId: string) => Promise<void>;
}>;

export function OcpAssistantRuntimeProvider({ children, isRunning, isSendDisabled, messages, onSubmit, onCancel, onEdit, onFeedback, onReload }: OcpAssistantRuntimeProviderProps) {
  const projectedMessages = useMemo(() => toAssistantThreadMessages(messages), [messages]);
  const submit = useCallback(async (message: AppendMessage): Promise<void> => {
    const prompt = assistantPromptFromAppendMessage(message);
    if (!prompt) throw new Error("OCP Chat accepts text-only messages");
    await onSubmit(prompt);
  }, [onSubmit]);
  const edit = useCallback(async (message: AppendMessage): Promise<void> => {
    const prompt = assistantPromptFromAppendMessage(message);
    const messageId = editedRuntimeMessageId(message, messages);
    if (!prompt || !messageId) throw new Error("OCP Chat edit target is unavailable");
    if (!onEdit) throw new Error("OCP Chat editing is unavailable");
    await onEdit(messageId, prompt);
  }, [messages, onEdit]);
  const runtime = useExternalStoreRuntime<ThreadMessageLike>({
    messages: projectedMessages,
    convertMessage: (message) => message,
    isSendDisabled,
    isRunning,
    onNew: submit,
    onEdit: onEdit ? edit : undefined,
    onReload: onReload ? async (parentId) => {
      const fallback = [...messages].reverse().find((message) => message.role === "user")?.id;
      const messageId = parentId ?? fallback;
      if (!messageId) throw new Error("OCP Chat regenerate target is unavailable");
      await onReload(messageId);
    } : undefined,
    onCancel,
    adapters: onFeedback ? {
      feedback: {
        submit: ({ message, type }) => onFeedback(message.id, type),
      },
    } : undefined,
    unstable_enableToolInvocations: false,
  });

  return <AssistantRuntimeProvider runtime={runtime}>{children}</AssistantRuntimeProvider>;
}
