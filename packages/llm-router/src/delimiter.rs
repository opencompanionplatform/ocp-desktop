//! Untrusted-content delimitation (SEC-032, PROMPT_STANDARD.md). Canonical
//! format:
//!
//! ```text
//! <untrusted source="mcp:weather-server/get_forecast">
//! ...content...
//! </untrusted>
//! ```
//!
//! Only the AI Router calls this — never the content producer. A
//! producer-supplied `<untrusted>`/`</untrusted>` string inside the content
//! itself is escaped so nesting cannot break out of the wrapper.
//!
//! Origin tag taxonomy (PROMPT_STANDARD.md): `plugin:<id>`,
//! `mcp:<serverId>/<tool>`, `memory:<scope>`, `web:<host>`.

/// Wrap `content` from `source` as delimited untrusted data.
#[must_use]
pub fn wrap_untrusted(source: &str, content: &str) -> String {
    let escaped = content
        .replace("<untrusted", "&lt;untrusted")
        .replace("</untrusted>", "&lt;/untrusted&gt;");
    format!("<untrusted source=\"{source}\">\n{escaped}\n</untrusted>")
}
