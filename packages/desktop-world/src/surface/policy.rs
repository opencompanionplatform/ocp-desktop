use serde::{Deserialize, Serialize};

/// Eligibility policy belongs beside geometry, but does not encode character
/// capabilities. RC27 uses it only to decide whether a Window may produce a
/// visible Surface.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SurfaceEligibilityPolicy {
    pub exclude_invisible_windows: bool,
    pub exclude_minimized_windows: bool,
    pub exclude_tool_windows: bool,
    pub excluded_application_prefixes: Vec<String>,
    pub excluded_title_fragments: Vec<String>,
}

impl Default for SurfaceEligibilityPolicy {
    fn default() -> Self {
        Self {
            exclude_invisible_windows: true,
            exclude_minimized_windows: true,
            exclude_tool_windows: true,
            excluded_application_prefixes: vec!["ocp".to_owned(), "godot".to_owned()],
            excluded_title_fragments: vec![
                "ocp desktop runtime".to_owned(),
                "runtime v3".to_owned(),
                "desktop world debug".to_owned(),
            ],
        }
    }
}

impl SurfaceEligibilityPolicy {
    #[must_use]
    pub fn permits_window(
        &self,
        application_id: &str,
        title: &str,
        visible: bool,
        minimized: bool,
        tool_window: bool,
    ) -> bool {
        if self.exclude_invisible_windows && !visible {
            return false;
        }
        if self.exclude_minimized_windows && minimized {
            return false;
        }
        if self.exclude_tool_windows && tool_window {
            return false;
        }

        let application = application_id.to_ascii_lowercase();
        if self
            .excluded_application_prefixes
            .iter()
            .any(|prefix| application.starts_with(&prefix.to_ascii_lowercase()))
        {
            return false;
        }

        let normalized_title = title.to_ascii_lowercase();
        !self
            .excluded_title_fragments
            .iter()
            .any(|fragment| normalized_title.contains(&fragment.to_ascii_lowercase()))
    }
}
