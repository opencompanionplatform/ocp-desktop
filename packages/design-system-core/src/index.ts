export const themeNames = ["solid", "glass", "liquid"] as const;
export type ThemeName = (typeof themeNames)[number];

export type ThemeTokens = Readonly<{
  canvas: string;
  canvasRaised: string;
  panel: string;
  panelStrong: string;
  border: string;
  borderBright: string;
  text: string;
  textMuted: string;
  cyan: string;
  blue: string;
  violet: string;
  success: string;
  danger: string;
  shadow: string;
  blur: string;
}>;

export const themes: Record<ThemeName, ThemeTokens> = {
  solid: {
    canvas: "#050a14",
    canvasRaised: "#081225",
    panel: "#0b1930",
    panelStrong: "#102340",
    border: "#24476f",
    borderBright: "#28c7ff",
    text: "#f4f8ff",
    textMuted: "#98aac2",
    cyan: "#28d7ff",
    blue: "#2979ff",
    violet: "#8b5cf6",
    success: "#32d296",
    danger: "#ff5d7a",
    shadow: "rgba(0, 0, 0, 0.42)",
    blur: "0px",
  },
  glass: {
    canvas: "#040a16",
    canvasRaised: "#071328",
    panel: "rgba(11, 28, 52, 0.78)",
    panelStrong: "rgba(15, 37, 68, 0.9)",
    border: "rgba(104, 166, 224, 0.32)",
    borderBright: "#31c8ff",
    text: "#f6f9ff",
    textMuted: "#9fb0c9",
    cyan: "#31d6ff",
    blue: "#377dff",
    violet: "#9a63ff",
    success: "#40dfaa",
    danger: "#ff6784",
    shadow: "rgba(0, 5, 18, 0.58)",
    blur: "18px",
  },
  liquid: {
    canvas: "#030815",
    canvasRaised: "#071126",
    panel: "rgba(7, 25, 51, 0.72)",
    panelStrong: "rgba(11, 33, 65, 0.88)",
    border: "rgba(61, 143, 220, 0.35)",
    borderBright: "#22d3ff",
    text: "#f8fbff",
    textMuted: "#9aaac3",
    cyan: "#22d3ff",
    blue: "#236dff",
    violet: "#a259ff",
    success: "#35d8a0",
    danger: "#ff5978",
    shadow: "rgba(0, 5, 22, 0.66)",
    blur: "26px",
  },
};

export const motionTokens = {
  instant: 0.08,
  quick: 0.18,
  panel: 0.28,
  characterSwap: 0.72,
  easing: [0.22, 1, 0.36, 1] as const,
};

export const localeNames = ["en", "th"] as const;
export type LocaleName = (typeof localeNames)[number];

// These choices are deliberately small and allowlisted.  They are shared by
// every desktop-shell window so a preference cannot turn into arbitrary CSS.
export const fontFamilyNames = ["system", "inter", "noto-sans-thai", "atkinson"] as const;
export type FontFamilyName = (typeof fontFamilyNames)[number];

export const fontFamilyStacks: Record<FontFamilyName, string> = {
  system: '"Segoe UI Variable Text", "Segoe UI", "Leelawadee UI", Tahoma, system-ui, sans-serif',
  inter: 'Inter, "Leelawadee UI", Tahoma, "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif',
  "noto-sans-thai": '"Noto Sans Thai", "Leelawadee UI", Tahoma, "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif',
  atkinson: 'Atkinson Hyperlegible, "Leelawadee UI", Tahoma, "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif',
};

export const textScaleNames = ["normal", "standard", "comfortable", "large", "extra"] as const;
export type TextScaleName = (typeof textScaleNames)[number];

// Matches docs/OCP_TEXT_SCALE_SPEC.md. Standard is the product default.
export const textScaleValues: Record<TextScaleName, number> = {
  normal: 1,
  standard: 1.15,
  comfortable: 1.3,
  large: 1.5,
  extra: 1.8,
};

const en = {
  appName: "OCP Desktop Shell",
  foundation: "Animated shell foundation",
  home: "Overview",
  characters: "Characters",
  chat: "Chat",
  settings: "Settings",
  preview: "Live preview",
  componentGallery: "Component gallery",
  runtimeSeparated: "Companion runtime separated",
  runtimeDescription: "Godot owns the transparent companion. This opaque shell owns normal application windows.",
  switchCharacter: "Switch character",
  reduceMotion: "Reduced motion follows Windows accessibility settings.",
  disconnected: "Runtime adapter not connected in this foundation gate",
  theme: "Theme",
  language: "Language",
  solid: "Solid",
  glass: "Glass",
  liquid: "Liquid",
  performance: "WebGL preview",
  secure: "Sandboxed renderer",
  nativeWindow: "Native window lifecycle",
} as const;

const th: Record<keyof typeof en, string> = {
  appName: "OCP Desktop Shell",
  foundation: "รากฐานหน้าต่างแบบเคลื่อนไหว",
  home: "ภาพรวม",
  characters: "ตัวละคร",
  chat: "แชต",
  settings: "ตั้งค่า",
  preview: "พรีวิวแบบสด",
  componentGallery: "ตัวอย่างคอมโพเนนต์",
  runtimeSeparated: "แยก Companion Runtime แล้ว",
  runtimeDescription: "Godot ดูแลตัวละครโปร่งใส ส่วน Shell แบบทึบนี้ดูแลหน้าต่างแอปปกติ",
  switchCharacter: "เปลี่ยนตัวละคร",
  reduceMotion: "ลดการเคลื่อนไหวตามค่าการช่วยการเข้าถึงของ Windows",
  disconnected: "ยังไม่เชื่อม Runtime adapter ใน foundation gate นี้",
  theme: "ธีม",
  language: "ภาษา",
  solid: "Solid",
  glass: "Glass",
  liquid: "Liquid",
  performance: "พรีวิว WebGL",
  secure: "Renderer แบบ Sandbox",
  nativeWindow: "วงจรหน้าต่าง Native",
};

export const messages = { en, th } as const;
export type MessageKey = keyof typeof en;
