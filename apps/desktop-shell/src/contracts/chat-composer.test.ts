import { describe, expect, it } from "vitest";

import { shouldSubmitChatOnEnter } from "./chat-composer";

describe("Chat composer keyboard policy", () => {
  it("sends with Enter and retains normal multiline input with Shift+Enter", () => {
    expect(shouldSubmitChatOnEnter("Enter", false)).toBe(true);
    expect(shouldSubmitChatOnEnter("Enter", true)).toBe(false);
    expect(shouldSubmitChatOnEnter("a", false)).toBe(false);
  });
});
