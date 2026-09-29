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
pub enum WalkDirection {
    Left,
    Right,
}

impl WalkDirection {
    #[must_use]
    pub const fn sign(self) -> f32 {
        match self {
            Self::Left => -1.0,
            Self::Right => 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WalkEdgeBehavior {
    StopAtEdge,
    WalkOff,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct WalkConfig {
    pub speed: f32,
    pub edge_epsilon: f32,
    pub max_step_seconds: f32,
}

impl Default for WalkConfig {
    fn default() -> Self {
        Self {
            speed: 140.0,
            edge_epsilon: 0.5,
            max_step_seconds: 1.0 / 30.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkError {
    BodyNotGrounded,
    SurfaceNotHorizontal { surface_id: SurfaceId },
    SurfaceNotWalkable { surface_id: SurfaceId },
    SurfaceTooNarrow { surface_id: SurfaceId },
}

impl fmt::Display for WalkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BodyNotGrounded => formatter.write_str("body is not grounded"),
            Self::SurfaceNotHorizontal { surface_id } => {
                write!(
                    formatter,
                    "grounded surface is not horizontal: {surface_id:?}"
                )
            }
            Self::SurfaceNotWalkable { surface_id } => {
                write!(
                    formatter,
                    "grounded surface is not walkable: {surface_id:?}"
                )
            }
            Self::SurfaceTooNarrow { surface_id } => {
                write!(
                    formatter,
                    "grounded surface is narrower than the body: \
                     {surface_id:?}"
                )
            }
        }
    }
}

impl std::error::Error for WalkError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WalkStepState {
    Moving,
    StoppedAtEdge,
    WalkedOff,
    SurfaceLost,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct WalkStepResult {
    pub previous_position: Point2,
    pub position: Point2,
    pub velocity: Vector2,
    pub state: WalkStepState,
    pub attachment_transition: AttachmentTransition,
    pub surface_id: SurfaceId,
}

#[derive(Debug, Clone, Copy)]
pub struct WalkMotor {
    config: WalkConfig,
}

impl WalkMotor {
    #[must_use]
    pub const fn new(config: WalkConfig) -> Self {
        Self { config }
    }

    pub fn step(
        &self,
        body: &mut PhysicsBody,
        direction: WalkDirection,
        edge_behavior: WalkEdgeBehavior,
        delta: Duration,
        world: &impl PhysicsWorldQuery,
    ) -> Result<WalkStepResult, WalkError> {
        let attachment = match body.attachment {
            AttachmentState::Grounded { attachment } => attachment,
            _ => return Err(WalkError::BodyNotGrounded),
        };

        let previous_position = body.position;
        let surface_id = attachment.surface_id;

        let Some(surface) = world.surface(surface_id) else {
            body.attachment = AttachmentState::Detached;
            body.velocity = Vector2::new(direction.sign() * self.config.speed, 0.0);

            return Ok(WalkStepResult {
                previous_position,
                position: body.position,
                velocity: body.velocity,
                state: WalkStepState::SurfaceLost,
                attachment_transition: AttachmentTransition::Detached {
                    previous_surface_id: surface_id,
                },
                surface_id,
            });
        };

        self.validate_surface(body, surface)?;

        let dt = delta.as_secs_f32().min(self.config.max_step_seconds);
        let requested_x = body.position.x + direction.sign() * self.config.speed * dt;
        let (minimum_x, maximum_x) = supported_center_range(body, surface);
        let walking_y = surface.start.y - body.collider.half_extents.height;
        let crossed_edge = requested_x < minimum_x - self.config.edge_epsilon
            || requested_x > maximum_x + self.config.edge_epsilon;

        if crossed_edge && edge_behavior == WalkEdgeBehavior::WalkOff {
            body.position = Point2::new(requested_x, walking_y);
            body.velocity = Vector2::new(direction.sign() * self.config.speed, 0.0);
            body.attachment = AttachmentState::Detached;

            return Ok(WalkStepResult {
                previous_position,
                position: body.position,
                velocity: body.velocity,
                state: WalkStepState::WalkedOff,
                attachment_transition: AttachmentTransition::Detached {
                    previous_surface_id: surface.id,
                },
                surface_id: surface.id,
            });
        }

        let next_x = requested_x.clamp(minimum_x, maximum_x);
        let stopped_at_edge = crossed_edge
            || (direction == WalkDirection::Left && next_x <= minimum_x + self.config.edge_epsilon)
            || (direction == WalkDirection::Right
                && next_x >= maximum_x - self.config.edge_epsilon);

        body.position = Point2::new(next_x, walking_y);
        body.velocity = if stopped_at_edge {
            Vector2::ZERO
        } else {
            Vector2::new(direction.sign() * self.config.speed, 0.0)
        };
        body.attachment = AttachmentState::Grounded {
            attachment: SurfaceAttachment {
                surface_id: surface.id,
                anchor: Point2::new(next_x, surface.start.y),
                normal: surface.normal,
            },
        };

        if physics_debug_enabled() && (stopped_at_edge || previous_position != body.position) {
            let stop_reason = if stopped_at_edge {
                match direction {
                    WalkDirection::Left => "left-edge",
                    WalkDirection::Right => "right-edge",
                }
            } else {
                "none"
            };
            eprintln!(
                "[physics-debug] phase=walk body={:?} surface_id={:?}                  direction={:?} previous=({:.1},{:.1}) requested_x={:.1}                  next=({:.1},{:.1}) velocity=({:.1},{:.1})                  constraint=({:.1},{:.1}) half_width={:.1} stop_reason={}",
                body.id,
                surface.id,
                direction,
                previous_position.x,
                previous_position.y,
                requested_x,
                body.position.x,
                body.position.y,
                body.velocity.x,
                body.velocity.y,
                minimum_x,
                maximum_x,
                body.collider.half_extents.width,
                stop_reason,
            );
        }

        Ok(WalkStepResult {
            previous_position,
            position: body.position,
            velocity: body.velocity,
            state: if stopped_at_edge {
                WalkStepState::StoppedAtEdge
            } else {
                WalkStepState::Moving
            },
            attachment_transition: AttachmentTransition::None,
            surface_id: surface.id,
        })
    }

    fn validate_surface(
        &self,
        body: &PhysicsBody,
        surface: PhysicsSurface,
    ) -> Result<(), WalkError> {
        if surface.orientation != Orientation::Horizontal {
            return Err(WalkError::SurfaceNotHorizontal {
                surface_id: surface.id,
            });
        }

        if !surface.capabilities.contains(SurfaceCapabilities::WALKABLE) {
            return Err(WalkError::SurfaceNotWalkable {
                surface_id: surface.id,
            });
        }

        let (minimum_x, maximum_x) = supported_center_range(body, surface);

        if minimum_x > maximum_x {
            return Err(WalkError::SurfaceTooNarrow {
                surface_id: surface.id,
            });
        }

        Ok(())
    }
}

impl Default for WalkMotor {
    fn default() -> Self {
        Self::new(WalkConfig::default())
    }
}

fn supported_center_range(body: &PhysicsBody, surface: PhysicsSurface) -> (f32, f32) {
    let left = surface.start.x.min(surface.end.x);
    let right = surface.start.x.max(surface.end.x);

    (
        left + body.collider.half_extents.width,
        right - body.collider.half_extents.width,
    )
}

fn physics_debug_enabled() -> bool {
    std::env::var("OCP_PHYSICS_DEBUG")
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on" | "full"
            )
        })
}
