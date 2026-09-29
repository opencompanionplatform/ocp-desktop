use ocp_shared_types::{Point2, Vector2, WorldRevision};
use serde::{Deserialize, Serialize};

use super::{SurfaceKindV2, SurfaceOrientation, SurfaceOwnerV2, SurfaceRegistryId};

/// Environmental support flags. Character capability is resolved separately.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SurfaceSupport {
    pub supports_walk: bool,
    pub supports_sit: bool,
    pub supports_climb: bool,
    pub supports_hang: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceSegment {
    pub id: SurfaceRegistryId,
    pub kind: SurfaceKindV2,
    pub start: Point2,
    pub end: Point2,
    pub normal: Vector2,
    pub thickness: f32,
    pub orientation: SurfaceOrientation,
    pub owner: SurfaceOwnerV2,
    pub support: SurfaceSupport,
    pub z_order: i32,
    pub eligible: bool,
    pub visible: bool,
    pub world_revision: WorldRevision,
    pub surface_revision: WorldRevision,
}

impl SurfaceSegment {
    #[must_use]
    pub fn length(&self) -> f32 {
        (self.end - self.start).length()
    }

    #[must_use]
    pub fn is_degenerate(&self) -> bool {
        self.length() <= f32::EPSILON
    }

    #[must_use]
    pub fn semantic_eq(&self, other: &Self) -> bool {
        let mut left = self.clone();
        let mut right = other.clone();
        left.world_revision = WorldRevision::new(0);
        left.surface_revision = WorldRevision::new(0);
        right.world_revision = WorldRevision::new(0);
        right.surface_revision = WorldRevision::new(0);
        left == right
    }
}
