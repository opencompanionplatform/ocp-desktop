use ocp_shared_types::{Point2, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContactKind {
    Surface,
    Boundary,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Contact {
    pub kind: ContactKind,
    pub point: Point2,
    pub normal: Vector2,
    pub surface_id: Option<SurfaceId>,
}
