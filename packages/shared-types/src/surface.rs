//! Canonical Surface domain types.

use crate::{Orientation, Point2, Rect, SurfaceId, Transform2, WorldEntityId};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SurfaceCapabilities(pub u32);

impl SurfaceCapabilities {
    pub const NONE: Self = Self(0);
    pub const WALKABLE: Self = Self(1 << 0);
    pub const RUNNABLE: Self = Self(1 << 1);
    pub const CLIMBABLE: Self = Self(1 << 2);
    pub const HANGABLE: Self = Self(1 << 3);
    pub const LANDABLE: Self = Self(1 << 4);
    pub const SITTABLE: Self = Self(1 << 5);
    pub const SLEEPABLE: Self = Self(1 << 6);
    pub const JUMP_ORIGIN: Self = Self(1 << 7);
    pub const JUMP_TARGET: Self = Self(1 << 8);
    pub const PASSABLE: Self = Self(1 << 9);
    pub const DYNAMIC: Self = Self(1 << 10);

    #[must_use]
    pub const fn contains(self, capability: Self) -> bool {
        (self.0 & capability.0) == capability.0
    }

    #[must_use]
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }
}

impl Default for SurfaceCapabilities {
    fn default() -> Self {
        Self::NONE
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceKind {
    DesktopFloor,
    MonitorEdge,
    WindowTop,
    WindowLeft,
    WindowRight,
    WindowBottom,
    TaskbarTop,
    DockTop,
    WidgetEdge,
    FloatingPanelEdge,
    Custom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceStability {
    Static,
    Dynamic,
    Volatile,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SurfaceGeometry {
    Segment { start: Point2, end: Point2 },
    Rectangle { rect: Rect },
    Point { position: Point2 },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceDescriptor {
    pub id: SurfaceId,
    pub provider_id: String,
    pub owner_entity_id: Option<WorldEntityId>,
    pub surface_kind: SurfaceKind,
    pub geometry: SurfaceGeometry,
    pub orientation: Orientation,
    pub normal: crate::Vector2,
    pub capabilities: SurfaceCapabilities,
    pub stability: SurfaceStability,
    pub motion_binding: Option<Transform2>,
    pub attachment_points: Vec<AttachmentPoint>,
    pub tags: Vec<String>,
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AttachmentPoint {
    pub position: Point2,
    pub normal: crate::Vector2,
    pub tag: Option<String>,
}
