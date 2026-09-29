/** Browser-independent keyboard policy for the Runtime-owned Chat command. */
export function shouldSubmitChatOnEnter(key: string, shiftKey: boolean): boolean {
  return key === "Enter" && !shiftKey;
}
