//! Canonical Goal domain types.

use crate::ids::GoalId;
use crate::{Point2, SurfaceCapabilities, SurfaceId};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfacePlacement {
    Start,
    Center,
    End,
    Nearest,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "goal_type")]
pub enum Goal {
    MoveToPoint {
        id: GoalId,
        target: Point2,
    },
    OccupySurface {
        id: GoalId,
        surface_id: SurfaceId,
        placement: SurfacePlacement,
        arrival_behavior: Option<String>,
    },
    OccupyActiveWindowSurface {
        id: GoalId,
        required_capabilities: SurfaceCapabilities,
        placement: SurfacePlacement,
        arrival_behavior: Option<String>,
    },
    FollowCursor {
        id: GoalId,
        stopping_distance: f32,
    },
    ReturnHome {
        id: GoalId,
    },
    Stop {
        id: GoalId,
    },
}

impl Goal {
    #[must_use]
    pub const fn id(&self) -> GoalId {
        match self {
            Self::MoveToPoint { id, .. }
            | Self::OccupySurface { id, .. }
            | Self::OccupyActiveWindowSurface { id, .. }
            | Self::FollowCursor { id, .. }
            | Self::ReturnHome { id }
            | Self::Stop { id } => *id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GoalStatus {
    Created,
    Started,
    Completed,
    Failed,
    Cancelled,
}
