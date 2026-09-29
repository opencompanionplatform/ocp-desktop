export const shellViews = ["home", "characters", "library", "chat", "settings", "updates"] as const;
export const shellSources = ["command-line", "hover-menu", "tray", "second-instance", "shell-navigation"] as const;

export type ShellView = (typeof shellViews)[number];
export type ShellSource = (typeof shellSources)[number];
export type DisplayPoint = Readonly<{ x: number; y: number }>;
export type ShellIntent = Readonly<{
  view: ShellView;
  source: ShellSource;
  displayPoint?: DisplayPoint;
}>;

export type ValidationResult<T> =
  | Readonly<{ ok: true; value: T }>
  | Readonly<{ ok: false; reason: string }>;

const MAX_COORDINATE = 1_000_000;
const INTENT_KEYS = new Set(["view", "source", "displayPoint"]);
const POINT_KEYS = new Set(["x", "y"]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>): boolean {
  return Object.keys(value).every((key) => allowed.has(key));
}

function isBoundedCoordinate(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && Math.abs(value) <= MAX_COORDINATE;
}

export function sanitizeShellIntent(value: unknown): ValidationResult<ShellIntent> {
  if (!isRecord(value) || !hasOnlyKeys(value, INTENT_KEYS)) {
    return { ok: false, reason: "intent must be a strict object" };
  }
  if (!shellViews.includes(value.view as ShellView)) {
    return { ok: false, reason: "view is not allowlisted" };
  }
  if (!shellSources.includes(value.source as ShellSource)) {
    return { ok: false, reason: "source is not allowlisted" };
  }

  let displayPoint: DisplayPoint | undefined;
  if (value.displayPoint !== undefined) {
    if (!isRecord(value.displayPoint) || !hasOnlyKeys(value.displayPoint, POINT_KEYS)) {
      return { ok: false, reason: "displayPoint must be a strict object" };
    }
    if (!isBoundedCoordinate(value.displayPoint.x) || !isBoundedCoordinate(value.displayPoint.y)) {
      return { ok: false, reason: "displayPoint coordinates are invalid" };
    }
    displayPoint = { x: value.displayPoint.x, y: value.displayPoint.y };
  }

  return {
    ok: true,
    value: {
      view: value.view as ShellView,
      source: value.source as ShellSource,
      ...(displayPoint ? { displayPoint } : {}),
    },
  };
}

function findArgument(args: readonly string[], name: string): string | undefined {
  const prefix = `--${name}=`;
  return args.find((argument) => argument.startsWith(prefix))?.slice(prefix.length);
}

export function parseShellIntentArgs(args: readonly string[]): ValidationResult<ShellIntent> {
  const view = findArgument(args, "ocp-open") ?? "home";
  const source = findArgument(args, "ocp-source") ?? "command-line";
  const xText = findArgument(args, "ocp-display-x");
  const yText = findArgument(args, "ocp-display-y");

  if ((xText === undefined) !== (yText === undefined)) {
    return { ok: false, reason: "display coordinates must be provided together" };
  }

  const candidate: Record<string, unknown> = { view, source };
  if (xText !== undefined && yText !== undefined) {
    if (xText.trim() === "" || yText.trim() === "") {
      return { ok: false, reason: "display coordinates cannot be empty" };
    }
    candidate.displayPoint = { x: Number(xText), y: Number(yText) };
  }
  return sanitizeShellIntent(candidate);
}
