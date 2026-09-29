//! Canonical Physics values shared by simulation and API layers.

use crate::{Point2, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Velocity(pub Vector2);

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Acceleration(pub Vector2);

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Gravity(pub Vector2);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CollisionKind {
    SurfaceContact,
    Obstacle,
    Boundary,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Collision {
    pub kind: CollisionKind,
    pub position: Point2,
    pub normal: Vector2,
    pub surface_id: Option<SurfaceId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AttachmentPoint {
    pub surface_id: SurfaceId,
    pub local_position: Point2,
    pub normal: Vector2,
}
