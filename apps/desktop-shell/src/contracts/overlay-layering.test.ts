import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const css = readFileSync(path.resolve(process.cwd(), "src/styles.css"), "utf8");

describe("Desktop overlay layering contract", () => {
  it("keeps the global Account dropdown above page cards", () => {
    expect(css).toContain(".topbar{position:relative;z-index:500;overflow:visible;");
    expect(css).toContain(".account-menu{position:absolute;right:0;top:calc(100% + 8px);");
    expect(css).toContain("z-index:120");
  });

  it("keeps Chat popovers above the Companion panel and message content", () => {
    expect(css).toContain(".gpt-chat-header { position:relative; z-index:80; overflow:visible;");
    expect(css).toContain(".gpt-more-menu { z-index:160;");
    expect(css).toContain(".gpt-companion-panel { position:relative; z-index:6;");
    expect(css).toContain(".gpt-runtime-alert { position:absolute; z-index:10;");
  });
});
