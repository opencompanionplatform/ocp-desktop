use ocp_shared_types::{Point2, Rect, Size2};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AabbCollider {
    pub half_extents: Size2,
}

impl AabbCollider {
    #[must_use]
    pub const fn new(half_width: f32, half_height: f32) -> Self {
        Self {
            half_extents: Size2::new(half_width, half_height),
        }
    }

    #[must_use]
    pub const fn rect_at(self, position: Point2) -> Rect {
        Rect::new(
            position.x - self.half_extents.width,
            position.y - self.half_extents.height,
            self.half_extents.width * 2.0,
            self.half_extents.height * 2.0,
        )
    }

    #[must_use]
    pub const fn feet_y(self, position: Point2) -> f32 {
        position.y + self.half_extents.height
    }
}

impl Default for AabbCollider {
    fn default() -> Self {
        Self::new(16.0, 24.0)
    }
}
