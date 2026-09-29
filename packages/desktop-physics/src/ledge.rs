use crate::{
    AttachmentState, AttachmentTransition, PhysicsBody, PhysicsSurface, PhysicsWorldQuery,
    SurfaceAttachment,
};
use ocp_shared_types::{Orientation, Point2, SurfaceCapabilities, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LedgeTransferConfig {
    pub max_horizontal_gap: f32,
    pub max_vertical_gap: f32,
    pub inward_clearance: f32,
}

impl Default for LedgeTransferConfig {
    fn default() -> Self {
        Self {
            max_horizontal_gap: 24.0,
            max_vertical_gap: 12.0,
            inward_clearance: 2.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LedgeTransferError {
    BodyNotHanging,
    SourceSurfaceNotFound { surface_id: SurfaceId },
    SourceSurfaceNotVertical { surface_id: SurfaceId },
    NoLandableLedge { source_surface_id: SurfaceId },
}

impl fmt::Display for LedgeTransferError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BodyNotHanging => formatter.write_str("body is not hanging"),
            Self::SourceSurfaceNotFound { surface_id } => {
                write!(formatter, "source surface not found: {surface_id:?}")
            }
            Self::SourceSurfaceNotVertical { surface_id } => {
                write!(formatter, "source surface is not vertical: {surface_id:?}")
            }
            Self::NoLandableLedge { source_surface_id } => {
                write!(
                    formatter,
                    "no landable ledge found for source surface: \
                     {source_surface_id:?}"
                )
            }
        }
    }
}

impl std::error::Error for LedgeTransferError {}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct LedgeTransferResult {
    pub source_surface_id: SurfaceId,
    pub target_surface_id: SurfaceId,
    pub previous_position: Point2,
    pub position: Point2,
    pub transition: AttachmentTransition,
}

#[derive(Debug, Clone, Copy)]
pub struct LedgeTransferSolver {
    config: LedgeTransferConfig,
}

impl LedgeTransferSolver {
    #[must_use]
    pub const fn new(config: LedgeTransferConfig) -> Self {
        Self { config }
    }

    pub fn transfer_hanging_to_grounded(
        &self,
        body: &mut PhysicsBody,
        world: &impl PhysicsWorldQuery,
    ) -> Result<LedgeTransferResult, LedgeTransferError> {
        let source_attachment = match body.attachment {
            AttachmentState::Hanging { attachment } => attachment,
            _ => return Err(LedgeTransferError::BodyNotHanging),
        };

        let source = world.surface(source_attachment.surface_id).ok_or(
            LedgeTransferError::SourceSurfaceNotFound {
                surface_id: source_attachment.surface_id,
            },
        )?;

        if source.orientation != Orientation::Vertical {
            return Err(LedgeTransferError::SourceSurfaceNotVertical {
                surface_id: source.id,
            });
        }

        let target =
            self.find_target(body, source, world)
                .ok_or(LedgeTransferError::NoLandableLedge {
                    source_surface_id: source.id,
                })?;

        let previous_position = body.position;
        let target_x = self.target_body_x(body, source, target);
        let target_y = target.start.y - body.collider.half_extents.height;

        body.position = Point2::new(target_x, target_y);
        body.velocity = Vector2::ZERO;
        body.attachment = AttachmentState::Grounded {
            attachment: SurfaceAttachment {
                surface_id: target.id,
                anchor: Point2::new(target_x, target.start.y),
                normal: target.normal,
            },
        };

        Ok(LedgeTransferResult {
            source_surface_id: source.id,
            target_surface_id: target.id,
            previous_position,
            position: body.position,
            transition: AttachmentTransition::Grounded {
                surface_id: target.id,
            },
        })
    }

    fn find_target(
        &self,
        body: &PhysicsBody,
        source: PhysicsSurface,
        world: &impl PhysicsWorldQuery,
    ) -> Option<PhysicsSurface> {
        let source_top = source.start.y.min(source.end.y);
        let search_center = Point2::new(source.start.x, source_top);
        let search_extent = self.config.max_horizontal_gap
            + body.collider.half_extents.width
            + self.config.inward_clearance;
        let search_top = Point2::new(
            search_center.x - search_extent,
            search_center.y - self.config.max_vertical_gap,
        );
        let search_bottom = Point2::new(
            search_center.x + search_extent,
            search_center.y + self.config.max_vertical_gap,
        );

        world
            .candidate_surfaces(search_top, search_bottom)
            .into_iter()
            .filter(|surface| {
                surface.orientation == Orientation::Horizontal
                    && surface.capabilities.contains(SurfaceCapabilities::LANDABLE)
                    && surface.normal.y < 0.0
            })
            .filter(|surface| (surface.start.y - source_top).abs() <= self.config.max_vertical_gap)
            .filter(|surface| self.target_x_is_supported(body, source, *surface))
            .min_by(|left, right| {
                let left_score = self.target_score(source, *left);
                let right_score = self.target_score(source, *right);
                left_score.total_cmp(&right_score)
            })
    }

    fn target_x_is_supported(
        &self,
        body: &PhysicsBody,
        source: PhysicsSurface,
        target: PhysicsSurface,
    ) -> bool {
        let left = target.start.x.min(target.end.x);
        let right = target.start.x.max(target.end.x);
        let horizontal_gap = if source.start.x < left {
            left - source.start.x
        } else if source.start.x > right {
            source.start.x - right
        } else {
            0.0
        };

        if horizontal_gap > self.config.max_horizontal_gap {
            return false;
        }

        let target_x = self.target_body_x(body, source, target);
        target_x >= left && target_x <= right
    }

    fn target_body_x(
        &self,
        body: &PhysicsBody,
        source: PhysicsSurface,
        target: PhysicsSurface,
    ) -> f32 {
        let direction = if source.normal.x.abs() > f32::EPSILON {
            source.normal.x.signum()
        } else {
            let target_center = (target.start.x + target.end.x) * 0.5;
            (target_center - source.start.x).signum()
        };

        let requested = source.start.x
            + direction * (body.collider.half_extents.width + self.config.inward_clearance);

        requested.clamp(
            target.start.x.min(target.end.x),
            target.start.x.max(target.end.x),
        )
    }

    fn target_score(&self, source: PhysicsSurface, target: PhysicsSurface) -> f32 {
        let source_top = source.start.y.min(source.end.y);
        let target_left = target.start.x.min(target.end.x);
        let target_right = target.start.x.max(target.end.x);
        let horizontal_gap = if source.start.x < target_left {
            target_left - source.start.x
        } else if source.start.x > target_right {
            source.start.x - target_right
        } else {
            0.0
        };

        horizontal_gap + (target.start.y - source_top).abs()
    }
}

impl Default for LedgeTransferSolver {
    fn default() -> Self {
        Self::new(LedgeTransferConfig::default())
    }
}
