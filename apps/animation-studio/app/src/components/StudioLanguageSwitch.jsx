export default function StudioLanguageSwitch({ locale = "en", onChange }) {
  return <div className="studio-language-switch" role="group" aria-label="Studio language">
    <button type="button" className={locale === "en" ? "is-active" : ""} onClick={() => onChange?.("en")} aria-pressed={locale === "en"}>EN</button>
    <button type="button" className={locale === "th" ? "is-active" : ""} onClick={() => onChange?.("th")} aria-pressed={locale === "th"}>ไทย</button>
  </div>;
}
