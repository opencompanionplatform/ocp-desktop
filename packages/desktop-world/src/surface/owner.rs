use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "owner_type")]
pub enum SurfaceOwnerV2 {
    Monitor {
        monitor_id: String,
    },
    Window {
        window_id: String,
        application_id: String,
    },
    Taskbar {
        entity_id: String,
    },
}

impl SurfaceOwnerV2 {
    #[must_use]
    pub fn semantic_id(&self) -> &str {
        match self {
            Self::Monitor { monitor_id } => monitor_id,
            Self::Window { window_id, .. } => window_id,
            Self::Taskbar { entity_id } => entity_id,
        }
    }
}
