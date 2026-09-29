export const ONBOARDING_SCHEMA_VERSION = 1 as const;

export const onboardingCompletionReasons = ["completed", "skipped", "existing-library"] as const;
export type OnboardingCompletionReason = (typeof onboardingCompletionReasons)[number];

export type OnboardingState = Readonly<{
  version: typeof ONBOARDING_SCHEMA_VERSION;
  completed: boolean;
  completedAt: string;
  reason: OnboardingCompletionReason | "";
}>;

export const DEFAULT_ONBOARDING_STATE: OnboardingState = Object.freeze({
  version: ONBOARDING_SCHEMA_VERSION,
  completed: false,
  completedAt: "",
  reason: "",
});

export function installHandoffShellView(state: OnboardingState): "home" | "characters" {
  return state.completed ? "characters" : "home";
}

export function sanitizeOnboardingState(value: unknown): OnboardingState | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = value as Record<string, unknown>;
  if (candidate.version !== ONBOARDING_SCHEMA_VERSION || typeof candidate.completed !== "boolean") return null;
  if (typeof candidate.completedAt !== "string" || candidate.completedAt.length > 64) return null;
  if (typeof candidate.reason !== "string") return null;
  if (candidate.completed) {
    if (!onboardingCompletionReasons.includes(candidate.reason as OnboardingCompletionReason)) return null;
    const timestamp = Date.parse(candidate.completedAt);
    if (!Number.isFinite(timestamp)) return null;
  } else if (candidate.completedAt !== "" || candidate.reason !== "") return null;
  return {
    version: ONBOARDING_SCHEMA_VERSION,
    completed: candidate.completed,
    completedAt: candidate.completedAt,
    reason: candidate.reason as OnboardingCompletionReason | "",
  };
}

export function completeOnboarding(reason: OnboardingCompletionReason, completedAt = new Date().toISOString()): OnboardingState {
  return {
    version: ONBOARDING_SCHEMA_VERSION,
    completed: true,
    completedAt,
    reason,
  };
}
