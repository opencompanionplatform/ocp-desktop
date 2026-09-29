export type Rectangle = Readonly<{ x: number; y: number; width: number; height: number }>;
export type DisplayArea = Readonly<{ id: string; workArea: Rectangle }>;
export type StoredWindowState = Readonly<{ bounds: Rectangle; maximized: boolean }>;

export const DEFAULT_WINDOW_SIZE = { width: 1280, height: 820 } as const;
export const MIN_WINDOW_SIZE = { width: 960, height: 680 } as const;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function validRectangle(value: unknown): value is Rectangle {
  return (
    isRecord(value) &&
    Object.keys(value).every((key) => ["x", "y", "width", "height"].includes(key)) &&
    finiteNumber(value.x) &&
    finiteNumber(value.y) &&
    finiteNumber(value.width) &&
    finiteNumber(value.height) &&
    value.width > 0 &&
    value.height > 0
  );
}

export function sanitizeStoredWindowState(value: unknown): StoredWindowState | null {
  if (
    !isRecord(value) ||
    !Object.keys(value).every((key) => ["bounds", "maximized"].includes(key)) ||
    !validRectangle(value.bounds) ||
    typeof value.maximized !== "boolean"
  ) {
    return null;
  }
  return { bounds: value.bounds, maximized: value.maximized };
}

function overlapArea(a: Rectangle, b: Rectangle): number {
  const width = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x));
  const height = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));
  return width * height;
}

function containsPoint(rect: Rectangle, point: Readonly<{ x: number; y: number }>): boolean {
  return point.x >= rect.x && point.x < rect.x + rect.width && point.y >= rect.y && point.y < rect.y + rect.height;
}

function centerBounds(workArea: Rectangle): Rectangle {
  const width = Math.min(DEFAULT_WINDOW_SIZE.width, workArea.width);
  const height = Math.min(DEFAULT_WINDOW_SIZE.height, workArea.height);
  return {
    x: Math.round(workArea.x + (workArea.width - width) / 2),
    y: Math.round(workArea.y + (workArea.height - height) / 2),
    width,
    height,
  };
}

export function resolveWindowPlacement(
  stored: StoredWindowState | null,
  displays: readonly DisplayArea[],
  preferredPoint?: Readonly<{ x: number; y: number }>,
): StoredWindowState {
  if (displays.length === 0) {
    return { bounds: { x: 0, y: 0, ...DEFAULT_WINDOW_SIZE }, maximized: stored?.maximized ?? false };
  }
  const preferred = preferredPoint
    ? displays.find((display) => containsPoint(display.workArea, preferredPoint))
    : undefined;
  const fallbackDisplay = preferred ?? displays[0];

  if (!stored || !displays.some((display) => overlapArea(stored.bounds, display.workArea) >= 64 * 64)) {
    return { bounds: centerBounds(fallbackDisplay.workArea), maximized: stored?.maximized ?? false };
  }

  const display = displays.reduce((best, candidate) =>
    overlapArea(stored.bounds, candidate.workArea) > overlapArea(stored.bounds, best.workArea) ? candidate : best,
  );
  const width = Math.min(display.workArea.width, Math.max(MIN_WINDOW_SIZE.width, stored.bounds.width));
  const height = Math.min(display.workArea.height, Math.max(MIN_WINDOW_SIZE.height, stored.bounds.height));
  const x = Math.min(
    Math.max(stored.bounds.x, display.workArea.x),
    display.workArea.x + display.workArea.width - width,
  );
  const y = Math.min(
    Math.max(stored.bounds.y, display.workArea.y),
    display.workArea.y + display.workArea.height - height,
  );
  return { bounds: { x, y, width, height }, maximized: stored.maximized };
}
