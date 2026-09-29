import { describe, expect, it } from "vitest";

import { completeOnboarding, DEFAULT_ONBOARDING_STATE, installHandoffShellView, sanitizeOnboardingState } from "./onboarding-state";

describe("desktop onboarding state", () => {
  it("accepts the canonical incomplete state", () => {
    expect(sanitizeOnboardingState(DEFAULT_ONBOARDING_STATE)).toEqual(DEFAULT_ONBOARDING_STATE);
  });

  it("creates and accepts a versioned completion marker", () => {
    const state = completeOnboarding("completed", "2026-09-06T12:00:00.000Z");
    expect(sanitizeOnboardingState(state)).toEqual(state);
  });

  it("accepts the existing-library migration reason", () => {
    const state = completeOnboarding("existing-library", "2026-09-06T12:00:00.000Z");
    expect(sanitizeOnboardingState(state)?.reason).toBe("existing-library");
  });

  it("keeps install handoffs on Home until First Run is completed", () => {
    expect(installHandoffShellView(DEFAULT_ONBOARDING_STATE)).toBe("home");
    expect(installHandoffShellView(completeOnboarding("completed", "2026-09-06T12:00:00.000Z"))).toBe("characters");
  });

  it("rejects malformed, future-version and incomplete-with-metadata states", () => {
    expect(sanitizeOnboardingState({ version: 2, completed: false, completedAt: "", reason: "" })).toBeNull();
    expect(sanitizeOnboardingState({ version: 1, completed: true, completedAt: "bad", reason: "completed" })).toBeNull();
    expect(sanitizeOnboardingState({ version: 1, completed: false, completedAt: "2026-09-06T12:00:00.000Z", reason: "" })).toBeNull();
  });
});
