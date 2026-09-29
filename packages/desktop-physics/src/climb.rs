use crate::{
    AttachmentState, AttachmentTransition, PhysicsBody, PhysicsSurface, PhysicsWorldQuery,
    SurfaceAttachment,
};
use ocp_shared_types::{Orientation, Point2, SurfaceCapabilities, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClimbDirection {
    Up,
    Down,
}

impl ClimbDirection {
    #[must_use]
    pub const fn sign(self) -> f32 {
        match self {
            Self::Up => -1.0,
            Self::Down => 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ClimbConfig {
    pub speed: f32,
    pub endpoint_epsilon: f32,
    pub max_step_seconds: f32,
}

impl Default for ClimbConfig {
    fn default() -> Self {
        Self {
            speed: 120.0,
            endpoint_epsilon: 0.5,
            max_step_seconds: 1.0 / 30.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentError {
    SurfaceNotFound { surface_id: SurfaceId },
    SurfaceNotVertical { surface_id: SurfaceId },
    SurfaceNotClimbable { surface_id: SurfaceId },
    BodyNotAttached,
    AttachedSurfaceChanged { surface_id: SurfaceId },
}

impl fmt::Display for AttachmentError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SurfaceNotFound { surface_id } => {
                write!(formatter, "surface not found: {surface_id:?}")
            }
            Self::SurfaceNotVertical { surface_id } => {
                write!(formatter, "surface is not vertical: {surface_id:?}")
            }
            Self::SurfaceNotClimbable { surface_id } => {
                write!(formatter, "surface is not climbable: {surface_id:?}")
            }
            Self::BodyNotAttached => formatter.write_str("body is not attached"),
            Self::AttachedSurfaceChanged { surface_id } => {
                write!(
                    formatter,
                    "attached surface is no longer climbable: {surface_id:?}"
                )
            }
        }
    }
}

impl std::error::Error for AttachmentError {}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ClimbStepResult {
    pub previous_position: Point2,
    pub position: Point2,
    pub velocity: Vector2,
    pub transition: AttachmentTransition,
    pub reached_endpoint: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct SurfaceAttachmentSolver {
    config: ClimbConfig,
}

impl SurfaceAttachmentSolver {
    #[must_use]
    pub const fn new(config: ClimbConfig) -> Self {
        Self { config }
    }

    pub fn attach_to_vertical_surface(
        &self,
        body: &mut PhysicsBody,
        surface_id: SurfaceId,
        requested_anchor_y: f32,
        world: &impl PhysicsWorldQuery,
    ) -> Result<AttachmentTransition, AttachmentError> {
        let surface = required_vertical_surface(surface_id, world)?;
        let (top, bottom) = vertical_range(surface);
        let anchor_y = requested_anchor_y.clamp(top, bottom);
        let body_x = attached_body_x(body, surface);

        body.position = Point2::new(body_x, anchor_y);
        body.velocity = Vector2::ZERO;
        body.attachment = AttachmentState::Attached {
            attachment: SurfaceAttachment {
                surface_id,
                anchor: Point2::new(surface.start.x, anchor_y),
                normal: surface.normal,
            },
        };

        Ok(AttachmentTransition::Attached { surface_id })
    }

    pub fn climb(
        &self,
        body: &mut PhysicsBody,
        direction: ClimbDirection,
        delta: Duration,
        world: &impl PhysicsWorldQuery,
    ) -> Result<ClimbStepResult, AttachmentError> {
        let previous_position = body.position;
        let attachment = body
            .attachment
            .attachment()
            .ok_or(AttachmentError::BodyNotAttached)?;

        if !matches!(
            body.attachment,
            AttachmentState::Attached { .. } | AttachmentState::Hanging { .. }
        ) {
            return Err(AttachmentError::BodyNotAttached);
        }

        let surface = required_vertical_surface(attachment.surface_id, world).map_err(|_| {
            AttachmentError::AttachedSurfaceChanged {
                surface_id: attachment.surface_id,
            }
        })?;

        let dt = delta.as_secs_f32().min(self.config.max_step_seconds);
        let requested_y = body.position.y + direction.sign() * self.config.speed * dt;
        let (top, bottom) = vertical_range(surface);
        let next_y = requested_y.clamp(top, bottom);
        let reached_top =
            direction == ClimbDirection::Up && next_y <= top + self.config.endpoint_epsilon;
        let reached_bottom =
            direction == ClimbDirection::Down && next_y >= bottom - self.config.endpoint_epsilon;
        let reached_endpoint = reached_top || reached_bottom;

        body.position = Point2::new(attached_body_x(body, surface), next_y);
        body.velocity = Vector2::new(0.0, direction.sign() * self.config.speed);

        if reached_endpoint {
            body.velocity = Vector2::ZERO;
        }

        let transition = if reached_top
            && surface.capabilities.contains(SurfaceCapabilities::HANGABLE)
        {
            body.attachment = AttachmentState::Hanging {
                attachment: SurfaceAttachment {
                    surface_id: surface.id,
                    anchor: Point2::new(surface.start.x, top),
                    normal: surface.normal,
                },
            };
            AttachmentTransition::Hanging {
                surface_id: surface.id,
            }
        } else if reached_bottom {
            if let Some(ground) =
                supported_ground_at_climb_bottom(body, next_y, world, self.config.endpoint_epsilon)
            {
                let ground_y = ground.start.y;
                let ground_left = ground.start.x.min(ground.end.x);
                let ground_right = ground.start.x.max(ground.end.x);
                let center_x = body.position.x.clamp(
                    ground_left + body.collider.half_extents.width,
                    ground_right - body.collider.half_extents.width,
                );
                body.position = Point2::new(center_x, ground_y - body.collider.half_extents.height);
                body.attachment = AttachmentState::Grounded {
                    attachment: SurfaceAttachment {
                        surface_id: ground.id,
                        anchor: Point2::new(center_x, ground_y),
                        normal: ground.normal,
                    },
                };
                AttachmentTransition::Grounded {
                    surface_id: ground.id,
                }
            } else {
                body.attachment = AttachmentState::Attached {
                    attachment: SurfaceAttachment {
                        surface_id: surface.id,
                        anchor: Point2::new(surface.start.x, next_y),
                        normal: surface.normal,
                    },
                };
                AttachmentTransition::None
            }
        } else {
            body.attachment = AttachmentState::Attached {
                attachment: SurfaceAttachment {
                    surface_id: surface.id,
                    anchor: Point2::new(surface.start.x, next_y),
                    normal: surface.normal,
                },
            };
            AttachmentTransition::None
        };

        Ok(ClimbStepResult {
            previous_position,
            position: body.position,
            velocity: body.velocity,
            transition,
            reached_endpoint,
        })
    }

    pub fn detach(&self, body: &mut PhysicsBody) -> AttachmentTransition {
        let Some(surface_id) = body.attachment.surface_id() else {
            return AttachmentTransition::None;
        };

        body.attachment = AttachmentState::Detached;
        body.velocity = Vector2::ZERO;

        AttachmentTransition::Detached {
            previous_surface_id: surface_id,
        }
    }
}

fn supported_ground_at_climb_bottom(
    body: &PhysicsBody,
    junction_y: f32,
    world: &impl PhysicsWorldQuery,
    endpoint_epsilon: f32,
) -> Option<PhysicsSurface> {
    let half_width = body.collider.half_extents.width;
    let epsilon = endpoint_epsilon.max(1.0);
    // Desktop monitor edges and their floor are character-independent surfaces
    // that meet at the same geometric endpoint. The body center reaches that
    // junction while climbing; its feet are intentionally still half a collider
    // below it until we transfer the body onto the horizontal support.
    let search_from = Point2::new(body.position.x - half_width, junction_y - epsilon);
    let search_to = Point2::new(body.position.x + half_width, junction_y + epsilon);

    world
        .candidate_surfaces(search_from, search_to)
        .into_iter()
        .filter(|candidate| {
            candidate.orientation == Orientation::Horizontal
                && candidate
                    .capabilities
                    .contains(SurfaceCapabilities::LANDABLE)
                && candidate.normal.y < 0.0
                && (candidate.start.y - junction_y).abs() <= epsilon
        })
        .filter(|candidate| {
            let supported_left = candidate.start.x.min(candidate.end.x) + half_width;
            let supported_right = candidate.start.x.max(candidate.end.x) - half_width;
            supported_left <= supported_right
                && body.position.x >= supported_left - epsilon
                && body.position.x <= supported_right + epsilon
        })
        .min_by(|left, right| {
            (left.start.y - junction_y)
                .abs()
                .total_cmp(&(right.start.y - junction_y).abs())
        })
}

impl Default for SurfaceAttachmentSolver {
    fn default() -> Self {
        Self::new(ClimbConfig::default())
    }
}

fn required_vertical_surface(
    surface_id: SurfaceId,
    world: &impl PhysicsWorldQuery,
) -> Result<PhysicsSurface, AttachmentError> {
    let surface = world
        .surface(surface_id)
        .ok_or(AttachmentError::SurfaceNotFound { surface_id })?;

    if surface.orientation != Orientation::Vertical {
        return Err(AttachmentError::SurfaceNotVertical { surface_id });
    }

    if !surface
        .capabilities
        .contains(SurfaceCapabilities::CLIMBABLE)
    {
        return Err(AttachmentError::SurfaceNotClimbable { surface_id });
    }

    Ok(surface)
}

fn vertical_range(surface: PhysicsSurface) -> (f32, f32) {
    (
        surface.start.y.min(surface.end.y),
        surface.start.y.max(surface.end.y),
    )
}

fn attached_body_x(body: &PhysicsBody, surface: PhysicsSurface) -> f32 {
    let offset = if surface.normal.x.abs() > f32::EPSILON {
        surface.normal.x * body.collider.half_extents.width
    } else {
        0.0
    };

    surface.start.x + offset
}
