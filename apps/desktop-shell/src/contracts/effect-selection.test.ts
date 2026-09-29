import { describe, expect, it } from "vitest";
import { effectSelectionOutcome } from "./effect-selection";

describe("effect selection preview sequencing", () => {
  it("waits for the selected pack to be equipped before previewing", () => {
    expect(effectSelectionOutcome(undefined, true, true)).toBe("wait");
    expect(effectSelectionOutcome({ status: "accepted" }, true, true)).toBe("wait");
    expect(effectSelectionOutcome({ status: "succeeded" }, true, true)).toBe("preview");
  });
  it("does not preview the previous pack after a failed selection", () => {
    expect(effectSelectionOutcome({ status: "failed" }, true, true)).toBe("failed");
  });
  it("discards a request after changing characters and waits for a loading preview", () => {
    expect(effectSelectionOutcome({ status: "succeeded" }, false, true)).toBe("discard");
    expect(effectSelectionOutcome({ status: "succeeded" }, true, false)).toBe("wait");
  });
});
