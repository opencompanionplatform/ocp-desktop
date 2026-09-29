use crate::{AabbCollider, AttachmentState};
use ocp_shared_types::{Point2, Vector2};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_BODY_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PhysicsBodyId(pub u64);

impl PhysicsBodyId {
    #[must_use]
    pub fn new() -> Self {
        Self(NEXT_BODY_ID.fetch_add(1, Ordering::Relaxed))
    }
}

impl Default for PhysicsBodyId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhysicsBody {
    pub id: PhysicsBodyId,
    pub position: Point2,
    pub velocity: Vector2,
    pub acceleration: Vector2,
    pub collider: AabbCollider,
    pub mass: f32,
    pub gravity_scale: f32,
    pub attachment: AttachmentState,
}

impl PhysicsBody {
    #[must_use]
    pub fn new(position: Point2, collider: AabbCollider) -> Self {
        Self {
            id: PhysicsBodyId::new(),
            position,
            velocity: Vector2::ZERO,
            acceleration: Vector2::ZERO,
            collider,
            mass: 1.0,
            gravity_scale: 1.0,
            attachment: AttachmentState::Detached,
        }
    }
}
