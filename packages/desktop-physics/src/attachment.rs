use ocp_shared_types::{Point2, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SurfaceAttachment {
    pub surface_id: SurfaceId,
    pub anchor: Point2,
    pub normal: Vector2,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "state")]
pub enum AttachmentState {
    #[default]
    Detached,
    Grounded {
        attachment: SurfaceAttachment,
    },
    Attached {
        attachment: SurfaceAttachment,
    },
    Hanging {
        attachment: SurfaceAttachment,
    },
}

impl AttachmentState {
    #[must_use]
    pub const fn surface_id(self) -> Option<SurfaceId> {
        match self {
            Self::Detached => None,
            Self::Grounded { attachment }
            | Self::Attached { attachment }
            | Self::Hanging { attachment } => Some(attachment.surface_id),
        }
    }

    #[must_use]
    pub const fn attachment(self) -> Option<SurfaceAttachment> {
        match self {
            Self::Detached => None,
            Self::Grounded { attachment }
            | Self::Attached { attachment }
            | Self::Hanging { attachment } => Some(attachment),
        }
    }

    #[must_use]
    pub const fn is_grounded(self) -> bool {
        matches!(self, Self::Grounded { .. })
    }

    #[must_use]
    pub const fn is_attached(self) -> bool {
        !matches!(self, Self::Detached)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "transition")]
pub enum AttachmentTransition {
    None,
    Attached { surface_id: SurfaceId },
    Grounded { surface_id: SurfaceId },
    Hanging { surface_id: SurfaceId },
    Detached { previous_surface_id: SurfaceId },
}
