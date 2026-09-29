import type { LocaleName } from "./contracts/appearance";
import enCatalog from "./locales/en.json";
import thCatalog from "./locales/th.json";

type MessageTable = Readonly<Record<string, string>>;

// Locale data lives in JSON so translators can edit catalogs without touching
// renderer code. New locales only need a JSON catalog and an allowlisted
// locale name in the appearance contract.
const catalogs: Readonly<Record<LocaleName, MessageTable>> = {
  en: enCatalog as MessageTable,
  th: thCatalog as MessageTable,
};

export function translate(locale: LocaleName, key: string, fallback?: string, values: Readonly<Record<string, string | number>> = {}): string {
  let result = catalogs[locale][key] ?? catalogs.en[key] ?? fallback ?? key;
  for (const [name, value] of Object.entries(values)) result = result.replaceAll(`{${name}}`, String(value));
  return result;
}

export function localeFromSettings(locale: string | undefined): LocaleName {
  return locale?.toLowerCase().startsWith("th") ? "th" : "en";
}
